"""路线回放引擎：把「路线 + 速度 + 循环模式」变成随时间推进的坐标流。

设计要点：
* 纯逻辑、无 IO，时钟可注入，可完全确定性地单元测试。
* tick() 由上层定时器调用；未在播放时只刷新时间基准，不产生坐标。
* loop=pingpong 时到终点反向，direction 表达当前行进方向。
"""

from __future__ import annotations

import math
import time
from typing import Callable, Optional

from .. import config
from .route import Route
from .speed import SpeedModel

STATE_IDLE = "idle"
STATE_PLAYING = "playing"
STATE_PAUSED = "paused"
STATE_FINISHED = "finished"

LOOP_NONE = "none"
LOOP_REPEAT = "loop"
LOOP_PINGPONG = "pingpong"
LOOP_MODES = (LOOP_NONE, LOOP_REPEAT, LOOP_PINGPONG)


class PlaybackError(RuntimeError):
    """回放状态或参数非法。"""


class Playback:
    def __init__(self, clock: Optional[Callable[[], float]] = None) -> None:
        self._clock = clock or time.monotonic
        self.route: Optional[Route] = None
        self.speed = 0.0
        self.speed_model: Optional[SpeedModel] = None
        self.loop = LOOP_NONE
        self.state = STATE_IDLE
        self.distance = 0.0
        self.direction = 1
        self._last_tick: Optional[float] = None
        self._elapsed = 0.0

    # --- 装载与状态切换 ------------------------------------------------
    @staticmethod
    def validate_speed(speed: float) -> float:
        try:
            value = float(speed)
        except (TypeError, ValueError):
            raise PlaybackError("速度必须是有限的正数")
        if not math.isfinite(value) or value <= 0:
            raise PlaybackError("速度必须是有限的正数")
        low, high = config.MIN_SPEED, config.MAX_SPEED
        if not low <= value <= high:
            raise PlaybackError("速度超出允许范围 %.1f–%.1f m/s" % (low, high))
        return value

    def load(self, route: Route, speed: float, loop: str = LOOP_NONE,
             speed_model: Optional[SpeedModel] = None) -> None:
        if route is None or not route.geometry:
            raise PlaybackError("路线为空，无法装载")
        speed = self.validate_speed(speed)
        if loop not in LOOP_MODES:
            raise PlaybackError("未知循环模式: %r" % (loop,))
        self.route = route
        self.speed = float(speed)
        self.speed_model = speed_model
        self.loop = loop
        self.distance = 0.0
        self.direction = 1
        self.state = STATE_IDLE
        self._last_tick = None
        self._elapsed = 0.0

    def set_base_speed(self, speed: float) -> float:
        """手动覆盖基准速度（保留随机参数）。"""
        value = self.validate_speed(speed)
        self.speed = value
        if self.speed_model is not None:
            self.speed_model.rebase(value)
        return value

    def start(self) -> dict:
        if self.route is None:
            raise PlaybackError("尚未装载路线")
        self.validate_speed(self.speed)
        if self.state == STATE_FINISHED:
            # 跑完再 start 应当从头重播（修复 LP-11）
            self.distance = 0.0
            self.direction = 1
            self._elapsed = 0.0
            if self.speed_model is not None:
                self.speed_model.reset()
        self.state = STATE_PLAYING
        self._last_tick = self._clock()
        return self.status()

    def pause(self) -> dict:
        if self.state == STATE_PLAYING:
            self.state = STATE_PAUSED
        self._last_tick = None
        return self.status()

    def resume(self) -> dict:
        if self.state == STATE_PAUSED:
            self.state = STATE_PLAYING
            self._last_tick = self._clock()
        return self.status()

    def stop(self, keep_distance: bool = False) -> dict:
        """停止回放。

        keep_distance=True 时保留当前位置/进度：设备停在最后走到的地方，
        再次 start 会从当前位置继续（路线模式「停止」用这个语义）。
        默认 False 用于断开/重新装载等需要归零的场景。
        """
        self.state = STATE_IDLE
        if not keep_distance:
            self.distance = 0.0
            self.direction = 1
            self._elapsed = 0.0
            if self.speed_model is not None:
                self.speed_model.reset()
        self._last_tick = None
        return self.status()

    # --- 推进 ----------------------------------------------------------
    def tick(self, now: Optional[float] = None) -> Optional[dict]:
        """按真实时间推进；返回新位置或 None。"""
        now = self._clock() if now is None else now
        if self.state != STATE_PLAYING:
            self._last_tick = now
            return None
        last = self._last_tick if self._last_tick is not None else now
        dt = max(0.0, now - last)
        self._last_tick = now
        return self.advance(dt)

    def advance(self, dt: float) -> Optional[dict]:
        """按给定步长推进（确定性，供测试直接调用）。"""
        if self.state != STATE_PLAYING or self.route is None:
            return None
        dt = float(dt)
        if not math.isfinite(dt):
            raise PlaybackError("时间步长必须是有限数字")
        dt = max(0.0, dt)
        self._elapsed += dt
        total = self.route.distance
        if total <= 0:
            self.state = STATE_FINISHED
            return self._position(total)
        if dt == 0:
            return self._position(self.distance)
        speed = self.speed_model.speed_at(dt) if self.speed_model is not None else self.speed
        travel = speed * dt
        if self.loop == LOOP_PINGPONG:
            phase = self.distance if self.direction > 0 else 2 * total - self.distance
            phase = (phase + travel) % (2 * total)
            self.distance = phase if phase < total else 2 * total - phase
            self.direction = 1 if phase < total else -1
        elif self.loop == LOOP_REPEAT:
            self.distance = (self.distance + travel) % total
        else:
            self.distance = min(total, self.distance + travel)
            if self.distance >= total:
                self.state = STATE_FINISHED
        return self._position(self.distance)

    def _position(self, distance: float) -> Optional[dict]:
        if self.route is None:
            return None
        pos = self.route.position_at(distance)
        if pos is None:
            return None
        pos["speed"] = self.speed_model.current if self.speed_model is not None else self.speed
        pos["direction"] = self.direction
        return pos

    # --- 状态输出 ------------------------------------------------------
    def status(self) -> dict:
        total = self.route.distance if self.route else 0.0
        remaining = max(0.0, total - self.distance)
        if self.speed_model is not None:
            current = self.speed_model.current
            base = self.speed_model.base
            mode = self.speed_model.mode
            jitter = self.speed_model.jitter
        else:
            current = self.speed
            base = self.speed
            mode = getattr(self.route, "mode", None) if self.route else None
            jitter = 0.0
        return {
            "state": self.state,
            "loop": self.loop,
            "speed": round(current, 4),
            "speed_base": round(base, 4),
            "mode": mode,
            "jitter": round(jitter, 4),
            "distance": round(self.distance, 3),
            "total_distance": round(total, 3),
            "remaining_distance": round(remaining, 3),
            "progress": round(self.distance / total, 6) if total > 0 else 0.0,
            "eta_seconds": round(remaining / base, 1) if base > 0 else None,
            "direction": self.direction,
            "route_name": getattr(self.route, "name", None),
        }

    @property
    def playing(self) -> bool:
        return self.state == STATE_PLAYING
