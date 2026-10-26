"""pymobiledevice3 常驻定位工作进程（stdin/stdout JSON Lines 协议）。

为什么需要常驻进程：pymobiledevice3 的 CLI set 在设置坐标后会阻塞等待 SIGINT，
每次改坐标都重启进程会反复建立 tunnel / DTX 连接（iOS 17+ 上是秒级开销）；
本进程只建一次会话，之后按行接收坐标，实现亚秒级连续移动。

协议（stdin 一行一个 JSON，stdout 一一对应）：
  {"id":1,"cmd":"open","udid":"...","rsd":["host",port],"tunnel":"UDID","mount":true}
  {"id":2,"cmd":"set","lat":31.2,"lon":121.4}
  {"id":3,"cmd":"clear"}
  {"id":4,"cmd":"ping"}
  {"id":5,"cmd":"close"}
响应：{"id":n,"ok":true,"detail":{...}} 或 {"id":n,"ok":false,"error":"..."}

该文件必须能被 venv 里的 python 直接执行；除 pymobiledevice3 外只依赖标准库。
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import threading
import time
import traceback
from contextlib import AsyncExitStack

PROTOCOL_VERSION = 1


class Session:
    """持有 lockdown/RSD 与定位服务。

    iOS 17+ 的 DVT 定位通道在长时间闲置后会静默失效（set 仍返回成功但设备不更新）。
    因此每次下发前检查闲置时长，超过 TTL 就重建定位通道；RSD/lockdown 保持不动。
    """

    def __init__(self) -> None:
        self.stack = AsyncExitStack()
        self.location_stack = AsyncExitStack()
        self.lockdown = None
        self.provider = None
        self.simulation = None
        self.mode = None
        self.product_version = None
        self.udid = None
        self.detail = {}
        self.refresh_ttl = 120.0
        self.refreshes = 0
        self._last_location = 0.0

    async def open(self, udid=None, rsd=None, tunnel=None, mount=False, ttl: float = 120.0) -> dict:
        await self.close()
        from pymobiledevice3.lockdown import create_using_usbmux

        self.lockdown = await create_using_usbmux(serial=udid, autopair=False)
        self.product_version = await self._product_version(self.lockdown)
        self.udid = getattr(self.lockdown, "identifier", None) or udid
        self.refresh_ttl = max(0.0, float(ttl or 0.0))
        major = self._major(self.product_version)

        if mount:
            self.detail["mount"] = await self._auto_mount()

        if major is not None and major >= 17:
            provider = await self._rsd_provider(udid, rsd=rsd, tunnel=tunnel)
            self.provider = provider
            closer = getattr(provider, "close", None)
            if callable(closer):
                self.detail["rsd_closer"] = type(provider).__name__
                self.stack.push_async_callback(closer)

        await self._open_location(major)
        self._last_location = time.monotonic()
        self.detail.update({
            "mode": self.mode,
            "product_version": self.product_version,
            "udid": self.udid,
            "refresh_ttl": self.refresh_ttl,
        })
        return dict(self.detail)

    async def _open_location(self, major) -> None:
        if major is not None and major >= 17:
            if self.provider is None:
                raise RuntimeError("RSD 会话尚未建立")
            from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
            from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

            dvt = await self._enter(DvtProvider(self.provider))
            self.simulation = await self._enter(LocationSimulation(dvt))
            self.mode = "dvt"
        else:
            from pymobiledevice3.services.simulate_location import DtSimulateLocation

            self.simulation = await self._enter(DtSimulateLocation(self.lockdown))
            self.mode = "legacy"

    def _should_refresh(self) -> bool:
        if self.refresh_ttl <= 0 or self._last_location <= 0:
            return False
        return (time.monotonic() - self._last_location) >= self.refresh_ttl

    async def refresh(self) -> dict:
        """重建定位通道（保留 RSD/lockdown），用于闲置后唤醒。"""
        if self.lockdown is None:
            raise RuntimeError("会话尚未打开")
        try:
            await self.location_stack.aclose()
        except Exception:
            pass
        self.location_stack = AsyncExitStack()
        self.simulation = None
        await self._open_location(self._major(self.product_version))
        self.refreshes += 1
        self._last_location = time.monotonic()
        self.detail["refreshes"] = self.refreshes
        return {"mode": self.mode, "refreshes": self.refreshes}

    async def set(self, lat: float, lon: float) -> dict:
        if self.simulation is None:
            raise RuntimeError("会话尚未打开")
        if self._should_refresh():
            await self.refresh()
        await self.simulation.set(float(lat), float(lon))
        self._last_location = time.monotonic()
        return {"mode": self.mode, "lat": float(lat), "lon": float(lon), "refreshes": self.refreshes}

    async def clear(self) -> dict:
        if self.simulation is None:
            raise RuntimeError("会话尚未打开")
        if self._should_refresh():
            await self.refresh()
        await self.simulation.clear()
        self._last_location = time.monotonic()
        return {"mode": self.mode, "cleared": True, "refreshes": self.refreshes}

    async def close(self) -> None:
        try:
            await self.location_stack.aclose()
        except Exception:
            pass
        self.location_stack = AsyncExitStack()
        try:
            await self.stack.aclose()
        except Exception:
            pass
        self.stack = AsyncExitStack()
        if self.lockdown is not None:
            closer = getattr(self.lockdown, "close", None)
            if callable(closer):
                await closer()
        self.simulation = None
        self.provider = None
        self.lockdown = None
        self.mode = None
        self.refreshes = 0
        self._last_location = 0.0
        self.detail = {}

    # --- 内部 ----------------------------------------------------------
    async def _enter(self, obj):
        """兼容有/无 __aenter__ 的服务对象。"""
        if hasattr(obj, "__aenter__"):
            return await self.location_stack.enter_async_context(obj)
        return obj

    @staticmethod
    def _major(version):
        if not version:
            return None
        try:
            return int(str(version).split(".", 1)[0])
        except ValueError:
            return None

    @staticmethod
    async def _product_version(lockdown):
        info = getattr(lockdown, "short_info", None)
        if isinstance(info, dict) and info.get("ProductVersion"):
            return str(info["ProductVersion"])
        value = getattr(lockdown, "product_version", None)
        if value:
            return str(value)
        try:
            value = await lockdown.get_value(key="ProductVersion")
            if value:
                return str(value)
        except Exception:
            pass
        return None

    async def _rsd_provider(self, udid, rsd=None, tunnel=None):
        """iOS 17+ 需要 RSD：显式 --rsd / tunneld / 无 root 用户态隧道，三级降级。"""
        if rsd:
            from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService

            service = RemoteServiceDiscoveryService(tuple(rsd))
            await service.connect()
            return service
        if tunnel:
            from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid

            return await get_tunneld_device_by_udid(tunnel)
        try:
            from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid

            return await get_tunneld_device_by_udid(self.udid or udid or "")
        except Exception as exc:
            self.detail["tunneld_error"] = str(exc)[:200]
        from pymobiledevice3.remote.userspace_tunnel import establish_userspace_rsd

        try:
            return await establish_userspace_rsd(serial=self.udid or udid)
        except Exception as exc:
            raise RuntimeError(
                "iOS 17+ 需要 RSD 隧道，且自动建立失败(%s)。请先运行: sudo pymobiledevice3 remote tunneld，"
                "或使用 --rsd HOST PORT 指定隧道" % (exc,)
            )

    @staticmethod
    async def _auto_mount() -> str:
        """best-effort 挂载 Developer Disk Image；失败只记录不阻断。"""
        try:
            proc = await asyncio.create_subprocess_exec(
                sys.executable, "-m", "pymobiledevice3", "mounter", "auto-mount",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=90)
            return (out or b"").decode("utf-8", "replace").strip()[-300:]
        except Exception as exc:
            return "auto-mount 失败: %s" % (exc,)


class Bridge:
    """把阻塞的 stdin 读取与 asyncio 事件循环桥接起来。"""

    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run, name="locpilot-pmd3-loop", daemon=True)
        self.thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def call(self, coro, timeout: float):
        future = asyncio.run_coroutine_threadsafe(coro, self.loop)
        return future.result(timeout)

    def shutdown(self) -> None:
        self.loop.call_soon_threadsafe(self.loop.stop)


def handle(bridge: Bridge, session: Session, message: dict) -> dict:
    cmd = message.get("cmd")
    if cmd == "ping":
        return {"protocol": PROTOCOL_VERSION, "pid": None}
    if cmd == "open":
        return bridge.call(
            session.open(
                udid=message.get("udid"),
                rsd=message.get("rsd"),
                tunnel=message.get("tunnel"),
                mount=bool(message.get("mount")),
                ttl=float(message.get("ttl") or 120.0),
            ),
            timeout=float(message.get("timeout") or 120.0),
        )
    if cmd == "set":
        return bridge.call(session.set(message.get("lat"), message.get("lon")), timeout=float(message.get("timeout") or 20.0))
    if cmd == "clear":
        return bridge.call(session.clear(), timeout=float(message.get("timeout") or 20.0))
    if cmd == "refresh":
        return bridge.call(session.refresh(), timeout=float(message.get("timeout") or 20.0))
    if cmd == "close":
        bridge.call(session.close(), timeout=20.0)
        return {"closed": True}
    raise ValueError("未知命令: %r" % (cmd,))


def main() -> int:
    bridge = Bridge()
    session = Session()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError as exc:
            print(json.dumps({"id": None, "ok": False, "error": "JSON 解析失败: %s" % (exc,)}), flush=True)
            continue
        try:
            detail = handle(bridge, session, message)
            print(json.dumps({"id": message.get("id"), "ok": True, "detail": detail}, ensure_ascii=False), flush=True)
        except Exception as exc:  # 单条命令失败不能杀死常驻进程
            print(
                json.dumps(
                    {"id": message.get("id"), "ok": False, "error": "%s: %s" % (type(exc).__name__, exc), "trace": traceback.format_exc()[-800:]},
                    ensure_ascii=False,
                ),
                flush=True,
            )
        if message.get("cmd") == "close":  # 正常关闭也要退出，否则父进程 terminate 前会挂住
            break
    try:
        bridge.call(session.close(), timeout=10.0)
    except Exception:
        pass
    bridge.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
