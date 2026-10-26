"""路线编排：区域选择 provider → 逐段规划 → 拼接 → 加密 → 汇总。

设计要点：

* **按整条路线选 provider**：所有点都在中国大陆 → 高德，否则 → Valhalla。
  不做逐段混合，避免"一段 GCJ、一段 WGS"的坐标拼接风险。
* **逐段串行**：高德步行/骑行/电动车不支持途经点，统一两两规划最稳；
  最多 7 个点 → 最多 6 次调用，由上层做防抖与缓存。
* **不做静默降级**：provider 失败就抛 `RoutingError`，由 API/UI 决定重试。
* 里程以拼接后的几何累计为准（沿用"不能信 provider 的 distance 做进度"的教训）。
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence

from ... import config
from .. import geo, regions
from .amap import AMapProvider
from .base import Point, RoutePlan, RoutingError, RoutingProvider, SegmentResult, geometry_distance, stitch
from .mock import MockProvider
from .valhalla import ValhallaProvider

PROVIDER_CHOICES = ("auto", "amap", "valhalla", "mock")


class RoutingService:
    def __init__(self, settings: Optional[dict] = None,
                 providers: Optional[Dict[str, RoutingProvider]] = None,
                 densify_step: Optional[float] = None) -> None:
        self.settings = dict(settings or {})
        self.providers: Dict[str, RoutingProvider] = providers or {
            "amap": AMapProvider(self.settings),
            "valhalla": ValhallaProvider(self.settings),
            "mock": MockProvider(),
        }
        self.densify_step = config.DENSIFY_STEP_M if densify_step is None else float(densify_step)

    def provider_for(self, points: Sequence[Sequence[float]], provider: str = "auto") -> RoutingProvider:
        chosen = str(provider or "auto").strip().lower()
        if chosen not in PROVIDER_CHOICES:
            raise RoutingError("未知路线服务：%s" % provider, retryable=False, code="bad_provider")
        if chosen == "auto":
            configured = str(self.settings.get("routing_provider") or "auto").strip().lower()
            if configured in ("amap", "valhalla", "mock"):
                chosen = configured
            else:
                chosen = "amap" if regions.route_region(points) == "china" else "valhalla"
        impl = self.providers.get(chosen)
        if impl is None:
            raise RoutingError("路线服务未配置：%s" % chosen,
                               retryable=False, code="no_provider", provider=chosen)
        return impl

    def plan(self, points: Sequence[Sequence[float]], mode: str = "walk",
             provider: str = "auto") -> RoutePlan:
        if mode not in config.MODE_PROFILES:
            raise RoutingError("未知交通方式：%s" % mode, retryable=False, code="bad_mode")
        try:
            pts = [geo.validate_point(point) for point in points]
        except Exception as exc:
            raise RoutingError("坐标非法：%s" % (exc,), retryable=False, code="bad_point")
        if len(pts) < 2:
            raise RoutingError("路线至少需要两个点", retryable=False, code="short_route")

        chosen = self.provider_for(pts, provider)
        segments: List[SegmentResult] = []
        for start, end in zip(pts, pts[1:]):
            if geo.haversine(start, end) < 0.5:
                segments.append(SegmentResult(geometry=[start], distance=0.0, duration=0.0))
                continue
            segments.append(chosen.plan_segment(start, end, mode))

        geometry, warnings = stitch(segments)
        if not geometry:
            raise RoutingError("路线几何为空", retryable=True, code="empty_geometry", provider=chosen.name)
        if self.densify_step > 0:
            geometry = geo.densify(geometry, step_m=self.densify_step)
        distance = geometry_distance(geometry)
        durations = [segment.duration for segment in segments if segment.duration]
        duration: Optional[float] = sum(durations) if durations else None
        return RoutePlan(
            geometry=geometry,
            distance=distance,
            duration=duration,
            provider=chosen.name,
            mode=mode,
            segments=len(segments),
            warnings=warnings,
        )
