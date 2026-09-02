// MicroCube -> three.js port: WORLD + TERRAIN.
// Ported from ../../../index.html sections SETTINGS (l.19), WORLD (l.68), TERRAIN (l.143).
// Deviation from upstream: the sparse cell/block pool (cellB / blocks / freeB / allocCell)
// is gone. A 3D texture needs a dense array, so the volume is one Uint8Array(N*N*N)
// indexed (z * N + y) * N + x -- x fastest, matching Data3DTexture upload order.
// Everything else (terrain, pyramid, shifting, editing) is a faithful port.

const SCALE = 4;
const M = (metres) => metres * SCALE;

export const CONST = {
  SCALE,
  M,
  BLOCK: 4,
  CHUNK: 32,
  GROUND: M(18),
  HILLS: M(8),
  CAVE_SIZE: M(9),
  CAVE_WIDTH: 0.045,
  ISLE_Y: M(40),
  ISLE_SIZE: M(20),
  ISLE_AMOUNT: 0.7,
  LOAD_BUDGET_MS: 3,
  SEED: 7,

  MOVE_SPEED: M(4.5),
  RUN_MULT: 1.9,
  JUMP_V: M(9.9),
  GRAVITY: M(26),
  EYE: M(1.62),
  PLAYER_R: M(0.32),
  MOUSE_SENS: 0.0022,
  REACH: M(45),
  DIG_R: 7,

  SUN: [0.42, 0.82, 0.38],
  SUN_COLOR: [255, 246, 214],
  SUN_COS: 0.9985,   // sun disc radius: closer to one means smaller
  SUN_GLOW: 0.96,    // where the halo around it starts
  FOG_COLOR: [150, 170, 195],
  SKY_TOP: [92, 132, 196],
  SKY_HOR: [186, 206, 226],

  MATS: 14,
  SHADES: 3,
};

// Past this many pending boxes the partial-upload bookkeeping costs more than a
// full re-upload, so collapse to fullDirty. gpu.js checks fullDirty first.
const DIRTY_CAP = 256;

const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

// ─────────────────────────── NOISE ───────────────────────────
// Bit-identical to upstream l.144-159. Math.imul, the >>> 0 and the /4294967296
// are load-bearing: change any of them and the terrain stops matching the reference.

export function hash2(x, z, s) {
  let h = Math.imul(x | 0, 374761393) + Math.imul(z | 0, 668265263) + Math.imul(s | 0, 1274126177);
  h = Math.imul(h ^ (h >>> 13), 1274126177); h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

export function vnoise(x, z, s) {
  const ix = Math.floor(x), iz = Math.floor(z), fx = x - ix, fz = z - iz;
  const ux = fx * fx * (3 - 2 * fx), uz = fz * fz * (3 - 2 * fz);
  const a = hash2(ix, iz, s), b = hash2(ix + 1, iz, s), c = hash2(ix, iz + 1, s), d = hash2(ix + 1, iz + 1, s);
  return (a + (b - a) * ux) * (1 - uz) + (c + (d - c) * ux) * uz;
}

export function noise3(x, y, z, s) {
  const iy = Math.floor(y), f = y - iy, u = f * f * (3 - 2 * f);
  return vnoise(x, z, s + iy * 37) * (1 - u) + vnoise(x, z, s + (iy + 1) * 37) * u;
}

// ─────────────────────────── PALETTE ───────────────────────────
// Upstream l.161-171. buildPaletteBytes returns the raw 0..255 integers the
// reference stores in PAL; buildPalette returns the same values scaled to 0..1
// for the shader uniform. test/fidelity.mjs compares against the integers.

export function buildPaletteBytes() {
  const { MATS, SHADES } = CONST;
  const pal = [[0, 0, 0]];
  for (let m = 0; m < MATS; m++) {
    const u = m / (MATS - 1);
    const hue = 0.32 - u * 0.30, sat = 0.16 + 0.24 * Math.abs(Math.sin(m * 1.7)), val = 0.40 + 0.34 * u;
    for (let s = 0; s < SHADES; s++) {
      const v = val * (0.86 + s * 0.14), c = v * sat, x = c * (1 - Math.abs((hue * 6) % 2 - 1));
      const rgb = hue < 1 / 6 ? [c, x, 0] : hue < 1 / 3 ? [x, c, 0] : [0, c, x];
      pal.push(rgb.map((q) => Math.round((q + v - c) * 255)));
    }
  }
  return pal;
}

export function buildPalette() {
  const bytes = buildPaletteBytes();
  const out = new Float32Array(bytes.length * 3);
  for (let i = 0; i < bytes.length; i++) {
    out[i * 3] = bytes[i][0] / 255;
    out[i * 3 + 1] = bytes[i][1] / 255;
    out[i * 3 + 2] = bytes[i][2] / 255;
  }
  return out;
}

const base = (m) => 1 + m * CONST.SHADES;
const pick = (m, x, y, z) => base(m) + ((hash2(x * 7 + y, z * 13 + y, 5) * CONST.SHADES) | 0);

// ─────────────────────────── WORLD ───────────────────────────

export class World {
  constructor(N) {
    this.N = N;
    this.LMAX = Math.log2(N) | 0;
    this.vox = new Uint8Array(N * N * N);
    this.lv = [null, ...Array.from({ length: this.LMAX }, (_, i) => new Uint8Array((N >> (i + 1)) ** 3))];
    this.wox = -(N >> 1);
    this.woz = -(N >> 1);
    this.pal = buildPalette();
    this.dirty = [];
    this.fullDirty = true;
    this.pending = [];
  }

  inBox(x, y, z) {
    const N = this.N;
    return (x | y | z) >= 0 && x < N && y < N && z < N;
  }

  voxAt(x, y, z) {
    const N = this.N;
    return this.vox[(z * N + y) * N + x];
  }

  getVox(x, y, z) {
    return this.inBox(x, y, z) ? this.voxAt(x, y, z) : 0;
  }

  voxSet(x, y, z, t) {
    const N = this.N;
    this.vox[(z * N + y) * N + x] = t;
  }

  // ── dirty tracking (no upstream equivalent; feeds gpu.js partial uploads) ──

  markDirty(x0, y0, z0, x1, y1, z1) {
    if (this.fullDirty) return;
    const N = this.N;
    x0 = Math.max(0, Math.floor(x0)); y0 = Math.max(0, Math.floor(y0)); z0 = Math.max(0, Math.floor(z0));
    x1 = Math.min(N - 1, Math.ceil(x1)); y1 = Math.min(N - 1, Math.ceil(y1)); z1 = Math.min(N - 1, Math.ceil(z1));
    if (x1 < x0 || y1 < y0 || z1 < z0) return;

    const last = this.dirty[this.dirty.length - 1];
    if (last) {
      if (x0 >= last.x0 && y0 >= last.y0 && z0 >= last.z0
        && x1 <= last.x1 && y1 <= last.y1 && z1 <= last.z1) return;
      if (last.x0 >= x0 && last.y0 >= y0 && last.z0 >= z0
        && last.x1 <= x1 && last.y1 <= y1 && last.z1 <= z1) {
        last.x0 = x0; last.y0 = y0; last.z0 = z0; last.x1 = x1; last.y1 = y1; last.z1 = z1;
        return;
      }
    }
    this.dirty.push({ x0, y0, z0, x1, y1, z1 });
    if (this.dirty.length > DIRTY_CAP) { this.dirty.length = 0; this.fullDirty = true; }
  }

  // ── pyramid ──

  // Rebuild one whole pyramid level from the level below it. Level 1 reads the
  // dense volume; upstream reads lv[L-1] unconditionally, which would deref
  // lv[0] === null. Behaviour is identical for every L >= 2.
  _rebuildLevel(L) {
    const N = this.N, n = N >> L, cn = N >> (L - 1), p = cn * cn;
    const dst = this.lv[L], d = this.lv[L - 1];
    for (let z = 0; z < n; z++) for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
      let any;
      if (L === 1) {
        const px = 2 * x, py = 2 * y, pz = 2 * z;
        any = this.voxAt(px, py, pz) || this.voxAt(px + 1, py, pz) || this.voxAt(px, py + 1, pz) || this.voxAt(px + 1, py + 1, pz)
          || this.voxAt(px, py, pz + 1) || this.voxAt(px + 1, py, pz + 1) || this.voxAt(px, py + 1, pz + 1) || this.voxAt(px + 1, py + 1, pz + 1);
      } else {
        const c = ((2 * z * cn) + 2 * y) * cn + 2 * x;
        any = d[c] || d[c + 1] || d[c + cn] || d[c + cn + 1] || d[c + p] || d[c + p + 1] || d[c + p + cn] || d[c + p + cn + 1];
      }
      dst[(z * n + y) * n + x] = any ? 1 : 0;
    }
  }

  // Upstream l.107. Same clamping, same level walk; L === 1 reads the dense
  // volume through voxAt instead of the sparse pool. Also marks the touched
  // level-0 box dirty so gpu.js knows what to re-upload.
  reduceBox(x0, y0, z0, x1, y1, z1) {
    const N = this.N;
    x0 = Math.max(0, x0); y0 = Math.max(0, y0); z0 = Math.max(0, z0);
    x1 = Math.min(N - 1, x1); y1 = Math.min(N - 1, y1); z1 = Math.min(N - 1, z1);
    if (x1 < x0 || y1 < y0 || z1 < z0) return;
    this.markDirty(x0, y0, z0, x1, y1, z1);

    for (let L = 1; L <= this.LMAX; L++) {
      x0 >>= 1; y0 >>= 1; z0 >>= 1; x1 >>= 1; y1 >>= 1; z1 >>= 1;
      const n = N >> L, cn = N >> (L - 1), p = cn * cn, d = this.lv[L - 1], dst = this.lv[L];
      for (let z = z0; z <= z1; z++) for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
        let any;
        if (L === 1) {
          const px = 2 * x, py = 2 * y, pz = 2 * z;
          any = this.voxAt(px, py, pz) || this.voxAt(px + 1, py, pz) || this.voxAt(px, py + 1, pz) || this.voxAt(px + 1, py + 1, pz)
            || this.voxAt(px, py, pz + 1) || this.voxAt(px + 1, py, pz + 1) || this.voxAt(px, py + 1, pz + 1) || this.voxAt(px + 1, py + 1, pz + 1);
        } else {
          const c = ((2 * z * cn) + 2 * y) * cn + 2 * x;
          any = d[c] || d[c + 1] || d[c + cn] || d[c + cn + 1] || d[c + p] || d[c + p + 1] || d[c + p + cn] || d[c + p + cn + 1];
        }
        dst[(z * n + y) * n + x] = any ? 1 : 0;
      }
    }
  }

  // Upstream l.128.
  sphereEdit(cx, cy, cz, r, t) {
    const R = Math.ceil(r) + 1;
    const x0 = Math.round(cx), y0 = Math.round(cy), z0 = Math.round(cz);
    const r2 = r * r;
    for (let dz = -R; dz <= R; dz++) for (let dy = -R; dy <= R; dy++) for (let dx = -R; dx <= R; dx++) {
      if (dx * dx + dy * dy + dz * dz > r2) continue;
      const x = x0 + dx, y = y0 + dy, z = z0 + dz;
      if (!this.inBox(x, y, z)) continue;
      const v = this.voxAt(x, y, z);
      if (t === 0 ? v === 0 : v !== 0) continue;
      this.voxSet(x, y, z, t);
    }
    this.reduceBox(x0 - R, y0 - R, z0 - R, x0 + R, y0 + R, z0 + R);
  }

  // ─────────────────────────── TERRAIN ───────────────────────────

  // Upstream l.173.
  heightAt(wx, wz) {
    const { SEED, GROUND, HILLS } = CONST;
    const n = vnoise(wx / (12 * SCALE), wz / (12 * SCALE), SEED) * 0.55
      + vnoise(wx / (5 * SCALE), wz / (5 * SCALE), SEED + 1) * 0.3
      + vnoise(wx / (2 * SCALE), wz / (2 * SCALE), SEED + 2) * 0.15;
    const ridge = 1 - Math.abs(vnoise(wx / (22 * SCALE), wz / (22 * SCALE), SEED + 3) * 2 - 1);
    return Math.round(GROUND + (n - 0.5) * HILLS * 2 + ridge * ridge * HILLS * 0.8);
  }

  blockTop(wx, wz) {
    return Math.round(this.heightAt(wx, wz) / CONST.BLOCK) * CONST.BLOCK;
  }

  isleAt(wx, y, wz) {
    const { ISLE_Y, ISLE_SIZE } = CONST;
    return Math.abs(y - ISLE_Y) > ISLE_SIZE * 1.4 ? 0
      : noise3(wx / ISLE_SIZE, y / (ISLE_SIZE * 0.6), wz / ISLE_SIZE, 53) - Math.abs(y - ISLE_Y) / (ISLE_SIZE * 1.4);
  }

  // Upstream l.187, minus the cell-pool bookkeeping (the `(y >> CL) !== cy`
  // line and the b/blocks writes). Every voxel is written, air included.
  genColumn(x, z) {
    const N = this.N;
    const { BLOCK, CAVE_SIZE, CAVE_WIDTH, ISLE_AMOUNT, GROUND, HILLS, MATS, SHADES } = CONST;
    const wx = this.wox + x, wz = this.woz + z;
    const h = this.blockTop(wx, wz);
    const bx = Math.floor(wx / BLOCK), bz = Math.floor(wz / BLOCK);
    const col = z * N * N + x;
    let cave = 1, isle = 0, isleTop = false;
    for (let y = 0; y < N; y++) {
      let t = 0;
      if (y % BLOCK === 0) {
        if (y < h) cave = Math.abs(noise3(wx / CAVE_SIZE, y / CAVE_SIZE, wz / CAVE_SIZE, 41) - 0.5);
        else { isle = this.isleAt(wx, y, wz); isleTop = isle > ISLE_AMOUNT && this.isleAt(wx, y + BLOCK, wz) <= ISLE_AMOUNT; }
      }
      const solid = y < h ? !(cave < CAVE_WIDTH && (y < h - BLOCK * 2 || cave < CAVE_WIDTH * 0.35)) : isle > ISLE_AMOUNT;
      if (solid) {
        const depthBlocks = y < h ? Math.floor((h - 1 - y) / BLOCK) : (isleTop ? 0 : 2);
        const by = Math.floor(y / BLOCK);
        const lvl = (h - GROUND + HILLS) / (2 * HILLS) + (vnoise(wx / (6 * SCALE), wz / (6 * SCALE), 31) - 0.5) * 0.28;
        const band = vnoise(wx / (40 * SCALE), wz / (40 * SCALE), 21) * 6 + y / (2.5 * SCALE);
        const m = depthBlocks === 0 ? Math.max(0, Math.min(MATS - 1, (lvl * MATS) | 0))
          : depthBlocks === 1 ? Math.max(0, Math.min(MATS - 1, (lvl * MATS) | 0) - 1)
            : (Math.floor(band) % MATS + MATS) % MATS;
        t = pick(m, bx, by, bz);
        if (hash2(wx * 3, wz * 5, y) > 0.82) t = base(m) + (t - base(m) + 1) % SHADES;
      }
      this.vox[col + y * N] = t;
    }
  }

  // Upstream l.216. The cell-pool free list and the cellB move are gone; the
  // dense volume is moved with the same copyWithin walk (n = N, step = CHUNK)
  // because it is now the thing the GPU reads.
  shiftWorld(dx, dz) {
    const N = this.N, LMAX = this.LMAX, CHUNK = CONST.CHUNK;
    const s = dx ? Math.sign(dx) : Math.sign(dz);
    const axis = dx ? 0 : 2;
    let topRebuild = 1;

    const moveGrid = (arr, n, step, blank = 0) => {
      if (axis === 0) {
        for (let z = 0; z < n; z++) for (let y = 0; y < n; y++) {
          const row = (z * n + y) * n;
          if (s > 0) { arr.copyWithin(row, row + step, row + n); arr.fill(blank, row + n - step, row + n); }
          else { arr.copyWithin(row + step, row, row + n - step); arr.fill(blank, row, row + step); }
        }
      } else {
        const plane = n * n;
        if (s > 0) { arr.copyWithin(0, step * plane, n * plane); arr.fill(blank, (n - step) * plane, n * plane); }
        else { arr.copyWithin(step * plane, 0, (n - step) * plane); arr.fill(blank, 0, step * plane); }
      }
    };

    moveGrid(this.vox, N, CHUNK);
    for (let L = 1; L <= LMAX; L++) {
      const step = CHUNK >> L;
      if (step < 1 || (step << L) !== CHUNK) { topRebuild = L; break; }
      moveGrid(this.lv[L], N >> L, step);
      topRebuild = L + 1;
    }
    for (let L = topRebuild; L <= LMAX; L++) this._rebuildLevel(L);

    if (axis === 0) this.wox += s * CHUNK; else this.woz += s * CHUNK;

    const pending = this.pending;
    for (let i = pending.length - 1; i >= 0; i--) {
      const j = pending[i];
      if (axis === 0) { j.x0 -= s * CHUNK; j.x1 -= s * CHUNK; j.x -= s * CHUNK; } else { j.z0 -= s * CHUNK; j.z1 -= s * CHUNK; j.z -= s * CHUNK; }
      if (j.x1 <= 0 || j.z1 <= 0 || j.x0 >= N || j.z0 >= N) { pending.splice(i, 1); continue; }
      const cx0 = Math.max(0, j.x0), cz0 = Math.max(0, j.z0);
      if (cx0 !== j.x0 || cz0 !== j.z0 || j.x1 > N || j.z1 > N) {
        j.x0 = cx0; j.z0 = cz0; j.x1 = Math.min(N, j.x1); j.z1 = Math.min(N, j.z1);
        j.x = j.x0; j.z = j.z0;
      } else if (j.x < j.x0 || j.z < j.z0) { j.x = j.x0; j.z = j.z0; }
    }

    const from = s > 0 ? N - CHUNK : 0;
    const job = axis === 0
      ? { x0: from, z0: 0, x1: from + CHUNK, z1: N }
      : { x0: 0, z0: from, x1: N, z1: from + CHUNK };
    job.x = job.x0; job.z = job.z0;
    pending.push(job);

    // The whole volume moved, so every texel of the 3D texture is stale.
    this.dirty.length = 0;
    this.fullDirty = true;
  }

  // Upstream l.277.
  pumpPending(budgetMs) {
    const pending = this.pending;
    if (!pending.length) return;
    if (pending.length > 1) budgetMs *= pending.length;
    const N = this.N;
    const t0 = now();
    while (pending.length && now() - t0 < budgetMs) {
      const job = pending[0];
      const z0 = job.z;
      let count = 0;
      while (job.z < job.z1 && count < 256) {
        this.genColumn(job.x, job.z);
        count++;
        if (++job.x >= job.x1) { job.x = job.x0; job.z++; }
      }
      this.reduceBox(job.x0, 0, z0, job.x1, N - 1, Math.min(job.z1, job.z + 1));
      if (job.z >= job.z1) pending.shift();
    }
  }

  generateAll() {
    const N = this.N;
    for (let z = 0; z < N; z++) for (let x = 0; x < N; x++) this.genColumn(x, z);
    this.reduceBox(0, 0, 0, N - 1, N - 1, N - 1);
    this.pending.length = 0;
    this.dirty.length = 0;
    this.fullDirty = true;
  }
}
