"""NVIDIA SimReady asset (OpenUSD + OmniPBR) -> GLB for three.js and Godot.

usage: simready_to_glb.py <asset_name> <out.glb> [--cache DIR] [--tex 512|256|full]

Downloads only what the asset needs from huggingface.co/datasets/nvidia/simready-assets (USD layers and the 512 px
texture previews instead of the 8K originals), flattens instanced meshes, converts Z-up to glTF's Y-up in metres,
writes one primitive per material subset, and maps OmniPBR (albedo / normal / ORM) to glTF metallic-roughness PBR.
Licence of the source assets: CC-BY-4.0 (NVIDIA). Prints a JSON summary on success.
"""
import argparse, io, json, os, sys, urllib.parse, urllib.request

import numpy as np
from PIL import Image
from pxr import Gf, Usd, UsdGeom, UsdShade
import pygltflib as G

REPO = "https://huggingface.co/datasets/nvidia/simready-assets/resolve/main/"
API = "https://huggingface.co/api/datasets/nvidia/simready-assets/tree/main/"


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "Sirpi-SimReady/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest + ".part", "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    os.replace(dest + ".part", dest)
    return dest


def download_asset(name, cache):
    """USD layers only (no textures); textures are fetched per material later at the chosen size."""
    root = os.path.join(cache, name)
    listing = json.loads(urllib.request.urlopen(API + urllib.parse.quote(name) + "?recursive=true", timeout=60).read())
    usd_files = [x["path"] for x in listing if x.get("type") == "file"
                 and x["path"].split("/")[1:2] == ["simready_usd"] and x["path"].endswith((".usd", ".usda", ".usdc"))
                 and "/.thumbs/" not in x["path"]]
    for p in usd_files:
        fetch(REPO + urllib.parse.quote(p), os.path.join(cache, p))
    roots = [p for p in usd_files if p.count("/") == 2 and p.split("/")[-1].startswith("sm_")]
    if not roots:
        raise SystemExit(f"no root USD found for {name}")
    files = {x["path"] for x in listing if x.get("type") == "file"}
    return os.path.join(cache, roots[0]), files


def texture(asset_dir_rel, tex_path, size, files, cache):
    """Resolves an OmniPBR texture path to a local PNG at the requested size (thumbnail when available)."""
    # Paths are authored relative to payloads/*.usda ("../Textures/x.png"); textures live in <asset>/simready_usd/.
    rel = tex_path.replace("\\", "/")
    while rel.startswith(("./", "../")):
        rel = rel.split("/", 1)[1]
    base = f"{asset_dir_rel}/{rel}"
    folder, fname = base.rsplit("/", 1)
    if size != "full":
        thumb = f"{folder}/.thumbs/{size}x{size}/{fname}.png"
        if thumb in files:
            return fetch(REPO + urllib.parse.quote(thumb), os.path.join(cache, thumb))
    if base in files:
        return fetch(REPO + urllib.parse.quote(base), os.path.join(cache, base))
    return None


def preview_tiling(material):
    """UV tiling from a UsdPreviewSurface network (UsdTransform2d 'scale'), used when OmniPBR has none."""
    for p in Usd.PrimRange(material.GetPrim()):
        if p.IsA(UsdShade.Shader):
            sh = UsdShade.Shader(p)
            if (sh.GetIdAttr().Get() or "") == "UsdTransform2d" or p.GetName().lower() == "mapping":
                sc = sh.GetInput("scale")
                if sc and sc.Get() is not None:
                    return tuple(float(x) for x in sc.Get())
    return None


def shader_inputs(material):
    """OmniPBR inputs if present, else UsdPreviewSurface; returns a flat dict."""
    best = {}
    for out in material.GetSurfaceOutputs():
        for src in out.GetConnectedSources()[0]:
            sh = UsdShade.Shader(src.source.GetPrim())
            vals = {i.GetBaseName(): i.Get() for i in sh.GetInputs() if i.Get() is not None}
            if sh.GetSourceAssetSubIdentifier("mdl") or "diffuse_texture" in vals:
                return {"kind": "omnipbr", **vals}
            best = {"kind": "preview", **vals}
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("asset")
    ap.add_argument("out")
    ap.add_argument("--cache", default=os.path.expanduser("~/Library/Caches/SimReady"))
    ap.add_argument("--tex", default="512", choices=["256", "512", "full"])
    a = ap.parse_args()

    root_usd, files = download_asset(a.asset, a.cache)
    stage = Usd.Stage.Open(root_usd)
    up = UsdGeom.GetStageUpAxis(stage)
    mpu = UsdGeom.GetStageMetersPerUnit(stage) or 1.0
    # Z-up -> Y-up: rotate -90 degrees about X; then scale to metres.
    fix = Gf.Matrix4d(1.0).SetRotate(Gf.Rotation(Gf.Vec3d(1, 0, 0), -90)) if up == "Z" else Gf.Matrix4d(1.0)
    fix = fix * Gf.Matrix4d(1.0).SetScale(mpu)
    cache_xf = UsdGeom.XformCache(Usd.TimeCode.Default())
    root_rel = os.path.relpath(os.path.dirname(root_usd), a.cache).replace(os.sep, "/")

    gltf = G.GLTF2(asset=G.Asset(generator="Sirpi SimReady importer"), scene=0, scenes=[G.Scene(nodes=[])])
    blob = bytearray()

    def add_view(data, target=None):
        while len(blob) % 4:
            blob.append(0)
        off = len(blob); blob.extend(data)
        gltf.bufferViews.append(G.BufferView(buffer=0, byteOffset=off, byteLength=len(data), target=target))
        return len(gltf.bufferViews) - 1

    def add_accessor(arr, ctype, typ, target=None, minmax=False):
        view = add_view(arr.tobytes(), target)
        acc = G.Accessor(bufferView=view, componentType=ctype, count=len(arr), type=typ)
        if minmax:
            acc.min = arr.min(axis=0).tolist(); acc.max = arr.max(axis=0).tolist()
        gltf.accessors.append(acc)
        return len(gltf.accessors) - 1

    images, materials = {}, {}

    def image_index(path, kind, orm_mix=None):
        key = (path, orm_mix)
        if key in images:
            return images[key]
        im = Image.open(path)
        im = im.convert("RGB")
        if orm_mix:
            # Bake OmniPBR's texture-vs-constant influence into the channels glTF reads (G roughness, B metallic).
            r_inf, r_const, m_inf, m_const = orm_mix
            a = np.asarray(im, dtype=np.float32)
            a[..., 1] = r_inf * a[..., 1] + (1 - r_inf) * r_const * 255
            a[..., 2] = m_inf * a[..., 2] + (1 - m_inf) * m_const * 255
            im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
        buf = io.BytesIO()
        if kind == "alb":
            im.save(buf, "JPEG", quality=90); mime = "image/jpeg"
        else:
            im.save(buf, "PNG", optimize=True); mime = "image/png"
        view = add_view(buf.getvalue())
        gltf.images.append(G.Image(bufferView=view, mimeType=mime))
        gltf.textures.append(G.Texture(source=len(gltf.images) - 1, sampler=0))
        images[key] = len(gltf.textures) - 1
        return images[key]

    gltf.samplers.append(G.Sampler(magFilter=9729, minFilter=9987, wrapS=10497, wrapT=10497))
    textures_used = 0

    def material_index(mat):
        nonlocal textures_used
        key = mat.GetPath().pathString if mat else "__default"
        if key in materials:
            return materials[key]
        name = mat.GetPrim().GetName() if mat else "default"
        pbr = G.PbrMetallicRoughness(baseColorFactor=[0.8, 0.8, 0.8, 1], metallicFactor=0.0, roughnessFactor=0.6)
        m = G.Material(name=name, pbrMetallicRoughness=pbr, doubleSided=False)
        ins = shader_inputs(mat) if mat else {}
        scale = [float(x) for x in (ins.get("texture_scale", (1, 1)) or (1, 1))]
        if scale == [1.0, 1.0] and mat:
            scale = list(preview_tiling(mat) or (1.0, 1.0))
        ext = {"KHR_texture_transform": {"scale": [float(scale[0]), float(scale[1])]}} if scale != [1, 1] else None

        def tex_info(cls, path, kind, orm_mix=None, **kw):
            nonlocal textures_used
            local = texture(root_rel, path.path if hasattr(path, "path") else str(path), a.tex, files, a.cache)
            if not local:
                return None
            textures_used += 1
            info = cls(index=image_index(local, kind, orm_mix), **kw)
            if ext:
                info.extensions = ext
            return info

        if ins.get("kind") == "omnipbr":
            if ins.get("diffuse_texture"):
                pbr.baseColorTexture = tex_info(G.TextureInfo, ins["diffuse_texture"], "alb")
                pbr.baseColorFactor = [1, 1, 1, 1]
            elif ins.get("diffuse_color_constant") is not None:
                c = ins["diffuse_color_constant"]; pbr.baseColorFactor = [c[0], c[1], c[2], 1]
            if ins.get("normalmap_texture"):
                m.normalTexture = tex_info(G.NormalMaterialTexture, ins["normalmap_texture"], "nor")
                if m.normalTexture is not None:
                    m.normalTexture.scale = float(ins.get("bump_factor", 1.0) or 1.0)
            if ins.get("ORM_texture") and ins.get("enable_ORM_texture", True):
                mix = (float(ins.get("reflection_roughness_texture_influence", 1.0)),
                       float(ins.get("reflection_roughness_constant", 0.5)),
                       float(ins.get("metallic_texture_influence", 1.0)),
                       float(ins.get("metallic_constant", 0.0)))
                t = tex_info(G.TextureInfo, ins["ORM_texture"], "orm", orm_mix=None if mix[0] == 1 and mix[2] == 1 else mix)
                if t:
                    pbr.metallicRoughnessTexture = t
                    pbr.metallicFactor = 1.0; pbr.roughnessFactor = 1.0
                    m.occlusionTexture = G.OcclusionTextureInfo(index=t.index, extensions=t.extensions)
            else:
                pbr.metallicFactor = float(ins.get("metallic_constant", 0.0) or 0.0)
                pbr.roughnessFactor = float(ins.get("reflection_roughness_constant", 0.5) or 0.5)
            op = float(ins.get("opacity_constant", 1.0) or 1.0)
            if op < 0.999:
                pbr.baseColorFactor[3] = op; m.alphaMode = "BLEND"
        elif ins:
            c = ins.get("diffuseColor")
            if c is not None:
                pbr.baseColorFactor = [c[0], c[1], c[2], float(ins.get("opacity", 1.0))]
            pbr.metallicFactor = float(ins.get("metallic", 0.0)); pbr.roughnessFactor = float(ins.get("roughness", 0.5))
        gltf.materials.append(m)
        materials[key] = len(gltf.materials) - 1
        return materials[key]

    meshes, tris_total = 0, 0
    for prim in Usd.PrimRange.Stage(stage, Usd.TraverseInstanceProxies()):
        if not prim.IsA(UsdGeom.Mesh) or not UsdGeom.Imageable(prim).ComputeVisibility() != UsdGeom.Tokens.invisible:
            continue
        if UsdGeom.Imageable(prim).GetPurposeAttr().Get() in ("guide", "proxy"):
            continue
        mesh = UsdGeom.Mesh(prim)
        pts = np.array(mesh.GetPointsAttr().Get() or [], dtype=np.float64)
        counts = np.array(mesh.GetFaceVertexCountsAttr().Get() or [], dtype=np.int64)
        idx = np.array(mesh.GetFaceVertexIndicesAttr().Get() or [], dtype=np.int64)
        if len(pts) == 0 or len(counts) == 0:
            continue
        xf = cache_xf.GetLocalToWorldTransform(prim) * fix
        M = np.array(xf, dtype=np.float64)  # row-vector convention
        pw = np.c_[pts, np.ones(len(pts))] @ M
        pw = pw[:, :3]
        nmat = np.linalg.inv(M[:3, :3]).T

        # Per-corner UVs and normals (handles vertex, faceVarying and indexed primvars).
        corner = np.arange(len(idx))

        def corner_values(pv, n_comp):
            if not pv or not pv.HasValue():
                return None
            vals = np.array(pv.ComputeFlattened(), dtype=np.float64).reshape(-1, n_comp)
            interp = pv.GetInterpolation()
            if interp == UsdGeom.Tokens.faceVarying and len(vals) == len(idx):
                return vals
            if interp in (UsdGeom.Tokens.vertex, UsdGeom.Tokens.varying) and len(vals) == len(pts):
                return vals[idx]
            if interp == UsdGeom.Tokens.uniform and len(vals) == len(counts):
                return np.repeat(vals, counts, axis=0)
            return None

        api = UsdGeom.PrimvarsAPI(prim)
        uv = corner_values(api.GetPrimvar("st"), 2)
        nrm_attr = mesh.GetNormalsAttr()
        nrm = None
        if nrm_attr.HasValue():
            nv = np.array(nrm_attr.Get(), dtype=np.float64).reshape(-1, 3)
            it = mesh.GetNormalsInterpolation()
            nrm = nv if (it == UsdGeom.Tokens.faceVarying and len(nv) == len(idx)) else (nv[idx] if len(nv) == len(pts) else None)
        # Fan-triangulate every face into corner triples.
        starts = np.r_[0, np.cumsum(counts)[:-1]]
        tri_corners, tri_face = [], []
        for k in range(3, int(counts.max()) + 1):
            faces = np.nonzero(counts >= k)[0]
            s = starts[faces]
            tri_corners.append(np.c_[s, s + k - 2, s + k - 1]); tri_face.append(faces)
        tri_corners = np.vstack(tri_corners); tri_face = np.concatenate(tri_face)
        if mesh.GetOrientationAttr().Get() == UsdGeom.Tokens.leftHanded:
            tri_corners = tri_corners[:, [0, 2, 1]]
        # Material per face from GeomSubsets, else the mesh binding.
        face_mat = np.full(len(counts), -1, dtype=np.int64)
        default_mat = material_index(UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()[0])
        for s in UsdGeom.Subset.GetGeomSubsets(mesh, "face"):
            mat = UsdShade.MaterialBindingAPI(s.GetPrim()).ComputeBoundMaterial()[0]
            fi = np.array(s.GetIndicesAttr().Get() or [], dtype=np.int64)
            if len(fi):
                face_mat[fi] = material_index(mat)
        face_mat[face_mat < 0] = default_mat

        prims = []
        for mi in np.unique(face_mat[tri_face]):
            tc = tri_corners[face_mat[tri_face] == mi].reshape(-1)
            P = pw[idx[tc]].astype(np.float32)
            cols = [P]
            if nrm is not None:
                Nn = (nrm[tc] @ nmat.T); Nn /= np.linalg.norm(Nn, axis=1, keepdims=True) + 1e-12
                cols.append(Nn.astype(np.float32))
            else:
                a_, b_, c_ = P[0::3], P[1::3], P[2::3]
                fn = np.cross(b_ - a_, c_ - a_); fn /= np.linalg.norm(fn, axis=1, keepdims=True) + 1e-12
                cols.append(np.repeat(fn, 3, axis=0).astype(np.float32))
            if uv is not None:
                U = uv[tc].astype(np.float32).copy(); U[:, 1] = 1.0 - U[:, 1]
                cols.append(U)
            # Weld identical corners to shrink the file.
            packed = np.hstack(cols)
            uniq, inv = np.unique(packed.round(6), axis=0, return_inverse=True)
            uniq = uniq.astype(np.float32)
            attrs = G.Attributes(POSITION=add_accessor(np.ascontiguousarray(uniq[:, 0:3]), G.FLOAT, G.VEC3, G.ARRAY_BUFFER, True),
                                 NORMAL=add_accessor(np.ascontiguousarray(uniq[:, 3:6]), G.FLOAT, G.VEC3, G.ARRAY_BUFFER))
            if uv is not None:
                attrs.TEXCOORD_0 = add_accessor(np.ascontiguousarray(uniq[:, 6:8]), G.FLOAT, G.VEC2, G.ARRAY_BUFFER)
            ind = inv.reshape(-1).astype(np.uint32)
            prims.append(G.Primitive(attributes=attrs, indices=add_accessor(ind, G.UNSIGNED_INT, G.SCALAR, G.ELEMENT_ARRAY_BUFFER),
                                     material=int(mi)))
            tris_total += len(ind) // 3
        gltf.meshes.append(G.Mesh(name=prim.GetName(), primitives=prims))
        gltf.nodes.append(G.Node(name=prim.GetParent().GetName() or prim.GetName(), mesh=len(gltf.meshes) - 1))
        gltf.scenes[0].nodes.append(len(gltf.nodes) - 1)
        meshes += 1

    if meshes == 0:
        raise SystemExit("no meshes found")
    if any(m.normalTexture and m.normalTexture.extensions or m.pbrMetallicRoughness.baseColorTexture and m.pbrMetallicRoughness.baseColorTexture.extensions
           for m in gltf.materials):
        gltf.extensionsUsed = ["KHR_texture_transform"]
    gltf.buffers.append(G.Buffer(byteLength=len(blob)))
    gltf.set_binary_blob(bytes(blob))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    gltf.save_binary(a.out)
    print(json.dumps({"asset": a.asset, "out": a.out, "meshes": meshes, "triangles": tris_total, "materials": len(gltf.materials),
                      "textures": len(gltf.textures), "bytes": os.path.getsize(a.out), "license": "CC-BY-4.0 (NVIDIA SimReady)"}))


if __name__ == "__main__":
    main()
