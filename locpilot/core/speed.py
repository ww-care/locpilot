"""速度模型：按交通方式给基准速度，并叠加轻微随机波动。

为什么需要随机：恒定速度看起来像机器；但每个 tick 独立随机又会抖得不自然。
做法是「慢随机游走 + 加速度限幅」：

* 每 3–8 秒才更新一次目标速度（围绕基准的乘性扰动，夹在 base*(1±jitter) 内）；
* 实际速度按加速度上限逼近目标，避免瞬间弹射；
* 支持 seed，测试可复现；jitter=0 退化为恒定速度；
* ETA 应使用基准速度计算，不要用瞬时速度（否则数字乱跳）。

设计见 docs/route-mode-design.md 第 6 节。
"""

from __future__ import annotations

import math
import random
from typing import Optional

from .. import config


class SpeedModel:
    """可复现的随机速度生成器。"""

    def __init__(self, mode: str = "walk", base: Optional[float] = None,
                 jitter: Optional[float] = None, seed: Optional[int] = None, rng=None) -> None:
        if mode not in config.MODE_PROFILES:
            mode = "walk"
        profile = config.MODE_PROFILES[mode]
        self.mode = mode
        self.base = float(base if base is not None else profile["base"])
        self.jitter = max(0.0, float(profile["jitter"] if jitter is None else jitter))
        self.accel = max(0.0, float(profile["accel"]))
        self._sigma = max(0.0, float(profile["sigma"]))
        self._interval = (float(profile["interval"][0]), float(profile["interval"][1]))
        self._rng = rng if rng is not None else random.Random(seed)
        self.seed = seed
        self.current = self.base
        self.target = self.base
        self._elapsed = 0.0
        self._next_update = 0.0

    def reset(self) -> None:
        self.current = self.base
        self.target = self.base
        self._elapsed = 0.0
        self._next_update = 0.0

    def rebase(self, base: float) -> None:
        """手动覆盖基准速度（保留随机参数与 seed）。"""
        self.base = float(base)
        self.reset()

    def speed_at(self, dt: float) -> float:
        """推进 dt 秒并返回当前瞬时速度（m/s）。"""
        dt = max(0.0, float(dt))
        self._elapsed += dt
        if self._elapsed >= self._next_update:
            self._pick_target()
            self._next_update = self._elapsed + self._rng.uniform(*self._interval)
        if dt > 0.0 and self.accel > 0.0:
            limit = self.accel * dt
            delta = self.target - self.current
            if delta > limit:
                self.current += limit
            elif delta < -limit:
                self.current -= limit
            else:
                self.current = self.target
        return self.current

    def _pick_target(self) -> None:
        if self.jitter <= 0.0:
            self.target = self.base
            return
        low = self.base * (1.0 - self.jitter)
        high = self.base * (1.0 + self.jitter)
        factor = math.exp(self._rng.gauss(0.0, self._sigma))
        self.target = min(high, max(low, self.current * factor))

    def status(self) -> dict:
        return {
            "mode": self.mode,
            "speed_base": round(self.base, 4),
            "speed": round(self.current, 4),
            "jitter": round(self.jitter, 4),
        }
