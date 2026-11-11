"""Hard-surface modelling toolkit for headless Blender 5.x (bmesh based).

Conventions: metres, ship space = +X right (starboard), +Y forward (nose), +Z up.
Primitives return a bmesh (pass `bm=` to accumulate several primitives into one mesh),
`to_obj()` turns it into an object. Parts are built around their own origin with +Z as the
"out of the surface" / symmetry axis unless stated otherwise.
"""
import math

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

TAU = math.tau
V = Vector


# ------------------------------------------------------------------------------------------
# scene helpers
# ------------------------------------------------------------------------------------------
def collection(name, parent=None):
    col = bpy.data.collections.get(name)
    if col is None:
        col = bpy.data.collections.new(name)
        (parent or bpy.context.scene.collection).children.link(col)
    return col


def shade(ob, angle=35.0):
    """Smooth shading with edges sharper than `angle` degrees kept sharp."""
    me = ob.data
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(angle))


def to_obj(name, bm, col=None, mats=(), smooth=35.0, recalc=True):
    """bmesh -> linked object (frees the bmesh). `mats`: materials for slots 0..n."""
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    (col or bpy.context.scene.collection).objects.link(ob)
    if smooth is not None:
        shade(ob, smooth)
    return ob


def apply_mods(ob):
    """Bake the modifier stack into the mesh."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
    old = ob.data
    ob.modifiers.clear()
    ob.data = me
    me.name = old.name
    if old.users == 0:
        bpy.data.meshes.remove(old)
    return ob


def mod_bevel(ob, width=0.006, segs=2, angle=40.0, harden=True, profile=0.6):
    m = ob.modifiers.new("Bevel", "BEVEL")
    m.width = width
    m.segments = segs
    m.limit_method = "ANGLE"
    m.angle_limit = math.radians(angle)
    m.harden_normals = harden
    m.profile = profile
    m.miter_outer = "MITER_ARC"
    return m


def mod_subsurf(ob, levels=2):
    m = ob.modifiers.new("Subsurf", "SUBSURF")
    m.levels = m.render_levels = levels
    return m


def mod_solidify(ob, thickness=0.02, rim_only=False, offset=-1.0):
    m = ob.modifiers.new("Solidify", "SOLIDIFY")
    m.thickness = thickness
    m.offset = offset
    m.use_rim_only = rim_only
    m.use_even_offset = True
    return m


def mod_weighted_normal(ob):
    m = ob.modifiers.new("WeightedNormal", "WEIGHTED_NORMAL")
    m.keep_sharp = True
    m.weight = 60
    return m


def place(ob, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), parent=None):
    """Set a transform (rot = XYZ euler in degrees)."""
    ob.location = loc
    ob.rotation_euler = [math.radians(a) for a in rot]
    ob.scale = scale
    if parent is not None:
        ob.parent = parent
    return ob


def instance(ob, name=None, col=None):
    """Linked duplicate (shares mesh data)."""
    c = ob.copy()
    if name:
        c.name = name
    (col or ob.users_collection[0]).objects.link(c)
    return c


def join(objs, name=None):
    """Join objects into the first one (keeps materials / attributes)."""
    objs = [o for o in objs if o is not None]
    if not objs:
        return None
    bpy.context.view_layer.update()
    with bpy.context.temp_override(active_object=objs[0], selected_editable_objects=objs, selected_objects=objs):
        bpy.ops.object.join()
    if name:
        objs[0].name = name
        objs[0].data.name = name
    return objs[0]


def bake_transform(ob):
    """Apply the object's world matrix to its mesh (object ends up at identity)."""
    bpy.context.view_layer.update()
    mw = ob.matrix_world.copy()
    if ob.data.users > 1:
        ob.data = ob.data.copy()
    ob.data.transform(mw)
    if mw.determinant() < 0:
        ob.data.flip_normals()
    ob.parent = None
    ob.matrix_world = Matrix.Identity(4)
    return ob


def mirrored_copy(ob, name=None, col=None):
    """World-space mirror across the YZ plane (x -> -x) as an independent mesh object."""
    bpy.context.view_layer.update()
    c = ob.copy()
    c.data = ob.data.copy()
    c.name = name or (ob.name + "_L")
    (col or ob.users_collection[0]).objects.link(c)
    mw = Matrix.Scale(-1, 4, (1, 0, 0)) @ ob.matrix_world
    c.parent = None
    c.data.transform(mw)
    c.data.flip_normals()
    c.matrix_world = Matrix.Identity(4)
    return c


def bbox_world(objs):
    bpy.context.view_layer.update()
    pts = [o.matrix_world @ V(c) for o in objs if o.type == "MESH" for c in o.bound_box]
    lo = V((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = V((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


# ------------------------------------------------------------------------------------------
# transforms
# ------------------------------------------------------------------------------------------
def T(x=0.0, y=0.0, z=0.0):
    return Matrix.Translation((x, y, z))


def R(axis, deg):
    return Matrix.Rotation(math.radians(deg), 4, axis)


def S(x=1.0, y=None, z=None):
    y = x if y is None else y
    z = x if z is None else z
    return Matrix.Diagonal((x, y, z, 1.0))


def frame(origin, zaxis, xhint=(1, 0, 0)):
    """4x4 with local +Z along `zaxis`, local +X as close to `xhint` as possible."""
    z = V(zaxis).normalized()
    x = V(xhint) - z * V(xhint).dot(z)
    if x.length < 1e-6:
        x = V((0, 1, 0)) - z * z.y
    x.normalize()
    y = z.cross(x)
    m = Matrix((x, y, z)).transposed().to_4x4()
    m.translation = V(origin)
    return m


def _xf(bm, verts, mx):
    if mx is not None:
        bmesh.ops.transform(bm, matrix=mx, verts=verts)


# ------------------------------------------------------------------------------------------
# 2D outlines (CCW lists of (x, y))
# ------------------------------------------------------------------------------------------
def rect2(w, h, cx=0.0, cy=0.0):
    return [(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2), (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2)]


def chamfer_rect2(w, h, c, cx=0.0, cy=0.0, corners=(1, 1, 1, 1)):
    """Rectangle with 45-degree corners; corners = (bottom-left, bottom-right, top-right, top-left) flags
    (values scale the chamfer)."""
    x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    bl, br, tr, tl = (c * k for k in corners)
    pts = []
    pts += [(x0 + bl, y0)] if bl else [(x0, y0)]
    pts += [(x1 - br, y0), (x1, y0 + br)] if br else [(x1, y0)]
    pts += [(x1, y1 - tr), (x1 - tr, y1)] if tr else [(x1, y1)]
    pts += [(x0 + tl, y1), (x0, y1 - tl)] if tl else [(x0, y1)]
    if bl:
        pts += [(x0, y0 + bl)]
    return pts


def rrect2(w, h, r, n=5, cx=0.0, cy=0.0):
    """Rounded rectangle, n segments per corner."""
    r = min(r, w / 2 - 1e-6, h / 2 - 1e-6)
    pts = []
    for (ox, oy, a0) in ((w / 2 - r, h / 2 - r, 0.0), (-w / 2 + r, h / 2 - r, 90.0), (-w / 2 + r, -h / 2 + r, 180.0),
                         (w / 2 - r, -h / 2 + r, 270.0)):
        for i in range(n + 1):
            a = math.radians(a0 + 90.0 * i / n)
            pts.append((cx + ox + r * math.cos(a), cy + oy + r * math.sin(a)))
    return pts


def ngon2(n, r, rot=0.0, cx=0.0, cy=0.0, sx=1.0, sy=1.0):
    return [(cx + sx * r * math.cos(math.radians(rot) + TAU * i / n), cy + sy * r * math.sin(math.radians(rot) + TAU * i / n))
            for i in range(n)]


def offset_convex2(poly, d):
    """Offset a convex CCW polygon outward by d (negative = inward)."""
    n = len(poly)
    lines = []
    for i in range(n):
        ax, ay = poly[i]
        bx, by = poly[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        ln = math.hypot(ex, ey)
        nx, ny = ey / ln, -ex / ln  # outward normal of a CCW polygon
        lines.append((ax + nx * d, ay + ny * d, ex, ey))
    out = []
    for i in range(n):
        x1, y1, dx1, dy1 = lines[i - 1]
        x2, y2, dx2, dy2 = lines[i]
        den = dx1 * dy2 - dy1 * dx2
        if abs(den) < 1e-9:
            out.append((x2, y2))
            continue
        t = ((x2 - x1) * dy2 - (y2 - y1) * dx2) / den
        out.append((x1 + dx1 * t, y1 + dy1 * t))
    return out


# ------------------------------------------------------------------------------------------
# primitives
# ------------------------------------------------------------------------------------------
def lathe(profile, segs=48, bm=None, mx=None, close=False, arc=TAU, start=0.0):
    """Revolve profile [(radius, z), ...] about +Z. Points with radius 0 become poles.
    A profile running towards +Z gives outward-facing normals. `close` links the last ring to the first."""
    bm = bm or bmesh.new()
    full = abs(arc - TAU) < 1e-6
    n = segs if full else segs + 1
    rings = []
    for r, h in profile:
        if r <= 1e-9:
            rings.append([bm.verts.new((0.0, 0.0, h))])
        else:
            rings.append([bm.verts.new((r * math.cos(start + arc * j / segs), r * math.sin(start + arc * j / segs), h))
                          for j in range(n)])
    pairs = list(zip(rings, rings[1:]))
    if close:
        pairs.append((rings[-1], rings[0]))
    for a, b in pairs:
        for j in range(segs):
            j2 = (j + 1) % n
            if len(a) == 1 and len(b) == 1:
                continue
            if len(a) == 1:
                bm.faces.new((a[0], b[j2], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[j], a[j2], b[0]))
            else:
                bm.faces.new((a[j], a[j2], b[j2], b[j]))
    _xf(bm, [v for r_ in rings for v in r_], mx)
    return bm


def cylinder(r, z0, z1, segs=32, chamfer=0.0, bm=None, mx=None, caps=True):
    """Capped cylinder along +Z with optional edge chamfer."""
    c = min(chamfer, r * 0.9, abs(z1 - z0) * 0.45)
    prof = [(r, z0 + c), (r, z1 - c)]
    if c > 0:
        prof = [(r - c, z0)] + prof + [(r - c, z1)]
    if caps:
        prof = [(0.0, z0)] + prof + [(0.0, z1)]
    return lathe(prof, segs, bm, mx)


def ring(r_out, r_in, z0, z1, segs=48, chamfer=0.0, bm=None, mx=None):
    """Annulus with rectangular (chamfered) section."""
    c = min(chamfer, (r_out - r_in) * 0.45, abs(z1 - z0) * 0.45)
    if c > 0:
        prof = [(r_in + c, z0), (r_out - c, z0), (r_out, z0 + c), (r_out, z1 - c), (r_out - c, z1), (r_in + c, z1),
                (r_in, z1 - c), (r_in, z0 + c)]
    else:
        prof = [(r_in, z0), (r_out, z0), (r_out, z1), (r_in, z1)]
    return lathe(prof, segs, bm, mx, close=True)


def torus(R_, r, segs=48, tube_segs=12, bm=None, mx=None):
    prof = [(R_ + r * math.cos(TAU * i / tube_segs), r * math.sin(TAU * i / tube_segs)) for i in range(tube_segs)]
    return lathe(prof, segs, bm, mx, close=True)


def box(size, center=(0.0, 0.0, 0.0), bevel=0.0, segs=2, bm=None, mx=None):
    """Box (optionally with all edges bevelled)."""
    bm = bm or bmesh.new()
    m = Matrix.Translation(center) @ Matrix.Diagonal((size[0], size[1], size[2], 1.0))
    verts = bmesh.ops.create_cube(bm, size=1.0, matrix=m)["verts"]
    if bevel > 0:
        vs = set(verts)
        edges = [e for v in verts for e in v.link_edges if e.verts[0] in vs and e.verts[1] in vs]
        res = bmesh.ops.bevel(bm, geom=list(set(edges)), offset=bevel, offset_type="OFFSET", segments=segs, profile=0.5,
                              affect="EDGES", clamp_overlap=True)
        verts = list(set(res["verts"]) | {v for v in verts if v.is_valid})
    _xf(bm, verts, mx)
    return bm


def prism(poly, z0, z1, bm=None, mx=None, taper=1.0, top_shift=(0.0, 0.0)):
    """Extrude a 2D CCW outline from z0 to z1 (`taper` scales the z1 outline, `top_shift` offsets it)."""
    bm = bm or bmesh.new()
    lo = [bm.verts.new((x, y, z0)) for x, y in poly]
    hi = [bm.verts.new((x * taper + top_shift[0], y * taper + top_shift[1], z1)) for x, y in poly]
    n = len(poly)
    bm.faces.new(list(reversed(lo)))
    bm.faces.new(hi)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    _xf(bm, lo + hi, mx)
    return bm


def loft(rings, bm=None, cap_start=True, cap_end=True, closed=True, mx=None):
    """Skin consecutive rings (lists of 3D points, equal counts). Returns (bm, vert_rings)."""
    bm = bm or bmesh.new()
    vr = [[bm.verts.new(p) for p in ring_] for ring_ in rings]
    n = len(rings[0])
    # face layers "li" (span index along the loft) / "lj" (index around the ring) survive subdivision and
    # let panel layouts follow the cage's edge loops exactly; caps get li = -1 (start) / -2 (end)
    li = bm.faces.layers.int.get("li") or bm.faces.layers.int.new("li")
    lj = bm.faces.layers.int.get("lj") or bm.faces.layers.int.new("lj")
    for i in range(len(vr) - 1):
        for j in range(n if closed else n - 1):
            j2 = (j + 1) % n
            f = bm.faces.new((vr[i][j], vr[i][j2], vr[i + 1][j2], vr[i + 1][j]))
            f[li] = i
            f[lj] = j
    if cap_start:
        f = bm.faces.new(list(reversed(vr[0])))
        f[li] = -1
    if cap_end:
        f = bm.faces.new(vr[-1])
        f[li] = -2
    _xf(bm, [v for r_ in vr for v in r_], mx)
    return bm, vr


def crease_path(bm, verts, value, closed=False):
    """Set subdivision crease on the edges joining consecutive verts."""
    layer = bm.edges.layers.float.get("crease_edge") or bm.edges.layers.float.new("crease_edge")
    seq = list(verts) + ([verts[0]] if closed else [])
    for a, b in zip(seq, seq[1:]):
        e = bm.edges.get((a, b))
        if e is not None:
            e[layer] = value


def fillet_path(points, radius, n=5):
    """Round the interior corners of a 3D polyline with arcs approximated by quadratic curves."""
    pts = [V(p) for p in points]
    if radius <= 0 or len(pts) < 3:
        return pts
    out = [pts[0]]
    for i in range(1, len(pts) - 1):
        p0, p1, p2 = pts[i - 1], pts[i], pts[i + 1]
        d0, d1 = (p0 - p1), (p2 - p1)
        r = min(radius, d0.length * 0.45, d1.length * 0.45)
        a, b = p1 + d0.normalized() * r, p1 + d1.normalized() * r
        for k in range(n + 1):
            t = k / n
            out.append((1 - t) ** 2 * a + 2 * (1 - t) * t * p1 + t ** 2 * b)
    out.append(pts[-1])
    return out


def tube(points, radius, segs=10, bm=None, caps=True, fillet=0.0, mx=None):
    """Sweep a circle along a 3D polyline (parallel-transport frames). Good for pipes / cables / struts."""
    bm = bm or bmesh.new()
    pts = fillet_path(points, fillet) if fillet > 0 else [V(p) for p in points]
    tans = []
    for i in range(len(pts)):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, len(pts) - 1)]
        tans.append((b - a).normalized())
    t0 = tans[0]
    ref = V((0, 0, 1)) if abs(t0.z) < 0.9 else V((1, 0, 0))
    nrm = (ref - t0 * ref.dot(t0)).normalized()
    rings = []
    for i, (p, t) in enumerate(zip(pts, tans)):
        if i > 0:
            nrm = (nrm - t * nrm.dot(t)).normalized()
        bn = t.cross(nrm)
        rr = radius(i / max(len(pts) - 1, 1)) if callable(radius) else radius
        rings.append([p + (nrm * math.cos(TAU * j / segs) + bn * math.sin(TAU * j / segs)) * rr for j in range(segs)])
    loft(rings, bm, cap_start=caps, cap_end=caps, mx=mx)
    return bm


def bevel_all(bm, width, segs=2, angle=None):
    """Destructively bevel every edge (or only edges sharper than `angle` degrees)."""
    bm.normal_update()
    edges = bm.edges[:]
    if angle is not None:
        lim = math.radians(angle)
        edges = [e for e in edges if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > lim]
    bmesh.ops.bevel(bm, geom=edges, offset=width, offset_type="OFFSET", segments=segs, profile=0.5, affect="EDGES",
                    clamp_overlap=True)
    return bm


def bm_from_obj(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    return bm


# ------------------------------------------------------------------------------------------
# Panelizer: cut a smooth skin into separate armour panels with real gaps
# ------------------------------------------------------------------------------------------
class Region:
    def __init__(self, idx, mx, poly, depth, facing, attrs):
        self.idx = idx
        self.mx = mx
        self.inv = mx.inverted()
        self.poly = poly
        self.depth = depth
        self.facing = facing
        self.paint = attrs.get("paint")      # None = keep whatever the base gave
        self.mat = attrs.get("mat")
        self.offset = attrs.get("offset", 0.0)
        self.gap = attrs.get("gap")
        self.remove = attrs.get("remove", False)
        self.name = attrs.get("name", "")
        self.tag = attrs.get("tag", 0)
        self.cut = attrs.get("cut", True)    # False: do not bisect the mesh along the outline
        self.seam = attrs.get("seam", True)  # False: paint-only region (exact outline, but no panel gap)
        self.user = attrs.get("user")
        j = attrs.get("join")                # merge into another region's panel (same id, offset, gap)
        self.pid = j.pid if j is not None else idx
        if j is not None:
            self.offset, self.gap, self.remove = j.offset, j.gap, j.remove


class Panelizer:
    """Usage:
        pz = Panelizer(bm)
        pz.plane(co, no)                       # global cut line (grid of base panels)
        pz.base = lambda C, N: ids             # numpy (F,3) centres / normals -> int array of base panel ids
        pz.region(frame, poly2d, depth=(lo, hi), paint=2, offset=0.01, remove=False)
        pz.run()
    Regions are convex 2D polygons in the XY plane of `frame`, projected along the frame's -Z onto faces
    that look towards +Z (dot > facing) and lie within `depth` along Z. Later regions override earlier ones.
    Face int layers written: "pid" (panel id), "paint" (paint slot).
    """

    def __init__(self, bm, snap=0.003, gap=0.014, margin=0.5):
        self.bm = bm
        self.snap = snap
        self.gap = gap
        self.margin = margin
        self.planes = []
        self.regions = []
        self.base = None
        self.base_paint = None  # optional fn(C, N) -> int array
        self.base_face = None   # optional fn(face) -> (panel id, paint) evaluated per face after cutting
        self.log = []
        self.fixed = 0

    def plane(self, co, no, where=None):
        self.planes.append((V(co), V(no).normalized(), where))

    def region(self, mx, poly, depth=(-1e6, 1e6), facing=0.15, **attrs):
        r = Region(len(self.regions) + 1, mx.copy(), [tuple(p) for p in poly], depth, facing, attrs)
        self.regions.append(r)
        return r

    # -- helpers ---------------------------------------------------------------------------
    def _arrays(self):
        bm = self.bm
        bm.faces.ensure_lookup_table()
        n = len(bm.faces)
        C = np.empty((n, 3))
        N = np.empty((n, 3))
        for i, f in enumerate(bm.faces):
            C[i] = f.calc_center_median()
            N[i] = f.normal
        return C, N

    @staticmethod
    def _local(r, C, N):
        m = np.array(r.inv)
        P = C @ m[:3, :3].T + m[:3, 3]
        w = np.array(r.mx.to_3x3().col[2])
        return P, N @ w

    def _mask(self, r, C, N, grow=0.0, loose=False):
        P, f = self._local(r, C, N)
        ok = (P[:, 2] >= r.depth[0] - grow) & (P[:, 2] <= r.depth[1] + grow)
        if r.facing > -1.5:   # facing <= -1.5: project through the whole body, whatever the face orientation
            ok &= f > (r.facing - (0.35 if loose else 0.0))
        poly = r.poly
        if loose:
            xs = [p[0] for p in poly]
            ys = [p[1] for p in poly]
            ok &= (P[:, 0] > min(xs) - grow) & (P[:, 0] < max(xs) + grow) & (P[:, 1] > min(ys) - grow) & (P[:, 1] < max(ys) + grow)
            return ok
        n = len(poly)
        for i in range(n):
            ax, ay = poly[i]
            bx, by = poly[(i + 1) % n]
            ex, ey = bx - ax, by - ay
            ok &= ((P[:, 0] - ax) * ey - (P[:, 1] - ay) * ex) <= 1e-7  # inside = right of the outward normal
        return ok

    def _bisect(self, faces, co, no):
        if not faces:
            return faces
        geom = set(faces)
        for f in faces:
            geom.update(f.edges)
            geom.update(f.verts)
        res = bmesh.ops.bisect_plane(self.bm, geom=list(geom), dist=self.snap, plane_co=co, plane_no=no)
        return [g for g in res["geom"] if isinstance(g, bmesh.types.BMFace)]

    # -- main ------------------------------------------------------------------------------
    def run(self):
        bm = self.bm
        bm.normal_update()
        # 1. global planes
        for co, no, where in self.planes:
            if where is None:
                faces = bm.faces[:]
            else:
                C, N = self._arrays()
                sel = where(C, N)
                faces = [f for f, s in zip(bm.faces, sel) if s]
            self._bisect(faces, co, no)
        # 2. region outlines
        for r in self.regions:
            if not r.cut:
                continue
            C, N = self._arrays()
            sel = self._mask(r, C, N, grow=self.margin, loose=True)
            faces = [f for f, s in zip(bm.faces, sel) if s]
            n = len(r.poly)
            for i in range(n):
                ax, ay = r.poly[i]
                bx, by = r.poly[(i + 1) % n]
                ex, ey = bx - ax, by - ay
                co = r.mx @ V((ax, ay, 0.0))
                no = (r.mx.to_3x3() @ V((ey, -ex, 0.0))).normalized()
                faces = [f for f in self._bisect(faces, co, no) if f.is_valid]
        bm.normal_update()
        # 3. classify (on the exact cut result: every face lies wholly on one side of every outline)
        C, N = self._arrays()
        nf = len(C)
        pid = np.zeros(nf, dtype=np.int64)
        if self.base is not None:
            pid = np.asarray(self.base(C, N), dtype=np.int64) + 100000
        paint = np.zeros(nf, dtype=np.int64)
        if self.base_paint is not None:
            paint = np.asarray(self.base_paint(C, N), dtype=np.int64)
        if self.base_face is not None:
            for i, f in enumerate(bm.faces):
                a, b_ = self.base_face(f)
                pid[i] = a + 100000
                paint[i] = b_
        reg = np.zeros(nf, dtype=np.int64)
        for r in self.regions:
            m = self._mask(r, C, N)
            if r.seam:
                pid[m] = r.pid
                reg[m] = r.pid
            if r.paint is not None:
                paint[m] = r.paint
            self.log.append((r.name, int(m.sum())))
        lp = bm.faces.layers.int.get("pid") or bm.faces.layers.int.new("pid")
        lc = bm.faces.layers.int.get("paint") or bm.faces.layers.int.new("paint")
        rmap = {r.idx: r for r in self.regions}
        for i, f in enumerate(bm.faces):
            f[lp] = int(pid[i])
            f[lc] = int(paint[i])
            r = rmap.get(int(reg[i]))
            if r is not None and r.mat is not None:
                f.material_index = r.mat
        # tiny faces must never form their own island (they would turn into spikes when inset)
        for f in bm.faces:
            if f.calc_area() < 3e-5:
                best, blen = None, 0.0
                same = False
                for e in f.edges:
                    for g in e.link_faces:
                        if g is f:
                            continue
                        if g[lp] == f[lp]:
                            same = True
                        ln = e.calc_length()
                        if ln > blen:
                            best, blen = g, ln
                if not same and best is not None:
                    f[lp] = best[lp]
                    f[lc] = best[lc]
                    f.material_index = best.material_index
        # 4. split along panel borders
        seams = [e for e in bm.edges if len(e.link_faces) == 2 and e.link_faces[0][lp] != e.link_faces[1][lp]]
        bmesh.ops.split_edges(bm, edges=seams)
        # 5. removed regions
        dead = [f for f in bm.faces if (rmap.get(f[lp]) is not None and rmap[f[lp]].remove)]
        if dead:
            bmesh.ops.delete(bm, geom=dead, context="FACES")
        # 6. raised / recessed panels
        bm.normal_update()
        moved = {}
        for f in bm.faces:
            r = rmap.get(f[lp])
            if r is not None and r.offset:
                for v in f.verts:
                    moved[v] = r.offset
        for v, d in moved.items():
            v.co += v.normal * d
        # 7. gaps
        groups = {}
        for f in bm.faces:
            r = rmap.get(f[lp])
            g = self.gap if (r is None or r.gap is None) else r.gap
            groups.setdefault(g, []).append(f)
        for g, faces in groups.items():
            if g <= 0:
                continue
            faces = [f for f in faces if f.is_valid]
            pre = {f: f.normal.copy() for f in faces}
            res = bmesh.ops.inset_region(bm, faces=faces, thickness=g * 0.5, depth=0.0, use_boundary=True,
                                         use_even_offset=True, use_interpolate=True)
            bmesh.ops.delete(bm, geom=res["faces"], context="FACES")
            # the border may have been pushed across small faces next to it (they flip): collapse those
            for _pass in range(6):
                bm.normal_update()
                flipped = [f for f in pre if f.is_valid and f.normal.dot(pre[f]) < 0.3]
                if not flipped:
                    break
                tmap, kill = {}, []
                for f in flipped:
                    bv = [v for v in f.verts if v.is_boundary]
                    iv = [v for v in f.verts if not v.is_boundary]
                    if not bv or not iv:
                        kill.append(f)
                        continue
                    for v in iv:
                        tmap[v] = min(bv, key=lambda q: (q.co - v.co).length_squared)
                if kill:
                    bmesh.ops.delete(bm, geom=kill, context="FACES")
                if tmap:
                    bmesh.ops.weld_verts(bm, targetmap=tmap)
                self.fixed += len(flipped)
        bm.normal_update()
        return bm


def skin_objects(name, bm, col, mats, thickness=0.03, bevel=0.006, under=None, under_mat=None, under_shrink=0.022,
                 smooth=40.0):
    """Finish a panelized skin: rim-solidify + bevel; optional dark under-layer from the uncut mesh `under`."""
    ob = to_obj(name, bm, col, mats, smooth=smooth, recalc=False)
    mod_solidify(ob, thickness, rim_only=True)
    if bevel > 0:
        mod_bevel(ob, bevel, segs=2, angle=50.0)
    apply_mods(ob)
    shade(ob, smooth)
    uo = None
    if under is not None:
        under.normal_update()
        for v in under.verts:
            v.co -= v.normal * under_shrink
        uo = to_obj(name + "_under", under, col, [under_mat] if under_mat else (), smooth=smooth, recalc=False)
    return ob, uo


def surface_points(bvh, mx, pts2d, z_from=50.0):
    """Project 2D points (in the XY plane of frame `mx`) along the frame's -Z onto a BVH.
    Returns [(location, normal)] for points that hit."""
    out = []
    zax = mx.to_3x3() @ V((0, 0, 1))
    for x, y in pts2d:
        o = mx @ V((x, y, z_from))
        hit, nrm, _i, _d = bvh.ray_cast(o, -zax)
        if hit is not None:
            out.append((hit, nrm))
    return out


def outline_points(poly, spacing, inset=0.0):
    """Evenly spaced points along a (convex) 2D outline, optionally inset."""
    p = offset_convex2(poly, -inset) if inset else poly
    pts = []
    n = len(p)
    for i in range(n):
        a, b = V(p[i]), V(p[(i + 1) % n])
        ln = (b - a).length
        k = max(1, round(ln / spacing))
        for j in range(k):
            q = a.lerp(b, (j + 0.5) / k)
            pts.append((q.x, q.y))
    return pts
