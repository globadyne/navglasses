# TZ Bridge

Takes TimeZero's NMEA output from a virtual COM port, decodes it, and serves it over the boat's WiFi for the Ray-Ban Display glasses app.

```
TimeZero ──NMEA──> virtual COM pair ──> tz_bridge.py ──WiFi──> phone app ──Bluetooth──> glasses
```

What the bridge decodes:

| Data | NMEA sentences |
|---|---|
| Position, speed, course | RMC, GGA, GLL, VTG |
| Heading (true / magnetic) | HDT, THS, HDG, HDM |
| Rate of turn | ROT |
| Depth | DPT, DBT |
| Wind | MWV |
| Active route: next waypoint, range, bearing, cross-track error | RMB, APB, XTE, BWC |
| Active route's full waypoint list | RTE, WPL |
| Tracked targets (AIS or radar ARPA) as TimeZero outputs them | TTM |
| Own ship data, water temperature, leg bearing, heading to steer, arrival alarm | OSD, MTW, BOD, HSC, AAM |
| Saved marks and routes, live | TimeZero's database (UserObjects.tzdb) |
| Saved marks, routes and tracks | GPX export from TimeZero |
| AIS vessels and aids to navigation (buoys) | VDM, VDO |

For every AIS target, it works out range, true bearing, bearing relative to your heading, CPA and TCPA.

## 1. Install (nav PC, Windows)

1. Install Python 3.10 or newer from python.org. Tick "Add Python to PATH."
2. Open a Command Prompt in this folder and run:
   ```
   pip install -r requirements.txt
   ```

## 2. Test it without the boat

Open two Command Prompts in this folder.

```
python tz_bridge.py --udp 10110
python nmea_sim.py --udp 127.0.0.1:10110
```

Open http://localhost:8080 in a browser. You should see heading, speed, depth, an active route and five sample AIS targets near Halifax Harbour. The cargo ship turns amber as its CPA drops under 0.5 nm.

## 3. Connect TimeZero

TimeZero can send NMEA over UDP, so no virtual COM port is needed.

**In TimeZero's Connection Wizard:**
1. Choose **Add/Configure UDP connection (advanced)**.
2. Set it as an **output** to IP `127.0.0.1` (this same PC), port `10110`. If the bridge runs on a different PC, use that PC's address instead.
3. Tick these output sentences:

   | Tick | What the glasses use it for |
   |---|---|
   | RMC, GGA | Position, speed, course |
   | HDT, OSD | Heading |
   | TTM | AIS and radar targets: name, range, bearing, CPA, TCPA |
   | RMB, APB, BWC, BOD, XTE | Active route and next waypoint |
   | AAM | Waypoint arrival |
   | DPT | Depth |
   | MWV | Wind |
   | MTW, VHW | Water temperature and speed through water (optional) |

   Also tick RTE and WPL if they appear further down the list.
4. Set the options on the right:
   - **TTM Bearing and Course: True**
   - **APB: True North**
   - **MWV: Both**
   - **DPT Offset: From transducer to waterline**, if you want depth below the surface

**Start the bridge:**
```
python tz_bridge.py --udp 10110 --gpx "C:\Users\you\Documents\TZ Export"
```

Check http://localhost:8080. The "Data feed" panel lists which sentence types are arriving, which is the quickest way to see what TimeZero is actually sending. TimeZero only sends targets and route data once it has a position, so connect the GPS (or run TimeZero's simulation mode) to see them.

**Serial instead of UDP:** if you'd rather use a COM port, create a virtual COM pair with com0com, set TimeZero's output to one port at 38400 baud, and run `python tz_bridge.py --serial COM10 --baud 38400` on the other.

**About AIS:** TimeZero 4 doesn't offer raw AIS (VDM) output, so it sends targets as TTM. The glasses get name, position, speed, course and CPA, but not vessel type. For vessel type, also feed the AIS receiver straight into the bridge: add `--serial COMx` or `--udp` for its port alongside the TimeZero input.

## 4. Reach it from the phone

The bridge prints its address at startup, for example:
```
Status page:  http://192.168.1.20:8080/
Live stream:  ws://192.168.1.20:8080/ws
```
- Open the status page on your phone, connected to the boat WiFi, to confirm it reaches the PC.
- Windows Firewall will ask to allow Python the first time. Allow it on private networks.
- The glasses app connects to the `ws://…/ws` address.

## 5. Marks, routes and tracks

**Easiest: read them straight from TimeZero.** TimeZero keeps marks and routes in `C:\ProgramData\TimeZero\DATA\UserObjects.tzdb`. The bridge can read that file directly, read-only, and picks up changes within 5 seconds of you adding, moving or deleting a mark:

```
python tz_bridge.py --udp 10110 --tzdb "C:\ProgramData\TimeZero\DATA\UserObjects.tzdb"
```

The bridge never writes to this file. It also reads which route is active and which waypoint is next. If a TimeZero update changes the file's layout, the bridge logs an error and keeps running; use the GPX export below instead until the bridge is updated.

Marks you leave unnamed in TimeZero show as unnamed in the glasses, so give the important ones names.

**Or use a GPX export.** This also covers tracks, which the database reader doesn't handle yet.

1. Make a folder, for example `Documents\TZ Export`.
2. In TimeZero, export to GPX into that folder, using either:
   - **Import/Export → GPX**, which exports everything, or
   - **Lists → Mark List** (or Route List), select rows, then **Action → Export Selected → GPX**.
3. Start the bridge with the folder:
   ```
   python tz_bridge.py --serial COM10 --baud 38400 --gpx "C:\Users\you\Documents\TZ Export"
   ```

The bridge checks the folder every 5 seconds. When you add marks in TimeZero, re-export over the same file and the glasses pick up the change. Every `.gpx` file in the folder is loaded.

What the app gets:
- **Nearby marks** in every live update, nearest first, with range and bearing. Use `--mark-range 5` to change the distance; the default is 10 nm.
- **All routes, tracks and marks** at `/userdata.json`. The live data carries `userdata_version`, so the app re-downloads only after a new export.
- **Your own track**, recorded by the bridge from GPS as you go, in `/userdata.json` as `own_track`. No export needed.
- **The active route's waypoints, live**, if TimeZero sends RTE and WPL sentences. Enable them in TimeZero's NMEA output if offered.

Try it with the included sample: `python tz_bridge.py --udp 10110 --gpx sample_tz_export.gpx` with the simulator running. You'll see four marks near Halifax Harbour.

## Other inputs

```
python tz_bridge.py --udp 10110                   # NMEA over UDP (many WiFi gateways)
python tz_bridge.py --tcp 192.168.1.50:10110      # NMEA TCP server
python tz_bridge.py --replay mylog.nmea           # replay a recorded log
python tz_bridge.py --serial COM10 --udp 10110    # several at once
```

**AIS straight from the receiver.** If TimeZero won't repeat AIS, run the bridge with two inputs: TimeZero on the virtual COM port, and the AIS receiver on its own COM port or WiFi gateway.

**Record a test log:** `python nmea_sim.py --stdout > test.nmea`, then stop it with Ctrl+C.

**Pass the data on:** `--forward-udp 255.255.255.255:10110` re-broadcasts the raw NMEA on the network for other apps.

## Data format (for the glasses app)

`/state.json` and every `/ws` message carry the same JSON, sent twice a second:

```json
{
  "own":   {"lat": 44.6203, "lon": -63.5559, "sog": 6.5, "cog": 161.1, "hdg": 161.1,
            "rot": 9.3, "depth_m": 22.6, "awa": 38, "aws": 15.6},
  "route": {"to_wp": "WP4 Harbour mouth", "range_nm": 3.99, "bearing": 158.0,
            "xte_nm": 0.001, "steer": "L", "wp_lat": 44.5587, "wp_lon": -63.5209},
  "targets": [
    {"mmsi": 316001234, "name": "ATLANTIC SAMPLE", "kind": "vessel", "type_label": "Cargo",
     "lat": 44.607, "lon": -63.532, "sog": 12.0, "cog": 275.0,
     "range_nm": 2.27, "bearing": 130.2, "rel_bearing": -30.9, "cpa_nm": 0.51, "tcpa_min": 8.4},
    {"name": "SAMPLE BUOY", "kind": "aton", "range_nm": 1.19, "bearing": 154.9, "rel_bearing": -6.2}
  ],
  "rx_age_s": 0.4
}
```

- `rel_bearing` is relative to heading: negative is to port, positive to starboard. The glasses app adds the wearer's head turn to this to place labels in the lens.
- Values that stop updating for 30 seconds are dropped, so missing fields mean "no data," not zero.
- `rx_age_s` is seconds since any NMEA arrived. Above 5, the feed has stopped.

## Files

| File | What it does |
|---|---|
| `tz_bridge.py` | The bridge |
| `status.html` | Live status page served at http://localhost:8080 |
| `nmea_sim.py` | Simulated TimeZero output for testing |
| `sample_tz_export.gpx` | Sample TimeZero export with marks, a route and a track |
| `requirements.txt` | Python packages |
