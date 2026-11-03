#!/usr/bin/env python3
"""Read-only GLB 2 audit of jobs.json local_file entries.

Writes validation.json and validation.txt only. This is a bounded structural
audit, not a complete Khronos glTF validator or a game-ready certification.
No network requests, mesh changes, Blender imports or manifest writes occur.
Python 3.10+; Pillow is optional (recommended for embedded image headers).
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import io
import json
import math
from pathlib import Path
import shutil
import struct
import sys
import tempfile
from urllib.parse import unquote, unquote_to_bytes, urlsplit
import warnings

try:
    from PIL import Image
except ImportError:
    Image = None


COMPONENTS = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
              5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
TYPE_SHAPES = {"SCALAR": (1, 1), "VEC2": (2, 1), "VEC3": (3, 1),
               "VEC4": (4, 1), "MAT2": (2, 2), "MAT3": (3, 3), "MAT4": (4, 4)}
IDENTITY = (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
DEFAULT_BUDGETS = {
    "characters": {"triangles": 20000, "materials": 2, "texture_max_edge": 2048},
    "ships": {"triangles": 20000, "materials": 3, "texture_max_edge": 2048},
    "backpacks": {"triangles": 3000, "materials": 1, "texture_max_edge": 1024},
    "tools": {"triangles": 2000, "materials": 1, "texture_max_edge": 1024},
}
PROTOTYPE_TRIANGLE_WARNING_FRACTION = 0.05
SCOPE = {
    "performed": ["GLB header and chunk layout", "selected glTF JSON references",
                  "buffer/view/accessor bounds and layouts including sparse accessors",
                  "uncompressed index ranges and finite POSITION values",
                  "stored mesh and active-scene triangle/vertex counts",
                  "embedded/local image header dimensions", "node-transformed scene AABB",
                  "skin/animation presence and selected references", "declared asset budgets"],
    "not_performed": ["full Khronos schema/extension conformance", "compressed mesh decoding",
                      "manifold/interior/duplicate/loose geometry inspection",
                      "normals orientation or shading quality", "UV overlap/packing/texel density",
                      "visual silhouette or reference match", "rig deformation and animation playback",
                      "collision/LOD construction or validation", "real-world scale/pivot/forward-axis verification",
                      "engine import (reported separately in godot_import_check.*), material appearance or runtime performance"],
}


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def finite_vector(value, length):
    return (isinstance(value, list) and len(value) == length and
            all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
                for x in value))


def merge_bounds(bounds):
    valid = [b for b in bounds if b is not None]
    if not valid:
        return None
    lo = [min(b[0][i] for b in valid) for i in range(3)]
    hi = [max(b[1][i] for b in valid) for i in range(3)]
    return lo, hi


def bounds_dict(bounds):
    if bounds is None:
        return None
    lo, hi = bounds
    return {"min": lo, "max": hi, "size": [hi[i] - lo[i] for i in range(3)]}


def matrix_multiply(a, b):
    return tuple(sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4))
                 for c in range(4) for r in range(4))


def transformed_bounds(bounds, matrix):
    if bounds is None:
        return None
    lo, hi = bounds
    points = []
    for x in (lo[0], hi[0]):
        for y in (lo[1], hi[1]):
            for z in (lo[2], hi[2]):
                points.append([matrix[r] * x + matrix[4 + r] * y +
                               matrix[8 + r] * z + matrix[12 + r] for r in range(3)])
    return ([min(p[i] for p in points) for i in range(3)],
            [max(p[i] for p in points) for i in range(3)])


class GLBAudit:
    def __init__(self, path):
        self.path = Path(path).resolve()
        self.errors, self.warnings, self.incomplete = [], [], []
        self.doc, self.bin_chunk = {}, None
        self.buffers, self.views, self.accessors = [], [], []
        self.mesh_bounds, self.mesh_stats = [], []
        self.position_bounds = {}
        self.compressed_accessors = set()
        self.used_position_accessors = set()
        self.used_materials = set()
        self.report = {"path": str(self.path), "game_ready": "not_assessed"}

    def issue(self, message, *, warning=False, incomplete=False):
        target = self.incomplete if incomplete else self.warnings if warning else self.errors
        if message not in target:
            target.append(message)

    def array(self, key):
        value = self.doc.get(key, [])
        if not isinstance(value, list):
            self.issue(f"{key}: expected an array")
            return []
        return value

    def extensions(self, item, context):
        value = item.get("extensions", {})
        if not isinstance(value, dict):
            self.issue(f"{context}.extensions: expected an object")
            return {}
        return value

    def ref(self, value, values, context):
        if not is_int(value) or not 0 <= value < len(values):
            self.issue(f"{context}: invalid index {value!r} (array length {len(values)})")
            return None
        return value

    def uint(self, value, context, minimum=0):
        if not is_int(value) or value < minimum:
            self.issue(f"{context}: expected integer >= {minimum}, got {value!r}")
            return None
        return value

    def load_container(self):
        data = self.path.read_bytes()
        self.report["file_bytes"] = len(data)
        if len(data) < 12:
            self.issue("GLB: truncated 12-byte header")
            return False
        magic, version, declared_length = struct.unpack_from("<4sII", data)
        self.report["container"] = {"magic": magic.decode("ascii", "replace"),
                                    "version": version, "declared_length": declared_length}
        if magic != b"glTF":
            self.issue("GLB: invalid magic; expected glTF")
        if version != 2:
            self.issue(f"GLB: unsupported container version {version}; expected 2")
        if declared_length != len(data):
            self.issue(f"GLB: declared length {declared_length} != file length {len(data)}")
        offset, chunks = 12, []
        while offset < len(data):
            if offset + 8 > len(data):
                self.issue("GLB: truncated chunk header")
                break
            length, kind = struct.unpack_from("<I4s", data, offset)
            offset += 8
            if length % 4:
                self.issue(f"GLB: {kind!r} chunk length {length} is not 4-byte aligned")
            if offset + length > len(data):
                self.issue("GLB: chunk extends beyond file")
                break
            chunks.append((kind, memoryview(data)[offset:offset + length]))
            offset += length
        self.report["container"]["chunks"] = [
            {"type": k.decode("ascii", "replace"), "bytes": len(v)} for k, v in chunks]
        if not chunks or chunks[0][0] != b"JSON":
            self.issue("GLB: first chunk must be JSON")
            return False
        if sum(k == b"JSON" for k, _ in chunks) != 1:
            self.issue("GLB: exactly one JSON chunk is required")
        bins = [v for k, v in chunks if k == b"BIN\x00"]
        if len(bins) > 1:
            self.issue("GLB: more than one BIN chunk")
        self.bin_chunk = bins[0] if bins else None
        for index, (kind, _) in enumerate(chunks):
            if kind == b"BIN\x00" and index != 1:
                self.issue("GLB: BIN chunk must immediately follow JSON")
            if kind not in (b"JSON", b"BIN\x00"):
                self.issue(f"GLB: unknown chunk {kind!r} ignored", warning=True)
        try:
            self.doc = json.loads(bytes(chunks[0][1]).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            self.issue(f"GLB: invalid UTF-8 JSON: {exc}")
            return False
        if not isinstance(self.doc, dict):
            self.issue("glTF JSON root must be an object")
            return False
        asset = self.doc.get("asset", {})
        if not isinstance(asset, dict) or asset.get("version") != "2.0":
            self.issue("asset.version must be '2.0'")
        self.report["generator"] = asset.get("generator") if isinstance(asset, dict) else None
        self.report["extensions_used"] = self.doc.get("extensionsUsed", [])
        self.report["extensions_required"] = self.doc.get("extensionsRequired", [])
        return magic == b"glTF" and version == 2

    def uri_bytes(self, uri, context):
        if not isinstance(uri, str):
            self.issue(f"{context}: URI must be a string")
            return None
        if uri.startswith("data:"):
            try:
                header, payload = uri.split(",", 1)
                return base64.b64decode(payload, validate=True) if header.endswith(";base64") else unquote_to_bytes(payload)
            except (ValueError, TypeError) as exc:
                self.issue(f"{context}: malformed data URI: {exc}")
                return None
        parsed = urlsplit(uri)
        if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment:
            self.issue(f"{context}: external/network URI not read", incomplete=True)
            return None
        target = (self.path.parent / unquote(parsed.path)).resolve()
        if not target.is_relative_to(self.path.parent):
            self.issue(f"{context}: URI escapes model folder; not read", incomplete=True)
            return None
        if not target.is_file():
            self.issue(f"{context}: referenced local file is missing: {target.name}")
            return None
        return target.read_bytes()

    def load_buffers(self):
        for i, item in enumerate(self.array("buffers")):
            if not isinstance(item, dict):
                self.issue(f"buffers[{i}]: expected object")
                self.buffers.append(None)
                continue
            length = self.uint(item.get("byteLength"), f"buffers[{i}].byteLength", 1)
            if "uri" in item:
                payload = self.uri_bytes(item["uri"], f"buffers[{i}]")
            elif i == 0:
                payload = self.bin_chunk
                if payload is None:
                    self.issue("buffers[0]: no URI and no BIN chunk")
            else:
                payload = None
                self.issue(f"buffers[{i}]: only buffer 0 may use the GLB BIN chunk")
            if payload is not None and length is not None:
                if len(payload) < length:
                    self.issue(f"buffers[{i}]: {length} declared bytes exceed {len(payload)} actual bytes")
                if "uri" not in item and len(payload) - length not in range(4):
                    self.issue(f"buffers[{i}]: GLB BIN padding must be 0-3 bytes")
                payload = memoryview(payload)[:length]
            self.buffers.append(payload)
        if self.bin_chunk is not None and not self.array("buffers"):
            self.issue("GLB BIN chunk has no buffers[0] declaration", warning=True)

    def load_views(self):
        for i, item in enumerate(self.array("bufferViews")):
            context = f"bufferViews[{i}]"
            if not isinstance(item, dict):
                self.issue(f"{context}: expected object")
                self.views.append(None)
                continue
            buffer = self.ref(item.get("buffer"), self.buffers, context + ".buffer")
            offset = self.uint(item.get("byteOffset", 0), context + ".byteOffset")
            length = self.uint(item.get("byteLength"), context + ".byteLength", 1)
            stride = item.get("byteStride")
            if stride is not None and (not is_int(stride) or not 4 <= stride <= 252 or stride % 4):
                self.issue(f"{context}: byteStride must be a multiple of 4 in 4..252")
            target = item.get("target")
            if target is not None and target not in (34962, 34963):
                self.issue(f"{context}: invalid target {target!r}")
            compressed = "EXT_meshopt_compression" in self.extensions(item, context)
            if compressed:
                self.issue(f"{context}: meshopt compressed data is not decoded", incomplete=True)
            if None in (buffer, offset, length):
                self.views.append(None)
                continue
            data = self.buffers[buffer]
            if data is not None and offset + length > len(data):
                self.issue(f"{context}: byte range exceeds buffer")
                self.views.append(None)
                continue
            self.views.append({"buffer": buffer, "offset": offset, "length": length,
                               "stride": stride, "data": data, "compressed": compressed})

    @staticmethod
    def element_layout(type_name, component_type):
        rows, columns = TYPE_SHAPES[type_name]
        code, component_size = COMPONENTS[component_type]
        column_size = rows * component_size
        column_stride = (column_size + 3) // 4 * 4 if columns > 1 else column_size
        offsets = [col * column_stride + row * component_size
                   for col in range(columns) for row in range(rows)]
        return {"element_bytes": columns * column_stride, "component_bytes": component_size,
                "component_offsets": offsets, "component_count": rows * columns,
                "struct": struct.Struct("<" + code * (rows * columns)),
                "scalar_struct": struct.Struct("<" + code), "matrix": columns > 1}

    def load_accessors(self):
        for i, item in enumerate(self.array("accessors")):
            context = f"accessors[{i}]"
            if not isinstance(item, dict):
                self.issue(f"{context}: expected object")
                self.accessors.append(None)
                continue
            type_name, component_type = item.get("type"), item.get("componentType")
            count = self.uint(item.get("count"), context + ".count", 1)
            offset = self.uint(item.get("byteOffset", 0), context + ".byteOffset")
            if type_name not in TYPE_SHAPES or component_type not in COMPONENTS or count is None or offset is None:
                self.issue(f"{context}: invalid type/componentType/count/offset")
                self.accessors.append(None)
                continue
            layout = self.element_layout(type_name, component_type)
            layout.update({"count": count, "type": type_name, "component_type": component_type,
                           "normalized": item.get("normalized", False), "item": item,
                           "view": None, "offset": offset, "valid": True, "sparse": None})
            if not isinstance(layout["normalized"], bool):
                self.issue(f"{context}: normalized must be boolean")
            if layout["normalized"] and component_type in (5125, 5126):
                self.issue(f"{context}: UINT32/FLOAT cannot be normalized")
            if offset % layout["component_bytes"]:
                self.issue(f"{context}: byteOffset not aligned to component size")
                layout["valid"] = False
            if "bufferView" in item:
                vi = self.ref(item["bufferView"], self.views, context + ".bufferView")
                view = self.views[vi] if vi is not None else None
                layout["view"] = view
                if view is None:
                    layout["valid"] = False
                else:
                    stride = view["stride"] or layout["element_bytes"]
                    layout["stride"] = stride
                    if not is_int(stride) or stride < layout["element_bytes"] or stride % layout["component_bytes"]:
                        self.issue(f"{context}: invalid element stride")
                        layout["valid"] = False
                    elif offset + (count - 1) * stride + layout["element_bytes"] > view["length"]:
                        self.issue(f"{context}: accessor extends beyond bufferView")
                        layout["valid"] = False
                    if (view["offset"] + offset) % layout["component_bytes"]:
                        self.issue(f"{context}: absolute byte offset is misaligned")
                        layout["valid"] = False
                    if layout["matrix"] and (view["offset"] + offset) % 4:
                        self.issue(f"{context}: matrix columns must be 4-byte aligned")
                        layout["valid"] = False
            elif offset:
                self.issue(f"{context}: byteOffset must be zero without a bufferView")
                layout["valid"] = False
            for bound in ("min", "max"):
                value = item.get(bound)
                if value is not None and not finite_vector(value, layout["component_count"]):
                    self.issue(f"{context}.{bound}: invalid finite vector")
            if finite_vector(item.get("min"), layout["component_count"]) and finite_vector(item.get("max"), layout["component_count"]):
                if any(a > b for a, b in zip(item["min"], item["max"])):
                    self.issue(f"{context}: min exceeds max")
            self.accessors.append(layout)
            if "sparse" in item:
                self.load_sparse(i, layout, item["sparse"])

    def sparse_view(self, entry, count, element_bytes, context, alignment):
        if not isinstance(entry, dict):
            self.issue(f"{context}: expected object")
            return None
        vi = self.ref(entry.get("bufferView"), self.views, context + ".bufferView")
        offset = self.uint(entry.get("byteOffset", 0), context + ".byteOffset")
        view = self.views[vi] if vi is not None else None
        if view is None or offset is None:
            return None
        if view["stride"] is not None:
            self.issue(f"{context}: sparse bufferView cannot have byteStride")
            return None
        if offset + count * element_bytes > view["length"]:
            self.issue(f"{context}: sparse byte range exceeds bufferView")
            return None
        if (view["offset"] + offset) % alignment:
            self.issue(f"{context}: sparse byte range is misaligned")
            return None
        return view, offset

    def load_sparse(self, ai, layout, sparse):
        context = f"accessors[{ai}].sparse"
        if not isinstance(sparse, dict):
            self.issue(f"{context}: expected object")
            layout["valid"] = False
            return
        count = self.uint(sparse.get("count"), context + ".count", 1)
        indices = sparse.get("indices", {})
        ct = indices.get("componentType") if isinstance(indices, dict) else None
        if count is None or count > layout["count"] or ct not in (5121, 5123, 5125):
            self.issue(f"{context}: invalid count/index component type")
            layout["valid"] = False
            return
        code, size = COMPONENTS[ct]
        index_view = self.sparse_view(indices, count, size, context + ".indices", size)
        value_view = self.sparse_view(sparse.get("values"), count, layout["element_bytes"],
                                      context + ".values", 4 if layout["matrix"] else layout["component_bytes"])
        if index_view is None or value_view is None:
            layout["valid"] = False
            return
        layout["sparse"] = {"count": count, "indices": index_view, "values": value_view,
                            "index_struct": struct.Struct("<" + code), "index_bytes": size}
        previous = -1
        for index, _ in self.iter_sparse(layout):
            if not previous < index < layout["count"]:
                self.issue(f"{context}: sparse indices must increase strictly and remain within count")
                layout["valid"] = False
                break
            previous = index

    @staticmethod
    def unpack_element(layout, data, offset):
        offsets = layout["component_offsets"]
        if offsets == list(range(0, layout["component_count"] * layout["component_bytes"], layout["component_bytes"])):
            return layout["struct"].unpack_from(data, offset)
        return tuple(layout["scalar_struct"].unpack_from(data, offset + x)[0] for x in offsets)

    def iter_sparse(self, layout):
        sparse = layout["sparse"]
        iv, io = sparse["indices"]
        vv, vo = sparse["values"]
        if iv["data"] is None or vv["data"] is None or iv["compressed"] or vv["compressed"]:
            return
        for n in range(sparse["count"]):
            index = sparse["index_struct"].unpack_from(iv["data"], iv["offset"] + io + n * sparse["index_bytes"])[0]
            value = self.unpack_element(layout, vv["data"], vv["offset"] + vo + n * layout["element_bytes"])
            yield index, value

    def can_read(self, index):
        layout = self.accessors[index]
        if layout is None or not layout["valid"] or index in self.compressed_accessors:
            return False
        view = layout["view"]
        if view is not None and (view["data"] is None or view["compressed"]):
            return False
        sparse = layout["sparse"]
        return not sparse or all(v[0]["data"] is not None and not v[0]["compressed"]
                                 for v in (sparse["indices"], sparse["values"]))

    def values(self, index, normalized=False):
        layout = self.accessors[index]
        view = layout["view"]
        overrides = iter(self.iter_sparse(layout)) if layout["sparse"] else iter(())
        current = next(overrides, None)
        zero = (0,) * layout["component_count"]
        for n in range(layout["count"]):
            if current is not None and current[0] == n:
                value = current[1]
                current = next(overrides, None)
            elif view is not None:
                value = self.unpack_element(layout, view["data"], view["offset"] + layout["offset"] + n * layout["stride"])
            else:
                value = zero
            if normalized and layout["normalized"]:
                ct = layout["component_type"]
                divisor = {5120: 127, 5121: 255, 5122: 32767, 5123: 65535}.get(ct)
                if divisor:
                    value = tuple(max(v / divisor, -1.0) if ct in (5120, 5122) else v / divisor for v in value)
            yield value

    def get_position_bounds(self, ai):
        if ai in self.position_bounds:
            return self.position_bounds[ai]
        layout = self.accessors[ai]
        if layout is None or layout["type"] != "VEC3":
            self.issue(f"POSITION accessor {ai}: must be VEC3")
            return None
        result = None
        if self.can_read(ai):
            lo, hi = [math.inf] * 3, [-math.inf] * 3
            for value in self.values(ai, normalized=True):
                if not all(math.isfinite(v) for v in value):
                    self.issue(f"POSITION accessor {ai}: non-finite coordinate")
                    continue
                for axis in range(3):
                    lo[axis] = min(lo[axis], value[axis])
                    hi[axis] = max(hi[axis], value[axis])
            if all(math.isfinite(v) for v in lo + hi):
                result = lo, hi
                item = layout["item"]
                if not layout["normalized"]:
                    for name, actual in (("min", lo), ("max", hi)):
                        declared = item.get(name)
                        if finite_vector(declared, 3) and any(not math.isclose(a, b, rel_tol=1e-5, abs_tol=1e-6) for a, b in zip(declared, actual)):
                            self.issue(f"POSITION accessor {ai}: declared {name} differs from decoded data")
                if all(abs(hi[x] - lo[x]) < 1e-12 for x in range(3)):
                    self.issue(f"POSITION accessor {ai}: all positions occupy one point", warning=True)
        else:
            item = layout["item"]
            if finite_vector(item.get("min"), 3) and finite_vector(item.get("max"), 3) and not layout["normalized"]:
                result = item["min"], item["max"]
            self.issue(f"POSITION accessor {ai}: data not decoded; bounds use metadata where available", incomplete=True)
        if "min" not in layout["item"] or "max" not in layout["item"]:
            self.issue(f"POSITION accessor {ai}: required min/max missing")
        self.position_bounds[ai] = result
        return result

    def inspect_meshes(self):
        meshes, materials = self.array("meshes"), self.array("materials")
        for mi, mesh in enumerate(meshes):
            if not isinstance(mesh, dict) or not isinstance(mesh.get("primitives"), list) or not mesh["primitives"]:
                self.issue(f"meshes[{mi}]: nonempty primitives array required")
                self.mesh_bounds.append(None)
                self.mesh_stats.append({"index": mi, "triangles": 0, "vertices": 0, "primitives": []})
                continue
            stats = {"index": mi, "name": mesh.get("name"), "triangles": 0, "vertices": 0, "primitives": []}
            boxes = []
            for pi, primitive in enumerate(mesh["primitives"]):
                context = f"meshes[{mi}].primitives[{pi}]"
                if not isinstance(primitive, dict):
                    self.issue(f"{context}: expected object")
                    continue
                attributes = primitive.get("attributes", {})
                if not isinstance(attributes, dict):
                    self.issue(f"{context}.attributes: expected object")
                    continue
                attr_indices = {}
                for name, index in attributes.items():
                    ai = self.ref(index, self.accessors, context + ".attributes." + name)
                    if ai is not None and self.accessors[ai] is not None:
                        attr_indices[name] = ai
                if "POSITION" not in attr_indices:
                    self.issue(f"{context}: POSITION attribute required")
                    continue
                position = attr_indices["POSITION"]
                self.used_position_accessors.add(position)
                vertex_count = self.accessors[position]["count"]
                primitive_extensions = self.extensions(primitive, context)
                if "KHR_draco_mesh_compression" in primitive_extensions:
                    self.compressed_accessors.update(attr_indices.values())
                    if is_int(primitive.get("indices")):
                        self.compressed_accessors.add(primitive["indices"])
                    self.issue(f"{context}: Draco payload not decoded; counts derive from accessors", incomplete=True)
                    extension = primitive_extensions["KHR_draco_mesh_compression"]
                    if isinstance(extension, dict):
                        self.ref(extension.get("bufferView"), self.views, context + ".Draco.bufferView")
                for name, ai in attr_indices.items():
                    if self.accessors[ai]["count"] != vertex_count:
                        self.issue(f"{context}: {name} count differs from POSITION")
                    view = self.accessors[ai]["view"]
                    if view and (view["offset"] + self.accessors[ai]["offset"]) % 4:
                        self.issue(f"{context}: vertex attribute {name} must be 4-byte aligned")
                for name in ("NORMAL", "TEXCOORD_0"):
                    if name not in attributes:
                        self.issue(f"{context}: {name} absent", warning=True)
                count = vertex_count
                if "indices" in primitive:
                    ai = self.ref(primitive["indices"], self.accessors, context + ".indices")
                    if ai is not None and self.accessors[ai] is not None:
                        accessor = self.accessors[ai]
                        count = accessor["count"]
                        if accessor["type"] != "SCALAR" or accessor["component_type"] not in (5121, 5123, 5125):
                            self.issue(f"{context}: indices must be unsigned SCALAR")
                        elif self.can_read(ai):
                            maximum = max((v[0] for v in self.values(ai)), default=-1)
                            if maximum >= vertex_count:
                                self.issue(f"{context}: index {maximum} exceeds vertex count {vertex_count}")
                            if maximum == {5121: 255, 5123: 65535, 5125: 4294967295}[accessor["component_type"]]:
                                self.issue(f"{context}: index uses the forbidden primitive-restart value")
                        else:
                            self.issue(f"{context}: index range not decoded", incomplete=True)
                        if accessor["normalized"]:
                            self.issue(f"{context}: index accessor cannot be normalized")
                        if accessor["view"] and accessor["view"]["stride"] is not None:
                            self.issue(f"{context}: index bufferView cannot have byteStride")
                mode = primitive.get("mode", 4)
                triangles = count // 3 if mode == 4 else max(0, count - 2) if mode in (5, 6) else 0
                if not is_int(mode) or mode not in range(7):
                    self.issue(f"{context}: invalid primitive mode {mode!r}")
                if mode == 4 and count % 3:
                    self.issue(f"{context}: TRIANGLES index/vertex count not divisible by 3")
                if mode != 4:
                    self.issue(f"{context}: mode {mode}; strip/fan counts include degenerates, points/lines are not triangles", warning=True)
                if "material" in primitive:
                    material = self.ref(primitive["material"], materials, context + ".material")
                    if material is not None:
                        self.used_materials.add(material)
                boxes.append(self.get_position_bounds(position))
                stats["triangles"] += triangles
                stats["vertices"] += vertex_count
                stats["primitives"].append({"index": pi, "mode": mode, "triangles": triangles,
                                            "vertices": vertex_count, "attributes": sorted(attributes),
                                            "material": primitive.get("material"), "morph_targets": len(primitive.get("targets", []))})
                for ti, target in enumerate(primitive.get("targets", [])):
                    if not isinstance(target, dict):
                        self.issue(f"{context}.targets[{ti}]: expected object")
                        continue
                    for name, index in target.items():
                        ai = self.ref(index, self.accessors, f"{context}.targets[{ti}].{name}")
                        if ai is not None and self.accessors[ai] is not None and self.accessors[ai]["count"] != vertex_count:
                            self.issue(f"{context}: morph target count differs from POSITION")
            self.mesh_bounds.append(merge_bounds(boxes))
            stats["bounds_local"] = bounds_dict(self.mesh_bounds[-1])
            self.mesh_stats.append(stats)

    def node_matrix(self, node, context):
        if "matrix" in node:
            if any(k in node for k in ("translation", "rotation", "scale")):
                self.issue(f"{context}: matrix and TRS cannot coexist")
            if not finite_vector(node["matrix"], 16):
                self.issue(f"{context}: invalid 16-element matrix")
                return IDENTITY
            return tuple(node["matrix"])
        values = {}
        for key, default in (("translation", [0, 0, 0]), ("rotation", [0, 0, 0, 1]), ("scale", [1, 1, 1])):
            value = node.get(key, default)
            if not finite_vector(value, len(default)):
                self.issue(f"{context}.{key}: invalid finite vector")
                value = default
            values[key] = value
        x, y, z, w = values["rotation"]
        if not math.isclose(x*x + y*y + z*z + w*w, 1.0, rel_tol=1e-4, abs_tol=1e-4):
            self.issue(f"{context}: rotation quaternion is not unit length")
        sx, sy, sz = values["scale"]
        tx, ty, tz = values["translation"]
        return ((1-2*y*y-2*z*z)*sx, (2*x*y+2*z*w)*sx, (2*x*z-2*y*w)*sx, 0,
                (2*x*y-2*z*w)*sy, (1-2*x*x-2*z*z)*sy, (2*y*z+2*x*w)*sy, 0,
                (2*x*z+2*y*w)*sz, (2*y*z-2*x*w)*sz, (1-2*x*x-2*y*y)*sz, 0,
                tx, ty, tz, 1)

    def inspect_scene(self):
        nodes, scenes, skins = self.array("nodes"), self.array("scenes"), self.array("skins")
        matrices, children, parents = [], [], [0] * len(nodes)
        for ni, node in enumerate(nodes):
            context = f"nodes[{ni}]"
            if not isinstance(node, dict):
                self.issue(f"{context}: expected object")
                node = {}
            matrices.append(self.node_matrix(node, context))
            child_list = node.get("children", [])
            if not isinstance(child_list, list):
                self.issue(f"{context}.children: expected array")
                child_list = []
            valid = []
            for child in child_list:
                ci = self.ref(child, nodes, context + ".children")
                if ci is not None:
                    parents[ci] += 1
                    valid.append(ci)
            if len(valid) != len(set(valid)):
                self.issue(f"{context}: duplicate children")
            children.append(valid)
            if "mesh" in node:
                self.ref(node["mesh"], self.mesh_stats, context + ".mesh")
            if "skin" in node:
                self.ref(node["skin"], skins, context + ".skin")
        if any(n > 1 for n in parents):
            self.issue("nodes: a node has multiple parents; glTF hierarchy must be a forest")
        colors = [0] * len(nodes)

        def visit(index):
            if colors[index] == 1:
                self.issue("nodes: cycle in child hierarchy")
                return
            if colors[index] == 2:
                return
            colors[index] = 1
            for child in children[index]:
                visit(child)
            colors[index] = 2

        for ni in range(len(nodes)):
            visit(ni)
        roots = []
        for si, scene in enumerate(scenes):
            if not isinstance(scene, dict) or not isinstance(scene.get("nodes", []), list):
                self.issue(f"scenes[{si}]: invalid scene/nodes")
                continue
            for node in scene.get("nodes", []):
                self.ref(node, nodes, f"scenes[{si}].nodes")
        active_scene = self.doc.get("scene", 0 if scenes else None)
        if active_scene is not None:
            si = self.ref(active_scene, scenes, "scene")
            if si is not None and isinstance(scenes[si], dict):
                roots = scenes[si].get("nodes", [])
        else:
            roots = [ni for ni, count in enumerate(parents) if count == 0]
            self.issue("No scene declared; scene metrics use all hierarchy roots", warning=True)
        scene_boxes, scene_triangles, scene_vertices, scene_primitives = [], 0, 0, 0
        active_meshes, active_nodes = set(), set()

        def traverse(index, parent, ancestors):
            nonlocal scene_triangles, scene_vertices, scene_primitives
            if not is_int(index) or not 0 <= index < len(nodes) or index in ancestors:
                return
            node = nodes[index]
            if not isinstance(node, dict):
                return
            world = matrix_multiply(parent, matrices[index])
            active_nodes.add(index)
            mesh = node.get("mesh")
            if is_int(mesh) and 0 <= mesh < len(self.mesh_stats):
                active_meshes.add(mesh)
                instances = 1
                instancing = self.extensions(node, f"nodes[{index}]").get("EXT_mesh_gpu_instancing")
                if instancing is not None:
                    self.issue(f"nodes[{index}]: GPU instance transforms not applied to scene AABB", incomplete=True)
                    if isinstance(instancing, dict) and isinstance(instancing.get("attributes"), dict):
                        counts = []
                        for value in instancing["attributes"].values():
                            ai = self.ref(value, self.accessors, f"nodes[{index}].instancing")
                            if ai is not None and self.accessors[ai] is not None:
                                counts.append(self.accessors[ai]["count"])
                        if counts:
                            instances = counts[0]
                            if len(set(counts)) > 1:
                                self.issue(f"nodes[{index}]: GPU instance attribute counts differ")
                scene_triangles += self.mesh_stats[mesh]["triangles"] * instances
                scene_vertices += self.mesh_stats[mesh]["vertices"] * instances
                scene_primitives += len(self.mesh_stats[mesh]["primitives"]) * instances
                scene_boxes.append(transformed_bounds(self.mesh_bounds[mesh], world))
            for child in children[index]:
                traverse(child, world, ancestors | {index})

        if isinstance(roots, list):
            for root in roots:
                traverse(root, IDENTITY, set())
        self.report["scene"] = {"active_scene_index": active_scene, "active_nodes": len(active_nodes),
                                 "active_meshes": len(active_meshes), "triangles": scene_triangles,
                                 "vertices": scene_vertices, "render_primitive_instances": scene_primitives,
                                 "bounds": bounds_dict(merge_bounds(scene_boxes)),
                                 "bounds_note": "glTF coordinate units; static node transforms only; no animation/skin deformation or verified real-world scale"}
        self.report["node_count"] = len(nodes)

    def inspect_skins_animations(self):
        nodes, accessors = self.array("nodes"), self.accessors
        skins, animations = self.array("skins"), self.array("animations")
        skin_info, animation_info = [], []
        for si, skin in enumerate(skins):
            if not isinstance(skin, dict):
                self.issue(f"skins[{si}]: expected object")
                continue
            joints = skin.get("joints", [])
            if not isinstance(joints, list) or not joints:
                self.issue(f"skins[{si}]: nonempty joints array required")
                joints = []
            for joint in joints:
                self.ref(joint, nodes, f"skins[{si}].joints")
            if "skeleton" in skin:
                self.ref(skin["skeleton"], nodes, f"skins[{si}].skeleton")
            if "inverseBindMatrices" in skin:
                ai = self.ref(skin["inverseBindMatrices"], accessors, f"skins[{si}].inverseBindMatrices")
                if ai is not None and accessors[ai] is not None:
                    layout = accessors[ai]
                    if layout["type"] != "MAT4" or layout["component_type"] != 5126 or layout["count"] < len(joints):
                        self.issue(f"skins[{si}]: inverse bind accessor must be FLOAT MAT4 and cover all joints")
            skin_info.append({"name": skin.get("name"), "joints": len(joints)})
        for ai, animation in enumerate(animations):
            if not isinstance(animation, dict):
                self.issue(f"animations[{ai}]: expected object")
                continue
            samplers, channels = animation.get("samplers", []), animation.get("channels", [])
            if not isinstance(samplers, list) or not isinstance(channels, list):
                self.issue(f"animations[{ai}]: samplers/channels must be arrays")
                continue
            for si, sampler in enumerate(samplers):
                if not isinstance(sampler, dict):
                    self.issue(f"animations[{ai}].samplers[{si}]: expected object")
                    continue
                for key in ("input", "output"):
                    ref = self.ref(sampler.get(key), accessors, f"animations[{ai}].samplers[{si}].{key}")
                    if key == "input" and ref is not None and accessors[ref] is not None:
                        if accessors[ref]["type"] != "SCALAR" or accessors[ref]["component_type"] != 5126:
                            self.issue(f"animations[{ai}]: input must be FLOAT SCALAR")
            for ci, channel in enumerate(channels):
                if not isinstance(channel, dict):
                    self.issue(f"animations[{ai}].channels[{ci}]: expected object")
                    continue
                self.ref(channel.get("sampler"), samplers, f"animations[{ai}].channels[{ci}].sampler")
                target = channel.get("target", {})
                if not isinstance(target, dict):
                    self.issue(f"animations[{ai}].channels[{ci}].target: expected object")
                elif "node" in target:
                    self.ref(target["node"], nodes, f"animations[{ai}].channels[{ci}].target.node")
            animation_info.append({"name": animation.get("name"), "samplers": len(samplers), "channels": len(channels)})
        self.report["skins"] = {"count": len(skins), "items": skin_info}
        self.report["animations"] = {"count": len(animations), "items": animation_info}

    def inspect_images_materials(self):
        images, textures, materials = self.array("images"), self.array("textures"), self.array("materials")
        image_info = []
        for ii, image in enumerate(images):
            entry = {"index": ii, "embedded": False, "width": None, "height": None}
            if not isinstance(image, dict):
                self.issue(f"images[{ii}]: expected object")
                image_info.append(entry)
                continue
            entry.update({"name": image.get("name"), "mime_type": image.get("mimeType")})
            payload = None
            if "bufferView" in image and "uri" in image:
                self.issue(f"images[{ii}]: bufferView and uri cannot coexist")
            if "bufferView" in image:
                entry["embedded"] = True
                vi = self.ref(image["bufferView"], self.views, f"images[{ii}].bufferView")
                view = self.views[vi] if vi is not None else None
                if view is not None and view["data"] is not None:
                    payload = view["data"][view["offset"]:view["offset"] + view["length"]]
                if not image.get("mimeType"):
                    self.issue(f"images[{ii}]: bufferView image requires mimeType")
            elif "uri" in image:
                entry["embedded"] = isinstance(image["uri"], str) and image["uri"].startswith("data:")
                payload = self.uri_bytes(image["uri"], f"images[{ii}]")
            else:
                self.issue(f"images[{ii}]: bufferView or uri required")
            if payload is not None:
                entry["bytes"] = len(payload)
                try:
                    signature = bytes(payload[:12])
                    if signature == b"\xabKTX 20\xbb\r\n\x1a\n" and len(payload) >= 48:
                        width, height = struct.unpack_from("<II", payload, 20)
                        entry.update({"width": width, "height": height, "format": "KTX2"})
                    elif Image is not None:
                        with warnings.catch_warnings():
                            warnings.simplefilter("error", Image.DecompressionBombWarning)
                            with Image.open(io.BytesIO(payload)) as decoded:
                                entry.update({"width": decoded.width, "height": decoded.height, "format": decoded.format})
                    else:
                        self.issue(f"images[{ii}]: Pillow unavailable; image dimensions not read", incomplete=True)
                except Exception as exc:
                    self.issue(f"images[{ii}]: cannot read image header: {type(exc).__name__}: {exc}")
                if entry["width"] is not None and (entry["width"] <= 0 or entry["height"] <= 0):
                    self.issue(f"images[{ii}]: non-positive image dimensions")
            image_info.append(entry)
        for ti, texture in enumerate(textures):
            if not isinstance(texture, dict):
                self.issue(f"textures[{ti}]: expected object")
                continue
            if "source" in texture:
                self.ref(texture["source"], images, f"textures[{ti}].source")
            for name in ("KHR_texture_basisu", "EXT_texture_webp", "EXT_texture_avif"):
                source = self.extensions(texture, f"textures[{ti}]").get(name)
                if isinstance(source, dict):
                    self.ref(source.get("source"), images, f"textures[{ti}].{name}.source")
            if "sampler" in texture:
                self.ref(texture["sampler"], self.array("samplers"), f"textures[{ti}].sampler")

        def texture_refs(obj, context):
            if isinstance(obj, dict):
                for key, value in obj.items():
                    if key.lower().endswith("texture") and isinstance(value, dict) and "index" in value:
                        self.ref(value["index"], textures, context + "." + key + ".index")
                    texture_refs(value, context + "." + key)
            elif isinstance(obj, list):
                for value in obj:
                    texture_refs(value, context)

        for mi, material in enumerate(materials):
            if not isinstance(material, dict):
                self.issue(f"materials[{mi}]: expected object")
            else:
                texture_refs(material, f"materials[{mi}]")
        self.report["materials"] = {"count": len(materials), "used_count": len(self.used_materials),
                                     "unused_indices": sorted(set(range(len(materials))) - self.used_materials),
                                     "names": [m.get("name") if isinstance(m, dict) else None for m in materials]}
        self.report["textures"] = {"count": len(textures), "image_count": len(images), "images": image_info,
                                    "max_edge": max((max(i["width"], i["height"]) for i in image_info if i["width"] is not None), default=None),
                                    "verification": "Image headers/dimensions only; full pixel integrity/material appearance not assessed"}

    def run(self):
        try:
            if self.load_container():
                self.load_buffers()
                self.load_views()
                self.load_accessors()
                self.inspect_meshes()
                self.inspect_scene()
                self.inspect_skins_animations()
                self.inspect_images_materials()
                self.report["geometry"] = {
                    "mesh_count": len(self.mesh_stats),
                    "triangles": sum(m["triangles"] for m in self.mesh_stats),
                    "vertices": sum(m["vertices"] for m in self.mesh_stats),
                    "unique_position_accessor_vertices": sum(self.accessors[i]["count"] for i in self.used_position_accessors),
                    "primitive_count": sum(len(m["primitives"]) for m in self.mesh_stats),
                    "meshes": self.mesh_stats,
                    "count_note": "Stored mesh totals, including unused meshes; vertices sum primitive POSITION counts, not welded unique vertices. Scene totals include node instances."}
                if not self.mesh_stats:
                    self.issue("No meshes present", warning=True)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, struct.error, RecursionError) as exc:
            self.issue(f"Audit interrupted: {type(exc).__name__}: {exc}")
        self.report.update({"structural_status": "invalid" if self.errors else "incomplete" if self.incomplete else "no_errors_detected",
                            "errors": self.errors, "warnings": self.warnings, "incomplete_checks": self.incomplete})
        return self.report


def detect_blender():
    candidates = [shutil.which("blender"),
                  r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe",
                  r"C:\Program Files\Blender Foundation\Blender 4.2\blender.exe"]
    return next((str(Path(p)) for p in candidates if p and Path(p).is_file()), None)


def assess_budget(report, job):
    budget = dict(DEFAULT_BUDGETS.get(job.get("category"), {}))
    optimization = job.get("optimization") or {}
    if isinstance(optimization, dict):
        override = optimization.get("estimated_triangle_budget")
        if is_int(override) and override > 0:
            budget["triangles"] = override
    checks = []
    for name, actual in (("triangles", report.get("geometry", {}).get("triangles")),
                         ("materials", report.get("materials", {}).get("count")),
                         ("texture_max_edge", report.get("textures", {}).get("max_edge"))):
        limit = budget.get(name)
        status = "unknown" if actual is None or limit is None else "over" if actual > limit else "within"
        if status == "over" and name == "triangles" and actual <= limit * (1 + PROTOTYPE_TRIANGLE_WARNING_FRACTION):
            status = "warning"
        checks.append({"metric": name, "actual": actual, "limit": limit, "status": status,
                       "strict_limit_exceeded": actual > limit if actual is not None and limit is not None else None,
                       "over_by": max(0, actual - limit) if actual is not None and limit is not None else None})
    statuses = {c["status"] for c in checks}
    return {"status": "over" if "over" in statuses else "unknown" if "unknown" in statuses else "warning" if "warning" in statuses else "within",
            "checks": checks, "note": "Proposed prototype budgets only; triangle excess up to 5% remains explicitly over the strict limit but is a warning, not a batch failure. Meeting budgets does not establish game readiness."}


def validate_jobs(jobs_path):
    jobs_path = Path(jobs_path).resolve()
    manifest = json.loads(jobs_path.read_text(encoding="utf-8-sig"))
    jobs = manifest.get("jobs") if isinstance(manifest, dict) else manifest
    if not isinstance(jobs, list):
        raise ValueError("jobs.json must be an array or an object containing a jobs array")
    entries, cache = [], {}
    for index, job in enumerate(jobs):
        if not isinstance(job, dict):
            entries.append({"id": str(index), "status": "invalid_job", "errors": ["job must be an object"], "game_ready": "not_assessed"})
            continue
        entry = {"id": job.get("id", str(index)), "title": job.get("title", job.get("title_ru")),
                 "category": job.get("category"), "job_status": job.get("status"),
                 "local_file": job.get("local_file"), "game_ready": "not_assessed"}
        local_file = job.get("local_file")
        if not local_file:
            entry.update({"status": "not_downloaded", "reason": "local_file is empty; no model data inspected"})
        elif not isinstance(local_file, str):
            entry.update({"status": "invalid_job", "errors": ["local_file must be a string or null"]})
        else:
            path = (jobs_path.parent / local_file).resolve()
            if not path.is_relative_to(jobs_path.parent):
                entry.update({"status": "invalid_job", "errors": ["local_file escapes models folder; not read"]})
            elif not path.is_file():
                entry.update({"status": "missing_file", "reason": "local_file is set but the file is absent"})
            else:
                if path not in cache:
                    cache[path] = GLBAudit(path).run()
                audit = cache[path]
                entry.update({"status": "inspected", "audit": audit, "budget": assess_budget(audit, job)})
                if job.get("category") == "characters" and audit.get("skins", {}).get("count") == 0:
                    entry["character_note"] = "No glTF skin present: static mesh/T-pose only; rigging and deformation not validated."
        entries.append(entry)
    inspected = [e for e in entries if e["status"] == "inspected"]
    summary = {"jobs": len(entries), "inspected": len(inspected), "unique_files_inspected": len(cache),
               "pending_or_missing": sum(e["status"] in ("not_downloaded", "missing_file") for e in entries),
               "invalid_jobs": sum(e["status"] == "invalid_job" for e in entries),
               "structurally_invalid": sum(e["audit"]["structural_status"] == "invalid" for e in inspected),
               "structurally_incomplete": sum(e["audit"]["structural_status"] == "incomplete" for e in inspected),
               "over_budget": sum(e["budget"]["status"] == "over" for e in inspected),
               "budget_warnings": sum(e["budget"]["status"] == "warning" for e in inspected),
               "game_ready": "not_assessed"}
    return {"generated_utc": datetime.now(timezone.utc).isoformat(), "jobs_file": str(jobs_path),
            "scope": SCOPE, "blender_cli": {"available_path": detect_blender(), "audit_performed": False},
            "budgets": DEFAULT_BUDGETS, "summary": summary, "jobs": entries}


def text_report(report):
    summary = report["summary"]
    lines = ["STELLAR DRIFT - LOCAL GLB STRUCTURAL AUDIT", report["generated_utc"],
             "Game readiness: NOT ASSESSED. This is not a full Khronos glTF conformance check.",
             f"Inspected {summary['inspected']}/{summary['jobs']} jobs; unique files {summary['unique_files_inspected']}; pending/missing {summary['pending_or_missing']}.",
             f"Structurally invalid: {summary['structurally_invalid']}; incomplete: {summary['structurally_incomplete']}; substantial budget excess: {summary['over_budget']}; prototype budget warnings: {summary['budget_warnings']}.",
             "Blender CLI available: " + (report["blender_cli"]["available_path"] or "not found") + "; Blender geometric audit NOT RUN.", ""]
    for entry in report["jobs"]:
        lines.append(f"[{entry['id']}] {entry.get('title') or ''} - {entry['status']}")
        if entry["status"] != "inspected":
            lines.append("  " + entry.get("reason", "; ".join(entry.get("errors", []))))
            lines.append("")
            continue
        audit = entry["audit"]
        geometry, textures, materials = audit.get("geometry", {}), audit.get("textures", {}), audit.get("materials", {})
        lines.extend([f"  File: {entry['local_file']} ({audit.get('file_bytes', '?')} bytes)",
                      f"  Structure: {audit['structural_status']}; budget: {entry['budget']['status']}",
                      f"  Stored mesh: {geometry.get('triangles', '?')} triangles; {geometry.get('vertices', '?')} primitive vertices; {geometry.get('mesh_count', '?')} meshes; {geometry.get('primitive_count', '?')} primitives.",
                      f"  Materials: {materials.get('count', '?')} total / {materials.get('used_count', '?')} used. Images: {textures.get('image_count', '?')}, max edge: {textures.get('max_edge', '?')}.",
                      f"  Skins: {audit.get('skins', {}).get('count', '?')}; animations: {audit.get('animations', {}).get('count', '?')}.",
                      "  Scene AABB: " + json.dumps(audit.get("scene", {}).get("bounds"), ensure_ascii=False)])
        for image in textures.get("images", []):
            lines.append(f"  Image {image['index']}: {image.get('width')} x {image.get('height')} ({image.get('format', image.get('mime_type'))}), embedded={image['embedded']}")
        for check in entry["budget"]["checks"]:
            lines.append(f"  Budget {check['metric']}: {check['actual']} / {check['limit']} - {check['status']}")
        if "character_note" in entry:
            lines.append("  NOTE: " + entry["character_note"])
        for field, prefix in (("errors", "ERROR"), ("warnings", "WARNING"), ("incomplete_checks", "NOT CHECKED")):
            for issue in audit.get(field, []):
                lines.append(f"  {prefix}: {issue}")
        lines.append("")
    lines.append("ACTUAL SCOPE")
    lines.extend("  Checked: " + s for s in report["scope"]["performed"])
    lines.extend("  NOT checked: " + s for s in report["scope"]["not_performed"])
    lines.append("Triangle totals count submitted topology, including degenerate triangles in strips/fans. No welded-vertex, deformation or runtime-performance conclusion is implied.")
    return "\n".join(lines) + "\n"


def self_test():
    """Small behavioural fixtures, held in a temporary directory only."""
    def make_glb(document, payload=b""):
        js = json.dumps(document, separators=(",", ":")).encode()
        js += b" " * (-len(js) % 4)
        chunks = struct.pack("<I4s", len(js), b"JSON") + js
        if payload:
            payload += b"\0" * (-len(payload) % 4)
            chunks += struct.pack("<I4s", len(payload), b"BIN\0") + payload
        return struct.pack("<4sII", b"glTF", 2, 12 + len(chunks)) + chunks

    payload = struct.pack("<9f3H", 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 2)
    document = {"asset": {"version": "2.0"}, "buffers": [{"byteLength": len(payload)}],
                "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36},
                                {"buffer": 0, "byteOffset": 36, "byteLength": 6}],
                "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
                              {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
                "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
                "nodes": [{"mesh": 0, "translation": [2, 3, 4], "scale": [2, 2, 2]}],
                "scenes": [{"nodes": [0]}], "scene": 0}
    with tempfile.TemporaryDirectory(prefix="stellar-glb-validation-") as folder:
        path = Path(folder) / "test.glb"
        path.write_bytes(make_glb(document, payload))
        result = GLBAudit(path).run()
        assert result["structural_status"] == "no_errors_detected", result
        assert result["geometry"]["triangles"] == 1
        assert result["scene"]["bounds"] == {"min": [2.0, 3.0, 4.0], "max": [4.0, 5.0, 4.0], "size": [2.0, 2.0, 0.0]}
        bad = bytearray(make_glb(document, payload))
        struct.pack_into("<I", bad, 8, len(bad) + 4)
        path.write_bytes(bad)
        assert GLBAudit(path).run()["structural_status"] == "invalid"
        invalid_indices = payload[:-6] + struct.pack("<3H", 0, 1, 3)
        path.write_bytes(make_glb(document, invalid_indices))
        assert any("exceeds vertex count" in e for e in GLBAudit(path).run()["errors"])
        broken = json.loads(json.dumps(document))
        broken["accessors"][0]["byteOffset"] = 4
        path.write_bytes(make_glb(broken, payload))
        assert any("extends beyond bufferView" in e for e in GLBAudit(path).run()["errors"])
        sparse = json.loads(json.dumps(document))
        sparse_data = struct.pack("<B", 2) + b"\0" * 3 + struct.pack("<3f", 0, 1, 0)
        sparse["buffers"][0]["byteLength"] = len(sparse_data)
        sparse["bufferViews"] = [{"buffer": 0, "byteLength": 1}, {"buffer": 0, "byteOffset": 4, "byteLength": 12}]
        sparse["accessors"] = [{"componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [0, 1, 0],
                                "sparse": {"count": 1, "indices": {"bufferView": 0, "componentType": 5121}, "values": {"bufferView": 1}}}]
        sparse["meshes"][0]["primitives"][0].pop("indices")
        path.write_bytes(make_glb(sparse, sparse_data))
        result = GLBAudit(path).run()
        assert result["structural_status"] == "no_errors_detected", result
        assert result["geometry"]["meshes"][0]["bounds_local"]["max"] == [0.0, 1.0, 0.0]
        layout = GLBAudit.element_layout("MAT3", 5121)
        assert layout["element_bytes"] == 12 and layout["component_offsets"] == [0, 1, 2, 4, 5, 6, 8, 9, 10]
        path.write_bytes(b"not-a-glb")
        assert GLBAudit(path).run()["structural_status"] == "invalid"
        malformed = json.loads(json.dumps(document))
        malformed["nodes"][0]["extensions"] = None
        path.write_bytes(make_glb(malformed, payload))
        assert any("extensions: expected an object" in e for e in GLBAudit(path).run()["errors"])
        normalized = json.loads(json.dumps(document))
        normalized["accessors"][1]["normalized"] = True
        path.write_bytes(make_glb(normalized, payload))
        assert any("index accessor cannot be normalized" in e for e in GLBAudit(path).run()["errors"])
        budget = assess_budget({"geometry": {"triangles": 2039}, "materials": {"count": 1},
                                "textures": {"max_edge": 1024}}, {"category": "tools"})
        assert budget["status"] == "warning" and budget["checks"][0]["actual"] == 2039 and budget["checks"][0]["strict_limit_exceeded"]
    print("Self-test: 10 behavioural checks passed (container, indices, view range, transforms, sparse, padded matrix, truncation, malformed extensions, normalized indices, prototype budget warning).")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=Path, default=Path(__file__).with_name("jobs.json"))
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--output-text", type=Path)
    parser.add_argument("--self-test", action="store_true", help="Run synthetic read-only validation fixtures; do not write reports")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    try:
        report = validate_jobs(args.jobs)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Cannot read jobs manifest: {exc}", file=sys.stderr)
        return 1
    output_json = args.output_json or args.jobs.resolve().with_name("validation.json")
    output_text = args.output_text or args.jobs.resolve().with_name("validation.txt")
    protected = {args.jobs.resolve(), Path(__file__).resolve()}
    protected.update(Path(entry["audit"]["path"]).resolve() for entry in report["jobs"] if "audit" in entry)
    if output_json.resolve() == output_text.resolve() or output_json.resolve() in protected or output_text.resolve() in protected:
        print("Report paths must differ and cannot overwrite the manifest, validator or inspected models.", file=sys.stderr)
        return 1
    output_json.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    output_text.write_text(text_report(report), encoding="utf-8")
    print(json.dumps({"json": str(output_json.resolve()), "text": str(output_text.resolve()), "summary": report["summary"]}, ensure_ascii=False))
    summary = report["summary"]
    if summary["structurally_invalid"] or summary["invalid_jobs"] or summary["over_budget"]:
        return 1
    if not summary["inspected"] or summary["pending_or_missing"] or summary["structurally_incomplete"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
