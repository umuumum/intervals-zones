# Zones 42d — Connect IQ app + intervals.icu bridge

Three screens on the watch, over a rolling 42-day window:

1. **POWER** — % of time in each power zone (Z1–Z7)
2. **HEART RATE** — % of time in each HR zone (Z1–Z5)
3. **POLARIZED** — Z1-2 / Z3 / Z4+ for power and HR side by side, each with a
   tick marking the 80 · 5 · 15 polarized reference

Up/down (swipe, or the UP/DOWN buttons) pages between them. START forces a
refresh. The last good numbers are cached, so the screens are populated
instantly and survive being out of range.

---

## Why there are two halves

Time-in-zone is activity-derived, and 42 days is about 90 activities. Parsing
that on the watch means pulling a multi-hundred-kilobyte JSON response into a
device with a hard memory ceiling — possible, but it would be the thing that
breaks. So the aggregation happens on the Mac mini, which already runs the
daily Garmin → intervals.icu bridge, and the result lands in **custom wellness
fields**. The watch then does one GET that returns about 300 bytes.

Custom wellness fields do exist and are writable through the API — the wellness
dialog has a **Fields** button, the `code` you type there becomes the JSON key,
and a `PUT /wellness/{date}` sets it. This is the same mechanism behind the
existing `GarminStress` field.

The app authenticates with an intervals.icu API key over HTTP Basic, not OAuth.
That sidesteps the sideload problem noted in the earlier handoff: a sideloaded
build has a different app ID than a store listing, so an OAuth consent flow
would not round-trip. An API key does not care.

---

## Setup

### 1. Create the custom wellness fields

intervals.icu → wellness dialog → **Fields** → plus icon. All type **Number**.
The **code** must match exactly (it is the JSON key):

| Code | |
|---|---|
| `PwrZ1` … `PwrZ7` | % of power-zone time |
| `HrZ1` … `HrZ5` | % of HR-zone time |
| `PwrHrs` | hours of power data in the window |
| `HrHrs` | hours of HR data in the window |

### 2. Probe before trusting anything

```bash
export INTERVALS_API_KEY=...            # Settings → Developer → API key
export INTERVALS_ATHLETE_ID=i399953
python3 server/zone_bridge.py --probe
```

Read-only. It prints which zone-time keys the API actually returned, the zone
count each sport reports, how much time landed in each zone, and the payload it
*would* write. This settles the questions the earlier session left open:

- whether zone times arrive as a flat seconds array or as `{id, secs}` objects
  (it handles both, and says which it found)
- whether run / bike / SkiErg agree on how many zones exist — if they disagree
  the script **stops** rather than summing incompatible buckets. `--force`
  overrides and keeps the dominant count.

If the numbers look right, `--dry-run` shows the exact payload, then drop both
flags to write.

### 3. Fold into the daily bridge

```bash
# 08:35 Zurich, just after the existing wellness bridge
35 8 * * *  cd /path/to/intervals-zones && \
            INTERVALS_API_KEY=... /usr/bin/python3 server/zone_bridge.py >> /tmp/zone_bridge.log 2>&1
```

Each run rewrites today and the two previous days, so a missed run or a
late-syncing activity self-corrects on the next pass. `--backfill 30` once at
the start gives the wellness chart some history.

### 4. Build and sideload

```bash
./build.sh --list                # device ids your SDK has files for
DEVICE=fenix9pro51mm ./build.sh  # writes bin/zones42d-<device>.prg
./build.sh --install             # copies to a mounted watch
```

Before building, put your athlete ID and API key into
`resources/settings/properties.xml` — a sideloaded app cannot be configured
from the phone, so the defaults baked in at build time are what it uses.

Needs the Connect IQ SDK (9.2 or newer for fenix 9 device files) and a
developer key:

```bash
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER \
  -in developer_key.pem -out ~/.Garmin/developer_key.der -nocrypt
```

Copy the `.prg` to `/GARMIN/Apps/` over USB and restart the watch. A sideloaded
build does not auto-update.

---

## Decisions baked in

**Power is cycling only.** Rides, gravel, MTB, virtual and e-bike. A rowing erg
or a run reports "power" on some devices but not on the cycling FTP scale, so
pooling it would make the power screen meaningless. HR pools every sport, as
requested.

**Pooled HR across sports mixes zone definitions.** intervals.icu keeps HR
zones per sport. If your run and bike zone *boundaries* differ, the combined
distribution is a blend of two different scales. The zone *count* mismatch is
caught and refused; differing boundaries at the same count are not detectable
from the API, so `--probe` prints the per-sport settings for you to eyeball.

**More zones than fields fold into the top bar.** intervals.icu allows up to 7
HR zones. If you have 6 or 7, the overflow is summed into `HrZ5` rather than
dropped, so the top bar means "Z5 and above" and the percentages still total
100. Dropping it would understate the hard end — the end the polarized check
exists to watch. The script says so on stderr when it folds.

**Activities with HR ignored are excluded by design** — intervals.icu leaves
them out of time-in-zone. Strength sessions will not appear. That is correct,
but it looks like missing data, hence `PwrHrs` / `HrHrs` on screen so you can
see how much time the percentages are actually describing.

**Z3 is the grey zone on both scales.** On the 5-zone HR scale and the 7-zone
Coggan power scale alike, zone 3 is tempo and everything from 4 up is threshold
or harder, so the same Z1-2 / Z3 / Z4+ split reads correctly for both.

---

## Files

```
manifest.xml              fenix 9 family product ids
monkey.jungle             build config
build.sh                  build / sideload helper
source/ZonesApp.mc        app entry, settings plumbing
source/Model.mc           settings, fetch, parse, cache
source/ZonesView.mc       the three pages
source/ZonesDelegate.mc   paging and manual refresh
source/Draw.mc            round-screen-aware layout and bars
server/zone_bridge.py     42-day aggregation → custom wellness fields
```

The layout is computed from `dc.getWidth()` with a chord calculation, so bars
narrow towards the top and bottom of a round display instead of being clipped.
It fits the 416 / 454 / 466 px screens in the fenix 9 family without
per-device layout files.
