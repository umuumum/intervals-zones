#!/usr/bin/env python3
"""
probe_power_buckets.py -- read-only diagnostic.

Power zone settings define 7 zones, but icu_zone_times returns 8 values. This
prints the raw arrays for your longest rides next to moving/elapsed time so the
extra bucket can be identified by arithmetic rather than guessed at.

    export INTERVALS_API_KEY=...
    python probe_power_buckets.py

Writes nothing.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys

import requests

ATHLETE = os.environ.get("INTERVALS_ATHLETE_ID", "i399953")
KEY = os.environ.get("INTERVALS_API_KEY", "")
BASE = f"https://intervals.icu/api/v1/athlete/{ATHLETE}"
WINDOW = 42
N_SHOW = 3

POWER_SPORTS = {"Ride", "GravelRide", "MountainBikeRide", "VirtualRide", "EBikeRide"}

if not KEY:
    sys.exit("INTERVALS_API_KEY is not set.")
AUTH = ("API_KEY", KEY)


def secs(value):
    """Normalise a zone-time array to a list of seconds."""
    if not isinstance(value, list) or not value:
        return None
    if isinstance(value[0], (int, float)):
        return [float(x or 0) for x in value]
    if isinstance(value[0], dict):
        for k in ("secs", "seconds", "time", "moving_time"):
            if k in value[0]:
                return [float(i.get(k) or 0) for i in value]
    return None


def hms(s):
    s = int(s or 0)
    return f"{s // 3600}:{(s % 3600) // 60:02d}:{s % 60:02d}"


end = dt.date.today()
start = end - dt.timedelta(days=WINDOW - 1)

r = requests.get(
    f"{BASE}/activities",
    auth=AUTH,
    params={"oldest": start.isoformat(), "newest": end.isoformat()},
    timeout=60,
)
r.raise_for_status()
acts = r.json()

rides = [
    a for a in acts
    if a.get("type") in POWER_SPORTS and secs(a.get("icu_zone_times"))
]
rides.sort(key=lambda a: -(a.get("moving_time") or 0))

if not rides:
    sys.exit("No rides with power zone times in the window.")

# --------------------------------------------------------------------------
# Which keys on an activity mention zones at all? Catches anything I have not
# thought of (a separate zero-power field, a second zone array, etc).
# --------------------------------------------------------------------------
sample = rides[0]
zone_keys = sorted(k for k in sample.keys() if "zone" in k.lower())
print("keys mentioning 'zone':", zone_keys)
for k in ("icu_zone_times", "icu_hr_zone_times"):
    v = sample.get(k)
    if isinstance(v, list) and v:
        print(f"  {k}: len={len(v)} element type={type(v[0]).__name__}")
        if isinstance(v[0], dict):
            print(f"    first element: {json.dumps(v[0])}")

for a in rides[:N_SHOW]:
    mv = a.get("moving_time") or 0
    el = a.get("elapsed_time") or 0
    p = secs(a.get("icu_zone_times")) or []
    h = secs(a.get("icu_hr_zone_times")) or []

    print("\n" + "=" * 70)
    print(f"{a.get('name')}   [{a.get('type')}]  {a.get('start_date_local')}")
    print(f"  moving {hms(mv)}   elapsed {hms(el)}   "
          f"avg {a.get('icu_average_watts') or a.get('average_watts')} W   "
          f"NP {a.get('icu_weighted_avg_watts')} W")

    if p:
        tot = sum(p)
        print(f"\n  POWER  {len(p)} buckets, sum {hms(tot)}")
        for i, s in enumerate(p):
            print(f"    [{i}]  {hms(s):>9}  {100 * s / tot:5.1f}%")
        print(f"    sum/moving  = {tot / mv:.3f}" if mv else "")
        print(f"    sum/elapsed = {tot / el:.3f}" if el else "")

    if h:
        tot = sum(h)
        print(f"\n  HR  {len(h)} buckets, sum {hms(tot)}")
        for i, s in enumerate(h):
            print(f"    [{i}]  {hms(s):>9}  {100 * s / tot:5.1f}%")
        print(f"    sum/moving  = {tot / mv:.3f}" if mv else "")

print("\n" + "=" * 70)
print("""
What to look for:

- If POWER sums to roughly moving time while HR sums to the same, then all
  eight buckets are real time and one of them is a zero-power bucket. Whichever
  end holds an implausibly large share (bucket [0] or bucket [7]) is it.
- If POWER sums to about twice HR, the last bucket is a total, not a zone.
- Bucket [7] on an easy ride should be near zero if it is Coggan Z7
  (>150% FTP). If it is large on an easy ride, it is not a power zone.
""")
