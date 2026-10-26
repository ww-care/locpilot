"""路线服务适配层：provider 抽象、高德（国内）、Valhalla（境外）与编排。"""

from .amap import AMapProvider
from .base import (
    Point,
    RoutePlan,
    RoutingError,
    RoutingProvider,
    SegmentResult,
    decode_polyline6,
    geometry_distance,
    stitch,
)
from .mock import MockProvider
from .service import PROVIDER_CHOICES, RoutingService
from .valhalla import ValhallaProvider

__all__ = [
    "Point",
    "RoutePlan",
    "RoutingError",
    "RoutingProvider",
    "SegmentResult",
    "decode_polyline6",
    "geometry_distance",
    "stitch",
    "AMapProvider",
    "ValhallaProvider",
    "MockProvider",
    "RoutingService",
    "PROVIDER_CHOICES",
]
