"""Library-clip -> R15 animation retargeter (the Pilot Doctrine's animation leg, slice 2).

Pure-python world-space delta retargeting — no Blender needed for this leg (the banked plan
reached for copy-rotation constraints; the constraint math reduces to quaternion algebra on
data meshio.parse_animation already extracts, because R15 block-rig Motor6D joint frames are
WORLD-ALIGNED at rest — C0/C1 are translation-only):

    Transform(J, t) = Dw(parentBone(J), t)^-1 * Dw(bone(J), t)
    where Dw(B, t)  = Wanim(B, t) * Wrest(B)^-1   (B's world-rotation delta from ITS rest)

The product TELESCOPES down the joint chain, so the R15 rig reproduces the source skeleton's
WORLD orientations frame-by-frame regardless of proportion differences, and unmapped
intermediate bones (clavicles, the 3-segment spine, fingers) fold into their nearest mapped
ancestor automatically. Assumes source rest pose ~= R15 rest pose per mapped bone (both
T-pose families — verify by filmstrip; a per-bone rest-offset correction is the escalation).

Output JSON (per clip): {clip, duration_s, fps, joints: {R15JointName: {times: [...],
rot: [[qx,qy,qz,qw], ...]}}} — quaternions land in Luau as CFrame.new(0,0,0, qx,qy,qz,qw)
for KeyframeSequence Poses. Root translation is NOT emitted (v1: in-place clips).

The UAL2->R15 name map covers Quaternius' UE-mannequin-style skeleton (Universal Animation
Library 2); other libraries add their own map here.
"""

import json
import math
import os

import meshio

SPEC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "specs", "r15-skeleton.json")

# R15 Motor6D joint -> (source bone, source bone of the R15 PARENT joint; None = world/HRP).
# World-delta division by the parent bone makes intermediate source bones fold in.
UAL2_MAP = {
    "Root": ("pelvis", None),
    "Waist": ("spine_03", "pelvis"),
    "Neck": ("Head", "spine_03"),
    "LeftShoulder": ("upperarm_l", "spine_03"),
    "LeftElbow": ("lowerarm_l", "upperarm_l"),
    "LeftWrist": ("hand_l", "lowerarm_l"),
    "RightShoulder": ("upperarm_r", "spine_03"),
    "RightElbow": ("lowerarm_r", "upperarm_r"),
    "RightWrist": ("hand_r", "lowerarm_r"),
    "LeftHip": ("thigh_l", "pelvis"),
    "LeftKnee": ("calf_l", "thigh_l"),
    "LeftAnkle": ("foot_l", "calf_l"),
    "RightHip": ("thigh_r", "pelvis"),
    "RightKnee": ("calf_r", "thigh_r"),
    "RightAnkle": ("foot_r", "calf_r"),
}


# ---- quaternion helpers (xyzw, right-handed, unit) ----

def q_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return [
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ]


def q_inv(q):
    return [-q[0], -q[1], -q[2], q[3]]


def q_norm(q):
    m = math.sqrt(sum(c * c for c in q)) or 1.0
    return [c / m for c in q]


def q_slerp(a, b, t):
    """Normalized-lerp with shortest-path sign fix — indistinguishable from true slerp at the
    dense keyframe spacing baked library clips use, and total (no domain errors)."""
    d = sum(x * y for x, y in zip(a, b))
    if d < 0.0:
        b = [-c for c in b]
    return q_norm([x + (y - x) * t for x, y in zip(a, b)])


# ---- glTF skeleton walk ----

def _rest_locals(gltf):
    """node index -> rest local rotation (xyzw). Matrix-form nodes are not expected in
    Quaternius exports; rotation defaults to identity."""
    out = {}
    for i, n in enumerate(gltf.get("nodes", [])):
        out[i] = list(n.get("rotation", [0.0, 0.0, 0.0, 1.0]))
    return out


def _parents(gltf):
    parent = {}
    for ni, n in enumerate(gltf.get("nodes", [])):
        for c in n.get("children", []):
            parent[int(c)] = ni
    return parent


def _name_index(gltf):
    return {n.get("name", f"node{i}"): i for i, n in enumerate(gltf.get("nodes", []))}


def q_rot_vec(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    uvx = 2 * (y * vz - z * vy)
    uvy = 2 * (z * vx - x * vz)
    uvz = 2 * (x * vy - y * vx)
    return [
        vx + w * uvx + (y * uvz - z * uvy),
        vy + w * uvy + (z * uvx - x * uvz),
        vz + w * uvz + (x * uvy - y * uvx),
    ]


def q_from_to(a, b):
    """Shortest-arc quaternion rotating unit vector a onto unit vector b (xyzw)."""
    d = max(-1.0, min(1.0, sum(x * y for x, y in zip(a, b))))
    if d > 0.99999:
        return [0.0, 0.0, 0.0, 1.0]
    if d < -0.99999:
        ax = [0.0, -a[2], a[1]] if abs(a[0]) < 0.9 else [-a[1], a[0], 0.0]
        m = math.sqrt(sum(c * c for c in ax)) or 1.0
        return [ax[0] / m, ax[1] / m, ax[2] / m, 0.0]
    cx = a[1] * b[2] - a[2] * b[1]
    cy = a[2] * b[0] - a[0] * b[2]
    cz = a[0] * b[1] - a[1] * b[0]
    return q_norm([cx, cy, cz, 1.0 + d])


def _rest_world_positions(gltf):
    """node index -> rest world position (composing the TRS chain; scale ignored — Quaternius
    exports are unit-scale)."""
    nodes = gltf.get("nodes", [])
    parent = _parents(gltf)
    cache = {}

    def pos(ni):
        if ni in cache:
            return cache[ni]
        chain = []
        n = ni
        while n is not None:
            chain.append(n)
            n = parent.get(n)
        q = [0.0, 0.0, 0.0, 1.0]
        t = [0.0, 0.0, 0.0]
        for n in reversed(chain):
            node = nodes[n]
            lt = list(node.get("translation", [0.0, 0.0, 0.0]))
            rt = q_rot_vec(q, lt)
            t = [t[i] + rt[i] for i in range(3)]
            q = q_mul(q, list(node.get("rotation", [0.0, 0.0, 0.0, 1.0])))
        cache[ni] = t
        return t

    return {i: pos(i) for i in range(len(nodes))}


# Source bone -> the bone whose rest position defines its DIRECTION (limb child). Bones absent
# here (torso chain, head, feet) keep identity alignment — near-vertical on both skeletons.
UAL2_DIR_CHILD = {
    "upperarm_l": "lowerarm_l", "lowerarm_l": "hand_l", "hand_l": "middle_01_l",
    "upperarm_r": "lowerarm_r", "lowerarm_r": "hand_r", "hand_r": "middle_01_r",
    "thigh_l": "calf_l", "calf_l": "foot_l",
    "thigh_r": "calf_r", "calf_r": "foot_r",
}

# R15 joint -> (pivot of, pivot toward) for the TARGET rest limb direction, from the skeleton
# spec. Wrists point straight down at rest (no finger pivot in the spec).
R15_DIR = {
    "LeftShoulder": ("LeftShoulder", "LeftElbow"), "LeftElbow": ("LeftElbow", "LeftWrist"),
    "LeftWrist": ("LeftWrist", None),
    "RightShoulder": ("RightShoulder", "RightElbow"), "RightElbow": ("RightElbow", "RightWrist"),
    "RightWrist": ("RightWrist", None),
    "LeftHip": ("LeftHip", "LeftKnee"), "LeftKnee": ("LeftKnee", "LeftAnkle"),
    "RightHip": ("RightHip", "RightKnee"), "RightKnee": ("RightKnee", "RightAnkle"),
}


def _conv(q):
    """glTF-world -> Roblox-world: characters face +Z in glTF, -Z in Roblox — RotY(pi)
    conjugation, which on quaternions flips the X and Z components (measured live: without it
    the rig scrambles)."""
    return [-q[0], q[1], -q[2], q[3]]


def _alignments(gltf, name_map, spec_path):
    """Per-SOURCE-BONE rest-offset quaternions A_b: the shortest arc taking the TARGET's rest
    limb direction onto the (facing-converted) SOURCE rest limb direction. Bridges mismatched
    rest poses (R15 rests arms-down ~33deg off vertical; UAL2 rests in a T-pose — measured:
    pure world-deltas left the rig in a twisted crouch). Bones without direction data stay
    identity."""
    with open(spec_path or SPEC_PATH, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    pivots = {j["name"]: [j["pivot"]["x"], j["pivot"]["y"], j["pivot"]["z"]] for j in spec["joints"]}
    names = _name_index(gltf)
    positions = _rest_world_positions(gltf)
    align = {}
    for joint, (bone, _pbone) in name_map.items():
        childname = UAL2_DIR_CHILD.get(bone)
        dirspec = R15_DIR.get(joint)
        if childname is None or dirspec is None:
            continue
        if bone not in names or childname not in names:
            continue
        a = positions[names[bone]]
        b = positions[names[childname]]
        sdir = [b[i] - a[i] for i in range(3)]
        m = math.sqrt(sum(c * c for c in sdir))
        if m < 1e-6:
            continue
        sdir = [c / m for c in sdir]
        sdir = [-sdir[0], sdir[1], -sdir[2]]  # facing conversion, vector form
        p_from, p_to = dirspec
        if p_to is None:
            tdir = [0.0, -1.0, 0.0]
        else:
            pa, pb = pivots[p_from], pivots[p_to]
            tdir = [pb[i] - pa[i] for i in range(3)]
            tm = math.sqrt(sum(c * c for c in tdir)) or 1.0
            tdir = [c / tm for c in tdir]
        align[bone] = q_from_to(tdir, sdir)
    return align


def _sample(track, t):
    """Sample a {times, values} rotation channel at time t (LINEAR, clamped ends)."""
    times, values = track["times"], track["values"]
    if not times:
        return None
    if t <= times[0]:
        return list(values[0])
    if t >= times[-1]:
        return list(values[-1])
    lo, hi = 0, len(times) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if times[mid] <= t:
            lo = mid
        else:
            hi = mid
    span = times[hi] - times[lo]
    f = (t - times[lo]) / span if span > 0 else 0.0
    return q_slerp(list(values[lo]), list(values[hi]), f)


def retarget_clip(glb_path, clip_name, fps=30, name_map=None, spec_path=None):
    """Retarget one named library clip onto the R15 skeleton. Returns the joints-JSON dict."""
    name_map = name_map or UAL2_MAP
    clip = meshio.parse_animation(glb_path, clip_name)
    gltf, _ = meshio._read_glb(glb_path)
    rest = _rest_locals(gltf)
    parent = _parents(gltf)
    names = _name_index(gltf)

    # animated local-rotation channels by node index
    channels = {}
    for node_name, chans in clip["joints"].items():
        if "rotation" in chans and node_name in names:
            channels[names[node_name]] = chans["rotation"]

    duration = clip["duration_s"]
    steps = max(1, round(duration * fps))
    times = [round(i * duration / steps, 5) for i in range(steps + 1)]

    def world_rot(ni, t, animated):
        q = None
        node = ni
        while node is not None:
            local = None
            if animated and node in channels:
                local = _sample(channels[node], t)
            if local is None:
                local = rest.get(node, [0.0, 0.0, 0.0, 1.0])
            q = local if q is None else q_mul(local, q)
            node = parent.get(node)
        return q_norm(q if q is not None else [0.0, 0.0, 0.0, 1.0])

    # world deltas per mapped source bone, per grid time
    needed = set()
    for bone, pbone in name_map.values():
        needed.add(bone)
        if pbone is not None:
            needed.add(pbone)
    deltas = {}
    for bone in needed:
        ni = names.get(bone)
        if ni is None:
            continue
        w_rest = world_rot(ni, 0.0, animated=False)
        w_rest_inv = q_inv(w_rest)
        deltas[bone] = [q_norm(q_mul(world_rot(ni, t, animated=True), w_rest_inv)) for t in times]

    align = _alignments(gltf, name_map, spec_path)
    identity = [0.0, 0.0, 0.0, 1.0]

    joints = {}
    for joint, (bone, pbone) in name_map.items():
        if bone not in deltas:
            continue
        if pbone is not None and pbone not in deltas:
            continue  # named parent missing from the file: an undivided track would DOUBLE-COUNT
            # inherited motion — omit the joint rather than emit a knowingly-wrong channel
        a_b = align.get(bone, identity)
        a_p = align.get(pbone, identity) if pbone is not None else identity
        track = []
        moving = False
        for i in range(len(times)):
            # Transform = A_p^-1 * Conv(Dp)^-1 * Conv(Db) * A_b  — facing-converted world deltas
            # (RotY(pi) conjugation; measured: raw axes scramble the rig) bridged across the
            # mismatched rest poses by the per-bone alignment offsets.
            db = _conv(deltas[bone][i])
            d = db
            if pbone is not None and pbone in deltas:
                d = q_mul(q_inv(_conv(deltas[pbone][i])), db)
            d = q_norm(q_mul(q_inv(a_p), q_mul(d, a_b)))
            if abs(d[3]) < 0.99999:  # any real rotation on any frame -> keep the track
                moving = True
            track.append([round(c, 5) for c in d])
        if moving:
            joints[joint] = {"times": times, "rot": track}

    return {
        "clip": clip_name,
        "duration_s": duration,
        "fps": fps,
        "source": os.path.basename(glb_path),
        "joints": joints,
    }


# ---- Kimodo (SMPL-X) -> R15 via direction-matching forward kinematics ----
#
# The world-delta/orientation approach fights the T-pose(SMPL-X) vs arms-down(R15) rest mismatch.
# Direction matching sidesteps it: aim each R15 bone straight along the corresponding SMPL-X bone's
# WORLD direction (from posed_joints), so the rig reproduces the source's limb DIRECTIONS frame by
# frame regardless of rest pose. Loses bone-twist (a v2 concern); reads correct for locomotion/melee.
#
# SMPL-X world -> Roblox world (MEASURED live 2026-07-12 off the rig + the generated data): R15
# faces -Z with +X=right; SMPL-X faces +Z with +X=left -> RotY(pi): (x,y,z)->(-x,y,-z).
#
# Each row: (R15 joint, R15 part, R15 parent part, SMPL-X from-joint, to-joint, R15 rest bone dir).
# SMPL-X 22-joint indices: 0 pelvis 1 lhip 2 rhip 3 spine1 4 lknee 5 rknee 6 spine2 7 lankle 8 rankle
# 9 spine3 10 lfoot 11 rfoot 12 neck 13 lcollar 14 rcollar 15 head 16 lsho 17 rsho 18 lelb 19 relb
# 20 lwr 21 rwr.
KIMODO_SMPLX_CHAIN = [
    ("Root", "LowerTorso", "HumanoidRootPart", 0, 6, (0.0, 1.0, 0.0)),
    ("Waist", "UpperTorso", "LowerTorso", 6, 12, (0.0, 1.0, 0.0)),
    ("Neck", "Head", "UpperTorso", 12, 15, (0.0, 1.0, 0.0)),
    ("RightShoulder", "RightUpperArm", "UpperTorso", 17, 19, (0.0, -1.0, 0.0)),
    ("RightElbow", "RightLowerArm", "RightUpperArm", 19, 21, (0.0, -1.0, 0.0)),
    ("LeftShoulder", "LeftUpperArm", "UpperTorso", 16, 18, (0.0, -1.0, 0.0)),
    ("LeftElbow", "LeftLowerArm", "LeftUpperArm", 18, 20, (0.0, -1.0, 0.0)),
    ("RightHip", "RightUpperLeg", "LowerTorso", 2, 5, (0.0, -1.0, 0.0)),
    ("RightKnee", "RightLowerLeg", "RightUpperLeg", 5, 8, (0.0, -1.0, 0.0)),
    ("LeftHip", "LeftUpperLeg", "LowerTorso", 1, 4, (0.0, -1.0, 0.0)),
    ("LeftKnee", "LeftLowerLeg", "LeftUpperLeg", 4, 7, (0.0, -1.0, 0.0)),
]


# SMPL-X L/R joint-index swap (for mirroring a clip left<->right across the sagittal plane).
_SMPLX_LR_SWAP = {1: 2, 2: 1, 4: 5, 5: 4, 7: 8, 8: 7, 10: 11, 11: 10, 13: 14, 14: 13,
                  16: 17, 17: 16, 18: 19, 19: 18, 20: 21, 21: 20}
KIMODO_SMPLX_CHAIN_MIRROR = [
    (j, p, par, _SMPLX_LR_SWAP.get(si, si), _SMPLX_LR_SWAP.get(sj, sj), rest)
    for (j, p, par, si, sj, rest) in KIMODO_SMPLX_CHAIN
]


# ---- SOMA-77 (Kimodo-SOMA-RP-v1) -> R15: adds WRISTS + ANKLES the 22-joint SMPL-X lacked ----
#
# SOMA-77 has full finger + toe chains, so the hand can aim along Hand->HandMiddle1 (wrist flick)
# and the foot along Foot->ToeBase (plant/point) — the "hands/feet stuck" fix. The bone ORDER is
# the canonical kimodo `SOMASkeleton77.bone_order_names_with_parents` (index = position); the chain
# is declared by NAME against it so a miscount can't silently mis-map a joint.
SOMA77_BONES = [
    "Hips", "Spine1", "Spine2", "Chest", "Neck1", "Neck2", "Head", "HeadEnd", "Jaw",
    "LeftEye", "RightEye",
    "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
    "LeftHandThumb1", "LeftHandThumb2", "LeftHandThumb3", "LeftHandThumbEnd",
    "LeftHandIndex1", "LeftHandIndex2", "LeftHandIndex3", "LeftHandIndex4", "LeftHandIndexEnd",
    "LeftHandMiddle1", "LeftHandMiddle2", "LeftHandMiddle3", "LeftHandMiddle4", "LeftHandMiddleEnd",
    "LeftHandRing1", "LeftHandRing2", "LeftHandRing3", "LeftHandRing4", "LeftHandRingEnd",
    "LeftHandPinky1", "LeftHandPinky2", "LeftHandPinky3", "LeftHandPinky4", "LeftHandPinkyEnd",
    "RightShoulder", "RightArm", "RightForeArm", "RightHand",
    "RightHandThumb1", "RightHandThumb2", "RightHandThumb3", "RightHandThumbEnd",
    "RightHandIndex1", "RightHandIndex2", "RightHandIndex3", "RightHandIndex4", "RightHandIndexEnd",
    "RightHandMiddle1", "RightHandMiddle2", "RightHandMiddle3", "RightHandMiddle4", "RightHandMiddleEnd",
    "RightHandRing1", "RightHandRing2", "RightHandRing3", "RightHandRing4", "RightHandRingEnd",
    "RightHandPinky1", "RightHandPinky2", "RightHandPinky3", "RightHandPinky4", "RightHandPinkyEnd",
    "LeftLeg", "LeftShin", "LeftFoot", "LeftToeBase", "LeftToeEnd",
    "RightLeg", "RightShin", "RightFoot", "RightToeBase", "RightToeEnd",
]
SOMA77_IX = {name: i for i, name in enumerate(SOMA77_BONES)}

# (R15 joint, R15 part, R15 parent part, SOMA from-bone, SOMA to-bone, R15 rest bone dir).
# rest dirs: torso up (+Y), limbs down (-Y), feet forward (-Z). Wrist/ankle signs are the ones
# to VERIFY LIVE (per the repo's axis-tuned-live history).
KIMODO_SOMA_CHAIN = [
    ("Root", "LowerTorso", "HumanoidRootPart", "Hips", "Chest", (0.0, 1.0, 0.0)),
    ("Waist", "UpperTorso", "LowerTorso", "Chest", "Neck1", (0.0, 1.0, 0.0)),
    ("Neck", "Head", "UpperTorso", "Neck1", "Head", (0.0, 1.0, 0.0)),
    ("RightShoulder", "RightUpperArm", "UpperTorso", "RightArm", "RightForeArm", (0.0, -1.0, 0.0)),
    ("RightElbow", "RightLowerArm", "RightUpperArm", "RightForeArm", "RightHand", (0.0, -1.0, 0.0)),
    ("RightWrist", "RightHand", "RightLowerArm", "RightHand", "RightHandMiddle1", (0.0, -1.0, 0.0)),
    ("LeftShoulder", "LeftUpperArm", "UpperTorso", "LeftArm", "LeftForeArm", (0.0, -1.0, 0.0)),
    ("LeftElbow", "LeftLowerArm", "LeftUpperArm", "LeftForeArm", "LeftHand", (0.0, -1.0, 0.0)),
    ("LeftWrist", "LeftHand", "LeftLowerArm", "LeftHand", "LeftHandMiddle1", (0.0, -1.0, 0.0)),
    ("RightHip", "RightUpperLeg", "LowerTorso", "RightLeg", "RightShin", (0.0, -1.0, 0.0)),
    ("RightKnee", "RightLowerLeg", "RightUpperLeg", "RightShin", "RightFoot", (0.0, -1.0, 0.0)),
    ("RightAnkle", "RightFoot", "RightLowerLeg", "RightFoot", "RightToeBase", (0.0, 0.0, -1.0)),
    ("LeftHip", "LeftUpperLeg", "LowerTorso", "LeftLeg", "LeftShin", (0.0, -1.0, 0.0)),
    ("LeftKnee", "LeftLowerLeg", "LeftUpperLeg", "LeftShin", "LeftFoot", (0.0, -1.0, 0.0)),
    ("LeftAnkle", "LeftFoot", "LeftLowerLeg", "LeftFoot", "LeftToeBase", (0.0, 0.0, -1.0)),
]


def _swap_lr(name):
    """Left<->Right on a bone name ('RightArm'->'LeftArm'); other names unchanged."""
    if name.startswith("Left"):
        return "Right" + name[4:]
    if name.startswith("Right"):
        return "Left" + name[5:]
    return name


def _soma_rows(mirror):
    """KIMODO_SOMA_CHAIN name-rows -> index-rows; mirror swaps the L/R SOURCE bones."""
    rows = []
    for joint, part, parent, sfrom, sto, rest in KIMODO_SOMA_CHAIN:
        if mirror:
            sfrom, sto = _swap_lr(sfrom), _swap_lr(sto)
        rows.append((joint, part, parent, SOMA77_IX[sfrom], SOMA77_IX[sto], rest))
    return rows


def _smplx_rows(mirror):
    chain = KIMODO_SMPLX_CHAIN_MIRROR if mirror else KIMODO_SMPLX_CHAIN
    return list(chain)


def _direction_fk(pj, fps, rows, xsign):
    """Direction-matching FK: aim each R15 rest bone dir along its SOMA/SMPL-X bone's world
    direction, accumulating parent world rotations. rows = index-tuples (joint, part, parent,
    from_idx, to_idx, rest_dir) in PARENT-BEFORE-CHILD order. Returns (times, tracks)."""
    total = int(pj.shape[0])
    times = [round(t / fps, 5) for t in range(total)]
    tracks = {row[0]: [] for row in rows}
    for t in range(total):
        world = {"HumanoidRootPart": [0.0, 0.0, 0.0, 1.0]}  # accumulated R15 part world rotations
        for joint, part, parent, si, sj, rest in rows:
            v = pj[t, sj] - pj[t, si]
            src = [xsign * float(v[0]), float(v[1]), -float(v[2])]  # -> R15 world (+ optional mirror)
            m = math.sqrt(sum(c * c for c in src)) or 1.0
            src = [c / m for c in src]
            wpar = world[parent]
            dlocal = q_rot_vec(q_inv(wpar), src)  # target dir in the parent's animated frame
            q = q_from_to(list(rest), dlocal)  # rotate the R15 rest bone dir onto the target
            tracks[joint].append([round(c, 5) for c in q])
            world[part] = q_norm(q_mul(wpar, q))
    return times, tracks


def retarget_kimodo_npz(npz_path, fps=30, mirror=False):
    """Kimodo posed_joints -> R15 Motor6D Pose channels via direction-matching FK. Auto-detects
    the skeleton from the joint count: 77 = SOMA (wrists + ankles articulate), 22 = SMPL-X body.
    mirror=True reflects L<->R (Kimodo picks a handedness per clip). Returns {clip, duration_s,
    fps, skeleton, joints: {R15Joint: {times, rot: [[qx,qy,qz,qw]...]}}}."""
    import numpy as np

    d = np.load(npz_path, allow_pickle=True)
    pj = d["posed_joints"]  # [T, J, 3]
    nj = int(pj.shape[1])
    if nj >= 77:
        rows, skel = _soma_rows(mirror), "soma77"
    elif nj == 22:
        rows, skel = _smplx_rows(mirror), "smplx22"
    else:
        raise meshio.MeshError(f"unsupported Kimodo joint count {nj} (need 22 or 77)")
    xsign = 1.0 if mirror else -1.0  # mirror negates X; RotY(pi) also negates X -> they cancel
    times, tracks = _direction_fk(pj, fps, rows, xsign)
    total = int(pj.shape[0])

    def moving(track):  # drop channels that never leave the R15 rest dir (identity every frame)
        return any(abs(q[3]) < 0.99999 for q in track)

    return {
        "clip": "KimodoClip",
        "duration_s": round((total - 1) / fps, 5) if total > 1 else 0.0,
        "fps": fps,
        "skeleton": skel,
        "source": os.path.basename(npz_path),
        "joints": {r[0]: {"times": times, "rot": tracks[r[0]]} for r in rows if moving(tracks[r[0]])},
    }


def retarget_reference_kimodo(filename, fps=30, mirror=False):
    """Allowlisted assets/reference .npz entry point (the /animate/kimodo route)."""
    if not isinstance(filename, str) or "/" in filename or "\\" in filename or ".." in filename:
        raise meshio.MeshError("bad filename")
    if not filename.lower().endswith(".npz"):
        raise meshio.MeshError("only .npz files are supported")
    path = os.path.join(meshio.ASSET_DIR, filename)
    if not os.path.isfile(path):
        raise meshio.MeshError(f"no such reference clip: {filename}")
    return retarget_kimodo_npz(path, fps=fps, mirror=mirror)


def retarget_reference_clip(filename, clip_name, fps=30):
    """Allowlisted assets/reference entry point (the /animate/retarget route)."""
    if not isinstance(filename, str) or "/" in filename or "\\" in filename or ".." in filename:
        raise meshio.MeshError("bad filename")
    if not filename.lower().endswith(".glb"):
        raise meshio.MeshError("only .glb files are supported")
    path = os.path.join(meshio.ASSET_DIR, filename)
    if not os.path.isfile(path):
        raise meshio.MeshError(f"no such reference asset: {filename}")
    return retarget_clip(path, clip_name, fps=fps)


if __name__ == "__main__":
    import sys

    fname = sys.argv[1] if len(sys.argv) > 1 else "UAL2_Standard.glb"
    cname = sys.argv[2] if len(sys.argv) > 2 else "Sword_Regular_A"
    out = retarget_reference_clip(fname, cname)
    print(json.dumps({k: (v if k != "joints" else {j: len(t["times"]) for j, t in v.items()})
                      for k, v in out.items()}, indent=1))
