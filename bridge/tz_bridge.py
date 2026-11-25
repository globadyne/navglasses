#!/usr/bin/env python3
r"""
TimeZero NMEA bridge
--------------------
Reads NMEA 0183 output from TimeZero (via a virtual COM port, UDP or TCP),
decodes own-ship data, active route and AIS targets, computes range /
bearing / CPA / TCPA, and serves the result over the network:

  http://<pc-ip>:8080/            live status page (check it's working)
  http://<pc-ip>:8080/state.json  current snapshot (JSON)
  ws://<pc-ip>:8080/ws            live JSON stream (what the glasses app uses)
  http://<pc-ip>:8080/userdata.json  marks, routes and tracks exported from TimeZero

Marks and routes are read live from TimeZero's own database with --tzdb
(C:\ProgramData\TimeZero\DATA\UserObjects.tzdb), opened read-only.
They can also come from GPX files exported from TimeZero
(Lists > select > Action > Export, or Import/Export > GPX). Point the bridge
at the file or folder with --gpx; it reloads automatically when you re-export.

Examples
  python tz_bridge.py --serial COM10 --baud 38400
  python tz_bridge.py --serial COM11:4800 --serial COM12:38400     (several inputs, each at its own speed)
  python tz_bridge.py --serial COM12:auto                          (find the speed by itself)
  python tz_bridge.py --udp 10110
  python tz_bridge.py --tcp 192.168.1.50:10110
  python tz_bridge.py --replay sample.nmea
  python tz_bridge.py --udp 10110 --tzdb "C:\ProgramData\TimeZero\DATA\UserObjects.tzdb"   (marks, routes and tracks, live)
  python tz_bridge.py --udp 10110 --record tz-test.nmea   (save what TimeZero sends)
  python tz_bridge.py --serial COM10 --gpx "C:\Users\me\Documents\TZ Export"
"""
import argparse
import asyncio
import json
import logging
import math
import os
import socket
import sqlite3
import struct
import sys
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import pyais
from aiohttp import web, WSMsgType

log = logging.getLogger("tz_bridge")
# Where status.html and settings.html live: next to this script, or inside the packaged .exe.
HERE = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
FROZEN = getattr(sys, "frozen", False)
DEFAULT_TZDB = Path(r"C:\ProgramData\TimeZero\DATA\UserObjects.tzdb")
DEFAULT_CONFIG = Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "TZ Glasses Bridge" / "config.json"
BAUDS = ("4800", "9600", "19200", "38400", "57600", "115200", "auto")


# ---------------------------------------------------------------- settings file
# The installed bridge (a Windows service) has no command line to speak of: everything comes
# from config.json, edited on the Settings page. Command-line options still work and win.
def default_config():
    return {
        "inputs": [],          # {"type": "serial", "port": "COM11", "baud": "4800"} | tcp {host, port} | udp {port}
        "tzdb": str(DEFAULT_TZDB) if DEFAULT_TZDB.exists() else "",
        "gpx": [],
        "web_port": 8080,
        "mark_range": 10.0,
        "record": False,       # save the raw NMEA next to config.json (nmea-log.txt)
    }


def load_config(path):
    cfg = default_config()
    try:
        with open(path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        save_config(path, cfg)
        log.info("Created settings file %s", path)
    except (OSError, ValueError) as e:
        log.warning("Couldn't read settings %s (%s); using defaults", path, e)
    return cfg


def save_config(path, cfg):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    os.replace(tmp, path)  # never leave a half-written file


def validate_config(c):
    """Checks a config posted by the Settings page. Returns (clean config, error or None)."""
    out = default_config()
    try:
        inputs = []
        for i in c.get("inputs", []):
            t = i.get("type")
            if t == "serial":
                port, baud = str(i.get("port", "")).strip(), str(i.get("baud", "4800")).lower()
                if not port:
                    return None, "Choose a COM port for each serial input."
                if baud not in BAUDS:
                    return None, f"Unknown speed {baud}."
                inputs.append({"type": "serial", "port": port, "baud": baud})
            elif t == "tcp":
                host, port = str(i.get("host", "")).strip(), int(i.get("port", 0))
                if not host or not 0 < port < 65536:
                    return None, "Each TCP input needs an address and a port (1 to 65535)."
                inputs.append({"type": "tcp", "host": host, "port": port})
            elif t == "udp":
                port = int(i.get("port", 0))
                if not 0 < port < 65536:
                    return None, "Each UDP input needs a port (1 to 65535)."
                inputs.append({"type": "udp", "port": port})
            else:
                return None, f"Unknown input type {t!r}."
        out["inputs"] = inputs
        out["tzdb"] = str(c.get("tzdb", "")).strip()
        out["gpx"] = [str(g).strip() for g in c.get("gpx", []) if str(g).strip()]
        out["web_port"] = int(c.get("web_port", 8080))
        if not 1 <= out["web_port"] < 65536:
            return None, "The web port must be 1 to 65535."
        out["mark_range"] = float(c.get("mark_range", 10))
        out["record"] = bool(c.get("record", False))
    except (TypeError, ValueError, AttributeError) as e:
        return None, f"Invalid settings: {e}"
    return out, None


def apply_config(args, cfg, config_path):
    """Fills in args from the settings file, except options given on the command line."""
    if not (args.serial or args.udp or args.tcp or args.replay):
        args.serial = [f"{i['port']}:{i['baud']}" for i in cfg["inputs"] if i["type"] == "serial"]
        args.tcp = [f"{i['host']}:{i['port']}" for i in cfg["inputs"] if i["type"] == "tcp"]
        args.udp = [i["port"] for i in cfg["inputs"] if i["type"] == "udp"]
    if args.tzdb is None and cfg.get("tzdb"):
        args.tzdb = cfg["tzdb"]
    if not args.gpx and cfg.get("gpx"):
        args.gpx = list(cfg["gpx"])
    if args.port is None:
        args.port = cfg["web_port"]
    if args.mark_range is None:
        args.mark_range = cfg["mark_range"]
    if args.record is None and cfg.get("record"):
        args.record = str(Path(config_path).parent / "nmea-log.txt")


def list_serial_ports():
    try:
        from serial.tools import list_ports
        return [{"device": p.device, "description": p.description or ""}
                for p in sorted(list_ports.comports(), key=lambda p: (len(p.device), p.device))]
    except Exception as e:  # pyserial missing or the OS refused
        log.warning("Couldn't list COM ports: %s", e)
        return []

OWN_FIELD_MAX_AGE = 30        # s: drop own-ship values not refreshed
TARGET_MAX_AGE = 6 * 60       # s: drop AIS vessels not heard from
# Merging TimeZero's TTM copy of an AIS ship into the receiver's own (VDM) report of it.
SAME_SHIP_NM = 0.15           # positions this close…
SAME_SHIP_KN = 2.0            # …and speeds this close count as the same ship
ONLINE_AFTER_S = 90           # a TimeZero AIS target the receiver hasn't matched in this long is taken as online AIS
ATON_MAX_AGE = 20 * 60        # s: aids to navigation report less often
TRACK_MAX_POINTS = 2000       # per track, after thinning
OWN_TRACK_MIN_NM = 0.01       # record own breadcrumb every ~20 m
OWN_TRACK_MAX_POINTS = 5000


# ---------------------------------------------------------------- helpers
def checksum_ok(line: str) -> bool:
    if "*" not in line:
        return True  # some sources omit checksums
    body, _, cs = line[1:].partition("*")
    try:
        expected = int(cs[:2], 16)
    except ValueError:
        return False
    calc = 0
    for ch in body:
        calc ^= ord(ch)
    return calc == expected


def num(x):
    try:
        return float(x) if x not in ("", None) else None
    except ValueError:
        return None


def latlon(val, hemi, is_lat):
    if not val:
        return None
    try:
        dl = 2 if is_lat else 3
        v = float(val[:dl]) + float(val[dl:]) / 60.0
    except ValueError:
        return None
    return -v if hemi in ("S", "W") else v


def to_knots(speed, unit):
    if speed is None:
        return None
    return {"N": speed, "M": speed * 1.943844, "K": speed * 0.539957}.get(unit, speed)


def ship_type_label(t):
    if t is None:
        return None
    t = int(t)
    if t == 30: return "Fishing"
    if t in (31, 32, 52): return "Tug"
    if t == 35: return "Military"
    if t == 36: return "Sailing"
    if t == 37: return "Pleasure"
    if 40 <= t <= 49: return "High speed"
    if t == 50: return "Pilot"
    if t == 51: return "Search and rescue"
    if 60 <= t <= 69: return "Passenger"
    if 70 <= t <= 79: return "Cargo"
    if 80 <= t <= 89: return "Tanker"
    return "Other"


def rel_geometry(own, tgt):
    """Range (nm), true bearing (deg), CPA (nm), TCPA (min) using a local flat-earth frame."""
    coslat = math.cos(math.radians(own["lat"]))
    dx = (tgt["lon"] - own["lon"]) * 60.0 * coslat   # east, nm
    dy = (tgt["lat"] - own["lat"]) * 60.0            # north, nm
    rng = math.hypot(dx, dy)
    brg = (math.degrees(math.atan2(dx, dy)) + 360) % 360

    cpa = tcpa = None
    o_sog, o_cog = own.get("sog"), own.get("cog")
    t_sog, t_cog = tgt.get("sog"), tgt.get("cog")
    if None not in (o_sog, o_cog, t_sog, t_cog):
        ovx, ovy = o_sog * math.sin(math.radians(o_cog)), o_sog * math.cos(math.radians(o_cog))
        tvx, tvy = t_sog * math.sin(math.radians(t_cog)), t_sog * math.cos(math.radians(t_cog))
        vx, vy = tvx - ovx, tvy - ovy
        v2 = vx * vx + vy * vy
        t_h = 0.0 if v2 < 1e-9 else max(0.0, -(dx * vx + dy * vy) / v2)
        cpa = math.hypot(dx + vx * t_h, dy + vy * t_h)
        tcpa = t_h * 60.0
    return rng, brg, cpa, tcpa


# ---------------------------------------------------------------- user data (GPX)
def _local(tag):
    return tag.rsplit("}", 1)[-1]


def _child_text(el, name):
    for c in el:
        if _local(c.tag) == name:
            return (c.text or "").strip() or None
    return None


def _pt(el):
    try:
        return {"lat": float(el.get("lat")), "lon": float(el.get("lon"))}
    except (TypeError, ValueError):
        return None


def thin(points, max_points):
    if len(points) <= max_points:
        return points
    step = len(points) / max_points
    out = [points[int(i * step)] for i in range(max_points)]
    out[-1] = points[-1]
    return out


def load_gpx(path):
    """Return (marks, routes, tracks) from one GPX file. Handles GPX 1.0 and 1.1."""
    root = ET.parse(path).getroot()
    marks, routes, tracks = [], [], []
    for el in root:
        kind = _local(el.tag)
        if kind == "wpt":
            p = _pt(el)
            if p:
                p.update(name=_child_text(el, "name"), symbol=_child_text(el, "sym"),
                         note=_child_text(el, "desc") or _child_text(el, "cmt"), source=path.name)
                marks.append(p)
        elif kind == "rte":
            pts = []
            for c in el:
                if _local(c.tag) == "rtept":
                    p = _pt(c)
                    if p:
                        p["name"] = _child_text(c, "name")
                        pts.append(p)
            if pts:
                routes.append({"name": _child_text(el, "name") or path.stem, "points": pts, "source": path.name})
        elif kind == "trk":
            pts = []
            for seg in el.iter():
                if _local(seg.tag) == "trkpt":
                    p = _pt(seg)
                    if p:
                        pts.append(p)
            if pts:
                tracks.append({"name": _child_text(el, "name") or path.stem,
                               "points": thin(pts, TRACK_MAX_POINTS), "source": path.name})
    return marks, routes, tracks


# ---------------------------------------------------------------- TimeZero database
TZ_EPOCH = 946684800  # TimeZero stores dates as seconds since 2000-01-01 UTC
TZ_POINT, TZ_ROUTE = 0, 5


def tz_geometry(blob):
    """TimeZero geometry: 1 type byte, then (x, y) pairs as big-endian int32 Web Mercator
    centimetres (the same projection as Tracks2.tzdb, which uses metres). Some marks carry
    4 more bytes after their point; they're ignored.

    Not degrees: read as 2^31 = 180 degrees, positions look plausible in Nova Scotia but are
    wrong, and the error grows with latitude (a mark at 66 N came out at 83 N). Checked
    2026-11-25: a customer's 84 marks land within 1 nm of their own Tracks2 track as
    centimetres, and more than 10 nm from it as degrees."""
    if not blob or len(blob) < 9:
        return None, []
    pts = []
    for i in range(1, len(blob) - 7, 8):
        x, y = struct.unpack(">ii", blob[i:i + 8])
        lat, lon = merc_to_latlon(x / 100, y / 100)
        pts.append({"lat": round(lat, 7), "lon": round(lon, 7)})
    return blob[0], pts


def tz_signature(path, queries):
    """A cheap fingerprint of a TimeZero database's contents, or None if it can't be
    read right now. Backs up the file-time check: Windows doesn't always update a file's
    time while TimeZero holds it open, and new data may sit in the -wal file."""
    try:
        uri = Path(path).resolve().as_uri() + "?mode=ro"
        con = sqlite3.connect(uri, uri=True, timeout=2)
        try:
            con.execute("PRAGMA query_only = ON")
            out = []
            for q in queries:                  # each on its own: a missing table only blanks its part
                try:
                    out.append(tuple(con.execute(q).fetchone() or ()))
                except sqlite3.Error:
                    out.append(None)
            return tuple(out) if any(o is not None for o in out) else None
        finally:
            con.close()
    except (sqlite3.Error, OSError):
        return None


# Any added, edited or deleted mark or route changes one of these (TimeZero stamps
# LastModificationDate on every change), as does starting or moving along a route.
TZ_OBJECTS_SIGNATURE = (
    "SELECT count(*), total(Deleted), max(LastModificationDate), total(LastModificationDate) FROM UserObject",
    "SELECT group_concat(quote(RouteGuid) || ':' || NextDestinationPointIndex) FROM ActiveRoute")
# New track pieces, a growing current piece, or a deleted track.
TZ_TRACKS_SIGNATURE = (
    "SELECT count(*), max(FID), max(DateMax), total(Obsolete) FROM Portions",
    "SELECT total(Obsolete) FROM Tracks")


def load_tzdb(path):
    """Read marks, routes and the active route from TimeZero's UserObjects.tzdb, read-only."""
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        con.execute("PRAGMA query_only = ON")
        marks, routes, skipped = [], [], {}
        names_by_route = {}
        try:
            for guid, idx, name in con.execute(
                    "SELECT RouteGuid, IndexInRoute, Name FROM PlanningRoutePoint"):
                names_by_route.setdefault(guid, {})[idx] = name
        except sqlite3.Error:
            pass
        route_by_guid = {}
        for guid, otype, geom, name, comment, icon, color, modified in con.execute(
                "SELECT Guid, ObjectType, Geometry, Name, Comment, Icon, Color, LastModificationDate "
                "FROM UserObject WHERE Deleted = 0"):
            _, pts = tz_geometry(geom)
            if not pts:
                continue
            modified = TZ_EPOCH + modified if modified else None
            if otype == TZ_POINT:
                marks.append({**pts[0], "name": name or None, "note": comment or None, "icon": icon,
                              "color": color, "id": guid.hex(), "modified": modified, "source": "TimeZero"})
            elif otype == TZ_ROUTE:
                wp_names = names_by_route.get(guid, {})
                for i, p in enumerate(pts):
                    p["name"] = wp_names.get(i) or f"WP{i + 1}"
                r = {"name": name or "Route", "points": pts, "id": guid.hex(), "modified": modified,
                     "source": "TimeZero"}
                routes.append(r)
                route_by_guid[guid] = r
            else:
                skipped[otype] = skipped.get(otype, 0) + 1
        active = None
        try:
            row = con.execute("SELECT RouteGuid, NextDestinationPointIndex, DestinationPointIndex "
                              "FROM ActiveRoute").fetchone()
            if row and row[0] and row[0] in route_by_guid:
                active = {"route_id": row[0].hex(), "name": route_by_guid[row[0]]["name"],
                          "next_index": row[1], "destination_index": row[2]}
        except sqlite3.Error:
            pass
        return marks, routes, active, skipped
    finally:
        con.close()


class UserData:
    """Marks, routes and tracks from TimeZero's database and/or GPX files.
    check() runs every 5 s; it reloads only when a file's modified time changes,
    and keeps the last good data if a file is caught mid-save."""

    def __init__(self, paths, tzdb=None):
        self.paths = [Path(p) for p in paths]
        self.tzdb = Path(tzdb) if tzdb else None
        self.active_route = None
        self.mtimes = {}
        self.marks, self.routes, self.tracks = [], [], []
        self.version = 0.0
        self.errors = []

    def files(self):
        out = []
        for p in self.paths:
            if p.is_dir():
                out += sorted(p.glob("*.gpx")) + sorted(p.glob("*.GPX"))
            elif p.exists():
                out.append(p)
        return sorted(set(out))

    def check(self):
        files = self.files()
        mt = {}
        if self.tzdb:
            for suffix in ("", "-wal"):
                f = Path(str(self.tzdb) + suffix)
                if f.exists():
                    try:
                        mt[f] = f.stat().st_mtime
                    except OSError:
                        pass
        for f in files:
            try:
                mt[f] = f.stat().st_mtime
            except OSError:
                pass
        if self.tzdb:
            sig = tz_signature(self.tzdb, TZ_OBJECTS_SIGNATURE)
            # Can't read it this moment (TimeZero mid-write): judge by file times alone.
            mt["contents"] = sig if sig is not None else self.mtimes.get("contents")
        if mt == self.mtimes:
            return False
        marks, routes, tracks, errors = [], [], [], []
        active = None
        if self.tzdb:
            try:
                m, r, active, skipped = load_tzdb(self.tzdb)
                marks += m; routes += r
                if skipped:
                    log.info("TimeZero object types not used yet: %s", skipped)
            except (sqlite3.Error, OSError) as e:
                errors.append(f"{self.tzdb.name}: {e}")  # TimeZero mid-write; retried next check
        for f in files:
            try:
                m, r, t = load_gpx(f)
                marks += m; routes += r; tracks += t
            except (ET.ParseError, OSError) as e:
                errors.append(f"{f.name}: {e}")  # often a half-written file; retried next check
        if errors:
            # A file was mid-save (TimeZero writing, or a GPX export in progress).
            # Keep showing the last good data and try again on the next check.
            if errors != self.errors:
                for e in errors:
                    log.warning("Couldn't read %s (will retry)", e)
            self.errors = errors
            return False
        self.mtimes = mt
        self.marks, self.routes, self.tracks, self.errors = marks, routes, tracks, errors
        self.active_route = active
        self.version = time.time()
        log.info("Loaded %d marks, %d routes, %d tracks from %s%d GPX file(s)",
                 len(marks), len(routes), len(tracks), "TimeZero database + " if self.tzdb else "", len(files))
        return True


# ---------------------------------------------------------------- TimeZero tracks
# Tracks2.tzdb (SQLite, next to UserObjects.tzdb). Each track is split into Portions;
# each portion's HighResBlob holds its points in Web Mercator metres:
#   byte 0       format (4 = 1 byte per component, 7/8 = 2 bytes)
#   bytes 1-2    point count n (little-endian), not counting the start point
#   bytes 3-34   8 floats: (min, max) scale for x steps, an unused pair, y steps, unused
#   bytes 35-42  start x (double);  43-50 unused (double);  51-58 start y (double)
#   then n points of 3 components (x step, unused, y step), each an unsigned integer
#   q scaled to min + q / qmax * (max - min) and added to the previous point.
# Decoded against Portions' bounding boxes (within 4 cm) on a real TimeZero 4 file.
# MobileDescriptions.MobileType 0 is this boat; others are AIS/ARPA targets it logged.
MERC_R = 6378137.0


def merc_to_latlon(x, y):
    return (math.degrees(2 * math.atan(math.exp(y / MERC_R)) - math.pi / 2), math.degrees(x / MERC_R))


def latlon_to_merc(lat, lon):
    return (math.radians(lon) * MERC_R, MERC_R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)))


def tz_track_points(blob):
    """Web Mercator (x, y) points of one Portions.HighResBlob."""
    if not blob or len(blob) < 59:
        return []
    n = struct.unpack_from("<H", blob, 1)[0]
    f = struct.unpack_from("<8f", blob, 3)
    x = struct.unpack_from("<d", blob, 35)[0]
    y = struct.unpack_from("<d", blob, 51)[0]
    pts = [(x, y)]
    tail = blob[59:]
    if n == 0 or len(tail) < 3 * n or len(tail) % (3 * n):
        return pts
    w = len(tail) // (3 * n)
    qmax = (1 << (8 * w)) - 1
    sx, sy = (f[1] - f[0]) / qmax, (f[5] - f[4]) / qmax
    for k in range(n):
        o = 3 * w * k
        x += f[0] + int.from_bytes(tail[o:o + w], "little") * sx
        y += f[4] + int.from_bytes(tail[o + 2 * w:o + 3 * w], "little") * sy
        pts.append((x, y))
    return pts


def load_tz_tracks(path, lat, lon, radius_nm, max_points, min_step_m=15.0):
    """This boat's tracks from TimeZero's Tracks2.tzdb within radius_nm of (lat, lon),
    newest first, as runs of points about min_step_m apart, at most max_points in all.
    Read-only, so it's safe while TimeZero is running."""
    cx, cy = latlon_to_merc(lat, lon)
    r = radius_nm * 1852 / math.cos(math.radians(lat))   # Mercator metres stretch with latitude
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        con.execute("PRAGMA query_only = ON")
        rows = con.execute(
            "SELECT t.FID, t.Name, t.Guid, p.HighResBlob FROM Portions p "
            "JOIN Tracks t ON t.FID = p.FK_Tracks "
            "LEFT JOIN MobileDescriptions m ON m.FID = t.FK_MobileDescription "
            "WHERE p.Obsolete = 0 AND t.Obsolete = 0 AND (m.MobileType IS NULL OR m.MobileType = 0) "
            "AND p.BbRight >= ? AND p.BbLeft <= ? AND p.BbTop >= ? AND p.BbBottom <= ? "
            "ORDER BY t.DateMax DESC, t.FID, p.DateMin", (cx - r, cx + r, cy - r, cy + r)).fetchall()
    finally:
        con.close()
    out, total, run, last = [], 0, None, None
    r2 = r * r
    for fid, name, guid, blob in rows:
        if run is None or run["fid"] != fid:
            if run and len(run["points"]) >= 2:
                out.append(run)
            run, last = {"fid": fid, "name": name or "Track", "id": guid.hex() if guid else str(fid), "points": []}, None
        for x, y in tz_track_points(blob):
            if (x - cx) ** 2 + (y - cy) ** 2 > r2:
                if len(run["points"]) >= 2:      # left the area: end this run, start another
                    out.append(run)
                run = {**run, "points": []}; last = None
                continue
            if last and (x - last[0]) ** 2 + (y - last[1]) ** 2 < min_step_m ** 2:
                continue
            la, lo = merc_to_latlon(x, y)
            run["points"].append({"lat": round(la, 6), "lon": round(lo, 6)})
            last = (x, y)
            total += 1
        if total >= max_points:
            break
    if run and len(run["points"]) >= 2:
        out.append(run)
    return [{"name": t["name"], "id": t["id"], "points": t["points"], "source": "TimeZero"} for t in out]


# ---------------------------------------------------------------- state
class BoatState:
    def __init__(self):
        self.own, self.own_t = {}, {}
        self.route, self.route_t = {}, 0.0
        self.targets = {}
        self.own_mmsi = None
        self.frag = {}
        # When an AIS receiver feeds the bridge directly (VDM): last heard, and since when without a gap.
        self.vdm_last = None
        self.vdm_since = None
        self.stats = {"lines": 0, "bad_checksum": 0, "ais_decoded": 0, "ais_errors": 0}
        self.inputs = {}  # input name -> {"lines", "last", "note"}, shown on the status page
        self.sentence_counts = {}
        self.last_rx = None
        self.user = UserData([])
        # TimeZero's own tracks near the boat (Tracks2.tzdb), refreshed by refresh_tz_tracks().
        self.tz_tracks, self.tz_tracks_key, self.tz_tracks_version = [], None, 0.0
        self.mark_range = 10.0
        self.own_track = []
        self.nmea_wpts = {}          # name -> {lat, lon} from WPL
        self.nmea_route = {}         # active route from RTE: name + waypoint names
        self.nmea_route_parts = {}

    def set_own(self, **kw):
        now = time.time()
        for k, v in kw.items():
            if v is not None:
                self.own[k] = v
                self.own_t[k] = now

    def set_route(self, **kw):
        for k, v in kw.items():
            if v is not None:
                self.route[k] = v
        self.route_t = time.time()

    # -- entry point for every raw line
    def feed(self, raw: str):
        line = raw.strip()
        if not line or line[0] not in "$!":
            return
        self.stats["lines"] += 1
        self.last_rx = time.time()
        if not checksum_ok(line):
            self.stats["bad_checksum"] += 1
            return
        body = line[1:].split("*")[0]
        f = body.split(",")
        stype = f[0][-3:]
        self.sentence_counts[stype] = self.sentence_counts.get(stype, 0) + 1
        handler = getattr(self, "_" + stype, None)
        if handler:
            try:
                handler(f, line)
            except (IndexError, ValueError) as e:
                log.debug("bad %s sentence %r: %s", stype, line, e)

    # -- own ship
    def _breadcrumb(self):
        lat, lon = self.own.get("lat"), self.own.get("lon")
        if lat is None or lon is None:
            return
        if self.own_track:
            last = self.own_track[-1]
            d = math.hypot((lat - last["lat"]) * 60, (lon - last["lon"]) * 60 * math.cos(math.radians(lat)))
            if d < OWN_TRACK_MIN_NM:
                return
        self.own_track.append({"lat": round(lat, 6), "lon": round(lon, 6), "t": round(time.time())})
        if len(self.own_track) > OWN_TRACK_MAX_POINTS:
            self.own_track = self.own_track[::2]

    def _RMC(self, f, _):
        if f[2] == "A":
            self.set_own(lat=latlon(f[3], f[4], True), lon=latlon(f[5], f[6], False),
                         sog=num(f[7]), cog=num(f[8]))
            self._breadcrumb()

    def _GGA(self, f, _):
        if f[6] not in ("", "0"):
            self.set_own(lat=latlon(f[2], f[3], True), lon=latlon(f[4], f[5], False))

    def _GLL(self, f, _):
        if len(f) > 6 and f[6] == "A":
            self.set_own(lat=latlon(f[1], f[2], True), lon=latlon(f[3], f[4], False))

    def _VTG(self, f, _):
        self.set_own(cog=num(f[1]), sog=num(f[5]))

    def _HDT(self, f, _):
        self.set_own(hdg=num(f[1]))

    def _THS(self, f, _):
        self.set_own(hdg=num(f[1]))

    def _ROT(self, f, _):
        if len(f) < 3 or f[2] == "A":
            self.set_own(rot=num(f[1]))  # deg/min, negative = turning to port

    def _HDM(self, f, _):
        self.set_own(hdg_mag=num(f[1]))

    def _HDG(self, f, _):
        mag = num(f[1])
        var = num(f[4])
        if mag is not None and var is not None:
            var = var if f[5] == "E" else -var
            self.set_own(hdg=(mag + var) % 360, hdg_mag=mag)
        else:
            self.set_own(hdg_mag=mag)

    def _DPT(self, f, _):
        self.set_own(depth_m=num(f[1]))

    def _DBT(self, f, _):
        self.set_own(depth_m=num(f[3]))

    def _MWV(self, f, _):
        if len(f) > 5 and f[5] != "A":
            return
        angle, spd = num(f[1]), to_knots(num(f[3]), f[4])
        if f[2] == "R":
            self.set_own(awa=angle, aws=spd)
        else:
            self.set_own(twa=angle, tws=spd)

    def _VHW(self, f, _):
        self.set_own(stw=num(f[5]))

    # -- route (from TimeZero's active route / autopilot output)
    def _RMB(self, f, _):
        if f[1] != "A":
            return
        self.set_route(xte_nm=num(f[2]), steer=f[3] or None, from_wp=f[4] or None,
                       to_wp=f[5] or None, wp_lat=latlon(f[6], f[7], True),
                       wp_lon=latlon(f[8], f[9], False), range_nm=num(f[10]),
                       bearing=num(f[11]), vmg=num(f[12]), arrived=(f[13] == "A"))

    def _APB(self, f, _):
        self.set_route(xte_nm=num(f[3]), steer=f[4] or None, to_wp=f[10] or None,
                       bearing=num(f[11]), heading_to_steer=num(f[13]) if len(f) > 13 else None)

    def _XTE(self, f, _):
        self.set_route(xte_nm=num(f[3]), steer=f[4] or None)

    def _BWC(self, f, _):
        self.set_route(wp_lat=latlon(f[2], f[3], True), wp_lon=latlon(f[4], f[5], False),
                       bearing=num(f[6]), range_nm=num(f[10]), to_wp=f[12] or None)

    def _OSD(self, f, _):
        # own ship data: heading, course, speed (speed units in f[9])
        if len(f) > 2 and f[2] not in ("", "A"):
            return
        self.set_own(hdg=num(f[1]), cog=num(f[3]), sog=to_knots(num(f[5]), f[9] if len(f) > 9 else "N"))

    def _MTW(self, f, _):
        self.set_own(water_temp_c=num(f[1]))

    def _BOD(self, f, _):
        self.set_route(leg_bearing=num(f[1]), to_wp=f[5] or None, from_wp=f[6] or None if len(f) > 6 else None)

    def _BWR(self, f, line):
        self._BWC(f, line)

    def _HSC(self, f, _):
        self.set_route(heading_to_steer=num(f[1]))

    def _AAM(self, f, _):
        self.set_route(arrived=(f[1] == "A" or f[2] == "A"), arrival_radius_nm=num(f[3]))

    def _TTM(self, f, _):
        # tracked target as TimeZero outputs it: radar ARPA, or AIS when acquisition is R:
        # $--TTM,num,dist,brg,T/R,speed,course,T/R,cpa,tcpa,units,name,status,ref,time,acq
        tnum, dist, brg = f[1], num(f[2]), num(f[3])
        if dist is None or brg is None:
            return
        units = f[10] if len(f) > 10 else "N"
        to_nm = {"N": 1.0, "K": 0.539957, "S": 0.868976}.get(units, 1.0)
        status = f[12] if len(f) > 12 else ""
        key = "ttm-" + tnum
        if status == "L":  # lost target
            self.targets.pop(key, None)
            return
        hdg = self.own.get("hdg", self.own.get("cog"))
        if f[4] == "R":
            if hdg is None:
                return
            brg = (brg + hdg) % 360
        t = self.targets.setdefault(key, {"mmsi": None, "kind": "vessel", "first": time.time()})
        # Field 15, type of acquisition: A = automatic, M = manual (both radar ARPA),
        # R = reported (an AIS target passed through the same sentence).
        acq = f[15][:1] if len(f) > 15 else ""
        t["source"] = "AIS" if acq == "R" else "ARPA" if acq in ("A", "M") else t.get("source", "TTM")
        lat, lon = self.own.get("lat"), self.own.get("lon")
        if lat is not None and lon is not None:
            d = dist * to_nm
            t["lat"] = lat + d * math.cos(math.radians(brg)) / 60.0
            t["lon"] = lon + d * math.sin(math.radians(brg)) / (60.0 * math.cos(math.radians(lat)))
            t["pos_t"] = time.time()
        spd, crs = num(f[5]), num(f[6])
        if spd is not None:
            t["sog"] = spd * to_nm  # same unit field covers speed (kn, km/h, mph)
        if crs is not None:
            if f[7] == "R" and hdg is not None:
                crs = (crs + hdg) % 360
            t["cog"] = crs
        name = f[11].strip() if len(f) > 11 else ""
        t["name"] = name or t.get("name") or (f"ARPA {tnum}" if t["source"] == "ARPA" else f"Target {tnum}")
        t["seen"] = time.time()

    def _WPL(self, f, _):
        lat, lon = latlon(f[1], f[2], True), latlon(f[3], f[4], False)
        if lat is not None and lon is not None and f[5]:
            self.nmea_wpts[f[5]] = {"lat": lat, "lon": lon}

    def _RTE(self, f, _):
        # $--RTE,total,num,c|w,route_id,wp1,wp2,...  (a long route spans several sentences)
        total, num_ = int(f[1]), int(f[2])
        self.nmea_route_parts[num_] = [w for w in f[5:] if w]
        if num_ == total:
            names = []
            for i in range(1, total + 1):
                names += self.nmea_route_parts.get(i, [])
            self.nmea_route = {"name": f[4] or "Active route", "waypoints": names, "t": time.time()}
            self.nmea_route_parts = {}

    # -- AIS
    def _VDM(self, f, line):
        self._ais(f, line, own=False)

    def _VDO(self, f, line):
        self._ais(f, line, own=True)

    def _ais(self, f, line, own):
        total, part, seq, chan = int(f[1]), int(f[2]), f[3], f[4]
        if total == 1:
            parts = [line]
        else:
            key = (seq, chan)
            buf = self.frag.setdefault(key, {"t": time.time(), "p": {}})
            buf["p"][part] = line
            if len(buf["p"]) < total:
                return
            del self.frag[key]
            try:
                parts = [buf["p"][i] for i in range(1, total + 1)]
            except KeyError:
                return
        try:
            msg = pyais.decode(*[p.encode() for p in parts]).asdict(enum_as_int=True)
        except Exception as e:  # pyais raises several error types
            self.stats["ais_errors"] += 1
            log.debug("AIS decode failed %r: %s", parts, e)
            return
        self.stats["ais_decoded"] += 1
        mmsi = msg.get("mmsi")
        if own:
            self.own_mmsi = mmsi
            return
        if mmsi is None or mmsi == self.own_mmsi:
            return
        self._update_target(mmsi, msg)

    def _update_target(self, mmsi, m):
        now = time.time()
        if self.vdm_last is None or now - self.vdm_last > 60:
            self.vdm_since = now
        self.vdm_last = now
        t = self.targets.setdefault(mmsi, {"mmsi": mmsi, "kind": "vessel", "source": "AIS"})
        mtype = m.get("msg_type")
        lat, lon = m.get("lat"), m.get("lon")
        if lat is not None and lon is not None and abs(lat) <= 90 and abs(lon) <= 180:
            t["lat"], t["lon"] = lat, lon
            t["pos_t"] = time.time()
        spd = m.get("speed")
        if spd is not None and spd < 102.2:
            t["sog"] = spd
        crs = m.get("course")
        if crs is not None and crs < 360:
            t["cog"] = crs
        hdg = m.get("heading")
        if hdg is not None and hdg < 360:
            t["hdg"] = hdg
        if mtype == 21:
            t["kind"] = "aton"
            t["name"] = (m.get("name") or "").strip("@ ").strip() or t.get("name")
            t["aid_type"] = m.get("aid_type")
        for src, dst in (("shipname", "name"), ("callsign", "callsign"), ("destination", "destination")):
            v = m.get(src)
            if isinstance(v, str) and v.strip("@ ").strip():
                t[dst] = v.strip("@ ").strip()
        st = m.get("ship_type")
        if st is not None and st != 0:
            t["ship_type"] = st
            t["type_label"] = ship_type_label(st)
        t["seen"] = time.time()

    def _merged_targets(self, now):
        """Targets with TimeZero's TTM copies of AIS ships folded into the receiver's own reports.

        With an AIS receiver feeding the bridge directly (VDM) as well as TimeZero (TTM), each
        ship would arrive twice. A TTM target reported as AIS (acquisition R, or no field) is
        dropped when a VDM target has the same name, or sits within SAME_SHIP_NM with a speed
        within SAME_SHIP_KN. Radar (ARPA) targets are always kept: the receiver can't see them.

        One the receiver still hasn't matched after ONLINE_AFTER_S, while it's been running
        that long, came from somewhere the receiver can't hear: in practice TimeZero's online
        AIS. Those are tagged source ONLINE (no age, no collision alarm in the app)."""
        for t in self.targets.values():          # re-decided every time, from scratch
            if t.pop("online_guess", None):
                t["source"] = "AIS"
        vdm = [t for t in self.targets.values() if t.get("mmsi") is not None and "lat" in t]
        receiving = self.vdm_last is not None and now - self.vdm_last <= 60
        if not receiving:
            return list(self.targets.values())

        def norm(n):
            return " ".join((n or "").upper().split())

        names = {norm(t.get("name")): t for t in vdm if norm(t.get("name"))}
        out = []
        for key, t in self.targets.items():
            if not str(key).startswith("ttm-") or t.get("source") not in ("AIS", "TTM", "ONLINE"):
                out.append(t)
                continue
            match = names.get(norm(t.get("name")))
            if match is None and "lat" in t:
                for v in vdm:
                    d = math.hypot(v["lat"] - t["lat"],
                                   (v["lon"] - t["lon"]) * math.cos(math.radians(t["lat"]))) * 60
                    if d <= SAME_SHIP_NM and abs((v.get("sog") or 0) - (t.get("sog") or 0)) <= SAME_SHIP_KN:
                        match = v
                        break
            if match is not None:
                if not match.get("name") and t.get("name") and not t["name"].startswith("Target "):
                    match["name"] = t["name"]
                t["source"] = "AIS"
                t.pop("online_guess", None)
                continue
            if (now - t.get("first", now) >= ONLINE_AFTER_S
                    and now - (self.vdm_since or now) >= ONLINE_AFTER_S):
                t["source"], t["online_guess"] = "ONLINE", True
            out.append(t)
        return out

    # -- output
    def snapshot(self):
        now = time.time()
        own = {k: v for k, v in self.own.items() if now - self.own_t.get(k, 0) <= OWN_FIELD_MAX_AGE}
        ref_hdg = own.get("hdg", own.get("cog"))

        # prune old targets and stale AIS fragments
        for mmsi in [m for m, t in self.targets.items()
                     if now - t.get("seen", 0) > (ATON_MAX_AGE if t["kind"] == "aton" else TARGET_MAX_AGE)]:
            del self.targets[mmsi]
        for k in [k for k, b in self.frag.items() if now - b["t"] > 10]:
            del self.frag[k]

        targets = []
        for t in self._merged_targets(now):
            if "lat" not in t:
                continue
            out = {k: v for k, v in t.items() if k not in ("pos_t", "seen", "first", "online_guess")}
            if t.get("online_guess"):
                out.pop("age_s", None)        # TimeZero doesn't say how old an online report is
            else:
                out["age_s"] = round(now - t.get("pos_t", t["seen"]), 1)
            if "lat" in own and "lon" in own:
                rng, brg, cpa, tcpa = rel_geometry(own, t)
                out["range_nm"] = round(rng, 3)
                out["bearing"] = round(brg, 1)
                if ref_hdg is not None:
                    out["rel_bearing"] = round(((brg - ref_hdg + 540) % 360) - 180, 1)
                if cpa is not None and t["kind"] == "vessel":
                    out["cpa_nm"] = round(cpa, 3)
                    out["tcpa_min"] = round(tcpa, 1)
            targets.append(out)
        targets.sort(key=lambda x: x.get("range_nm", 1e9))

        route = dict(self.route) if now - self.route_t <= OWN_FIELD_MAX_AGE else {}

        # active route waypoints sent live by TimeZero (RTE + WPL), if it sends them
        if self.nmea_route and now - self.nmea_route["t"] <= 60:
            wps = []
            for name in self.nmea_route["waypoints"]:
                p = self.nmea_wpts.get(name)
                if p:
                    wps.append({"name": name, **self._rel(own, p, ref_hdg)})
            if wps:
                route["waypoints"] = wps
                route["route_name"] = self.nmea_route["name"]

        # active route waypoints from TimeZero's database
        ar = self.user.active_route
        if "waypoints" not in route and ar:
            r = next((x for x in self.user.routes if x["id"] == ar["route_id"]), None)
            if r:
                route["route_name"] = r["name"]
                route["next_index"] = ar["next_index"]
                route["waypoints"] = [{"name": p["name"], **self._rel(own, p, ref_hdg)} for p in r["points"]]

        # marks from TimeZero (database or GPX export), nearest first, within range
        marks = []
        if "lat" in own and "lon" in own:
            for m in self.user.marks:
                r = self._rel(own, m, ref_hdg)
                if r["range_nm"] <= self.mark_range:
                    marks.append({**m, **r})
            marks.sort(key=lambda x: x["range_nm"])
            marks = marks[:100]

        return {
            "time": now,
            "rx_age_s": None if self.last_rx is None else round(now - self.last_rx, 1),
            "own": {k: (round(v, 6) if isinstance(v, float) else v) for k, v in own.items()},
            "route": route,
            "targets": targets,
            "marks": marks,
            "userdata_version": max(self.user.version, self.tz_tracks_version),
            "stats": {**self.stats, "sentences": self.sentence_counts,
                      "inputs": {k: {"lines": v["lines"], "note": v.get("note", ""),
                                     "age_s": round(time.time() - v["last"], 1) if v["last"] else None}
                                 for k, v in self.inputs.items()},
                      "marks_loaded": len(self.user.marks), "routes_loaded": len(self.user.routes),
                      "tracks_loaded": len(self.user.tracks), "gpx_errors": self.user.errors},
        }

    def _rel(self, own, p, ref_hdg):
        if "lat" not in own or "lon" not in own:
            return {"lat": p["lat"], "lon": p["lon"]}
        rng, brg, _, _ = rel_geometry(own, p)
        out = {"lat": p["lat"], "lon": p["lon"], "range_nm": round(rng, 3), "bearing": round(brg, 1)}
        if ref_hdg is not None:
            out["rel_bearing"] = round(((brg - ref_hdg + 540) % 360) - 180, 1)
        return out

    def tz_tracks_due(self, path):
        """The cache key for TimeZero's tracks near the boat if it changed (the file was
        saved, or the boat moved about half a mile), else None."""
        lat, lon = self.own.get("lat"), self.own.get("lon")
        if lat is None or lon is None:
            return None
        mt = []
        for suffix in ("", "-wal"):
            try:
                mt.append(Path(str(path) + suffix).stat().st_mtime)
            except OSError:
                pass
        sig = tz_signature(path, TZ_TRACKS_SIGNATURE)
        if sig is None and self.tz_tracks_key:
            sig = self.tz_tracks_key[1]                  # unreadable this moment: keep the last one
        key = (tuple(mt), sig, round(lat * 120), round(lon * 120 * math.cos(math.radians(lat))))
        return None if key == self.tz_tracks_key else key

    def userdata(self):
        return {"version": max(self.user.version, self.tz_tracks_version), "marks": self.user.marks, "routes": self.user.routes,
                "tracks": self.user.tracks + self.tz_tracks, "own_track": self.own_track,
                "active_route": self.user.active_route,
                "files": [f.name for f in self.user.mtimes if isinstance(f, Path)], "errors": self.user.errors}


# ---------------------------------------------------------------- inputs
AUTO_BAUDS = (4800, 38400, 9600, 115200, 19200, 57600)


def parse_serial_spec(spec, default_baud):
    """'COM11' -> (COM11, default); 'COM11:38400' -> (COM11, 38400); 'COM11:auto' -> (COM11, None)."""
    port, _, b = spec.partition(":")
    b = b or default_baud
    return port, (None if str(b).lower() == "auto" else int(b))


def _looks_like_nmea(raw: bytes) -> bool:
    line = raw.decode("ascii", errors="ignore").strip()
    return len(line) > 6 and line[0] in "$!" and checksum_ok(line)


def detect_baud(ser, port, stop, note):
    """Try the usual NMEA speeds until one gives clean sentences. Returns the baud or None."""
    for baud in AUTO_BAUDS:
        if stop.is_set():
            return None
        ser.baudrate = baud
        ser.reset_input_buffer()
        note(f"trying {baud} baud")
        good, deadline = 0, time.time() + 3
        while time.time() < deadline and not stop.is_set():
            if _looks_like_nmea(ser.readline()):
                good += 1
                if good >= 2:
                    log.info("%s: found NMEA at %d baud", port, baud)
                    return baud
    return None


def serial_reader(port, baud, push, stop, note=lambda s: None):
    """Reads one COM port. baud=None means detect it (tries the usual NMEA speeds)."""
    import serial  # pyserial
    while not stop.is_set():
        try:
            with serial.Serial(port, baud or AUTO_BAUDS[0], timeout=1) as ser:
                use = baud or detect_baud(ser, port, stop, note)
                if use is None:
                    note("no NMEA at any speed")
                    log.warning("%s: no NMEA found at %s baud (retrying)", port, "/".join(map(str, AUTO_BAUDS)))
                    continue
                ser.baudrate = use
                note(f"{use} baud")
                log.info("Reading %s at %d baud", port, use)
                while not stop.is_set():
                    raw = ser.readline()
                    if raw:
                        push(raw.decode("ascii", errors="ignore"))
        except Exception as e:
            if stop.is_set():
                return
            try:
                note(f"can't open: {e}")
            except RuntimeError:  # the bridge is restarting
                return
            log.warning("Serial %s: %s (retrying in 3 s)", port, e)
            stop.wait(3)


class UdpIn(asyncio.DatagramProtocol):
    def __init__(self, push):
        self.push = push

    def datagram_received(self, data, addr):
        for ln in data.decode("ascii", errors="ignore").splitlines():
            self.push(ln)


async def tcp_reader(host, port, push):
    while True:
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 10)
            log.info("Connected to %s:%d", host, port)
            try:
                while True:
                    # If TimeZero restarts, the old connection can go quiet without closing.
                    # Nothing for 20 s means it's dead: reconnect.
                    raw = await asyncio.wait_for(reader.readline(), 20)
                    if not raw:
                        log.warning("TCP %s:%d closed by TimeZero (reconnecting)", host, port)
                        break
                    push(raw.decode("ascii", errors="ignore"))
            finally:
                writer.close()
        except asyncio.TimeoutError:
            log.warning("TCP %s:%d: no data for 20 s (reconnecting)", host, port)
        except OSError as e:
            log.warning("TCP %s:%d: %s (retrying in 3 s)", host, port, e)
        await asyncio.sleep(3)


async def replay_reader(path, rate, push):
    lines = Path(path).read_text(errors="ignore").splitlines()
    log.info("Replaying %d lines from %s at %g lines/s (looping)", len(lines), path, rate)
    while True:
        for ln in lines:
            push(ln)
            await asyncio.sleep(1.0 / rate)


# ---------------------------------------------------------------- server
def build_app(state, interval, control=None):
    clients = set()
    control = control or {}

    async def index(_):
        return web.FileResponse(HERE / "status.html")

    async def settings_page(_):
        return web.FileResponse(HERE / "settings.html")

    async def get_config(request):
        path = control.get("config_path")
        cfg = load_config(path) if path else None
        return web.json_response({
            "config": cfg,
            "config_path": str(path) if path else None,
            # Settings can be changed only on the nav PC itself, not by anyone on the boat's WiFi.
            "editable": bool(path) and request.remote in ("127.0.0.1", "::1"),
            "running": control.get("running"),
            "ports": list_serial_ports(),
            "tzdb_found": DEFAULT_TZDB.exists(),
            "default_tzdb": str(DEFAULT_TZDB),
            "bauds": BAUDS,
            "addresses": [f"{ip}:{control.get('web_port', 8080)}" for ip in local_ips()],
        })

    async def post_config(request):
        path = control.get("config_path")
        if not path:
            return web.json_response({"error": "This bridge was started from the command line, so its "
                                               "settings are the options it was started with."}, status=409)
        if request.remote not in ("127.0.0.1", "::1"):
            return web.json_response({"error": "Settings can only be changed on the nav PC itself."}, status=403)
        if request.content_type != "application/json":
            return web.json_response({"error": "Expected JSON."}, status=415)
        cfg, err = validate_config(await request.json())
        if err:
            return web.json_response({"error": err}, status=400)
        save_config(path, cfg)
        log.info("Settings saved; restarting inputs")
        restart = control.get("restart")
        if restart:
            asyncio.get_running_loop().call_later(0.5, restart.set)  # after this reply has gone out
        return web.json_response({"ok": True, "web_port": cfg["web_port"]})

    async def state_json(_):
        return web.json_response(state.snapshot())

    async def userdata_json(_):
        return web.json_response(state.userdata())

    async def ws_handler(request):
        ws = web.WebSocketResponse(heartbeat=20)
        await ws.prepare(request)
        clients.add(ws)
        log.info("Client connected: %s (%d total)", request.remote, len(clients))
        try:
            await ws.send_str(json.dumps(state.snapshot()))
            async for msg in ws:
                if msg.type == WSMsgType.ERROR:
                    break
        finally:
            clients.discard(ws)
            log.info("Client left: %s", request.remote)
        return ws

    async def broadcaster(app):
        async def loop():
            while True:
                await asyncio.sleep(interval)
                if clients:
                    payload = json.dumps(state.snapshot())
                    for ws in list(clients):
                        try:
                            await ws.send_str(payload)
                        except (ConnectionError, RuntimeError):
                            clients.discard(ws)
        task = asyncio.create_task(loop())
        yield
        task.cancel()

    async def cors(app, handler):
        async def mw(request):
            resp = await handler(request)
            resp.headers["Access-Control-Allow-Origin"] = "*"
            return resp
        return mw

    app = web.Application(middlewares=[cors])
    app.router.add_get("/", index)
    app.router.add_get("/state.json", state_json)
    app.router.add_get("/userdata.json", userdata_json)
    app.router.add_get("/ws", ws_handler)
    app.router.add_get("/settings", settings_page)
    app.router.add_get("/api/config", get_config)
    app.router.add_post("/api/config", post_config)
    app.cleanup_ctx.append(broadcaster)
    return app


def local_ips():
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(ips) or ["127.0.0.1"]


async def main_async(args, control=None):
    """Runs the bridge until stopped, or until control["restart"] is set (settings changed).
    Returns True to be started again with new settings."""
    control = control or {}
    config_mode = bool(control.get("config_path"))
    tasks = []
    transports = []
    restart = asyncio.Event()
    control["restart"] = restart
    state = BoatState()
    state.mark_range = args.mark_range
    loop = asyncio.get_running_loop()
    if args.gpx or args.tzdb:
        state.user = UserData(args.gpx or [], args.tzdb)

        async def watch_gpx():
            while True:
                try:
                    state.user.check()
                except Exception as e:  # never let a bad file stop the bridge
                    log.warning("GPX check failed: %s", e)
                await asyncio.sleep(5)
        tasks.append(asyncio.create_task(watch_gpx()))

    tz_tracks = args.tz_tracks
    if not tz_tracks and args.tzdb and (Path(args.tzdb).parent / "Tracks2.tzdb").exists():
        tz_tracks = str(Path(args.tzdb).parent / "Tracks2.tzdb")
    if tz_tracks:
        log.info("Reading TimeZero tracks from %s (within %g nm of the boat)", tz_tracks, args.tz_track_range)

        async def watch_tz_tracks():
            while True:
                key = state.tz_tracks_due(tz_tracks)
                if key:
                    lat, lon = state.own["lat"], state.own["lon"]
                    try:
                        tracks = await loop.run_in_executor(
                            None, load_tz_tracks, tz_tracks, lat, lon, args.tz_track_range, args.tz_track_points)
                        state.tz_tracks, state.tz_tracks_key = tracks, key
                        state.tz_tracks_version = time.time()
                        log.info("TimeZero tracks: %d runs, %d points near the boat",
                                 len(tracks), sum(len(t["points"]) for t in tracks))
                    except (sqlite3.Error, OSError) as e:
                        log.warning("Couldn't read %s (will retry): %s", tz_tracks, e)  # TimeZero mid-write
                await asyncio.sleep(5)
        tasks.append(asyncio.create_task(watch_tz_tracks()))

    fwd = None
    if args.forward_udp:
        host, port = args.forward_udp.rsplit(":", 1)
        fwd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        fwd_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        fwd = (fwd_sock, (host, int(port)))

    rec = None
    if args.record:
        # Raw NMEA exactly as received, one sentence per line, so --replay can play it back.
        # Appends, and flushes every line so nothing is lost if the window is closed.
        rec = open(args.record, "a", encoding="ascii", errors="ignore", newline="\r\n", buffering=1)
        log.info("Recording raw NMEA to %s", Path(args.record).resolve())

    def push(line, src="input"):
        if line.strip():
            st = state.inputs.setdefault(src, {"lines": 0, "last": 0.0})
            st["lines"] += 1
            st["last"] = time.time()
        state.feed(line)
        if rec and line.strip():
            rec.write(line.strip() + "\n")
        if fwd and line.strip():
            try:
                fwd[0].sendto((line.strip() + "\r\n").encode(), fwd[1])
            except OSError:
                pass

    def pusher(src):
        state.inputs.setdefault(src, {"lines": 0, "last": 0.0})
        return lambda line: push(line, src)

    def threadsafe(fn):
        return lambda *a: loop.call_soon_threadsafe(fn, *a)

    def noter(src):
        def note(text):
            state.inputs.setdefault(src, {"lines": 0, "last": 0.0})["note"] = text
        return threadsafe(note)

    stop = threading.Event()
    serial_threads = []
    for spec in args.serial or []:
        port, baud = parse_serial_spec(spec, args.baud)
        th = threading.Thread(target=serial_reader, args=(port, baud, threadsafe(pusher(port)), stop, noter(port)),
                              daemon=True)
        th.start()
        serial_threads.append(th)
    for udp_port in args.udp or []:
        name = f"UDP {udp_port}"
        try:
            tr, _ = await loop.create_datagram_endpoint(lambda p=pusher(name): UdpIn(p),
                                                        local_addr=("0.0.0.0", udp_port))
            transports.append(tr)
        except OSError as e:
            if config_mode:  # a service must keep running: show the problem on the status page instead
                state.inputs[name]["note"] = ("port in use by another program (often TimeZero itself); "
                                              "use a virtual COM port or TCP instead")
                log.warning("UDP port %d is in use by another program", udp_port)
                continue
            raise SystemExit(
                f"\nUDP port {udp_port} is already in use ({e.strerror}).\n"
                "Another program is listening on it: often an earlier bridge still running in another window,\n"
                "or TimeZero itself (its UDP connection binds the port it sends to). To see which, run in PowerShell:\n"
                f"  Get-NetUDPEndpoint -LocalPort {udp_port} | Select OwningProcess,"
                "@{n='Program';e={(Get-Process -Id $_.OwningProcess).ProcessName}}\n"
                "Close it, or use a TCP output or a virtual COM port instead (see the bridge README).")
        log.info("Listening for NMEA on UDP %d", udp_port)
    for spec in args.tcp or []:
        host, port = spec.rsplit(":", 1)
        tasks.append(asyncio.create_task(tcp_reader(host, int(port), pusher(f"TCP {spec}"))))
    if args.replay:
        tasks.append(asyncio.create_task(replay_reader(args.replay, args.rate, pusher(f"replay {Path(args.replay).name}"))))

    if not (args.serial or args.udp or args.tcp or args.replay):
        log.warning("No inputs set up yet: open the Settings page to choose where the NMEA comes from")
    control["running"] = {"serial": args.serial or [], "tcp": args.tcp or [], "udp": args.udp or [],
                          "tzdb": args.tzdb, "gpx": args.gpx or [], "record": args.record}
    control["web_port"] = args.port

    app = build_app(state, args.interval, control)
    runner = web.AppRunner(app)
    await runner.setup()
    try:
        await web.TCPSite(runner, "0.0.0.0", args.port).start()
    except OSError as e:
        await runner.cleanup()
        raise SystemExit(f"\nWeb port {args.port} is already in use ({e.strerror}). "
                         f"Close the other program or start with --port {args.port + 1}.")
    for ip in local_ips():
        log.info("Status page:  http://%s:%d/", ip, args.port)
        log.info("Live stream:  ws://%s:%d/ws", ip, args.port)
    try:
        await restart.wait()
        return True
    finally:
        stop.set()
        # Wait until every COM port is really closed, so a restart can open them again.
        for th in serial_threads:
            await loop.run_in_executor(None, th.join, 5)
            if th.is_alive():
                log.warning("A serial port is slow to close; it will be retried")
        for t in tasks:
            t.cancel()
        for tr in transports:
            tr.close()
        if rec:
            rec.close()
        await runner.cleanup()


def main():
    p = argparse.ArgumentParser(description="TimeZero NMEA to glasses bridge")
    src = p.add_argument_group("input (use one or more)")
    src.add_argument("--serial", action="append", metavar="COM[:BAUD]",
                     help="COM port to read; repeat for several. Add the speed per port, e.g. COM11:4800 "
                          "--serial COM12:38400, or COM12:auto to detect it")
    src.add_argument("--baud", default="4800",
                     help="speed for --serial ports that don't give one: 4800 (GPS, instruments), "
                          "38400 (AIS, high-speed), or auto")
    src.add_argument("--udp", type=int, action="append", help="listen for NMEA on this UDP port; repeatable")
    src.add_argument("--tcp", action="append", metavar="HOST:PORT",
                     help="connect to an NMEA TCP server (TimeZero TCP output, Actisense W2K-1...); repeatable")
    src.add_argument("--replay", help="replay a recorded .nmea/.txt log (for testing)")
    src.add_argument("--rate", type=float, default=10, help="replay lines per second")
    p.add_argument("--gpx", action="append",
                   help="GPX file or folder exported from TimeZero (marks, routes, tracks); repeatable")
    p.add_argument("--tzdb", help="TimeZero UserObjects.tzdb to read marks and routes from (read-only)")
    p.add_argument("--tz-tracks", help="TimeZero Tracks2.tzdb to read this boat's tracks from (read-only); "
                                       "found automatically next to --tzdb")
    p.add_argument("--tz-track-range", type=float, default=10.0, help="send TimeZero tracks within this many nm")
    p.add_argument("--tz-track-points", type=int, default=20000, help="at most this many TimeZero track points")
    p.add_argument("--mark-range", type=float, help="send marks within this many nm (default 10)")
    p.add_argument("--port", type=int, help="HTTP/WebSocket port (default 8080)")
    p.add_argument("--interval", type=float, default=0.5, help="seconds between live updates")
    p.add_argument("--config", help="settings file, edited on the Settings page "
                                     "(the installed bridge uses C:\\ProgramData\\TZ Glasses Bridge\\config.json)")
    p.add_argument("--record", help="also save the raw NMEA received to this file (appends; play it back with --replay)")
    p.add_argument("--forward-udp", help="also re-send raw NMEA to host:port (e.g. 255.255.255.255:10110)")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    # The packaged .exe with no inputs on its command line uses the settings file.
    if not args.config and FROZEN and not (args.serial or args.udp or args.tcp or args.replay):
        args.config = str(DEFAULT_CONFIG)
    if not args.config and not (args.serial or args.udp or args.tcp or args.replay):
        p.error("choose an input (--serial, --udp, --tcp or --replay), or use --config with the Settings page")
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    cli = vars(args).copy()
    try:
        while True:
            a = argparse.Namespace(**cli)
            control = {}
            if a.config:
                control["config_path"] = a.config
                apply_config(a, load_config(a.config), a.config)
            if a.port is None:
                a.port = 8080
            if a.mark_range is None:
                a.mark_range = 10.0
            if not asyncio.run(main_async(a, control)):
                break
            time.sleep(1)  # let serial ports close before reopening them
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
