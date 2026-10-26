"""高德路线服务（中国大陆）。

要点（均已用真 Key 实测，见 docs/route-mode-design.md 第 3.1 节）：

* 路径规划 2.0 的 v5 接口：`/v5/direction/{driving,walking,bicycling,electrobike}`；
* 必须传 `show_fields=polyline,cost`，否则拿不到折线和耗时；
* 折线在 `route.paths[].steps[].polyline`，格式 `lon,lat;lon,lat`；
* 耗时字段不统一：驾车/步行在 `cost.duration`，骑行/电动车在 `path.duration`；
* 输入按 GCJ-02 解释、输出也是 GCJ-02，所以进出都要转换；
* 只有驾车支持途经点，步行/骑行/电动车带 waypoints 会返回 21002 → 由上层逐段规划。
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from typing import List, Optional

from ... import config
from .. import coord
from .base import Point, RoutingError, RoutingProvider, SegmentResult, to_float

BASE_URL = "https://restapi.amap.com/v5/direction"

PROFILES = {
    "walk": "walking",
    "run": "walking",
    "cycle": "bicycling",
    "ebike": "electrobike",
    "drive": "driving",
    "highway": "driving",
}


def _ll(point: Point) -> str:
    return "%.6f,%.6f" % (point[1], point[0])  # 高德要求 lon,lat


def _http_get_json(url: str, timeout: Optional[float] = None):
    request = urllib.request.Request(url, headers={"User-Agent": config.HTTP_USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout or max(config.HTTP_TIMEOUT, 10.0)) as response:
        return json.loads(response.read().decode("utf-8"))


def _map_error(info: str, code: str) -> RoutingError:
    if code == "10001":
        return RoutingError("高德 Key 无效", retryable=False, code=code, provider="amap")
    if code == "10012":
        return RoutingError("高德 Key 没有海外权限", retryable=False, code=code, provider="amap")
    if code in ("10003", "10004"):
        return RoutingError("高德配额或频率受限：%s" % (info or code), retryable=True, code=code, provider="amap")
    if code == "20803":
        return RoutingError("路线超过高德距离上限", retryable=False, code=code, provider="amap")
    if code == "21002":
        return RoutingError("高德该方式不支持途经点", retryable=False, code=code, provider="amap")
    return RoutingError("高德规划失败：%s" % (info or code or "未知错误"),
                        retryable=True, code=code or None, provider="amap")


class AMapProvider(RoutingProvider):
    name = "amap"

    def __init__(self, settings: Optional[dict] = None, get_json=None) -> None:
        self.settings = dict(settings or {})
        self._get_json = get_json or _http_get_json

    def key(self) -> str:
        return str(self.settings.get("amap_key") or "").strip()

    def available(self) -> bool:
        return bool(self.key())

    def plan_segment(self, start: Point, end: Point, mode: str) -> SegmentResult:
        key = self.key()
        if not key:
            raise RoutingError("未配置高德 Key", retryable=False, code="no_key", provider=self.name)
        profile = PROFILES.get(mode)
        if profile is None:
            raise RoutingError("高德不支持该交通方式：%s" % mode, retryable=False, code="bad_mode", provider=self.name)

        origin = coord.wgs84_to_gcj02(float(start[0]), float(start[1]))
        destination = coord.wgs84_to_gcj02(float(end[0]), float(end[1]))
        params = {
            "key": key,
            "origin": _ll(origin),
            "destination": _ll(destination),
            "show_fields": "polyline,cost",
        }
        url = "%s/%s?%s" % (BASE_URL, profile, urllib.parse.urlencode(params, safe=",;"))
        try:
            payload = self._get_json(url)
        except RoutingError:
            raise
        except Exception as exc:
            raise RoutingError("高德请求失败：%s" % (exc,), retryable=True, provider=self.name)

        if str(payload.get("status")) != "1":
            info = str(payload.get("info") or "")
            code = str(payload.get("infocode") or "")
            raise _map_error(info, code)

        paths = (payload.get("route") or {}).get("paths") or []
        if not paths:
            raise RoutingError("高德未返回路线", retryable=True, code="20802", provider=self.name)
        path = paths[0]

        geometry: List[Point] = []
        for step in path.get("steps") or []:
            for chunk in str(step.get("polyline") or "").split(";"):
                chunk = chunk.strip()
                if not chunk:
                    continue
                try:
                    lon_text, lat_text = chunk.split(",")
                    lat, lon = coord.gcj02_to_wgs84(float(lat_text), float(lon_text))
                except (ValueError, TypeError):
                    continue
                geometry.append((lat, lon))
        if not geometry:
            raise RoutingError("高德返回几何为空", retryable=True, code="empty_geometry", provider=self.name)

        duration = to_float(path.get("duration"))
        if duration is None:
            duration = to_float((path.get("cost") or {}).get("duration"))
        distance = to_float(path.get("distance")) or 0.0
        return SegmentResult(geometry=geometry, distance=distance, duration=duration)
