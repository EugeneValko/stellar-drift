"""ST-7 Tern chin hardware: nose sensor turret (EO/IR survey ball) and the light cannon (repeater).

    build_sensor_turret(col, radius=0.24)  -> one mesh, local +Z out of the hull, +Y ship forward
    build_cannon(col, length=2.2)          -> one mesh, local +Z = muzzle, +Y = ship up, origin at receiver rear

Both parts are authored at their reference size and scaled uniformly (turret) or along the bore (cannon).
"""
import math

import bmesh
import bpy
from mathutils import Matrix

import kit
import mats
from kit import R, S, T, V

TURRET_REF_R = 0.24
CANNON_REF_L = 2.2


# ------------------------------------------------------------------------------------------
# local helpers
# ------------------------------------------------------------------------------------------
class Parts:
    """Accumulates geometry per material name; `bake()` turns it into one joined object."""

    def __init__(self):
        self.bms = {}
        self.custom = {}   # material name -> bpy material (non-library ones)
        self.smooth = {}

    def bm(self, mat):
        if mat not in self.bms:
            self.bms[mat] = bmesh.new()
        return self.bms[mat]

    def add(self, mat, src):
        """Append (and free) a temporary bmesh into the material bucket."""
        me = bpy.data.meshes.new("_tmp")
        src.to_mesh(me)
        src.free()
        self.bm(mat).from_mesh(me)
        bpy.data.meshes.remove(me)

    def transform(self, mx):
        for bm in self.bms.values():
            bmesh.ops.transform(bm, matrix=mx, verts=bm.verts[:])

    def merge(self, other):
        for mat, bm in other.bms.items():
            self.add(mat, bm)
        self.custom.update(other.custom)
        self.smooth.update(other.smooth)
        other.bms = {}

    def material(self, mat):
        return self.custom[mat] if mat in self.custom else mats.get(mat)

    def bake(self, name, col, extra=()):
        obs = []
        for mat, bm in self.bms.items():
            if not bm.faces:
                bm.free()
                continue
            obs.append(kit.to_obj(name + "_" + mat, bm, col, [self.material(mat)], smooth=self.smooth.get(mat, 35.0)))
        self.bms = {}
        ob = kit.join(list(extra) + obs, name)
        return ob


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def bolt(bm, mx, r=0.008, h=0.007, washer=True, segs=6):
    """Hex bolt head (+ washer) standing on the local XY plane of `mx`, axis +Z."""
    if washer:
        kit.cylinder(r * 1.45, -0.001, h * 0.28, 12, chamfer=h * 0.08, bm=bm, mx=mx)
    kit.cylinder(r, -0.001, h, segs, chamfer=r * 0.18, bm=bm, mx=mx @ R("Z", 30.0))
    return bm


def socket_bolt(bm, mx, r=0.007, h=0.004):
    """Low round socket-head cap screw (the socket is suggested by a dark ring of a second call)."""
    kit.lathe([(0.0, -0.001), (r, -0.001), (r, h * 0.55), (r * 0.82, h), (0.0, h)], 12, bm=bm, mx=mx)
    return bm


def beveled_prism(poly, z0, z1, width, mx=None, segs=2, angle=30.0, taper=1.0):
    bm = kit.prism(poly, z0, z1, taper=taper)
    kit.bevel_all(bm, width, segs=segs, angle=angle)
    if mx is not None:
        bmesh.ops.transform(bm, matrix=mx, verts=bm.verts[:])
    return bm


def beveled_box(size, center=(0, 0, 0), bevel=0.004, mx=None, segs=2):
    bm = kit.box(size, center=center, bevel=bevel, segs=segs)
    if mx is not None:
        bmesh.ops.transform(bm, matrix=mx, verts=bm.verts[:])
    return bm


def cut_flat(bm, co, no, mat_index=1, snap=0.0015):
    """Slice a convex closed shell with a plane, discard the +normal side and cap the hole (no boolean)."""
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, dist=snap, plane_co=co, plane_no=no, clear_outer=True)
    edges = [e for e in bm.edges if e.is_boundary]
    res = bmesh.ops.holes_fill(bm, edges=edges, sides=0)
    for f in res["faces"]:
        f.material_index = mat_index
    return res["faces"]


# ------------------------------------------------------------------------------------------
# sensor turret
# ------------------------------------------------------------------------------------------
def _sensor_ball(r):
    """Ball (centre at origin, lens along +Y, elevation axis X) with a faceted window group.
    Returns a Parts bucket in 'ball space' (+Z = U = towards the outside / away from the hull)."""
    P = Parts()
    X, L, U = V((1, 0, 0)), V((0, 1, 0)), V((0, 0, 1))

    # --- shell: sphere lathed about the elevation axis, with two seam grooves near the pivots
    seams = (0.150, 0.198)
    gw, gd = 0.0028, 0.0045
    grooves = sorted({sg * s for s in seams for sg in (-1, 1)} | {0.0})   # + the clamshell seam at x = 0
    hs = [r * math.sin(-math.pi / 2 + math.pi * (i + 0.5) / 36) for i in range(36)]
    hs = [-r] + [h for h in hs if all(abs(h - g) > gw + 0.004 for g in grooves)] + [r]

    def rho(hh):
        return math.sqrt(max(r * r - hh * hh, 0.0))

    prof = []
    for h in hs:
        while grooves and grooves[0] < h:
            h0 = grooves.pop(0)
            prof += [(rho(h0 - gw), h0 - gw), (rho(h0 - gw) - gd, h0 - gw), (rho(h0 + gw) - gd, h0 + gw),
                     (rho(h0 + gw), h0 + gw)]
        prof.append((rho(h), h))
    prof[0] = (0.0, -r)
    prof[-1] = (0.0, r)
    shell = kit.lathe(prof, 64, mx=R("Y", 90.0))

    # --- window facets: main face + four bevelled side facets (a truncated pyramid)
    planes = [(L, 0.145)]
    for sg in (-1, 1):
        planes.append(((L * math.cos(math.radians(40)) + X * sg * math.sin(math.radians(40))).normalized(), 0.190))
        planes.append(((L * math.cos(math.radians(35)) + U * sg * math.sin(math.radians(35))).normalized(), 0.186))
    for n, d in planes:
        cut_flat(shell, n * d, n, 1)
    bmesh.ops.recalc_face_normals(shell, faces=shell.faces[:])
    shell.normal_update()
    edges = [e for e in shell.edges if len(e.link_faces) == 2 and any(f.material_index == 1 for f in e.link_faces)
             and e.calc_face_angle(0.0) > math.radians(12)]
    bmesh.ops.bevel(shell, geom=edges, offset=0.0055, offset_type="OFFSET", segments=2, profile=0.5, affect="EDGES",
                    clamp_overlap=True)
    shell.normal_update()
    # split into the painted ball and the dark window frame
    frame_bm = shell.copy()
    bmesh.ops.delete(shell, geom=[f for f in shell.faces if f.material_index == 1], context="FACES")
    bmesh.ops.delete(frame_bm, geom=[f for f in frame_bm.faces if f.material_index != 1], context="FACES")
    P.add("paint_grey", shell)
    P.add("paint_dark", frame_bm)
    P.smooth["paint_grey"] = 22.0
    P.smooth["paint_dark"] = 22.0

    # --- window plate: raised chamfered plate inset into the main facet, carrying all apertures
    d_main = planes[0][1]
    u_lim = (planes[1][1] - d_main * math.cos(math.radians(40))) / math.sin(math.radians(40))
    v_lim = (planes[2][1] - d_main * math.cos(math.radians(35))) / math.sin(math.radians(35))
    pt = 0.005                                     # plate thickness above the facet
    plate2d = kit.chamfer_rect2(2 * (u_lim - 0.014), 2 * (v_lim - 0.014), 0.026)
    P.add("metal_dark", beveled_prism(plate2d, -0.003, pt, 0.0018, mx=kit.frame(L * d_main, L, X)))
    for x, y in ((0.0, v_lim - 0.023), (0.0, -v_lim + 0.023), (u_lim - 0.024, -0.008)):
        socket_bolt(P.bm("metal_steel"), kit.frame(L * d_main, L, X) @ T(x, y, pt - 0.0005), 0.0042, 0.0022)

    def on_main(u, v):
        return kit.frame(L * (d_main + pt) + X * u + U * v, L, X)

    # main imaging lens: stepped bezel, steel retainer, dark inner wall, domed glass
    f = on_main(-0.024, -0.004)
    kit.lathe([(0.0, -0.006), (0.084, -0.006), (0.084, 0.007), (0.080, 0.011), (0.073, 0.011), (0.071, 0.009),
               (0.071, 0.002), (0.0, 0.002)], 48, bm=P.bm("metal_dark"), mx=f)
    kit.ring(0.0712, 0.064, 0.0015, 0.0085, 48, chamfer=0.0008, bm=P.bm("metal_steel"), mx=f)
    kit.ring(0.0645, 0.058, 0.0015, 0.0060, 48, bm=P.bm("inner_dark"), mx=f)
    dome = [(0.0635 * math.cos(math.pi / 2 * i / 8), 0.0045 + 0.010 * math.sin(math.pi / 2 * i / 8)) for i in range(9)]
    dome[-1] = (0.0, dome[-1][1])
    kit.lathe([(0.0, 0.0025), (0.0635, 0.0025)] + dome, 48, bm=P.bm("glass_dark"), mx=f)
    # bezel screws
    for i in range(8):
        a = math.tau * (i + 0.5) / 8
        socket_bolt(P.bm("metal_steel"), f @ T(0.0775 * math.cos(a), 0.0775 * math.sin(a), 0.0105), 0.0030, 0.0016)

    # secondary clear lens (laser rangefinder receiver)
    f = on_main(0.077, 0.060)
    kit.lathe([(0.0, -0.004), (0.030, -0.004), (0.030, 0.010), (0.027, 0.013), (0.0225, 0.013), (0.021, 0.011),
               (0.021, 0.004), (0.0, 0.004)], 40, bm=P.bm("metal_dark"), mx=f)
    kit.lathe([(0.0, 0.004), (0.0205, 0.004), (0.0205, 0.006), (0.0, 0.0085)], 40, bm=P.bm("lens_clear"), mx=f)
    kit.ring(0.0145, 0.0095, 0.0062, 0.0072, 32, bm=P.bm("inner_dark"), mx=f)

    # laser designator / status aperture (emissive core)
    f = on_main(0.077, -0.048)
    kit.lathe([(0.0, -0.004), (0.019, -0.004), (0.019, 0.016), (0.016, 0.019), (0.011, 0.019), (0.0095, 0.017),
               (0.0095, 0.008), (0.0, 0.008)], 32, bm=P.bm("metal_dark"), mx=f)
    kit.cylinder(0.0085, 0.0, 0.0105, 24, bm=P.bm("emit_red"), mx=f)

    # small wide-field camera window on the -X side facet (rectangular slit)
    n_side = next(n for n, _d in planes if n.x < -0.1)
    away = V((-n_side.y, n_side.x, 0.0))          # in the side facet, pointing away from the main face
    if away.y > 0:
        away = -away
    f = kit.frame(n_side * 0.190 + away * 0.042, n_side, U)
    P.add("metal_dark", beveled_prism(kit.chamfer_rect2(0.058, 0.030, 0.006), -0.004, 0.006, 0.0015, mx=f))
    kit.prism(kit.chamfer_rect2(0.046, 0.019, 0.004), 0.0055, 0.0075, bm=P.bm("glass_dark"), mx=f)
    # IR illuminator strip (three small clear lenses) on the +X side facet
    n_side = next(n for n, _d in planes if n.x > 0.1)
    away = V((-n_side.y, n_side.x, 0.0))
    if away.y > 0:
        away = -away
    f = kit.frame(n_side * 0.190 + away * 0.040, n_side, U)
    P.add("metal_dark", beveled_prism(kit.chamfer_rect2(0.074, 0.026, 0.008), -0.004, 0.005, 0.0015, mx=f))
    for i in (-1, 0, 1):
        kit.lathe([(0.0, 0.0045), (0.0075, 0.0045), (0.0075, 0.0060), (0.0, 0.0078)], 20, bm=P.bm("lens_clear"),
                  mx=f @ T(i * 0.022, 0, 0))
        kit.ring(0.0095, 0.0074, 0.0045, 0.0062, 20, bm=P.bm("metal_steel"), mx=f @ T(i * 0.022, 0, 0))

    # --- pivot hubs (bearing discs on both poles)
    for sg in (-1, 1):
        hub = kit.frame(X * sg * 0.218, X * sg, (0, 0, 1))
        kit.lathe([(0.0, 0.0), (0.094, 0.0), (0.094, 0.010), (0.088, 0.016), (0.0, 0.016)], 48,
                  bm=P.bm("metal_dark"), mx=hub)
        kit.ring(0.072, 0.058, 0.015, 0.039, 48, chamfer=0.002, bm=P.bm("metal_steel"), mx=hub)
        for i in range(10):
            a = math.tau * i / 10
            bolt(P.bm("metal_steel"), hub @ T(0.081 * math.cos(a), 0.081 * math.sin(a), 0.016), 0.0042, 0.0045,
                 washer=False)

    # --- rear service hatch (raised plate with fasteners)
    d = V((-0.50, -0.82, 0.22)).normalized()
    f = kit.frame(d * 0.242, d, U)
    hatch = kit.chamfer_rect2(0.12, 0.095, 0.02)
    P.add("paint_grey", beveled_prism(hatch, -0.03, 0.004, 0.0025, mx=f))
    for x, y in kit.outline_points(hatch, 0.045, inset=0.011):
        socket_bolt(P.bm("metal_steel"), f @ T(x, y, 0.0035), 0.0034, 0.0018)
    # purge / desiccant valve on the other rear quarter
    d = V((0.42, -0.86, -0.28)).normalized()
    f = kit.frame(d * 0.236, d, U)
    kit.cylinder(0.016, 0.0, 0.010, 20, chamfer=0.002, bm=P.bm("metal_dark"), mx=f)
    kit.cylinder(0.009, 0.009, 0.020, 6, chamfer=0.0015, bm=P.bm("metal_brass"), mx=f)
    kit.cylinder(0.0045, 0.019, 0.025, 12, chamfer=0.001, bm=P.bm("paint_accent"), mx=f)
    P.smooth["paint_grey"] = 22.0
    return P


def build_sensor_turret(col=None, radius=TURRET_REF_R, name="SensorTurret", tilt=15.0):
    """Gimballed EO/IR sensor ball on a yoke over an azimuth bearing and bolted mount ring.
    Local +Z out of the hull, z = 0 hull surface, +Y ship forward (lens looks along +Y tilted `tilt` to +Z)."""
    r = TURRET_REF_R
    zc = 2.6 * r - r                     # ball centre height (top of ball at 2.6 r)
    P = Parts()

    # --- base: octagonal bolted mounting plate + gasket
    plate_r, plate_h = 1.5 * r, 0.026
    kit.lathe([(0.0, 0.0), (plate_r - 0.006, 0.0), (plate_r, 0.006), (plate_r, plate_h - 0.007),
               (plate_r - 0.007, plate_h), (0.0, plate_h)], 8, bm=P.bm("metal_dark"), start=math.pi / 8)
    kit.ring(plate_r * math.cos(math.pi / 8) + 0.008, plate_r * 0.80, -0.002, 0.004, 8, bm=P.bm("rubber"),
             mx=R("Z", 22.5))
    for i in range(16):
        a = math.tau * (i + 0.5) / 16
        bolt(P.bm("metal_steel"), T(0.300 * math.cos(a), 0.300 * math.sin(a), plate_h), 0.0085, 0.0075)
    # fixed collar + azimuth bearing
    kit.lathe([(0.205, plate_h - 0.002), (0.268, plate_h - 0.002), (0.268, plate_h + 0.012), (0.258, plate_h + 0.022),
               (0.205, plate_h + 0.022)], 64, bm=P.bm("metal_dark"), close=True)
    kit.ring(0.214, 0.180, plate_h + 0.020, plate_h + 0.036, 64, chamfer=0.002, bm=P.bm("metal_steel"))
    kit.ring(0.209, 0.150, plate_h + 0.035, plate_h + 0.040, 64, bm=P.bm("inner_dark"))
    # rotating turntable
    zt0, zt1 = plate_h + 0.039, plate_h + 0.070
    kit.lathe([(0.0, zt0), (0.200, zt0), (0.206, zt0 + 0.005), (0.206, zt1 - 0.008), (0.196, zt1), (0.0, zt1)], 64,
              bm=P.bm("metal_dark"))
    for i in range(12):
        a = math.tau * (i + 0.5) / 12
        socket_bolt(P.bm("metal_steel"), T(0.182 * math.cos(a), 0.182 * math.sin(a), zt1 - 0.001), 0.0055, 0.0032)
    # azimuth drive motor (fixed, aft) with pinion housing
    P.add("metal_dark", beveled_box((0.110, 0.070, 0.050), (0.0, -0.255, plate_h + 0.025), 0.008))
    kit.cylinder(0.030, plate_h + 0.045, plate_h + 0.085, 32, chamfer=0.004, bm=P.bm("metal_dark"),
                 mx=T(0.0, -0.255, 0.0))
    kit.ring(0.031, 0.020, plate_h + 0.060, plate_h + 0.068, 32, bm=P.bm("inner_dark"), mx=T(0.0, -0.255, 0.0))
    for sx in (-1, 1):
        bolt(P.bm("metal_steel"), T(sx * 0.040, -0.255, plate_h + 0.050), 0.005, 0.005, washer=False)

    # --- yoke: bridge + two arms with round pivot bosses
    arm_in, arm_out = 0.256, 0.296
    zb0, zb1 = zt1 - 0.004, zt1 + 0.036
    P.add("metal_dark", beveled_prism(kit.chamfer_rect2(2 * arm_out, 0.17, 0.035), zb0, zb1, 0.006))
    arm2d = [(-0.085, zb0), (0.085, zb0), (0.085, zb1 + 0.06)]
    br = 0.082
    for i in range(21):
        a = math.radians(-35 + 250 * i / 20)
        arm2d.append((br * math.cos(a), zc + br * math.sin(a)))
    arm2d.append((-0.085, zb1 + 0.06))
    to_yz = Matrix(((0, 0, 1, 0), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # 2D (a,b) -> (y,z), extrude x
    for sg in (-1, 1):
        x0, x1 = (arm_in, arm_out) if sg > 0 else (-arm_out, -arm_in)
        P.add("metal_dark", beveled_prism(arm2d, x0, x1, 0.006, mx=to_yz))
        # raised stiffener plate on the outer face
        inner = kit.offset_convex2(arm2d, -0.016)
        xo = arm_out - 0.001 if sg > 0 else -arm_out - 0.005
        P.add("metal_dark", beveled_prism(inner, 0.0, 0.006, 0.002, mx=T(xo, 0, 0) @ to_yz))
        # pivot: through bearing + outer cap
        cap = kit.frame((sg * arm_out, 0.0, zc), (sg, 0, 0), (0, 0, 1))
        kit.lathe([(0.0, -0.002), (0.068, -0.002), (0.068, 0.012), (0.061, 0.019), (0.040, 0.019), (0.036, 0.026),
                   (0.0, 0.026)], 48, bm=P.bm("metal_steel"), mx=cap)
        kit.ring(0.036, 0.020, 0.025, 0.028, 32, bm=P.bm("inner_dark"), mx=cap)
        for i in range(8):
            a = math.tau * (i + 0.5) / 8
            bolt(P.bm("metal_dark"), cap @ T(0.052 * math.cos(a), 0.052 * math.sin(a), 0.019), 0.0045, 0.005,
                 washer=False)
    # elevation drive motor on the starboard arm (asymmetric, aft of the pivot)
    m = kit.frame((arm_out + 0.004, -0.075, zc - 0.135), (1, 0, 0), (0, 0, 1))
    kit.cylinder(0.036, 0.0, 0.052, 32, chamfer=0.005, bm=P.bm("metal_dark"), mx=m)
    kit.ring(0.037, 0.028, 0.020, 0.028, 32, bm=P.bm("inner_dark"), mx=m)
    kit.cylinder(0.022, 0.050, 0.060, 24, chamfer=0.003, bm=P.bm("metal_steel"), mx=m)

    # --- umbilical: turntable -> starboard arm -> elevation motor (two cables, clamp, ferrules)
    cab = [V((0.135, -0.150, zt1 - 0.002)), V((0.135, -0.150, zt1 + 0.040)), V((0.250, -0.175, zt1 + 0.090)),
           V((0.322, -0.130, zc - 0.180)), V((0.336, -0.075, zc - 0.145)), V((0.336, -0.075, zc - 0.135))]
    kit.tube(cab, 0.0115, 16, bm=P.bm("rubber"), fillet=0.045)
    cab2 = [p + V((-0.022 if i < 3 else 0.0, 0.020 if i < 3 else 0.0, 0.0)) for i, p in enumerate(cab[:4])]
    cab2 += [V((0.316, -0.112, zc - 0.180)), V((0.304, -0.100, zc - 0.160))]
    kit.tube(cab2, 0.0065, 12, bm=P.bm("rubber"), fillet=0.04)
    for p, d in ((cab[0], V((0, 0, 1))), (cab2[0], V((0, 0, 1)))):
        f = kit.frame(p, d)
        kit.cylinder(0.019, 0.0, 0.022, 24, chamfer=0.003, bm=P.bm("metal_brass"), mx=f)
        kit.cylinder(0.015, 0.020, 0.030, 6, chamfer=0.002, bm=P.bm("metal_steel"), mx=f @ R("Z", 30))
    # cable clamp on the arm
    f = kit.frame((arm_out + 0.003, -0.11, zb1 + 0.11), (1, 0, 0), (0, 0, 1))
    P.add("metal_steel", beveled_box((0.06, 0.03, 0.006), (0, 0, 0.003), 0.0015, mx=f))
    bolt(P.bm("metal_dark"), f @ T(0.022, 0, 0.006), 0.004, 0.004, washer=False)

    # --- sensor ball
    ball = _sensor_ball(r)
    ball.transform(T(0, 0, zc) @ R("X", tilt))
    P.merge(ball)

    ob = P.bake(name, col)
    k = radius / r
    if abs(k - 1.0) > 1e-6:
        ob.data.transform(S(k))
    return ob


# ------------------------------------------------------------------------------------------
# cannon
# ------------------------------------------------------------------------------------------
def build_cannon(col=None, length=CANNON_REF_L, name="Cannon"):
    """Fixed light repeater. Local +Z = muzzle (z = length), origin at the receiver rear, +Y = ship up."""
    q = length / CANNON_REF_L

    def Z(z):
        return z * q

    P = Parts()
    heat = "chin_cannon_heat_%d" % round(length * 1000)
    P.custom[heat] = mats.heat_metal(heat, axis=2, start=Z(1.90), length=Z(0.42))

    # --- receiver housing
    rw, rh, rl = 0.26, 0.22, Z(0.80)
    body2d = kit.chamfer_rect2(rw, rh, 0.034)
    P.add("metal_dark", beveled_prism(body2d, 0.0, rl, 0.006))
    # rear end cap (slightly inset, own casting)
    P.add("metal_dark", beveled_prism(kit.offset_convex2(body2d, 0.006), Z(0.0), Z(0.045), 0.005))
    P.add("metal_dark", beveled_prism(kit.offset_convex2(body2d, 0.006), rl - Z(0.05), rl, 0.005))
    for x, y in kit.outline_points(kit.offset_convex2(body2d, 0.006), 0.07, inset=0.018):
        socket_bolt(P.bm("metal_steel"), T(x, y, 0.0) @ R("X", 180), 0.0055, 0.003)
    # top access cover with fasteners and an orange latch
    top = kit.frame((0.0, rh / 2, Z(0.41)), (0, 1, 0), (1, 0, 0))   # local y = -Z (ship aft)
    cover = kit.chamfer_rect2(0.17, Z(0.46), 0.024)
    P.add("paint_dark", beveled_prism(cover, -0.004, 0.009, 0.0025, mx=top))
    for x, y in kit.outline_points(cover, 0.075, inset=0.013):
        socket_bolt(P.bm("metal_steel"), top @ T(x, y, 0.0085), 0.0045, 0.0025)
    P.add("metal_steel", beveled_box((0.05, 0.022, 0.008), (0.0, -Z(0.23) - 0.004, 0.011), 0.002, mx=top))
    P.add("metal_steel", beveled_box((0.036, 0.014, 0.010), (0.0, -Z(0.23) + 0.006, 0.010), 0.002, mx=top))
    # side mounting lugs with cross pins + vent fins
    for sx in (-1, 1):
        for zl in (Z(0.12), Z(0.66)):
            P.add("metal_dark", beveled_box((0.036, 0.11, 0.075), (sx * (rw / 2 + 0.014), 0.0, zl), 0.006))
            kit.cylinder(0.016, -0.066, 0.066, 24, chamfer=0.003, bm=P.bm("metal_steel"),
                         mx=T(sx * (rw / 2 + 0.018), 0.0, zl) @ R("X", 90))
            kit.cylinder(0.009, -0.070, 0.070, 16, chamfer=0.002, bm=P.bm("inner_dark"),
                         mx=T(sx * (rw / 2 + 0.018), 0.0, zl) @ R("X", 90))
        side = kit.frame((sx * rw / 2, 0.0, Z(0.40)), (sx, 0, 0), (0, 0, 1))
        P.add("inner_dark", beveled_box((Z(0.30), 0.12, 0.006), (0, 0, -0.002), 0.0015, mx=side))
        n_fin = 9
        for i in range(n_fin):
            zz = Z(0.40) - Z(0.27) / 2 + Z(0.27) * i / (n_fin - 1)
            P.add("metal_dark", beveled_box((0.014, 0.12, 0.008), (sx * (rw / 2 + 0.003), 0.0, zz), 0.0018, segs=1))
    # power / feed conduit stub on the belly, bending aft into the fairing
    f = kit.frame((0.0, -rh / 2, Z(0.22)), (0, -1, 0), (1, 0, 0))
    kit.cylinder(0.046, -0.003, 0.012, 32, chamfer=0.003, bm=P.bm("metal_dark"), mx=f)
    kit.cylinder(0.032, 0.010, 0.040, 8, chamfer=0.003, bm=P.bm("metal_steel"), mx=f)
    for i in range(6):
        a = math.tau * (i + 0.5) / 6
        bolt(P.bm("metal_steel"), f @ T(0.038 * math.cos(a), 0.038 * math.sin(a), 0.012), 0.004, 0.004, washer=False)
    cond = [V((0.0, -rh / 2 - 0.035, Z(0.22))), V((0.0, -rh / 2 - 0.085, Z(0.22))),
            V((0.0, -rh / 2 - 0.095, Z(0.10))), V((0.0, -rh / 2 - 0.095, -0.05))]
    kit.tube(cond, 0.022, 20, bm=P.bm("rubber"), fillet=0.06)
    for t in (0.02, 0.10):
        kit.cylinder(0.027, -0.01, 0.01, 24, chamfer=0.002, bm=P.bm("metal_steel"),
                     mx=kit.frame((0.0, -rh / 2 - 0.095, t), (0, 0, 1)))

    # --- front flange + collar (box -> round)
    P.add("metal_dark", beveled_prism(kit.chamfer_rect2(0.236, 0.200, 0.03), rl, rl + Z(0.022), 0.004))
    for x, y in ((0.09, 0.075), (-0.09, 0.075), (0.09, -0.075), (-0.09, -0.075)):
        bolt(P.bm("metal_steel"), T(x, y, rl + Z(0.022)), 0.0075, 0.007)
    z0 = rl + Z(0.020)
    kit.lathe([(0.0, z0), (0.100, z0), (0.100, z0 + 0.030), (0.092, z0 + 0.038), (0.084, z0 + 0.055),
               (0.084, Z(0.90)), (0.0, Z(0.90))], 48, bm=P.bm("metal_dark"))

    # --- barrel shroud / cooling jacket
    zs0, zs1 = Z(0.88), Z(1.78)
    kit.cylinder(0.058, zs0, zs1, 32, bm=P.bm("inner_dark"))
    clamps = (Z(0.90), Z(1.31), Z(1.74))
    for zc in clamps:
        kit.ring(0.086, 0.055, zc, zc + 0.04, 48, chamfer=0.004, bm=P.bm("metal_dark"))
        # clamp boss + pinch bolt on the top
        P.add("metal_dark", beveled_box((0.034, 0.024, 0.030), (0.0, 0.090, zc + 0.02), 0.004))
        bolt(P.bm("metal_steel"), kit.frame((0.0, 0.102, zc + 0.02), (0, 1, 0)), 0.006, 0.006, washer=False)
    # rear section: slotted sleeve (12 longitudinal bars over the dark core)
    a0, a1 = clamps[0] + 0.04, clamps[1]
    for i in range(12):
        a = 360.0 * i / 12
        P.add("metal_dark", beveled_box((0.014, 0.024, a1 - a0 + 0.01), (0.068, 0.0, (a0 + a1) / 2), 0.003, segs=1,
                                        mx=R("Z", a)))
    # front section: radial cooling fins on a core, tied by three through-rods
    f0, f1 = clamps[1] + 0.04, clamps[2]
    kit.cylinder(0.056, f0 - 0.005, f1 + 0.005, 32, bm=P.bm("metal_dark"))
    n_fins = 9
    for i in range(n_fins):
        zz = f0 + 0.012 + (f1 - f0 - 0.06) * i / (n_fins - 1)
        kit.ring(0.079, 0.054, zz, zz + 0.012, 48, chamfer=0.0025, bm=P.bm("metal_steel"))
    for i in range(3):
        a = math.tau * (i / 3 + 0.25)
        kit.cylinder(0.0045, f0 - 0.01, f1 + 0.01, 12, bm=P.bm("metal_dark"),
                     mx=T(0.071 * math.cos(a), 0.071 * math.sin(a), 0.0))
    # orange arming band just aft of the front clamp
    kit.ring(0.0815, 0.054, clamps[2] - 0.016, clamps[2] - 0.004, 64, chamfer=0.0015, bm=P.bm("paint_accent"))

    # --- exposed barrel
    zb0, zb1 = Z(1.76), Z(2.03)
    zr, zm = Z(1.90), Z(2.02)
    kit.lathe([(0.0, zb0), (0.040, zb0), (0.040, Z(1.815)), (0.037, Z(1.815) + 0.003), (0.036, Z(1.815) + 0.006),
               (0.036, zr), (0.042, zr + 0.003), (0.042, zr + 0.013), (0.034, zr + 0.016), (0.033, zr + 0.018),
               (0.033, zb1), (0.0, zb1)], 40, bm=P.bm(heat))
    # coolant / sensor line along the belly of the barrel with two clips
    line = [V((0.0, -0.058, Z(1.755))), V((0.0, -0.058, Z(1.80))), V((0.0, -0.049, Z(1.86))),
            V((0.0, -0.049, zm + 0.012))]
    kit.tube(line, 0.0055, 12, bm=P.bm("metal_steel"), fillet=0.03)
    for zz in (Z(1.86) + 0.012, Z(1.97)):
        kit.ring(0.0105, 0.0052, -0.006, 0.006, 16, chamfer=0.001, bm=P.bm("metal_dark"),
                 mx=T(0.0, -0.049, zz))
        P.add("metal_dark", beveled_box((0.010, 0.014, 0.010), (0.0, -0.040, zz), 0.0015, segs=1))

    # --- muzzle device: collar, three octagonal baffles on side straps, crown, glowing focusing ring
    kit.lathe([(0.0, zm), (0.044, zm), (0.050, zm + 0.006), (0.050, zm + 0.040), (0.044, zm + 0.046),
               (0.0, zm + 0.046)], 40, bm=P.bm(heat))
    kit.cylinder(0.021, zm + 0.040, zm + 0.0475, 32, bm=P.bm("inner_dark"))
    kit.torus(0.0165, 0.003, 32, 8, bm=P.bm("emit_amber"), mx=T(0, 0, zm + 0.0475))
    end = length
    n_baf, baf_t, crown_t = 3, 0.017, 0.020
    b0, b1 = zm + 0.058, end - crown_t
    baf_gap = (b1 - b0 - n_baf * baf_t) / n_baf
    for i in range(n_baf):
        zz = b0 + i * (baf_t + baf_gap)
        kit.lathe([(0.021, zz), (0.064, zz), (0.071, zz + 0.004), (0.071, zz + baf_t - 0.004),
                   (0.064, zz + baf_t), (0.021, zz + baf_t)], 8, bm=P.bm(heat), close=True, start=math.pi / 8)
    kit.lathe([(0.020, end - crown_t), (0.060, end - crown_t), (0.065, end - crown_t + 0.005), (0.065, end - 0.004),
               (0.061, end), (0.024, end), (0.020, end - 0.004)], 40, bm=P.bm(heat), close=True)
    for sx in (-1, 1):
        P.add(heat, beveled_box((0.018, 0.050, end - zm - 0.052), (sx * 0.053, 0.0, (zm + 0.044 + end - 0.008) / 2),
                                0.003))
    P.smooth[heat] = 35.0
    return P.bake(name, col)


# ------------------------------------------------------------------------------------------
# demos
# ------------------------------------------------------------------------------------------
CANNON_TO_DEMO = Matrix(((-1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # local +Z -> world +Y, +Y -> +Z


def _slab(col, size, center, mat="paint_white", bevel=0.01):
    bm = kit.box(size, center=center, bevel=bevel, segs=2)
    return kit.to_obj("slab", bm, col, [mats.get(mat)])


XZ_UP = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))   # 2D (a, b) -> (x, z), extrude -y


def _cradle(col, x, y, top, round_r=0.0, w=0.20):
    """Support block (flat top, or a V notch for a round section of radius `round_r`) standing on z = 0."""
    if round_r > 0:
        d = round_r * 0.7
        poly = [(-w / 2, 0.0), (w / 2, 0.0), (w / 2, top + d * 0.6), (d, top + d * 0.6), (0.18 * d, top),
                (-0.18 * d, top), (-d, top + d * 0.6), (-w / 2, top + d * 0.6)]
        bm = beveled_prism(poly, -0.04, 0.04, 0.004, mx=T(x, y, 0) @ XZ_UP)
    else:
        bm = beveled_prism(kit.rect2(w, top, 0.0, top / 2), -0.04, 0.04, 0.004, mx=T(x, y, 0) @ XZ_UP)
    return kit.to_obj("cradle", bm, col, [mats.get("metal_steel")])


def _place_cannon(c, x, y0, zax):
    """Lay the cannon horizontally with its muzzle towards world +Y, bore axis at height `zax`."""
    c.matrix_world = T(x, y0, zax) @ CANNON_TO_DEMO


def demo():
    col = kit.collection("Chin")
    objs = []
    t = build_sensor_turret(col)
    print("TURRET tris", tri_count(t), "dims", tuple(round(v, 3) for v in t.dimensions))
    objs.append(t)
    c = build_cannon(col)
    print("CANNON tris", tri_count(c), "dims", tuple(round(v, 3) for v in c.dimensions))
    zax, cx, cy0 = 0.26, -0.80, -1.1
    _place_cannon(c, cx, cy0, zax)
    objs.append(c)
    objs.append(_slab(col, (1.95, 2.7, 0.06), (-0.32, 0.0, -0.03)))
    objs.append(_cradle(col, cx, cy0 + 0.45, zax - 0.11))
    objs.append(_cradle(col, cx, cy0 + 1.12, zax - 0.075 * 1.3, round_r=0.075))
    return objs


def demo_turret():
    col = kit.collection("Chin")
    t = build_sensor_turret(col)
    s = _slab(col, (0.95, 0.95, 0.05), (0, 0, -0.025))
    print("TURRET tris", tri_count(t))
    return [t, s]


def demo_cannon():
    col = kit.collection("Chin")
    c = build_cannon(col)
    print("CANNON tris", tri_count(c))
    _place_cannon(c, 0.0, -1.1, 0.26)
    s = _slab(col, (0.7, 2.6, 0.05), (0.0, 0.0, -0.025))
    return [c, s, _cradle(col, 0.0, -0.65, 0.15), _cradle(col, 0.0, 0.02, 0.26 - 0.075 * 1.3, round_r=0.075)]


def demo_muzzle():
    """Close-up on the exposed barrel and muzzle device."""
    col = kit.collection("Chin")
    c = build_cannon(col)
    c.matrix_world = T(0, -1.1, 0.0) @ CANNON_TO_DEMO
    bm = kit.box((0.22, 0.55, 0.2), center=(0, 0.85, 0))
    ob = kit.to_obj("zoom_box", bm, col)
    ob.hide_render = True
    return [ob]


def demo_window():
    """Close-up on the turret window group."""
    col = kit.collection("Chin")
    build_sensor_turret(col)
    _slab(col, (0.95, 0.95, 0.05), (0, 0, -0.025))
    bm = kit.box((0.34, 0.2, 0.30), center=(0, 0.18, 0.43))
    ob = kit.to_obj("zoom_box", bm, col)
    ob.hide_render = True
    return [ob]
