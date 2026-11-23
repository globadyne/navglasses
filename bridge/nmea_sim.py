#!/usr/bin/env python3
"""
NMEA simulator: pretends to be TimeZero so you can test the bridge
without the boat. Outputs own ship, active route and AIS targets.

  python nmea_sim.py --udp 127.0.0.1:10110      (pair with: tz_bridge.py --udp 10110)
  python nmea_sim.py --serial COM11 --baud 38400 (pair with a virtual COM pair: tz_bridge.py --serial COM10)
  python nmea_sim.py --stdout > sample.nmea      (record a test log)
"""
import argparse
import math
import socket
import sys
import time
from datetime import datetime, timezone

from pyais.encode import encode_dict


def cs(body):
    c = 0
    for ch in body:
        c ^= ord(ch)
    return f"{c:02X}"


def sentence(body):
    return f"${body}*{cs(body)}"


def fmt_lat(lat):
    h = "N" if lat >= 0 else "S"
    lat = abs(lat)
    d = int(lat)
    return f"{d:02d}{(lat - d) * 60:07.4f}", h


def fmt_lon(lon):
    h = "E" if lon >= 0 else "W"
    lon = abs(lon)
    d = int(lon)
    return f"{d:03d}{(lon - d) * 60:07.4f}", h


def move(lat, lon, sog, cog, dt):
    dist = sog * dt / 3600.0  # nm
    lat2 = lat + dist * math.cos(math.radians(cog)) / 60.0
    lon2 = lon + dist * math.sin(math.radians(cog)) / (60.0 * math.cos(math.radians(lat)))
    return lat2, lon2


def offset(lat, lon, brg, nm):
    return move(lat, lon, nm * 3600, brg, 1)


def bearing_range(lat1, lon1, lat2, lon2):
    dx = (lon2 - lon1) * 60 * math.cos(math.radians(lat1))
    dy = (lat2 - lat1) * 60
    return (math.degrees(math.atan2(dx, dy)) + 360) % 360, math.hypot(dx, dy)


class Sim:
    def __init__(self):
        # own boat outbound from Halifax Harbour, heading roughly south-southeast
        self.lat, self.lon = 44.6205, -63.5560
        self.sog, self.base_hdg = 6.5, 160.0
        self.hdg = self.base_hdg
        self.t0 = time.time()
        self.wp_from = ("WP3", self.lat, self.lon)
        wl, wo = offset(self.lat, self.lon, 158, 4.0)
        self.wp_to = ("WP4 Harbour mouth", wl, wo)

        # AIS targets placed relative to own boat
        def place(brg, nm):
            return offset(self.lat, self.lon, brg, nm)
        self.targets = [
            dict(mmsi=316001234, name="ATLANTIC SAMPLE", ship_type=70, sog=12.0, cog=275.0, pos=place(130, 2.3)),
            dict(mmsi=316005678, name="BLUE HERON", ship_type=36, sog=4.5, cog=340.0, pos=place(200, 1.4)),
            dict(mmsi=316009012, name="HARBOUR FERRY", ship_type=60, sog=9.0, cog=60.0, pos=place(250, 1.8)),
            dict(mmsi=316003456, name="SEA SPRITE", ship_type=37, sog=0.2, cog=0.0, pos=place(40, 2.8)),
        ]
        self.aton = dict(mmsi=993160001, name="SAMPLE BUOY", pos=place(155, 1.2))
        self.tick = 0
        self.seq = 0

    def next_seq(self):
        self.seq = (self.seq + 1) % 10
        return self.seq

    def step(self, dt):
        t = time.time() - self.t0
        # gentle weave so heading and XTE change
        new_hdg = self.base_hdg + 4 * math.sin(t / 25.0)
        self.rot = (new_hdg - self.hdg) / dt * 60.0
        self.hdg = new_hdg
        self.lat, self.lon = move(self.lat, self.lon, self.sog, self.hdg, dt)
        for tg in self.targets:
            tg["pos"] = move(*tg["pos"], tg["sog"], tg["cog"], dt)
        self.tick += 1

    def own_sentences(self):
        now = datetime.now(timezone.utc)
        hms, dmy = now.strftime("%H%M%S.00"), now.strftime("%d%m%y")
        la, lah = fmt_lat(self.lat)
        lo, loh = fmt_lon(self.lon)
        out = [
            sentence(f"GPRMC,{hms},A,{la},{lah},{lo},{loh},{self.sog:.1f},{self.hdg:.1f},{dmy},17.0,W"),
            sentence(f"GPGGA,{hms},{la},{lah},{lo},{loh},1,10,0.9,5.0,M,-22.0,M,,"),
            sentence(f"GPVTG,{self.hdg:.1f},T,,M,{self.sog:.1f},N,{self.sog * 1.852:.1f},K,A"),
            sentence(f"HEHDT,{self.hdg:.1f},T"),
            sentence(f"HEROT,{self.rot:.1f},A"),
            sentence(f"SDDPT,{22 + 3 * math.sin(self.tick / 40):.1f},0.5"),
            sentence(f"WIMWV,{35 + 5 * math.sin(self.tick / 15):.0f},R,{14 + 2 * math.sin(self.tick / 9):.1f},N,A"),
        ]
        # active route, as TimeZero would send to an autopilot
        brg, rng = bearing_range(self.lat, self.lon, self.wp_to[1], self.wp_to[2])
        trk, _ = bearing_range(self.wp_from[1], self.wp_from[2], self.wp_to[1], self.wp_to[2])
        _, d_from = bearing_range(self.wp_from[1], self.wp_from[2], self.lat, self.lon)
        b_from, _ = bearing_range(self.wp_from[1], self.wp_from[2], self.lat, self.lon)
        xte = d_from * math.sin(math.radians(b_from - trk))  # + = right of track
        steer = "L" if xte > 0 else "R"
        wla, wlah = fmt_lat(self.wp_to[1])
        wlo, wloh = fmt_lon(self.wp_to[2])
        vmg = self.sog * math.cos(math.radians(self.hdg - brg))
        out.append(sentence(f"ECRMB,A,{abs(xte):.3f},{steer},{self.wp_from[0]},{self.wp_to[0]},"
                            f"{wla},{wlah},{wlo},{wloh},{rng:.2f},{brg:.1f},{vmg:.1f},V,A"))
        out.append(sentence(f"ECAPB,A,A,{abs(xte):.3f},{steer},N,V,V,{trk:.1f},T,{self.wp_to[0]},"
                            f"{brg:.1f},T,{brg:.1f},T,A"))
        # full active route every 10 s: waypoint positions (WPL) and order (RTE)
        if self.tick % 10 == 1:
            for name, lat, lon in (self.wp_from, self.wp_to):
                a, ah = fmt_lat(lat)
                o, oh = fmt_lon(lon)
                out.append(sentence(f"ECWPL,{a},{ah},{o},{oh},{name}"))
            out.append(sentence(f"ECRTE,1,1,c,Harbour run,{self.wp_from[0]},{self.wp_to[0]}"))
        return out

    def ais_sentences(self):
        out = []
        for tg in self.targets:
            if self.tick % 2 == 0:
                out += encode_dict({"type": 1 if tg["ship_type"] != 37 else 18, "mmsi": tg["mmsi"],
                                    "lat": tg["pos"][0], "lon": tg["pos"][1], "speed": tg["sog"],
                                    "course": tg["cog"], "heading": round(tg["cog"]) % 360},
                                   radio_channel="A", talker_id="AI", sentence_type="VDM")
            if self.tick % 20 == 1:
                out += encode_dict({"type": 5, "mmsi": tg["mmsi"], "shipname": tg["name"],
                                    "callsign": "SIM" + str(tg["mmsi"])[-3:], "ship_type": tg["ship_type"],
                                    "destination": "HALIFAX"},
                                   radio_channel="B", talker_id="AI", sentence_type="VDM", seq_id=self.next_seq())
        if self.tick % 20 == 3:
            out += encode_dict({"type": 21, "mmsi": self.aton["mmsi"], "name": self.aton["name"],
                                "lat": self.aton["pos"][0], "lon": self.aton["pos"][1], "aid_type": 22},
                               radio_channel="A", talker_id="AI", sentence_type="VDM")
        return out


def main():
    p = argparse.ArgumentParser(description="NMEA/AIS simulator for testing tz_bridge")
    p.add_argument("--udp", help="send to host:port, e.g. 127.0.0.1:10110")
    p.add_argument("--serial", help="write to a COM port, e.g. COM11")
    p.add_argument("--baud", type=int, default=38400)
    p.add_argument("--stdout", action="store_true")
    p.add_argument("--seconds", type=float, default=0, help="stop after N seconds (0 = run forever)")
    p.add_argument("--fast", action="store_true", help="no real-time delay (for recording logs)")
    a = p.parse_args()
    if not (a.udp or a.serial or a.stdout):
        p.error("choose an output: --udp, --serial or --stdout")

    sinks = []
    if a.udp:
        host, port = a.udp.rsplit(":", 1)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sinks.append(lambda ln: s.sendto((ln + "\r\n").encode(), (host, int(port))))
    if a.serial:
        import serial
        ser = serial.Serial(a.serial, a.baud)
        sinks.append(lambda ln: ser.write((ln + "\r\n").encode()))
    if a.stdout:
        sinks.append(lambda ln: (sys.stdout.write(ln + "\r\n"), sys.stdout.flush()))

    sim, start = Sim(), time.time()
    while not a.seconds or time.time() - start < a.seconds:
        sim.step(1.0)
        for ln in sim.own_sentences() + sim.ais_sentences():
            for sink in sinks:
                sink(ln)
        if not a.fast:
            time.sleep(1.0)


if __name__ == "__main__":
    main()
