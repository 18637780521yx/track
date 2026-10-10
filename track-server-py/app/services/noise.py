"""通用入库降噪：按规则丢弃高频重复事件（与具体业务解耦）。

规则来源（环境变量 ``TRACK_NOISE_RULES``）：

- 未设置：使用下方 ``DEFAULT_RULES``（导播场景的合理默认）
- ``none`` / ``-`` / 空串：关闭降噪
- 自定义：逗号分隔多条  
  ``事件名|模式|参数…``

模式：

1. ``onchange|prop``  
   同一设备、同一事件名，``properties[prop]`` 未变化则丢弃（适合 play 类「只记切换」）。

2. ``throttle|window_sec|prop``  
   同一设备、同一事件名、同一 ``properties[prop]``，在 ``window_sec`` 秒内只留 1 条。  
   ``prop`` 可省略（整事件按名节流）。

示例::

    TRACK_NOISE_RULES=content_play|onchange|content_id,content_end|throttle|600|content_id
"""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass
from typing import Any

from app.models import TrackEvent

# 未配置环境变量时的默认（CMS 导播）；其它产品可覆盖或设为 none
DEFAULT_RULES = (
    "content_play|onchange|content_id,"
    "content_end|throttle|600|content_id"
)

_MAX_KEYS = 50_000


@dataclass(frozen=True)
class NoiseRule:
    name: str
    mode: str  # onchange | throttle
    prop: str = ""
    window_sec: float = 0.0


_lock = threading.Lock()
_rules: list[NoiseRule] | None = None
# (device, event_name) -> last prop value  for onchange
_last_onchange: dict[tuple[str, str], str] = {}
# (device, event_name, prop_value) -> monotonic ts  for throttle
_last_throttle: dict[tuple[str, str, str], float] = {}


def _parse_rules(raw: str | None) -> list[NoiseRule]:
    if raw is None:
        text = DEFAULT_RULES
    else:
        text = raw.strip()
        if not text or text.lower() in ("none", "-", "off", "disable", "disabled"):
            return []

    out: list[NoiseRule] = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        bits = [b.strip() for b in part.split("|")]
        if len(bits) < 2:
            continue
        name, mode = bits[0], bits[1].lower()
        if not name or mode not in ("onchange", "throttle"):
            continue
        if mode == "onchange":
            prop = bits[2] if len(bits) > 2 else ""
            if not prop:
                continue
            out.append(NoiseRule(name=name, mode=mode, prop=prop))
        else:
            try:
                window = float(bits[2]) if len(bits) > 2 else 300.0
            except ValueError:
                window = 300.0
            prop = bits[3] if len(bits) > 3 else ""
            out.append(NoiseRule(name=name, mode=mode, prop=prop, window_sec=max(1.0, window)))
    return out


def reload_rules() -> list[NoiseRule]:
    """测试或热更新时调用。"""
    global _rules
    with _lock:
        _rules = _parse_rules(os.getenv("TRACK_NOISE_RULES"))
        return list(_rules)


def _get_rules() -> list[NoiseRule]:
    global _rules
    if _rules is None:
        _rules = _parse_rules(os.getenv("TRACK_NOISE_RULES"))
    return _rules


def _device_key(e: TrackEvent) -> str:
    return (e.distinct_id or e.anonymous_id or "unknown").strip() or "unknown"


def _prop(e: TrackEvent, key: str) -> str:
    if not key:
        return ""
    props = e.properties or {}
    v = props.get(key)
    if v is None:
        return ""
    return str(v)


def _prune_unlocked(now: float) -> None:
    if len(_last_throttle) > _MAX_KEYS:
        # drop entries older than 1h or oldest half
        cutoff = now - 3600
        stale = [k for k, ts in _last_throttle.items() if ts < cutoff]
        for k in stale:
            _last_throttle.pop(k, None)
        if len(_last_throttle) > _MAX_KEYS:
            ordered = sorted(_last_throttle.items(), key=lambda kv: kv[1])
            for k, _ in ordered[: len(ordered) // 2]:
                _last_throttle.pop(k, None)
    if len(_last_onchange) > _MAX_KEYS:
        _last_onchange.clear()


def should_drop_noisy_event(e: TrackEvent) -> bool:
    """True = 不要入库。无匹配规则则不过滤。"""
    rules = _get_rules()
    if not rules:
        return False

    name = (e.name or "").strip()
    matched = [r for r in rules if r.name == name]
    if not matched:
        return False

    dev = _device_key(e)
    now = time.monotonic()

    with _lock:
        _prune_unlocked(now)
        for rule in matched:
            if rule.mode == "onchange":
                val = _prop(e, rule.prop)
                key = (dev, name)
                prev = _last_onchange.get(key)
                if val and prev == val:
                    return True
                _last_onchange[key] = val
            elif rule.mode == "throttle":
                val = _prop(e, rule.prop)
                key = (dev, name, val)
                last = _last_throttle.get(key)
                if last is not None and (now - last) < rule.window_sec:
                    return True
                _last_throttle[key] = now
        return False


def noise_stats() -> dict[str, Any]:
    with _lock:
        rules = _get_rules()
        return {
            "rules": [
                {
                    "name": r.name,
                    "mode": r.mode,
                    "prop": r.prop,
                    "window_sec": r.window_sec,
                }
                for r in rules
            ],
            "onchange_keys": len(_last_onchange),
            "throttle_keys": len(_last_throttle),
        }
