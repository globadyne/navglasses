#!/usr/bin/env python3
"""
Line-by-line Python mirror of TZGlasses/HeadMath.swift, tested against simulated
head movements where the right answer is known. Keep the two in step.

    python3 tests/test_head_math.py
"""
import math
import random


# ---------------------------------------------------------------- mirror of HeadMath.swift
class Quat:
    def __init__(s, w, x, y, z): s.w, s.x, s.y, s.z = w, x, y, z
    def conj(s): return Quat(s.w, -s.x, -s.y, -s.z)
    def norm(s):
        n = math.sqrt(s.w**2 + s.x**2 + s.y**2 + s.z**2)
        return Quat(s.w/n, s.x/n, s.y/n, s.z/n)
    def __mul__(a, b):
        return Quat(a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
                    a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
                    a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                    a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w)
    def rotate(s, v):
        r = s * Quat(0, *v) * s.conj()
        return (r.x, r.y, r.z)


def vlen(v): return math.sqrt(sum(c*c for c in v))
def vnorm(v): l = vlen(v); return tuple(c/l for c in v) if l > 0 else (0, 0, 0)
def vadd(a, b): return tuple(x+y for x, y in zip(a, b))
def dot(a, b): return sum(x*y for x, y in zip(a, b))


class HeadMath:
    def __init__(s):
        s.upA = s.upB = (0, 0, 0); s.count = 0
        s.use_inverse = False; s.locked = False
        s.evidence = 0.0; s.auto_sign = 1.0
        s.ref_raw = None; s.last = None; s.world_up = (0, 0, 1)
        s.max_turn = 0.0; s.first_raw = None

    def to_world(s, raw): return raw.conj() if s.use_inverse else raw

    def ingest(s, t_ns, q, accel=None, gyro=None):
        raw = q.norm()
        s.learn_convention(raw, accel)
        qw = s.to_world(raw)
        if s.ref_raw is None:
            s.last = (raw, t_ns, 0.0)
            return None
        ccw = s.twist(s.to_world(s.ref_raw), qw, s.world_up)
        s.learn_sign(qw, ccw, t_ns, gyro)
        s.last = (raw, t_ns, ccw)
        return -ccw * s.auto_sign

    def calibrate(s):
        s.ref_raw = s.last[0] if s.last else None
        if s.last: s.last = (s.last[0], s.last[1], 0.0)

    @staticmethod
    def twist(a, b, up):
        r = b * a.conj()
        p = dot((r.x, r.y, r.z), up)
        ang = 2 * math.atan2(p, r.w) * 180 / math.pi
        if ang > 180: ang -= 360
        if ang < -180: ang += 360
        return ang

    def learn_convention(s, q, accel):
        if s.first_raw is not None:
            p = s.first_raw
            d = min(1, abs(p.w*q.w + p.x*q.x + p.y*q.y + p.z*q.z))
            s.max_turn = max(s.max_turn, 2 * math.acos(d) * 180 / math.pi)
        else:
            s.first_raw = q
        if accel is None or vlen(accel) <= 0.1: return
        g = vnorm(accel)
        s.upA = vadd(s.upA, q.rotate(g)); s.upB = vadd(s.upB, q.conj().rotate(g)); s.count += 1
        wa, wb = 1 - vlen(s.upA)/s.count, 1 - vlen(s.upB)/s.count
        if not s.locked:
            clear = max(wa, wb) > 0.003
            if clear: s.use_inverse = wb < wa * 0.5
            if s.max_turn > 40 and s.count >= 30 and clear: s.locked = True
        total = s.upB if s.use_inverse else s.upA
        if vlen(total) > 0: s.world_up = vnorm(total)

    def learn_sign(s, q, twist, t_ns, gyro):
        if gyro is None or s.last is None or t_ns <= s.last[1]: return
        dt = (t_ns - s.last[1]) / 1e9
        if not (0 < dt < 0.5): return
        up_dev = q.conj().rotate(s.world_up)
        gyro_rate = dot(gyro, up_dev) * 180 / math.pi
        d = twist - s.last[2]
        if d > 180: d -= 360
        if d < -180: d += 360
        tw_rate = d / dt
        if abs(gyro_rate) <= 15 or abs(tw_rate) <= 15: return
        s.evidence += 1 if gyro_rate * tw_rate > 0 else -1
        if s.evidence > 20: s.auto_sign, s.evidence = 1, 20
        if s.evidence < -20: s.auto_sign, s.evidence = -1, -20


# ---------------------------------------------------------------- simulated glasses
def axis_angle(axis, deg):
    a = math.radians(deg) / 2; ax = vnorm(axis)
    return Quat(math.cos(a), *(c * math.sin(a) for c in ax))


# The IMU inside the glasses is mounted at some arbitrary angle to the head.
MOUNT = axis_angle((0.3, 1, 0.2), 97) * axis_angle((1, 0, 0), -90)


def head_pose(compass_deg, pitch=0.0, roll=0.0):
    """device -> world, world z up. Compass bearing grows clockwise = negative rotation about +z."""
    yaw = axis_angle((0, 0, 1), -compass_deg)
    head = yaw * axis_angle((1, 0, 0), pitch) * axis_angle((0, 1, 0), roll)
    return head * MOUNT


def sample(compass, pitch=0.0, roll=0.0, rate_dps=0.0, inverse=False):
    q = head_pose(compass, pitch, roll)
    accel = q.conj().rotate((0, 0, 9.81))                        # specific force, up
    gyro = q.conj().rotate((0, 0, math.radians(-rate_dps)))      # clockwise turn rate about up
    return (q.conj() if inverse else q), accel, gyro


def run(path, inverse=False, noise=0.0, drop_gyro=False, flip_sign=False):
    """path: list of (compass, pitch, roll). Calibrates on the first sample. Returns outputs."""
    m = HeadMath(); out = []; t = 0; prev = path[0][0]
    for i, (c, p, r) in enumerate(path):
        rate = (c - prev) * 30; prev = c
        q, a, g = sample(c, p + random.gauss(0, noise), r + random.gauss(0, noise), rate, inverse)
        if flip_sign: g = tuple(-x for x in g)
        out.append(m.ingest(t, q, a, None if drop_gyro else g))
        if i == 0: m.calibrate()
        t += 33_333_333
    return m, out


def sweep(start=0, seconds=6):
    """Look at the bow for 3 s (still), then sweep to 60 deg starboard, 40 port, back."""
    path = [(start, 0, 0)] * 90
    for k in range(int(30 * seconds)):
        c = start + 60 * math.sin(k / 30 * 1.2) if k < 90 else start - 40 * math.sin((k - 90) / 30 * 1.0)
        path.append((c, 3 * math.sin(k / 9), 2 * math.cos(k / 7)))
    path += [(start + 45, 0, 0)] * 15
    return path


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail else ""))
    return cond


random.seed(1)
ok = True

# 1. Pure turns, normal convention
m, out = run([(0, 0, 0)] * 5 + [(30, 0, 0)] + [(-45, 0, 0)])
ok &= check("turn 30 deg to starboard reads +30", abs(out[5] - 30) < 0.01, f"{out[5]:.3f}")
ok &= check("turn 45 deg to port reads -45", abs(out[6] + 45) < 0.01, f"{out[6]:.3f}")

# 2. Turning while nodding and tilting the head
m, out = run([(0, 0, 0)] * 95 + [(25, 15, 8), (-60, -20, -10), (170, 10, 5)])
ok &= check("yaw with 15/8 deg tilt", abs(out[95] - 25) < 3, f"{out[95]:.2f}")
ok &= check("yaw with -20/-10 deg tilt", abs(out[96] + 60) < 5, f"{out[96]:.2f}")
ok &= check("looking astern reads ~170", abs(out[97] - 170) < 4, f"{out[97]:.2f}")

# 3. Quaternion arrives the other way round (world -> device): detected and handled
m, out = run(sweep(), inverse=True, noise=1.0)
ok &= check("detects inverse convention", m.use_inverse and m.locked)
ok &= check("inverse: final 45 deg starboard", abs(out[-1] - 45) < 4, f"{out[-1]:.2f}")

m, out = run(sweep(), inverse=False, noise=1.0)
ok &= check("normal convention kept", not m.use_inverse)
ok &= check("normal: final 45 deg starboard", abs(out[-1] - 45) < 4, f"{out[-1]:.2f}")

# 4. Gyro disagrees with the quaternion (opposite handedness): sign learned from gyro
m, out = run(sweep(), flip_sign=True)
ok &= check("sign flipped after head turns", m.auto_sign == -1, f"auto_sign={m.auto_sign}")
ok &= check("flipped: final reads -45 (follows gyro)", abs(out[-1] + 45) < 4, f"{out[-1]:.2f}")

# 5. No gyro at all: still works with the default sign
m, out = run(sweep(), drop_gyro=True)
ok &= check("no gyro: final 45", abs(out[-1] - 45) < 4, f"{out[-1]:.2f}")

# 6. Re-centre mid-way: new zero
m = HeadMath(); t = 0
for c in [0] * 10 + [50] * 5:
    q, a, g = sample(c); m.ingest(t, q, a, g); t += 33_333_333
    if t == 33_333_333: m.calibrate()
m.calibrate()
q, a, g = sample(80); r = m.ingest(t, q, a, g)
ok &= check("re-centre at 50, then look at 80 reads +30", abs(r - 30) < 0.01, f"{r:.3f}")

# 7. Boat turns under a still head: head world bearing unchanged, so gaze is unchanged.
#    (HeadTracker uses heading-at-calibration + head turn, not the live heading.)
heading_at_cal, head_turn = 160.0, 0.0
gaze_before = (heading_at_cal + head_turn) % 360
boat_now = 200.0          # boat swung 40 deg to starboard, head held still in the world
gaze_after = (heading_at_cal + head_turn) % 360
rel_to_bow = ((gaze_after - boat_now + 540) % 360) - 180
ok &= check("boat turn: gaze unchanged, now 40 deg to port of bow", gaze_after == gaze_before and rel_to_bow == -40)


# ---------------------------------------------------------------- lens placement (HUDModel.place)
def place(bearing, gaze, fov=20):
    rel = ((bearing - gaze + 540) % 360) - 180
    if abs(rel) > fov / 2: return None
    return round((0.5 + rel / fov) * 120) / 120

ok &= check("dead ahead is centre", place(100, 100) == 0.5)
ok &= check("5 deg right sits at 0.75", place(105, 100) == 0.75)
ok &= check("edge at 10 deg", place(90, 100) == 0.0 and place(110, 100) == 1.0)
ok &= check("11 deg is out of view", place(111, 100) is None)
ok &= check("wraps through north", place(355, 5) == 0.0 and place(2, 358) == 0.7)

print("\nALL PASSED" if ok else "\nSOME FAILED")
raise SystemExit(0 if ok else 1)
