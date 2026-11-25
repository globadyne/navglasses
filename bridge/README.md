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

### With the installer (recommended)

1. Download **TZ-Glasses-Bridge-Setup-x.y.z.exe**: from the repo's **Releases**, or from the latest
   "Bridge installer" run under **Actions** (Artifacts, at the bottom of the run).
2. Run it. It installs the bridge as a Windows service named **TZ Glasses Bridge** that starts with
   Windows and restarts itself if it ever stops, and lets phones reach it through the firewall.
   Nothing else is needed: Python and everything the bridge uses are inside.
3. The Settings page opens at the end (later: Start menu → **TZ Glasses Bridge Settings**, or
   http://localhost:8080/settings). Add where the NMEA comes from (for example the virtual COM port
   TimeZero sends to, and its speed) and press **Save**. TimeZero's database is found automatically.
4. The status page (Start menu → **TZ Glasses Bridge**) shows each input's line count and the
   address to type into the phone app.

Settings are kept in `C:\ProgramData\TZ Glasses Bridge\config.json` and survive upgrades: run a newer
installer over the old one. The service log is in `C:\ProgramData\TZ Glasses Bridge\logs`. Settings can
only be changed from the nav PC itself; phones on the WiFi can view the status page but not change it.

The installer isn't code-signed yet, so Windows SmartScreen says "Windows protected your PC": choose
**More info → Run anyway**.

### From source (for development)

1. Install Python 3.10 or newer from python.org. Tick "Add Python to PATH."
2. Open a Command Prompt in this folder and run:
   ```
   pip install -r requirements.txt
   ```
3. Run it with command-line options (below), or with `--config my-settings.json` to use the Settings page.

Stop the installed service first if it's running (`services.msc`, or the installer's uninstaller), since
both want port 8080.

### Building the installer

`.github/workflows/bridge-installer.yml` builds it on GitHub's Windows machines on every change to
`bridge/`, then tests it: replays sample NMEA through the packaged .exe, installs it as a service,
saves settings through the API, checks live data arrives, and uninstalls. Push a tag like
`bridge-v0.2.0` to publish a release. Pieces: PyInstaller (`installer/tz-bridge.spec`), WinSW as the
service wrapper (`installer/tz-bridge-service.xml`), Inno Setup (`installer/TZGlassesBridge.iss`).

## 2. Test it without the boat

Open two Command Prompts in this folder.

```
python tz_bridge.py --udp 10110
python nmea_sim.py --udp 127.0.0.1:10110
```

Open http://localhost:8080 in a browser. You should see heading, speed, depth, an active route and five sample AIS targets near Halifax Harbour. The cargo ship turns amber as its CPA drops under 0.5 nm.

## 3. Connect TimeZero

**Use a virtual COM port (recommended) or TCP, not UDP, when TimeZero and the bridge are on the same PC.** TimeZero's UDP connection also listens on the port it sends to, so a UDP output to `127.0.0.1` goes back to TimeZero itself, and the bridge can't open that port ("Only one usage of each socket address").

**Virtual COM port:**
1. Install **com0com** (the signed 64-bit build) and, in its Setup, rename the pair to e.g. **COM10** and **COM11**.
2. In TimeZero's Connection Wizard, add a **serial output** on **COM10** (4800 baud; 38400 if there are many targets) and tick the sentences below.
3. Run the bridge on the other end: `python tz_bridge.py --serial COM11:4800`. The speed must match TimeZero's (or use `COM11:auto`).

**TCP:** add a TCP NMEA output in TimeZero (TimeZero as server, e.g. port 10120) and run `python tz_bridge.py --tcp 127.0.0.1:10120`. The bridge reconnects by itself when TimeZero restarts.

**UDP** works when the bridge runs on a *different* PC: set TimeZero's UDP output to that PC's address, port 10110, and run `python tz_bridge.py --udp 10110` there.

**In TimeZero's Connection Wizard:**
Tick these output sentences on whichever connection you use:

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

## Several inputs, each at its own speed

Every input option can be repeated, and everything is merged into one picture. Each serial port takes its own speed after a colon; `auto` tries 4800, 38400, 9600, 115200, 19200 and 57600 until it finds clean sentences.

```
python tz_bridge.py --serial COM11:4800 --serial COM12:38400      # TimeZero at 4800, AIS receiver at 38400
python tz_bridge.py --serial COM12:auto                           # find the speed by itself
python tz_bridge.py --serial COM11:4800 --tcp 192.168.1.60:60001  # plus a WiFi gateway (e.g. Actisense W2K-1)
python tz_bridge.py --udp 10110 --udp 10111                       # two UDP feeds
python tz_bridge.py --replay mylog.nmea                           # replay a recorded log
```

The status page's "Data feed" panel lists every input with its line count, speed and when it last sent something, so a silent or wrong-speed port stands out.

Usual speeds: GPS, compass, depth and wind instruments at **4800**; AIS receivers and high-speed outputs at **38400**. If the same value (say heading) arrives from two inputs, the latest one wins, so feed each value from one place.

**NMEA 2000.** The bridge reads NMEA 0183. To use NMEA 2000 data, either let TimeZero read the network (it supports Actisense NGT-1) and pass it on in its output, or use a gateway that converts NMEA 2000 to 0183 (Actisense NGW-1 on a COM port, or a W2K-1 WiFi gateway set to send NMEA 0183 over TCP or UDP), and add it as another input.

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

## Recording what TimeZero sends

To capture TimeZero's output for testing (for example, to see how online AIS arrives), add `--record`:

```
python tz_bridge.py --udp 10110 --record tz-test.nmea
```

The bridge runs as normal and also saves every sentence it receives to `tz-test.nmea`, adding to the file if it already exists. Close the window to stop. Play a recording back later, without TimeZero, with:

```
python tz_bridge.py --replay tz-test.nmea
```

## TimeZero's own tracks, live

With `--tzdb`, the bridge also reads `Tracks2.tzdb` from the same folder (`C:\ProgramData\TimeZero\DATA\`), so tracks
need no GPX export. It sends this boat's tracks within 10 nm of where the boat is (newest first, a point every 15 m or
so, at most 20,000 points), and refreshes them when TimeZero saves or the boat moves about half a mile. Tracks of other
boats that TimeZero logged are left out. Change the area or limit with `--tz-track-range` and `--tz-track-points`, or
point at another file with `--tz-tracks`.
