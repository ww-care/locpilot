"""路线服务抽象：provider 协议、数据结构与几何工具。

约定：

* 内部与 API 一律 **WGS-84**；只有高德 provider 在自己的边界做 GCJ-02 转换。
* provider 只负责「一段」（两点之间）的规划；多点的编排、拼接、缓存由 service 负责。
* 失败一律抛 `RoutingError`，带 `retryable` / `code` / `provider`，供 API 映射。
* 不做静默降级：provider 失败就是失败，由调用方决定重试或换服务。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

from .. import geo

Point = Tuple[float, float]


class RoutingError(Exception):
    """路线规划失败。retryable 表示"原样重试可能成功"。"""

    def __init__(self, message: str, retryable: bool = True,
                 code: Optional[str] = None, provider: Optional[str] = None) -> None:
        super().__init__(message)
        self.retryable = bool(retryable)
        self.code = code
        self.provider = provider


@dataclass
class SegmentResult:
    """一段路线的结果。geometry 为 WGS-84。"""

    geometry: List[Point]
    distance: float
    duration: Optional[float] = None


@dataclass
class RoutePlan:
    """整条路线（多段拼接后）的结果。"""

    geometry: List[Point]
    distance: float
    duration: Optional[float]
    provider: str
    mode: str
    segments: int = 0
    warnings: List[str] = field(default_factory=list)
    routed: bool = True


class RoutingProvider:
    """路线服务适配器：只实现"两点一段"。"""

    name = "base"

    def plan_segment(self, start: Point, end: Point, mode: str) -> SegmentResult:
        raise NotImplementedError


def to_float(value) -> Optional[float]:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def decode_polyline6(encoded: str) -> List[Point]:
    """解码 Valhalla 的 polyline6（精度 1e6，lat/lon 顺序）。"""
    points: List[Point] = []
    if not encoded:
        return points
    index = 0
    lat = 0
    lon = 0
    length = len(encoded)
    while index < length:
        for axis in (0, 1):
            shift = 0
            result = 0
            while True:
                if index >= length:
                    return points
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else (result >> 1)
            if axis == 0:
                lat += delta
            else:
                lon += delta
        points.append((lat / 1e6, lon / 1e6))
    return points


def dedupe_consecutive(points: Sequence[Sequence[float]]) -> List[Point]:
    out: List[Point] = []
    for point in points:
        current = (float(point[0]), float(point[1]))
        if not out or current != out[-1]:
            out.append(current)
    return out


def stitch(segments: Sequence[SegmentResult], max_gap_m: float = 30.0) -> Tuple[List[Point], List[str]]:
    """把逐段几何拼成整条路线。

    * 接缝处坐标通常完全重合，直接去重；
    * 若接缝间距 > max_gap_m，说明数据异常，记 warning（不阻断）。
    """
    geometry: List[Point] = []
    warnings: List[str] = []
    for index, segment in enumerate(segments):
        points = [(float(p[0]), float(p[1])) for p in (segment.geometry or [])]
        if not points:
            raise RoutingError("路线服务返回空几何", retryable=True, code="empty_geometry")
        if not geometry:
            geometry.extend(points)
            continue
        gap = geo.haversine(geometry[-1], points[0])
        if gap <= 1.0:
            geometry.extend(points[1:])
        else:
            if gap > max_gap_m:
                warnings.append("第 %d 段接缝相距 %.0f 米" % (index + 1, gap))
            geometry.extend(points)
    return dedupe_consecutive(geometry), warnings


def geometry_distance(points: Sequence[Sequence[float]]) -> float:
    cumulative = geo.cumulative_distances(points)
    return cumulative[-1] if cumulative else 0.0
