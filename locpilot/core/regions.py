"""中国大陆区域判定：决定一条路线该用哪个路线服务 provider。

为什么需要：高德只覆盖中国大陆，且其坐标系是 GCJ-02；境外（含港澳台）应使用 WGS-84
的全球服务（Valhalla）。选错 provider 会同时导致"路线规划失败"和"坐标偏移数百米"。

为什么不用 `coord.out_of_china()`：那只是一个粗略矩形，实测会把首尔、曼谷、新加坡、
河内、香港、澳门、台北都误判为"境内"。这里改用 Natural Earth 50m 国界多边形
（公共领域）简化后内嵌，判定 15 个已知点全对。

数据仅用于**选择路线服务**，不渲染、不代表任何边界主张。
重新生成方式见 `china_mainland.json` 的 source 字段（RDP eps=0.05）。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

Point = Tuple[float, float]

_DATA = None  # (bbox, rings)


def _data():
    global _DATA
    if _DATA is None:
        raw = json.loads(Path(__file__).with_name("china_mainland.json").read_text(encoding="utf-8"))
        bbox = tuple(float(v) for v in raw["bbox"])
        rings = [tuple((float(x), float(y)) for x, y in ring) for ring in raw["rings"]]
        _DATA = (bbox, rings)
    return _DATA


def in_china_mainland(lat: float, lon: float) -> bool:
    """点是否在中国大陆（含海南等岛屿；不含港澳台，也不含周边国家）。"""
    (min_lon, min_lat, max_lon, max_lat), rings = _data()
    if not (min_lon <= lon <= max_lon and min_lat <= lat <= max_lat):
        return False
    inside = False
    for ring in rings:
        for i in range(len(ring) - 1):
            x1, y1 = ring[i]
            x2, y2 = ring[i + 1]
            if (y1 > lat) != (y2 > lat):
                # 射线与边的交点横坐标
                x = (x2 - x1) * (lat - y1) / (y2 - y1) + x1
                if lon < x:
                    inside = not inside
    return inside


def route_region(points: Sequence[Sequence[float]]) -> str:
    """整条路线的区域：所有点都在大陆 → 'china'，否则 'global'。

    保守策略：任一点在境外（含港澳台/边境）就整条走全球 provider，
    避免"一段 GCJ、一段 WGS"混拼，以及高德跨境无路线的问题。
    """
    for point in points:
        lat, lon = float(point[0]), float(point[1])
        if not in_china_mainland(lat, lon):
            return "global"
    return "china"
