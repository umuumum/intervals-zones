#!/usr/bin/env python3
"""
zone_bridge.py — aggregate a rolling 42-day power/HR zone distribution from
intervals.icu activities and publish it into custom wellness fields, so a
Connect IQ watch app can read it with one tiny GET.

Modes
-----
  --probe        Read-only. Reports what the API actually returns: which
                 zone-time field names exist, their shapes, zone counts and
                 boundaries per sport, and the resulting distributions.
                 Writes nothing. Run this first.
  --dry-run      Full aggregation, prints the payload, does not PUT.
  (default)      Aggregate and PUT into today's wellness record.
  --backfill N   Also write the same rolling window for the last N days
                 (each day computed from its own trailing 42-day window),
                 so the watch's history chart has something to show.

Setup
-----
  export INTERVALS_API_KEY=...          # Settings -> Developer -> API key
  export INTERVALS_ATHLETE_ID=i399953   # optional, defaults below

Create these custom wellness fields first (intervals.icu -> wellness dialog ->
"Fields" -> plus icon), all type Number:

  PwrZ1 .. PwrZ7    % of power-zone time (7 Coggan zones)
  HrZ1  .. HrZ7     % of HR-zone time (7-zone HR scale)
  PwrHrs HrHrs      hours in the window

The "code" you type is what becomes the JSON key -- it must match exactly.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import sys
from typing import Any

import requests

# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

ATHLETE_ID = os.environ.get("INTERVALS_ATHLETE_ID", "i399953")
API_KEY = os.environ.get("INTERVALS_API_KEY", "")
BASE = "https://intervals.icu/api/v1/athlete/{}".format(ATHLETE_ID)
WINDOW_DAYS = 42
TIMEOUT = 60

# Sports whose power numbers are meaningful. Everything else is ignored for
# the power screen (a rowing erg or a run reports "power" on some devices but
# it is not on the cycling FTP scale, so pooling it would be nonsense).
POWER_SPORTS = {
    "Ride",
    "GravelRide",
    "MountainBikeRide",
    "VirtualRide",
    "EBikeRide",
    "Handcycle",
    "Velomobile",
}

# Candidate JSON keys, most likely first. intervals.icu has used more than one
# shape over time and the field is not in the public docs, so we discover it.
POWER_KEYS = ["icu_zone_times", "icu_power_zone_times", "zone_times"]
HR_KEYS = ["icu_hr_zone_times", "hr_zone_times"]

POWER_FIELDS = ["PwrZ1", "PwrZ2", "PwrZ3", "PwrZ4", "PwrZ5", "PwrZ6", "PwrZ7"]
HR_FIELDS = ["HrZ1", "HrZ2", "HrZ3", "HrZ4", "HrZ5", "HrZ6", "HrZ7"]

# Zone ids that are real, disjoint zones. Anything else in the array is an
# OVERLAY band -- intervals.icu returns Sweet Spot (84-97% FTP) as an eighth
# entry alongside the seven Coggan zones, and it straddles the top of Z3 and
# the bottom of Z4. Counting it would double-count that time: with it included
# the buckets sum to more than the activity's elapsed time. Dropped by id.
ZONE_ID_RE = re.compile(r"^Z(\d+)$", re.I)


def auth() -> tuple[str, str]:
    if not API_KEY:
        sys.exit("INTERVALS_API_KEY is not set.")
    return ("API_KEY", API_KEY)


# --------------------------------------------------------------------------
# fetching
# --------------------------------------------------------------------------


def fetch_activities(start: dt.date, end: dt.date, use_fields: bool = True) -> list[dict]:
    """Pull activities in [start, end]. Falls back to unfiltered objects if the
    server rejects or ignores the `fields` parameter."""
    params: dict[str, Any] = {
        "oldest": start.isoformat(),
        "newest": end.isoformat(),
    }
    if use_fields:
        params["fields"] = ",".join(
            ["id", "type", "start_date_local", "moving_time"] + POWER_KEYS + HR_KEYS
        )

    r = requests.get(f"{BASE}/activities", auth=auth(), params=params, timeout=TIMEOUT)
    if r.status_code >= 400 and use_fields:
        # `fields` is the likeliest thing to be rejected -- retry without it.
        return fetch_activities(start, end, use_fields=False)
    r.raise_for_status()
    data = r.json()
    if not isinstance(data, list):
        sys.exit(f"Unexpected activities payload: {type(data).__name__}")

    # If `fields` was silently ignored we still got everything, which is fine.
    # If it was honoured but dropped the zone arrays, retry unfiltered once.
    if use_fields and data and not any(_find_zone_key(a, POWER_KEYS + HR_KEYS) for a in data):
        return fetch_activities(start, end, use_fields=False)
    return data


def fetch_sport_settings() -> list[dict]:
    r = requests.get(f"{BASE}/sport-settings", auth=auth(), timeout=TIMEOUT)
    if r.status_code >= 400:
        return []
    try:
        return r.json()
    except ValueError:
        return []


# --------------------------------------------------------------------------
# zone-array normalisation
# --------------------------------------------------------------------------


def _find_zone_key(activity: dict, keys: list[str]) -> str | None:
    for k in keys:
        v = activity.get(k)
        if isinstance(v, list) and v:
            return k
    return None


def normalise_zone_times(value: Any) -> tuple[list[float], list[str]] | None:
    """Return (seconds_per_zone, dropped_ids).

    intervals.icu returns time-in-zone either as a flat list of seconds (HR) or
    as a list of {id, secs} objects (power). Where ids are present they are
    authoritative: entries whose id is not Z<n> are overlay bands, not zones,
    and are dropped. Entries are ordered by zone number, never by position."""
    if not isinstance(value, list) or not value:
        return None

    first = value[0]

    # Flat list of seconds -- no ids to check, position is all there is.
    if isinstance(first, (int, float)):
        return [float(x or 0) for x in value], []

    if not isinstance(first, dict):
        return None

    secs_key = None
    for k in ("secs", "seconds", "time", "moving_time"):
        if k in first:
            secs_key = k
            break
    if secs_key is None:
        numeric = [k for k, v in first.items() if isinstance(v, (int, float))]
        if len(numeric) != 1:
            return None
        secs_key = numeric[0]

    keyed: list[tuple[int, float]] = []
    dropped: list[str] = []
    for item in value:
        zid = str(item.get("id", ""))
        m = ZONE_ID_RE.match(zid)
        if m:
            keyed.append((int(m.group(1)), float(item.get(secs_key) or 0)))
        else:
            dropped.append(zid or "?")

    if not keyed:
        return None
    keyed.sort(key=lambda t: t[0])
    return [s for _, s in keyed], dropped


def collect(activities: list[dict]) -> dict:
    """Bucket zone seconds by (kind, zone-count) so mismatches stay visible."""
    power: dict[int, list[float]] = {}
    hr: dict[int, list[float]] = {}
    per_sport: dict[str, dict[str, set]] = collections.defaultdict(
        lambda: {"power_counts": set(), "hr_counts": set()}
    )
    keys_seen: set[str] = set()
    skipped_power_sport: collections.Counter = collections.Counter()
    dropped_ids: collections.Counter = collections.Counter()

    for a in activities:
        sport = a.get("type") or "Unknown"

        hk = _find_zone_key(a, HR_KEYS)
        if hk:
            keys_seen.add(hk)
            parsed = normalise_zone_times(a[hk])
            if parsed:
                z, dropped = parsed
                for d in dropped:
                    dropped_ids["hr:" + d] += 1
                n = len(z)
                per_sport[sport]["hr_counts"].add(n)
                bucket = hr.setdefault(n, [0.0] * n)
                for i, secs in enumerate(z):
                    bucket[i] += secs

        pk = _find_zone_key(a, POWER_KEYS)
        if pk:
            keys_seen.add(pk)
            if sport not in POWER_SPORTS:
                skipped_power_sport[sport] += 1
            else:
                parsed = normalise_zone_times(a[pk])
                if parsed:
                    z, dropped = parsed
                    for d in dropped:
                        dropped_ids["power:" + d] += 1
                    n = len(z)
                    per_sport[sport]["power_counts"].add(n)
                    bucket = power.setdefault(n, [0.0] * n)
                    for i, secs in enumerate(z):
                        bucket[i] += secs

    return {
        "power": power,
        "hr": hr,
        "per_sport": per_sport,
        "keys_seen": keys_seen,
        "skipped_power_sport": skipped_power_sport,
        "dropped_ids": dropped_ids,
    }


def pick_bucket(buckets: dict[int, list[float]], label: str, force: bool) -> list[float] | None:
    """Choose the zone vector to publish. Multiple zone counts means sports
    disagree on how many zones exist -- pooling them is meaningless, so this
    fails loudly unless --force, which then keeps the count with the most time."""
    if not buckets:
        return None
    if len(buckets) == 1:
        return next(iter(buckets.values()))

    summary = {n: round(sum(v) / 3600, 1) for n, v in buckets.items()}
    msg = f"{label}: sports report different zone counts {summary} (count -> hours)"
    if not force:
        sys.exit(
            msg
            + "\nFix the zone counts in intervals.icu sport settings, or re-run "
              "with --force to keep only the dominant count."
        )
    print(f"  ! {msg} -- keeping dominant count", file=sys.stderr)
    return max(buckets.values(), key=sum)


def to_percent(zone_secs: list[float], slots: int, label: str = "") -> tuple[list[float], float]:
    """Percentages per zone, padded or folded to exactly `slots` values.

    If the athlete has more zones than there are fields (intervals.icu allows up
    to 7 HR zones), the overflow is folded into the LAST slot rather than
    dropped -- so the top bar reads as "Z5 and above" and the percentages still
    sum to 100. Dropping it would understate the hard end of the distribution,
    which is exactly the end the polarized check cares about."""
    total = sum(zone_secs)
    if total <= 0:
        return [0.0] * slots, 0.0

    secs = list(zone_secs)
    if len(secs) > slots:
        folded = len(secs) - slots + 1
        secs = secs[: slots - 1] + [sum(secs[slots - 1:])]
        print(
            f"  ! {label or 'zones'}: athlete has {len(zone_secs)} zones but only "
            f"{slots} fields -- folded the top {folded} into Z{slots}. "
            f"The top bar means 'Z{slots} and above'.",
            file=sys.stderr,
        )

    pct = [round(100.0 * s / total, 1) for s in secs]
    pct = (pct + [0.0] * slots)[:slots]

    # Rounding to 1 dp can leave the sum a few tenths off 100. Push the
    # remainder into the largest slot so the on-watch bars add up.
    drift = round(100.0 - sum(pct), 1)
    if abs(drift) >= 0.1:
        i = pct.index(max(pct))
        pct[i] = round(pct[i] + drift, 1)

    return pct, round(total / 3600.0, 1)


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------


def polarized(pct: list[float]) -> tuple[float, float, float]:
    """Collapse a zone vector to low / mid / high: Z1-2, Z3-4, Z5+.

    Both scales here are seven-zone, so one rule serves both. On Coggan power,
    Z3 is tempo and Z4 threshold -- the grey band -- with VO2 and above from Z5.
    On the seven-zone HR scale, Z4 (138-147 bpm against LTHR 153) is still
    sub-threshold, and Z5 starts at ~97% of LTHR. Treating Z4 as hard, as a
    five-zone split would, moves a big chunk of tempo work into the wrong
    bucket and flatters the hard share."""
    low = sum(pct[:2])
    mid = sum(pct[2:4])
    high = sum(pct[4:])
    return round(low, 1), round(mid, 1), round(high, 1)


def report(result: dict, pwr_pct, pwr_hrs, hr_pct, hr_hrs, n_acts: int) -> None:
    print(f"\nactivities in window: {n_acts}")
    print(f"zone-time keys found: {sorted(result['keys_seen']) or 'NONE'}")

    if result["skipped_power_sport"]:
        skipped = ", ".join(f"{k}x{v}" for k, v in result["skipped_power_sport"].most_common())
        print(f"power ignored for non-cycling sports: {skipped}")

    if result.get("dropped_ids"):
        dropped = ", ".join(f"{k}x{v}" for k, v in result["dropped_ids"].most_common())
        print(f"overlay bands dropped (not disjoint zones): {dropped}")

    print("\nper-sport zone counts")
    for sport, info in sorted(result["per_sport"].items()):
        p = sorted(info["power_counts"]) or "-"
        h = sorted(info["hr_counts"]) or "-"
        print(f"  {sport:<22} power={p}  hr={h}")

    if pwr_pct:
        print(f"\nPOWER  ({pwr_hrs} h)")
        for i, v in enumerate(pwr_pct):
            if v or i < 5:
                print(f"  Z{i + 1}  {v:5.1f}%  {'#' * int(round(v / 2))}")
        lo, mid, hi = polarized(pwr_pct)
        print(f"  sum {sum(pwr_pct):.1f}%")
        print(f"  -> low(Z1-2) {lo}%  mid(Z3-4) {mid}%  high(Z5+) {hi}%   (target 80 / 5 / 15)")
    else:
        print("\nPOWER  no data")

    if hr_pct:
        print(f"\nHR  ({hr_hrs} h)")
        for i, v in enumerate(hr_pct):
            if v or i < 5:
                print(f"  Z{i + 1}  {v:5.1f}%  {'#' * int(round(v / 2))}")
        lo, mid, hi = polarized(hr_pct)
        print(f"  sum {sum(hr_pct):.1f}%")
        print(f"  -> low(Z1-2) {lo}%  mid(Z3-4) {mid}%  high(Z5+) {hi}%   (target 80 / 5 / 15)")
    else:
        print("\nHR  no data")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def compute_for(end: dt.date, force: bool) -> tuple[dict, dict]:
    start = end - dt.timedelta(days=WINDOW_DAYS - 1)
    acts = fetch_activities(start, end)
    result = collect(acts)

    pwr = pick_bucket(result["power"], "power", force)
    hrz = pick_bucket(result["hr"], "hr", force)

    pwr_pct, pwr_hrs = to_percent(pwr, len(POWER_FIELDS), "power") if pwr else ([], 0.0)
    hr_pct, hr_hrs = to_percent(hrz, len(HR_FIELDS), "hr") if hrz else ([], 0.0)

    body: dict[str, float] = {}
    for name, v in zip(POWER_FIELDS, pwr_pct):
        body[name] = v
    for name, v in zip(HR_FIELDS, hr_pct):
        body[name] = v
    body["PwrHrs"] = pwr_hrs
    body["HrHrs"] = hr_hrs

    meta = {
        "result": result,
        "pwr_pct": pwr_pct,
        "pwr_hrs": pwr_hrs,
        "hr_pct": hr_pct,
        "hr_hrs": hr_hrs,
        "n_acts": len(acts),
    }
    return body, meta


def put_wellness(date: dt.date, body: dict) -> None:
    r = requests.put(
        f"{BASE}/wellness/{date.isoformat()}", json=body, auth=auth(), timeout=TIMEOUT
    )
    if r.status_code >= 400:
        sys.exit(f"PUT {date} failed {r.status_code}: {r.text[:400]}")
    echoed = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    missing = [k for k in body if k not in echoed]
    if missing:
        print(
            f"  ! wrote {date}, but the server did not echo: {missing}\n"
            f"    -> those custom wellness fields probably do not exist yet; "
            f"create them with exactly these codes.",
            file=sys.stderr,
        )
    else:
        print(f"  wrote {date}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true", help="report only, write nothing")
    ap.add_argument("--dry-run", action="store_true", help="aggregate, print payload, no write")
    ap.add_argument("--force", action="store_true", help="tolerate mixed zone counts")
    ap.add_argument("--backfill", type=int, default=0, metavar="N",
                    help="also write the trailing window for the last N days")
    ap.add_argument("--date", type=dt.date.fromisoformat, default=None,
                    help="end date of the window (default: today)")
    args = ap.parse_args()

    end = args.date or dt.date.today()

    if args.probe:
        settings = fetch_sport_settings()
        if settings:
            print("sport settings")
            for s in settings:
                print(
                    f"  id={s.get('id')} types={s.get('types')} "
                    f"ftp={s.get('ftp')} lthr={s.get('lthr')} "
                    f"hr_zones={s.get('hr_zones')} power_zones={s.get('power_zones')}"
                )

    body, meta = compute_for(end, args.force)

    if args.probe or args.dry_run:
        report(meta["result"], meta["pwr_pct"], meta["pwr_hrs"],
               meta["hr_pct"], meta["hr_hrs"], meta["n_acts"])
        print("\npayload for", end.isoformat())
        print(json.dumps(body, indent=2))
        if args.probe:
            print("\n(probe: nothing written)")
            return
        print("\n(dry run: nothing written)")
        return

    # Self-healing: rewrite today and the two days before, so a missed run or a
    # late-syncing activity gets corrected on the next pass.
    days = [end - dt.timedelta(days=d) for d in range(max(3, args.backfill + 1))]
    for d in sorted(days):
        payload, _ = compute_for(d, args.force) if d != end else (body, meta)
        put_wellness(d, payload)


if __name__ == "__main__":
    main()
