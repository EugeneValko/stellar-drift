"""Compositor post-processing for the beauty renders (Blender 5.x node-group compositor): bloom + lens vignette."""
import bpy


def _menu(sock, *names):
    for n in names:
        try:
            sock.default_value = n
            return True
        except (TypeError, ValueError):
            continue
    return False


def setup(bloom=0.35, threshold=1.6, size=0.55, vignette=0.22):
    """Render Layers -> bloom glare -> soft vignette -> output. Returns True when the graph was created."""
    sc = bpy.context.scene
    try:
        ng = bpy.data.node_groups.new("TernPost", "CompositorNodeTree")
        ng.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        rl = ng.nodes.new("CompositorNodeRLayers")
        out = ng.nodes.new("NodeGroupOutput")
        img = rl.outputs["Image"]
        if bloom > 0:
            g = ng.nodes.new("CompositorNodeGlare")
            _menu(g.inputs["Type"], "Bloom", "BLOOM", "Fog Glow", "FOG_GLOW")
            _menu(g.inputs["Quality"], "High", "HIGH")
            g.inputs["Threshold"].default_value = threshold
            g.inputs["Strength"].default_value = bloom
            g.inputs["Size"].default_value = size
            try:
                g.inputs["Smoothness"].default_value = 0.4
            except KeyError:
                pass
            ng.links.new(img, g.inputs["Image"])
            img = g.outputs["Image"]
        if vignette > 0:
            el = ng.nodes.new("CompositorNodeEllipseMask")
            for k, v in (("Size", (1.18, 1.05)), ("Position", (0.5, 0.5))):
                try:
                    el.inputs[k].default_value = v
                except (KeyError, TypeError, ValueError):
                    pass
            bl = ng.nodes.new("CompositorNodeBlur")
            try:
                bl.inputs["Size"].default_value = (260.0, 260.0)
            except (KeyError, TypeError, ValueError):
                pass
            ng.links.new(el.outputs[0], bl.inputs["Image"])
            mx = ng.nodes.new("ShaderNodeMix")
            mx.data_type = "RGBA"
            mx.blend_type = "MULTIPLY"
            sock = {s.identifier: s for s in mx.inputs}
            sock["Factor_Float"].default_value = vignette
            ng.links.new(img, sock["A_Color"])
            ng.links.new(bl.outputs[0], sock["B_Color"])
            img = next(s for s in mx.outputs if s.identifier == "Result_Color")
        ng.links.new(img, out.inputs[0])
        sc.compositing_node_group = ng
        try:
            sc.render.use_compositing = True
        except AttributeError:
            pass
        return True
    except Exception as e:  # noqa: BLE001
        print("POST SETUP FAILED:", e)
        return False
