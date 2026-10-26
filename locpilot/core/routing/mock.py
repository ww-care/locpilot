"""测试与离线用的假路线服务：两点之间画直线。"""

from __future__ import annotations

from typing import Optional

from ... import config
from .. import geo
from .base import Point, RoutingProvider, SegmentResult


class MockProvider(RoutingProvider):
    name = "mock"

    def __init__(self, settings: Optional[dict] = None) -> None:
        self.settings = dict(settings or {})

    def available(self) -> bool:
        return True

    def plan_segment(self, start: Point, end: Point, mode: str) -> SegmentResult:
        distance = geo.haversine(start, end)
        speed = float(config.SPEED_PRESETS.get(mode, 1.3))
        return SegmentResult(
            geometry=[(float(start[0]), float(start[1])), (float(end[0]), float(end[1]))],
            distance=distance,
            duration=distance / speed if speed > 0 else None,
        )
