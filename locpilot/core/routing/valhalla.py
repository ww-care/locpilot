"""Valhalla 路线服务（境外，公共 demo，免 Key）。

要点（均已实测）：

* 真正按方式规划：`costing` 支持 `auto` / `bicycle` / `pedestrian`，几何确实不同；
* 返回 `trip.legs[0].shape` 为 polyline6（1e6 精度、lat/lon 顺序）；
* `summary.length` 在 units=kilometers 时是 km，需要换算成米；
* 错误：`154` 超最大距离（1,500 km，不可重试）、`171` 无可用道路（可重试）、429 限流。
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import List, Optional

from ... import config
from .base import Point, RoutingError, RoutingProvider, SegmentResult, decode_polyline6, to_float

COSTINGS = {
    "walk": "pedestrian",
    "run": "pedestrian",
    "cycle": "bicycle",
    "ebike": "bicycle",
    "drive": "auto",
    "highway": "auto",
}


def _http_post_json(url: str, payload: dict, timeout: Optional[float] = None):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "User-Agent": config.HTTP_USER_AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout or max(config.HTTP_TIMEOUT, 10.0)) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            info = json.loads(body)
        except ValueError:
            info = {}
        code = str(info.get("error_code") or exc.code)
        message = info.get("error") or ("HTTP %s" % exc.code)
        if code == "154":
            raise RoutingError("路线超过路线服务最大距离上限（约 1500 km）",
                               retryable=False, code=code, provider="valhalla")
        raise RoutingError("Valhalla 规划失败：%s" % message,
                           retryable=True, code=code, provider="valhalla")
    except RoutingError:
        raise
    except Exception as exc:
        raise RoutingError("Valhalla 请求失败：%s" % (exc,), retryable=True, provider="valhalla")


class ValhallaProvider(RoutingProvider):
    name = "valhalla"

    def __init__(self, settings: Optional[dict] = None, post_json=None) -> None:
        self.settings = dict(settings or {})
        self._post_json = post_json or _http_post_json
        self.url = str(self.settings.get("valhalla_url") or config.VALHALLA_URL).rstrip("/")

    def available(self) -> bool:
        return True

    def plan_segment(self, start: Point, end: Point, mode: str) -> SegmentResult:
        costing = COSTINGS.get(mode)
        if costing is None:
            raise RoutingError("Valhalla 不支持该交通方式：%s" % mode,
                               retryable=False, code="bad_mode", provider=self.name)
        payload = {
            "locations": [
                {"lat": float(start[0]), "lon": float(start[1])},
                {"lat": float(end[0]), "lon": float(end[1])},
            ],
            "costing": costing,
            "units": "kilometers",
        }
        data = self._post_json(self.url + "/route", payload)
        legs = (data.get("trip") or {}).get("legs") or []
        if not legs:
            raise RoutingError("Valhalla 未返回路线", retryable=True, code="no_route", provider=self.name)
        leg = legs[0]
        summary = leg.get("summary") or {}
        geometry: List[Point] = decode_polyline6(str(leg.get("shape") or ""))
        if not geometry:
            raise RoutingError("Valhalla 返回几何为空", retryable=True, code="empty_geometry", provider=self.name)
        distance = (to_float(summary.get("length")) or 0.0) * 1000.0
        duration = to_float(summary.get("time"))
        return SegmentResult(geometry=geometry, distance=distance, duration=duration)
