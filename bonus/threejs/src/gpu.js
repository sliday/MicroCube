// GPU upload layer for the MicroCube three.js port.
//
// Two textures back the GLSL traversal:
//   uVol  a Data3DTexture over world.vox            (R8UI, N x N x N, x fastest)
//   uPyr  a DataTexture holding the whole occupancy pyramid packed into
//         one PYR_W-wide R8UI image, level L living at layout.offsets[L]
//
// Indexing conventions (must match world.js, trace.js and the GLSL):
//   volume  linear = (z * N + y) * N + x
//   level L local  = (z * n + y) * n + x   with n = N >> L
//   level L global = offsets[L] + local
//
// Everything here is integer-format only. Never let a filter go Linear and never
// tag these textures with a colour space: three.js must not touch the bytes.

import * as THREE from 'three';

export const PYR_W = 2048;

let warnedRawGL = false;

/**
 * Per-level offsets into the packed pyramid image, plus its dimensions.
 * offsets[0] is 0 and unused: level 0 IS the volume texture.
 *
 * The running sum agrees with the closed form (N^3 - s^3) / 7, s = N >> (L-1),
 * but the loop is written out because exactness matters more than cleverness.
 */
export function pyramidLayout(N) {
  const LMAX = Math.log2(N) | 0;
  const offsets = new Int32Array(LMAX + 1);
  let acc = 0;
  for (let L = 1; L <= LMAX; L++) {
    offsets[L] = acc;
    const n = N >> L;
    acc += n * n * n;
  }
  const total = acc;
  const height = Math.max(1, Math.ceil(total / PYR_W));
  return { offsets, total, width: PYR_W, height };
}

/**
 * The #define prelude the shader assembler pastes above common.glsl.
 * Pure string function, no side effects, safe to call before any GL context exists.
 */
export function shaderDefines(world, layout) {
  const N = world.N;
  const LMAX = world.LMAX;
  const palLen = world.pal && world.pal.length ? (world.pal.length / 3) | 0 : 43;
  const offs = [];
  for (let L = 0; L <= LMAX; L++) offs.push(layout.offsets[L] | 0);
  return [
    '#define N ' + N,
    '#define NF ' + N.toFixed(1),
    '#define LMAX ' + LMAX,
    '#define PYR_W ' + layout.width,
    '#define PAL_LEN ' + palLen,
    'const int PYR_OFF[LMAX + 1] = int[](' + offs.join(', ') + ');',
    ''
  ].join('\n');
}

/**
 * Refuse an N this context cannot hold.
 *
 * OpenGL ES 3.0 guarantees only MAX_TEXTURE_SIZE >= 2048 and MAX_3D_TEXTURE_SIZE >= 256.
 * N = 512 asks for a 512^3 volume and a 2048 x 9363 packed pyramid; on a device that
 * caps out below either, the allocation is rejected with INVALID_VALUE, the texture
 * stays incomplete, every pyrAt() reads 0 and the world traces as empty sky -- a black
 * screen with no error that names the cause. Throw something legible instead; main.js
 * catches it and prints it on the boot splash.
 */
function checkTextureLimits(renderer, N, layout) {
  let gl = null;
  try {
    gl = renderer.getContext();
  } catch (err) {
    return;                                   // no context to interrogate: let three.js decide
  }
  if (!gl || typeof gl.getParameter !== 'function') return;

  const max3D = gl.getParameter(gl.MAX_3D_TEXTURE_SIZE) | 0;
  if (max3D > 0 && N > max3D) {
    throw new Error(
      `?n=${N} needs a ${N}^3 3D texture, but this GPU caps MAX_3D_TEXTURE_SIZE at ${max3D}. `
      + `Reload with ?n=${1 << (Math.log2(max3D) | 0)} or smaller.`,
    );
  }

  const max2D = gl.getParameter(gl.MAX_TEXTURE_SIZE) | 0;
  if (max2D > 0 && (layout.width > max2D || layout.height > max2D)) {
    throw new Error(
      `?n=${N} packs the occupancy pyramid into a ${layout.width} x ${layout.height} texture, `
      + `but this GPU caps MAX_TEXTURE_SIZE at ${max2D}. Reload with a smaller ?n=.`,
    );
  }
}

export class WorldTextures {
  constructor(renderer, world) {
    this.renderer = renderer;
    this.world = world;
    this.layout = pyramidLayout(world.N);
    checkTextureLimits(renderer, world.N, this.layout);

    const N = world.N;

    // Volume. world.vox is handed over by reference: no copy, no shadow buffer.
    this.volumeTex = new THREE.Data3DTexture(world.vox, N, N, N);
    this.volumeTex.format = THREE.RedIntegerFormat;
    this.volumeTex.type = THREE.UnsignedByteType;
    this.volumeTex.internalFormat = 'R8UI';
    this.volumeTex.minFilter = THREE.NearestFilter;
    this.volumeTex.magFilter = THREE.NearestFilter;
    this.volumeTex.wrapS = THREE.ClampToEdgeWrapping;
    this.volumeTex.wrapT = THREE.ClampToEdgeWrapping;
    this.volumeTex.wrapR = THREE.ClampToEdgeWrapping;
    this.volumeTex.unpackAlignment = 1;
    this.volumeTex.generateMipmaps = false;
    this.volumeTex.colorSpace = THREE.NoColorSpace;
    this.volumeTex.needsUpdate = true;

    // Packed pyramid. One flat image, levels concatenated at layout.offsets[L].
    this.pyrData = new Uint8Array(this.layout.width * this.layout.height);
    this.pyrTex = new THREE.DataTexture(
      this.pyrData,
      this.layout.width,
      this.layout.height,
      THREE.RedIntegerFormat,
      THREE.UnsignedByteType
    );
    this.pyrTex.internalFormat = 'R8UI';
    this.pyrTex.minFilter = THREE.NearestFilter;
    this.pyrTex.magFilter = THREE.NearestFilter;
    this.pyrTex.wrapS = THREE.ClampToEdgeWrapping;
    this.pyrTex.wrapT = THREE.ClampToEdgeWrapping;
    this.pyrTex.unpackAlignment = 1;
    this.pyrTex.generateMipmaps = false;
    this.pyrTex.flipY = false;
    this.pyrTex.colorSpace = THREE.NoColorSpace;
    this.pyrTex.needsUpdate = true;

    // Scratch slab for partial volume uploads, grown on demand.
    this._slab = new Uint8Array(0);
  }

  uniforms() {
    return { uVol: { value: this.volumeTex }, uPyr: { value: this.pyrTex } };
  }

  /** Re-pack every pyramid level into the flat image. LMAX typed-array copies. */
  _packPyramid() {
    const { offsets } = this.layout;
    const lv = this.world.lv;
    for (let L = 1; L <= this.world.LMAX; L++) {
      const src = lv[L];
      if (!src) continue;
      this.pyrData.set(src, offsets[L]);
    }
  }

  /** Full re-upload of both textures. Clears world.fullDirty and world.dirty. */
  uploadAll() {
    this._packPyramid();

    this.volumeTex.needsUpdate = true;
    this.pyrTex.needsUpdate = true;

    // Force three.js to (re)upload now rather than at first bind, so the raw-GL
    // sub-image path below always finds a live __webglTexture.
    this.renderer.initTexture(this.volumeTex);
    this.renderer.initTexture(this.pyrTex);

    this.world.fullDirty = false;
    if (this.world.dirty) this.world.dirty.length = 0;

    return this.world.vox.length + this.pyrData.length;
  }

  /**
   * Consume world.dirty with partial uploads, or fall back to uploadAll() when
   * world.fullDirty is set (shiftWorld moves the entire volume).
   * Returns bytes uploaded so the HUD can show it. Never throws.
   */
  flushDirty() {
    const world = this.world;
    if (world.fullDirty) return this.uploadAll();

    const boxes = world.dirty;
    if (!boxes || boxes.length === 0) return 0;

    const gl = this._gl();
    const volGL = this._glTexture(this.volumeTex);
    const pyrGL = this._glTexture(this.pyrTex);
    if (!gl || !volGL || !pyrGL || typeof gl.texSubImage3D !== 'function') {
      // Escape hatch unavailable: correctness over bandwidth.
      this._warnOnce('gpu.js: raw texSubImage path unavailable, falling back to full uploads.');
      return this.uploadAll();
    }

    const N = world.N;
    const LMAX = world.LMAX;
    const offsets = this.layout.offsets;
    let bytes = 0;
    let rowMin = Infinity;
    let rowMax = -Infinity;

    try {
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_3D, volGL);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
      gl.pixelStorei(gl.UNPACK_IMAGE_HEIGHT, 0);
      gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, 0);
      gl.pixelStorei(gl.UNPACK_SKIP_ROWS, 0);
      gl.pixelStorei(gl.UNPACK_SKIP_IMAGES, 0);
      // texImage3D/texSubImage3D raise INVALID_OPERATION (a GL error, not a JS throw, so
      // the catch below would never see it) if either WebGL-only unpack flag is set.
      // three.js drives both from texture.flipY, and both textures here default to false,
      // but that invariant belongs to this call site, not to three's upload path.
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);

      for (let i = 0; i < boxes.length; i++) {
        const b = boxes[i];
        const x0 = clamp(b.x0, 0, N - 1), y0 = clamp(b.y0, 0, N - 1), z0 = clamp(b.z0, 0, N - 1);
        const x1 = clamp(b.x1, 0, N - 1), y1 = clamp(b.y1, 0, N - 1), z1 = clamp(b.z1, 0, N - 1);
        if (x1 < x0 || y1 < y0 || z1 < z0) continue;

        const w = x1 - x0 + 1, h = y1 - y0 + 1, d = z1 - z0 + 1;
        const slab = this._slabFor(w * h * d);

        // Tight repack in x-fastest order: one row copy per (z, y).
        const vox = world.vox;
        let o = 0;
        for (let z = z0; z <= z1; z++) {
          for (let y = y0; y <= y1; y++) {
            const base = (z * N + y) * N + x0;
            slab.set(vox.subarray(base, base + w), o);
            o += w;
          }
        }

        const view = slab.length === w * h * d ? slab : slab.subarray(0, w * h * d);
        gl.texSubImage3D(
          gl.TEXTURE_3D, 0,
          x0, y0, z0, w, h, d,
          gl.RED_INTEGER, gl.UNSIGNED_BYTE, view
        );
        bytes += w * h * d;

        // Widen the pyramid row range this box touches. The affected node span at
        // level L runs from its lowest to its highest global index; both collapse
        // to a row in the PYR_W-wide packed image.
        for (let L = 1; L <= LMAX; L++) {
          const n = N >> L;
          const lo = offsets[L] + (((z0 >> L) * n + (y0 >> L)) * n + (x0 >> L));
          const hi = offsets[L] + (((z1 >> L) * n + (y1 >> L)) * n + (x1 >> L));
          const rl = (lo / PYR_W) | 0;
          const rh = (hi / PYR_W) | 0;
          if (rl < rowMin) rowMin = rl;
          if (rh > rowMax) rowMax = rh;
        }
      }

      if (rowMax >= rowMin) {
        // Repacking every level is LMAX typed-array copies (~N^3/7 bytes) and is
        // cheaper than tracking per-level strided sub-ranges. Only the affected
        // ROWS are then sent to the GPU. Caveat, measured: level LMAX holds a single
        // node at global index total-1, so EVERY box drags rowMax to the last row and
        // this upload always runs to the end of the image (1.3-2.4 MB at N=256).
        // Tightening it means one texSubImage2D per level, not one union.
        this._packPyramid();
        rowMin = Math.max(0, rowMin);
        rowMax = Math.min(this.layout.height - 1, rowMax);
        const rows = rowMax - rowMin + 1;
        const start = rowMin * PYR_W;
        const count = rows * PYR_W;

        gl.bindTexture(gl.TEXTURE_2D, pyrGL);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);   // else the row range uploads mirrored
        gl.texSubImage2D(
          gl.TEXTURE_2D, 0,
          0, rowMin, PYR_W, rows,
          gl.RED_INTEGER, gl.UNSIGNED_BYTE,
          this.pyrData.subarray(start, start + count)
        );
        bytes += count;
      }
    } catch (err) {
      // A driver refusal must not kill the frame loop.
      this._warnOnce('gpu.js: partial upload failed, falling back to full uploads. ' + err);
      this.renderer.resetState();
      return this.uploadAll();
    }

    // three.js caches texture bindings per unit; raw binds desync that cache and
    // the next render would sample the wrong texture.
    this.renderer.resetState();

    boxes.length = 0;
    return bytes;
  }

  dispose() {
    this.volumeTex.dispose();
    this.pyrTex.dispose();
  }

  // ── internals ──────────────────────────────────────────────────────────────

  _gl() {
    try {
      return this.renderer.getContext();
    } catch (err) {
      return null;
    }
  }

  /** The live WebGLTexture, initialising the texture first if three has not uploaded it. */
  _glTexture(tex) {
    const props = this.renderer.properties;
    if (!props || typeof props.get !== 'function') return null;
    let entry = props.get(tex);
    if (!entry || entry.__webglTexture === undefined) {
      try {
        this.renderer.initTexture(tex);
      } catch (err) {
        return null;
      }
      entry = props.get(tex);
    }
    return entry && entry.__webglTexture !== undefined ? entry.__webglTexture : null;
  }

  _slabFor(n) {
    if (this._slab.length < n) this._slab = new Uint8Array(n);
    return this._slab;
  }

  _warnOnce(msg) {
    if (warnedRawGL) return;
    warnedRawGL = true;
    console.warn(msg);
  }
}

function clamp(v, lo, hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}
