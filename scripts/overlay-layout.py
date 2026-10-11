#!/usr/bin/env python3
"""The WayVR panel layouts, one set each. Switch between them on the watch.

    set 1, desk    two monitors as one curved ultrawide, the keyboard under them
    set 2, side    one monitor to the right for a glance at a page, the keyboard
                   straight ahead and low

    overlay-layout.py write STATE   write the layouts into WayVR's saved state
    overlay-layout.py check STATE   exit 0 if STATE holds the layouts, 1 if not

Write only while WayVR is stopped: WayVR saves its state on exit and would
overwrite the file.

WayVR keeps one transform per overlay, relative to the anchor of its set
(saved_transform). glam serializes an Affine3A column-wise: the x, y and z axes,
then the translation. The axes carry the scale, and a scale of 1 is 1 m of width.
"""
import json
import math
import re
import sys

# The set anchor sits 1 m in front of the head (anchor_local = NEG_Z), so a
# distance from the head D becomes z = ANCHOR - D in anchor space.
ANCHOR = 1.0

# Monitors: W m wide each, on one cylinder of radius R around the head, so the
# two curved panels continue each other like one ultrawide screen. Y is the
# height of their centre above eye level.
W, R, Y = 1.0, 0.85, 0.1

# Keyboard: KW m wide, tilted KP degrees, its top edge GAP m below the bottom edge
# of the monitors and BACK m nearer to the head than the cylinder.
KW, KP, GAP, BACK = 0.6, -30.0, 0.05, 0.15

# KDE places DP-4 at x=0 and DP-3 at x=2560, so DP-4 goes on the left.
LEFT, RIGHT, KEYBOARD = "DP-4", "DP-3", "kbd"

# Side set: the SIDE monitor, SW m wide, SR m from the head, SPHI degrees to the
# right of straight ahead, its centre SY m above eye level.
SIDE = RIGHT
SW, SR, SPHI, SY = 0.8, 0.8, 45.0, -0.05

# The panels are pinned: a grip on them does nothing, so a stray hand cannot
# move them. The set as a whole still moves with a recenter.
PINNED = True

GLOBAL_SET = "global"
TOLERANCE = 1e-4


def affine(scale, yaw_deg, pitch_deg, t):
    """R = Ry(yaw) * Rx(pitch), scaled, as glam's 12 serialized values."""
    cy, sy = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    cp, sp = math.cos(math.radians(pitch_deg)), math.sin(math.radians(pitch_deg))
    axes = ((cy, 0.0, -sy), (sy * sp, cp, cy * sp), (sy * cp, -sp, cy * cp))
    return [round(c * scale, 6) for axis in axes for c in axis] + [round(v, 6) for v in t]


def desk_layout():
    """Returns {overlay: (saved_transform, curvature or None)} for the desk set."""
    # One panel is an arc of W on the cylinder. Its centre sits half that arc
    # away from the middle and faces the head.
    theta = W / (2 * R)
    cx, cz, yaw = R * math.sin(theta), ANCHOR - R * math.cos(theta), math.degrees(theta)
    # SteamVR curvature is a fraction of a full circle: width / (2 pi r).
    curve = round(W / (2 * math.pi * R), 6)

    # The 16:9 monitors are W * 9/16 m tall. The keyboard is 6 rows of 23 units.
    kh = KW * 6 / 23
    kd = R - BACK - (kh / 2) * math.sin(math.radians(-KP))
    ky = Y - W * 9 / 32 - GAP - (kh / 2) * math.cos(math.radians(KP))

    return {
        LEFT: (affine(W, yaw, 0.0, (-cx, Y, cz)), curve),
        RIGHT: (affine(W, -yaw, 0.0, (cx, Y, cz)), curve),
        KEYBOARD: (affine(KW, 0.0, KP, (0.0, ky, ANCHOR - kd)), None),
    }


def side_layout():
    """Returns {overlay: (saved_transform, curvature or None)} for the side set."""
    # The monitor sits on a cylinder of radius SR at angle SPHI and faces the head.
    phi = math.radians(SPHI)
    curve = round(SW / (2 * math.pi * SR), 6)
    return {
        SIDE: (affine(SW, -SPHI, 0.0, (SR * math.sin(phi), SY, ANCHOR - SR * math.cos(phi))), curve),
        # The keyboard keeps its place from the desk set: straight ahead and low.
        KEYBOARD: desk_layout()[KEYBOARD],
    }


LAYOUTS = (desk_layout, side_layout)


def load(path):
    try:
        text = open(path).read()
    except FileNotFoundError:
        return {"sets": [], "spawn_overlays": [], "last_set": 0, "attribs": []}
    # json5 allows trailing commas; plain json does not.
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", text))


def overlay_template():
    return {
        "alpha": 1.0, "grabbable": True, "interactable": True,
        "positioning": "Anchored", "curvature": 0.15, "additive": False,
        "saved_transform": None, "block_input": True, "angle_fade": False,
        "align_to_hmd": False,
    }


def write(path):
    state = load(path)
    sets = [s for s in state["sets"] if s.get("name") != GLOBAL_SET]
    glob = [s for s in state["sets"] if s.get("name") == GLOBAL_SET]
    out = []
    for i, layout in enumerate(LAYOUTS):
        st = sets[i] if i < len(sets) else {"name": "", "overlays": {}, "hidden_overlays": {}}
        wanted = layout()
        # Each set shows exactly its own panels. A monitor left over from an
        # earlier layout would cover the others.
        st["overlays"] = {n: o for n, o in st["overlays"].items()
                          if n in wanted or not n.startswith("DP-")}
        for name, (transform, curve) in wanted.items():
            o = dict(st["overlays"].get(name) or overlay_template())
            o["saved_transform"] = transform
            o["grabbable"] = not PINNED
            if curve is not None:
                o["curvature"] = curve
            st["overlays"][name] = o
        st["hidden_overlays"] = {}
        out.append(st)
    state["sets"] = out + glob
    if state.get("last_set", 0) >= len(out):
        state["last_set"] = 0
    with open(path, "w") as f:
        f.write(json.dumps(state, indent=2) + "\n")


def close(a, b):
    return a is not None and b is not None and len(a) == len(b) and \
        all(abs(x - y) <= TOLERANCE for x, y in zip(a, b))


def check(path):
    sets = [s for s in load(path)["sets"] if s.get("name") != GLOBAL_SET]
    if len(sets) != len(LAYOUTS):
        return False
    for st, layout in zip(sets, LAYOUTS):
        overlays = st.get("overlays", {})
        wanted = layout()
        if any(n.startswith("DP-") and n not in wanted for n in overlays):
            return False
        for name, (transform, curve) in wanted.items():
            o = overlays.get(name)
            if not o or not close(o.get("saved_transform"), transform):
                return False
            if o.get("grabbable") != (not PINNED):
                return False
            if curve is not None and not close([o.get("curvature")], [curve]):
                return False
    return True


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("write", "check"):
        sys.exit(__doc__)
    if sys.argv[1] == "write":
        write(sys.argv[2])
    else:
        sys.exit(0 if check(sys.argv[2]) else 1)
