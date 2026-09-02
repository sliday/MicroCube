#!/usr/bin/env node
//
// fidelity.mjs - proof that bonus/threejs/src/world.js did not quietly drift
//                from the upstream CPU raycaster in ../../../index.html
//
//   run:  node test/fidelity.mjs
//   exit: 0 = every assertion held, 1 = first disagreement printed with a diff
//
// The reference implementations below are copied VERBATIM out of the upstream
// file. They are the ground truth. Nothing in this file may import them from
// the port, and nothing here may be "fixed" to make the port pass. If the port
// and the reference disagree, the port is wrong.
//
// No npm dependencies. No Math.random - every sample point comes from a counter
// so a failure reproduces byte for byte on the next run.

/* ══════════════════════════════════════════════════════════════════════════
 * BEGIN VERBATIM UPSTREAM
 *
 * Copied from /Users/stas/Playground/ultrafast-voxels/microcube/index.html
 * (MicroCube by @vseplet, AGPL-3.0) solely so this test can compare the port
 * against the original. Reproduced here under the AGPL for that purpose.
 *
 * Two mechanical edits, and only these two:
 *   1. The sparse cell/block pool (index.html l.75-105: cellB, blocks, freeB,
 *      allocCell, cellAt, inCell) is replaced by a dense Uint8Array indexed
 *      (z * N + y) * N + x, matching the port's deliberate deviation #1.
 *      In genColumn, upstream l.211-212 read
 *          if(t !== 0 && b < 0) b = allocCell(cellAt(x, y, z));
 *          if(b >= 0) blocks[b * CELL3 + inCell(x, y, z)] = t;
 *      An unallocated cell reads back as 0, and the only value written into a
 *      cell that stays unallocated is t === 0, so the dense equivalent is a
 *      plain unconditional store. The cy/b cursor at l.191/l.194 exists purely
 *      to cache the pool lookup and disappears with the pool.
 *   2. N, wox and woz become parameters instead of module-level bindings, so
 *      one copy of the code can be exercised at several grid sizes.
 *
 * Every arithmetic expression, every Math.floor vs |0, every constant and
 * every comparison operator is unchanged.
 * ══════════════════════════════════════════════════════════════════════════ */

// --- SETTINGS (index.html l.19-46) ---
const U_SCALE = 4;
const U_M = (metres) => metres * U_SCALE;

const U_CHUNK = 32;
const U_BLOCK = 4;
const U_GROUND = U_M(18);
const U_HILLS = U_M(8);
const U_CAVE_SIZE = U_M(9);
const U_CAVE_WIDTH = 0.045;
const U_ISLE_Y = U_M(40);
const U_ISLE_SIZE = U_M(20);
const U_ISLE_AMOUNT = 0.7;
const U_SEED = 7;

// --- TERRAIN (index.html l.144-213) ---

// index.html l.144
const u_hash2 = (x, z, s) => {
  let h = Math.imul(x | 0, 374761393) + Math.imul(z | 0, 668265263) + Math.imul(s | 0, 1274126177);
  h = Math.imul(h ^ (h >>> 13), 1274126177); h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
};

// index.html l.149
const u_vnoise = (x, z, s) => {
  const ix = Math.floor(x), iz = Math.floor(z), fx = x - ix, fz = z - iz;
  const ux = fx * fx * (3 - 2 * fx), uz = fz * fz * (3 - 2 * fz);
  const a = u_hash2(ix, iz, s), b = u_hash2(ix + 1, iz, s), c = u_hash2(ix, iz + 1, s), d = u_hash2(ix + 1, iz + 1, s);
  return (a + (b - a) * ux) * (1 - uz) + (c + (d - c) * ux) * uz;
};

// index.html l.156
const u_noise3 = (x, y, z, s) => {
  const iy = Math.floor(y), f = y - iy, u = f * f * (3 - 2 * f);
  return u_vnoise(x, z, s + iy * 37) * (1 - u) + u_vnoise(x, z, s + (iy + 1) * 37) * u;
};

// index.html l.161
const U_MATS = 14, U_SHADES = 3;

// index.html l.162-171
const buildUpstreamPAL = () => {
  const PAL = [[0, 0, 0]];
  for (let m = 0; m < U_MATS; m++) {
    const u = m / (U_MATS - 1);
    const hue = 0.32 - u * 0.30, sat = 0.16 + 0.24 * Math.abs(Math.sin(m * 1.7)), val = 0.40 + 0.34 * u;
    for (let s = 0; s < U_SHADES; s++) {
      const v = val * (0.86 + s * 0.14), c = v * sat, x = c * (1 - Math.abs((hue * 6) % 2 - 1));
      const rgb = hue < 1 / 6 ? [c, x, 0] : hue < 1 / 3 ? [x, c, 0] : [0, c, x];
      PAL.push(rgb.map((q) => Math.round((q + v - c) * 255)));
    }
  }
  return PAL;
};

// index.html l.172
const u_base = (m) => 1 + m * U_SHADES;
// index.html l.173
const u_pick = (m, x, y, z) => u_base(m) + ((u_hash2(x * 7 + y, z * 13 + y, 5) * U_SHADES) | 0);

// index.html l.175
const u_heightAt = (wx, wz) => {
  const n = u_vnoise(wx / (12 * U_SCALE), wz / (12 * U_SCALE), U_SEED) * 0.55
    + u_vnoise(wx / (5 * U_SCALE), wz / (5 * U_SCALE), U_SEED + 1) * 0.3
    + u_vnoise(wx / (2 * U_SCALE), wz / (2 * U_SCALE), U_SEED + 2) * 0.15;
  const ridge = 1 - Math.abs(u_vnoise(wx / (22 * U_SCALE), wz / (22 * U_SCALE), U_SEED + 3) * 2 - 1);
  return Math.round(U_GROUND + (n - 0.5) * U_HILLS * 2 + ridge * ridge * U_HILLS * 0.8);
};

// index.html l.182
const u_blockTop = (wx, wz) => Math.round(u_heightAt(wx, wz) / U_BLOCK) * U_BLOCK;

// index.html l.184
const u_isleAt = (wx, y, wz) => Math.abs(y - U_ISLE_Y) > U_ISLE_SIZE * 1.4 ? 0
  : u_noise3(wx / U_ISLE_SIZE, y / (U_ISLE_SIZE * 0.6), wz / U_ISLE_SIZE, 53) - Math.abs(y - U_ISLE_Y) / (U_ISLE_SIZE * 1.4);

// index.html l.187, sparse storage replaced by the dense array `vox`
const u_genColumn = (vox, N, wox, woz, x, z) => {
  const wx = wox + x, wz = woz + z;
  const h = u_blockTop(wx, wz);
  const bx = Math.floor(wx / U_BLOCK), bz = Math.floor(wz / U_BLOCK);
  let cave = 1, isle = 0, isleTop = false;
  for (let y = 0; y < N; y++) {
    let t = 0;
    if (y % U_BLOCK === 0) {
      if (y < h) cave = Math.abs(u_noise3(wx / U_CAVE_SIZE, y / U_CAVE_SIZE, wz / U_CAVE_SIZE, 41) - 0.5);
      else { isle = u_isleAt(wx, y, wz); isleTop = isle > U_ISLE_AMOUNT && u_isleAt(wx, y + U_BLOCK, wz) <= U_ISLE_AMOUNT; }
    }
    const solid = y < h ? !(cave < U_CAVE_WIDTH && (y < h - U_BLOCK * 2 || cave < U_CAVE_WIDTH * 0.35)) : isle > U_ISLE_AMOUNT;
    if (solid) {
      const depthBlocks = y < h ? Math.floor((h - 1 - y) / U_BLOCK) : (isleTop ? 0 : 2);
      const by = Math.floor(y / U_BLOCK);
      const lvl = (h - U_GROUND + U_HILLS) / (2 * U_HILLS) + (u_vnoise(wx / (6 * U_SCALE), wz / (6 * U_SCALE), 31) - 0.5) * 0.28;
      const band = u_vnoise(wx / (40 * U_SCALE), wz / (40 * U_SCALE), 21) * 6 + y / (2.5 * U_SCALE);
      const m = depthBlocks === 0 ? Math.max(0, Math.min(U_MATS - 1, (lvl * U_MATS) | 0))
        : depthBlocks === 1 ? Math.max(0, Math.min(U_MATS - 1, (lvl * U_MATS) | 0) - 1)
          : (Math.floor(band) % U_MATS + U_MATS) % U_MATS;
      t = u_pick(m, bx, by, bz);
      if (u_hash2(wx * 3, wz * 5, y) > 0.82) t = u_base(m) + (t - u_base(m) + 1) % U_SHADES;
    }
    vox[(z * N + y) * N + x] = t;
  }
};

// index.html l.107, sparse voxAt/lv replaced by the dense `vox` + `lv` arrays
const u_reduceBox = (vox, lv, N, LMAX, x0, y0, z0, x1, y1, z1) => {
  const voxAt = (x, y, z) => vox[(z * N + y) * N + x];
  x0 = Math.max(0, x0); y0 = Math.max(0, y0); z0 = Math.max(0, z0);
  x1 = Math.min(N - 1, x1); y1 = Math.min(N - 1, y1); z1 = Math.min(N - 1, z1);
  for (let L = 1; L <= LMAX; L++) {
    x0 >>= 1; y0 >>= 1; z0 >>= 1; x1 >>= 1; y1 >>= 1; z1 >>= 1;
    const n = N >> L, cn = N >> (L - 1);
    for (let z = z0; z <= z1; z++) for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      let any;
      if (L === 1) {
        const px = 2 * x, py = 2 * y, pz = 2 * z;
        any = voxAt(px, py, pz) || voxAt(px + 1, py, pz) || voxAt(px, py + 1, pz) || voxAt(px + 1, py + 1, pz)
          || voxAt(px, py, pz + 1) || voxAt(px + 1, py, pz + 1) || voxAt(px, py + 1, pz + 1) || voxAt(px + 1, py + 1, pz + 1);
      } else {
        const c = ((2 * z * cn) + 2 * y) * cn + 2 * x, p = cn * cn, d = lv[L - 1];
        any = d[c] || d[c + 1] || d[c + cn] || d[c + cn + 1] || d[c + p] || d[c + p + 1] || d[c + p + cn] || d[c + p + cn + 1];
      }
      lv[L][(z * n + y) * n + x] = any ? 1 : 0;
    }
  }
};

/* ══════════════════════════════════════════════════════════════════════════
 * END VERBATIM UPSTREAM
 * ══════════════════════════════════════════════════════════════════════════ */

// Upstream line numbers, quoted in every failure message.
const UP = {
  hash2: 144, vnoise: 149, noise3: 156, PAL: 161,
  heightAt: 175, blockTop: 182, isleAt: 184, genColumn: 187, reduceBox: 107,
};

// ─────────────────────────── harness ───────────────────────────

const PORT = '../src/world.js';
let assertionNo = 0;

const ok = (label) => { console.log(`ok   ${++assertionNo}  ${label}`); };

const fail = (label, detail) => {
  console.log(`FAIL ${++assertionNo}  ${label}`);
  console.log('');
  for (const line of detail) console.log(`     ${line}`);
  console.log('');
  process.exit(1);
};

// Reports a single value disagreement in the standard shape.
const diff = (label, fn, upLine, input, expected, actual, note) => {
  const d = [
    `function   ${fn}()  (index.html l.${upLine})`,
    `input      ${input}`,
    `expected   ${expected}   (upstream)`,
    `actual     ${actual}   (${PORT})`,
  ];
  if (note) d.push('', note);
  fail(label, d);
};

// Bit-comparison that still treats NaN as unequal to itself and does not trip
// on the 0 / -0 distinction (upstream and the port both produce plain zeros).
const same = (a, b) => a === b || (Number.isNaN(a) && Number.isNaN(b));

// Deterministic counter-driven bit source. No Math.random anywhere in this
// file, so a failing sample index is the same on every run and on every
// machine. Reset per assertion to keep the assertions independent.
let counter = 0;
const seedCounter = (v) => { counter = v; };
const nextU32 = () => {
  let h = Math.imul(++counter, 2654435761) >>> 0;
  h ^= h >>> 15; h = Math.imul(h, 2246822519) >>> 0;
  h ^= h >>> 13; h = Math.imul(h, 3266489917) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
};
const nextFloat = () => nextU32() / 4294967296;
const nextInt = (lo, hi) => lo + (nextU32() % (hi - lo + 1));

// ─────────────────────────── load the port ───────────────────────────

const portUrl = new URL(PORT, import.meta.url);
let world;
try {
  world = await import(portUrl.href);
} catch (err) {
  console.log(`FAIL 0  ${PORT} does not load under plain node`);
  console.log('');
  if (err && err.code === 'ERR_MODULE_NOT_FOUND') {
    console.log(`     ${portUrl.pathname} is missing.`);
    console.log('     Nothing to compare against. Write src/world.js first.');
  } else if (err instanceof ReferenceError) {
    console.log(`     ${err.name}: ${err.message}`);
    console.log('');
    console.log('     src/world.js reached for a browser global at module load time.');
    console.log('     The contract says world.js imports nothing and must run under');
    console.log('     plain node with no flags, because the fidelity test and any');
    console.log('     future headless tooling depend on that. This test deliberately');
    console.log('     does NOT shim the global - fix world.js instead.');
  } else {
    console.log(`     ${err && err.stack ? err.stack : err}`);
  }
  console.log('');
  process.exit(1);
}

// Structural preflight, so a renamed export fails as one clear line rather than
// as a confusing TypeError three assertions later.
{
  const missing = [];
  const wantFn = ['hash2', 'vnoise', 'noise3', 'buildPalette'];
  for (const k of wantFn) if (typeof world[k] !== 'function') missing.push(`export function ${k}()`);
  if (typeof world.World !== 'function') missing.push('export class World');
  if (!world.CONST || typeof world.CONST !== 'object') missing.push('export const CONST');
  if (missing.length) {
    console.log(`FAIL 0  ${PORT} does not match the module contract`);
    console.log('');
    console.log('     missing or wrong-kind exports:');
    for (const m of missing) console.log(`       - ${m}`);
    console.log('');
    console.log(`     found: ${Object.keys(world).sort().join(', ') || '(nothing)'}`);
    console.log('');
    process.exit(1);
  }
}

const { hash2, vnoise, noise3, buildPalette, World, CONST } = world;

// Terrain constants, checked directly. Every one of them also shows up inside
// heightAt or genColumn, but a mismatch found here names the constant instead
// of pointing at a voxel 300 lines later.
{
  const want = {
    SCALE: U_SCALE, BLOCK: U_BLOCK, CHUNK: U_CHUNK, SEED: U_SEED,
    GROUND: U_GROUND, HILLS: U_HILLS,
    CAVE_SIZE: U_CAVE_SIZE, CAVE_WIDTH: U_CAVE_WIDTH,
    ISLE_Y: U_ISLE_Y, ISLE_SIZE: U_ISLE_SIZE, ISLE_AMOUNT: U_ISLE_AMOUNT,
    MATS: U_MATS, SHADES: U_SHADES,
  };
  const bad = [];
  for (const [k, v] of Object.entries(want)) {
    if (!same(CONST[k], v)) bad.push(`  CONST.${k}  expected ${v}, got ${CONST[k]}`);
  }
  if (typeof CONST.M !== 'function' || CONST.M(18) !== U_M(18)) {
    bad.push(`  CONST.M(18)  expected ${U_M(18)}, got ${typeof CONST.M === 'function' ? CONST.M(18) : '(not a function)'}`);
  }
  if (bad.length) {
    console.log('FAIL 0  CONST drifted from the upstream SETTINGS block (index.html l.19-46)');
    console.log('');
    for (const b of bad) console.log(`   ${b}`);
    console.log('');
    process.exit(1);
  }
}

// ─────────────────── 1. hash2 / vnoise / noise3 ───────────────────
{
  const label = 'hash2 / vnoise / noise3 bit-identical over 10000 sample points';
  const SAMPLES = 10000;
  seedCounter(0x1101);

  for (let i = 0; i < SAMPLES; i++) {
    // Sample shapes rotate so the batch covers the cases that actually break a
    // port: negative coordinates (Math.floor vs |0), exact integers and values
    // a hair below one (the floor boundary), |0 wraparound past 2^31, and
    // negative seeds.
    const shape = i % 5;
    let x, z, y, s;
    if (shape === 0) {            // small signed integers
      x = nextInt(-64, 64); z = nextInt(-64, 64); y = nextInt(-64, 64); s = nextInt(-8, 64);
    } else if (shape === 1) {     // fractional, signed, wide range
      x = (nextFloat() - 0.5) * 512; z = (nextFloat() - 0.5) * 512;
      y = (nextFloat() - 0.5) * 512; s = nextInt(0, 96);
    } else if (shape === 2) {     // sitting exactly on integer boundaries
      x = nextInt(-32, 32); z = nextInt(-32, 32) + 0; y = nextInt(-32, 32); s = nextInt(0, 64);
    } else if (shape === 3) {     // a hair either side of an integer boundary
      const e = 1e-9;
      x = nextInt(-16, 16) - e; z = nextInt(-16, 16) + e;
      y = nextInt(-16, 16) - e; s = nextInt(0, 40);
    } else {                      // past 2^31, to exercise the |0 wrap in hash2
      x = 2147483647 + nextInt(1, 4096); z = -2147483648 - nextInt(1, 4096);
      y = nextInt(-4, 4); s = 2147483647 + nextInt(0, 16);
    }

    const eh = u_hash2(x, z, s), ah = hash2(x, z, s);
    if (!same(eh, ah)) {
      diff(label, 'hash2', UP.hash2, `x=${x} z=${z} s=${s}   (sample #${i})`, eh, ah,
        'A drift here is usually Math.imul dropped, or |0 replaced by Math.floor.');
    }

    const ev = u_vnoise(x, z, s), av = vnoise(x, z, s);
    if (!same(ev, av)) {
      diff(label, 'vnoise', UP.vnoise, `x=${x} z=${z} s=${s}   (sample #${i})`, ev, av,
        'Check the smoothstep fx*fx*(3-2*fx) and that ix/iz use Math.floor, not |0.');
    }

    const en = u_noise3(x, y, z, s), an = noise3(x, y, z, s);
    if (!same(en, an)) {
      diff(label, 'noise3', UP.noise3, `x=${x} y=${y} z=${z} s=${s}   (sample #${i})`, en, an,
        'Check the seed stride s + iy*37 and that iy uses Math.floor.');
    }
  }
  ok(`${label} (${SAMPLES} points)`);
}

// ─────────────────── 2. heightAt over a 128x128 grid ───────────────────
{
  const label = 'heightAt / blockTop / isleAt identical over a 128x128 world grid';
  const w = new World(256);

  // Deliberately straddles zero. wox/woz start at -(N>>1), so every real column
  // in the port asks for a negative wx or wz at some point, and that is exactly
  // where a floor-vs-truncate slip shows up.
  const LO = -140, STEP = 2, SIDE = 128;

  for (let j = 0; j < SIDE; j++) {
    const wz = LO + j * STEP;
    for (let i = 0; i < SIDE; i++) {
      const wx = LO + i * STEP;

      const eh = u_heightAt(wx, wz), ah = w.heightAt(wx, wz);
      if (!same(eh, ah)) {
        diff(label, 'heightAt', UP.heightAt, `wx=${wx} wz=${wz}`, eh, ah,
          'Check the three octave divisors (12/5/2 * SCALE) and the ridge term.');
      }

      const eb = u_blockTop(wx, wz), ab = w.blockTop(wx, wz);
      if (!same(eb, ab)) {
        diff(label, 'blockTop', UP.blockTop, `wx=${wx} wz=${wz}`, eb, ab,
          'blockTop is Math.round(h / BLOCK) * BLOCK, not floor.');
      }
    }
  }

  // isleAt is the other terrain input genColumn depends on. Cheap to check
  // here, and a mismatch is far easier to read at this level than buried
  // inside a column diff.
  seedCounter(0x2202);
  for (let i = 0; i < 4096; i++) {
    const wx = nextInt(-140, 140);
    const wz = nextInt(-140, 140);
    // Sweep across ISLE_Y (=160) and well outside the +/- ISLE_SIZE*1.4 cutoff.
    const y = nextInt(0, 320);
    const ei = u_isleAt(wx, y, wz), ai = w.isleAt(wx, y, wz);
    if (!same(ei, ai)) {
      diff(label, 'isleAt', UP.isleAt, `wx=${wx} y=${y} wz=${wz}   (sample #${i})`, ei, ai,
        'Note the argument order is (wx, y, wz) and the early-out returns exactly 0.');
    }
  }

  ok(`${label} (${SIDE * SIDE} height samples, 4096 isle samples)`);
}

// ─────────────────── 3. buildPalette ───────────────────
{
  const label = 'buildPalette matches the upstream PAL integers 0..255';
  const PAL = buildUpstreamPAL();
  const pal = buildPalette();

  const wantLen = (1 + U_MATS * U_SHADES) * 3;
  if (!(pal instanceof Float32Array) || pal.length !== wantLen) {
    fail(label, [
      `function   buildPalette()  (index.html l.${UP.PAL})`,
      `expected   Float32Array of length ${wantLen}`,
      `actual     ${pal && pal.constructor ? pal.constructor.name : typeof pal} of length ${pal ? pal.length : '?'}`,
    ]);
  }

  for (let k = 0; k < PAL.length; k++) {
    for (let c = 0; c < 3; c++) {
      const expInt = PAL[k][c];
      const actual = pal[k * 3 + c];
      const back = Math.round(actual * 255);
      const channel = 'rgb'[c];
      if (back !== expInt) {
        diff(label, 'buildPalette', UP.PAL,
          `entry ${k} (material ${k === 0 ? 'air' : ((k - 1) / U_SHADES) | 0}, shade ${k === 0 ? '-' : (k - 1) % U_SHADES}), channel ${channel}`,
          `${expInt}/255 = ${expInt / 255}`,
          `${actual}  (rounds back to ${back})`,
          'The palette must be the upstream integers divided by 255 - nothing else.');
      }
      // Guards a systematic scale slip (e.g. /256) that the integer round-trip
      // could still survive at the low end of the range.
      if (Math.abs(actual - expInt / 255) > 1e-6) {
        diff(label, 'buildPalette', UP.PAL,
          `entry ${k}, channel ${channel}`, expInt / 255, actual,
          'Rounds to the right byte but the float is off - wrong divisor?');
      }
    }
  }
  ok(`${label} (${PAL.length} entries)`);
}

// ─────────────────── 4. genColumn ───────────────────
{
  const label = 'genColumn produces identical columns';

  // Three grid sizes on purpose. At N=64 the whole column sits far below the
  // surface, so only the `band` material branch runs. N=128 puts the surface
  // inside the grid and reaches depthBlocks 0 and 1. N=256 is the only size
  // that reaches ISLE_Y (=160) and exercises the floating-island branch and
  // isleTop. A test that only ran the contract's N=64 case would pass with the
  // surface and island material code completely broken.
  const CASES = [64, 128, 256];
  let columnsChecked = 0;

  for (const N of CASES) {
    const w = new World(N);

    if (w.N !== N) {
      fail(label, [`World(${N}).N is ${w.N}, expected ${N}`]);
    }
    // genColumn reads world origin. If the port starts it anywhere else the
    // terrain is shifted and every downstream comparison is meaningless.
    if (w.wox !== -(N >> 1) || w.woz !== -(N >> 1)) {
      fail(label, [
        `function   World constructor / shiftWorld origin`,
        `expected   wox = woz = ${-(N >> 1)}   (upstream l.73: -(N >> 1))`,
        `actual     wox = ${w.wox}, woz = ${w.woz}`,
        '',
        'genColumn adds this origin to the grid coordinate, so a wrong start',
        'silently shifts the whole world.',
      ]);
    }

    const ref = new Uint8Array(N * N * N);

    // 64 columns per size, spread deterministically: the four corners and the
    // four edge midpoints first (where wox/woz sign flips bite), then a coprime
    // stride walk across the interior. No randomness.
    const cols = [
      [0, 0], [N - 1, 0], [0, N - 1], [N - 1, N - 1],
      [N >> 1, 0], [0, N >> 1], [N - 1, N >> 1], [N >> 1, N - 1],
    ];
    let cx = 1, cz = 1;
    while (cols.length < 64) {
      cx = (cx + 37) % N; cz = (cz + 53) % N;
      cols.push([cx, cz]);
    }

    for (let ci = 0; ci < cols.length; ci++) {
      const [x, z] = cols[ci];
      u_genColumn(ref, N, -(N >> 1), -(N >> 1), x, z);
      w.genColumn(x, z);
      columnsChecked++;

      for (let y = 0; y < N; y++) {
        const idx = (z * N + y) * N + x;
        const e = ref[idx], a = w.vox[idx];
        if (e !== a) {
          const h = u_blockTop(-(N >> 1) + x, -(N >> 1) + z);
          diff(label, 'genColumn', UP.genColumn,
            `N=${N} column (x=${x}, z=${z}) at y=${y}   [wx=${-(N >> 1) + x}, wz=${-(N >> 1) + z}, blockTop=${h}]`,
            e, a,
            y < h
              ? 'Below the surface: check cave carving, depthBlocks, and the band material.'
              : 'Above the surface: check isleAt, ISLE_AMOUNT and the isleTop lookahead.');
        }
      }

      // Also verify the port wrote nothing outside the column it was asked for.
      // A flattened-index transposition (x and z swapped) reads as plausible
      // terrain in a screenshot and is invisible to a same-column comparison.
      if (ci === 0 && N === 64) {
        const probeZ = (z + 7) % N, probeX = (x + 11) % N;
        for (let y = 0; y < N; y++) {
          const stray = w.vox[(probeZ * N + y) * N + probeX];
          if (stray !== 0) {
            fail(label, [
              `function   genColumn()  (index.html l.${UP.genColumn})`,
              `input      N=${N}, genColumn(${x}, ${z}) was the only call made`,
              `expected   0 at (x=${probeX}, y=${y}, z=${probeZ})`,
              `actual     ${stray}`,
              '',
              'genColumn wrote outside its own column. The volume index must be',
              '(z * N + y) * N + x with x fastest - check for a transposed index.',
            ]);
          }
        }
      }
    }
  }
  ok(`${label} (${columnsChecked} columns across N = ${CASES.join(', ')})`);
}

// ─────────────────── 5. reduceBox ───────────────────
{
  const label = 'reduceBox matches a brute-force pyramid recompute';
  const N = 64;
  const LMAX = Math.log2(N) | 0;

  // Ground truth, computed straight off the voxels with no reference to how
  // either implementation walks the levels: a node is 1 iff any voxel in its
  // 2^L cube is non-zero.
  const brutePyramid = (vox) => {
    const out = [null];
    for (let L = 1; L <= LMAX; L++) {
      const n = N >> L, sz = 1 << L;
      const a = new Uint8Array(n * n * n);
      for (let z = 0; z < n; z++) for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
        let any = 0;
        for (let dz = 0; dz < sz && !any; dz++) {
          for (let dy = 0; dy < sz && !any; dy++) {
            const row = ((z * sz + dz) * N + (y * sz + dy)) * N + x * sz;
            for (let dx = 0; dx < sz; dx++) if (vox[row + dx]) { any = 1; break; }
          }
        }
        a[(z * n + y) * n + x] = any;
      }
      out.push(a);
    }
    return out;
  };

  const comparePyramid = (w, truth, stage) => {
    for (let L = 1; L <= LMAX; L++) {
      const n = N >> L;
      const got = w.lv[L], want = truth[L];
      if (!got || got.length !== want.length) {
        fail(label, [
          `function   reduceBox()  (index.html l.${UP.reduceBox})`,
          `stage      ${stage}`,
          `expected   lv[${L}] to be a Uint8Array of length ${want.length}  ((N>>${L})^3)`,
          `actual     ${got ? `${got.constructor.name} of length ${got.length}` : String(got)}`,
        ]);
      }
      for (let i = 0; i < want.length; i++) {
        if (got[i] !== want[i]) {
          const x = i % n, y = ((i / n) | 0) % n, z = (i / (n * n)) | 0;
          const sz = 1 << L;
          diff(label, 'reduceBox', UP.reduceBox,
            `${stage}: level ${L} node (x=${x}, y=${y}, z=${z}) -> voxels [${x * sz}..${x * sz + sz - 1}] x [${y * sz}..${y * sz + sz - 1}] x [${z * sz}..${z * sz + sz - 1}]`,
            `${want[i]}  (brute force over the 2^${L} cube)`,
            got[i],
            want[i] === 1
              ? 'A solid voxel exists in this node but the pyramid says empty. The GPU\n     traversal will skip straight through it and punch a hole in the terrain.'
              : 'The node is empty but the pyramid says occupied. Traversal descends\n     needlessly - slower, not wrong, but still drift.');
        }
      }
    }
  };

  const w = new World(N);
  if (w.LMAX !== LMAX) {
    fail(label, [`World(${N}).LMAX is ${w.LMAX}, expected log2(N)|0 = ${LMAX}`]);
  }

  // Deterministic fill: sparse noise so most nodes are empty, plus a solid slab
  // and a single isolated voxel. The isolated voxel is the one that catches a
  // level-1 reduce that forgets a corner of the 2x2x2.
  seedCounter(0x5505);
  for (let i = 0; i < 20000; i++) {
    w.voxSet(nextInt(0, N - 1), nextInt(0, N - 1), nextInt(0, N - 1), nextInt(1, 42));
  }
  for (let z = 8; z < 12; z++) for (let y = 3; y < 5; y++) for (let x = 20; x < 40; x++) w.voxSet(x, y, z, 7);
  w.voxSet(N - 1, N - 1, N - 1, 41);
  w.voxSet(0, 0, 0, 1);

  // Full-grid reduce. The box is deliberately out of range on both ends so the
  // clamp at upstream l.108-109 gets exercised rather than assumed.
  const dirtyBefore = Array.isArray(w.dirty) ? w.dirty.length : null;
  w.reduceBox(-9, -9, -9, N + 9, N + 9, N + 9);
  comparePyramid(w, brutePyramid(w.vox), 'full reduce, out-of-range box');

  // Cross-check the brute force against the verbatim upstream reduceBox too, so
  // a bug in this test's ground truth cannot mask a bug in the port.
  {
    const refLv = [null];
    for (let L = 1; L <= LMAX; L++) refLv.push(new Uint8Array((N >> L) ** 3));
    u_reduceBox(w.vox, refLv, N, LMAX, -9, -9, -9, N + 9, N + 9, N + 9);
    const truth = brutePyramid(w.vox);
    for (let L = 1; L <= LMAX; L++) {
      for (let i = 0; i < refLv[L].length; i++) {
        if (refLv[L][i] !== truth[L][i]) {
          fail(label, [
            'The verbatim upstream reduceBox disagrees with the brute-force',
            `recompute at level ${L}, index ${i}. This test is broken, not the port.`,
          ]);
        }
      }
    }
  }

  // Simulate a completed GPU upload before the partial pass. A fresh World
  // starts with fullDirty set, and box tracking is legitimately skipped while
  // that flag is up - the whole texture is going to be re-sent anyway. The
  // interesting case is the steady state after the first upload.
  if (Array.isArray(w.dirty)) { w.dirty.length = 0; }
  w.fullDirty = false;

  // Partial reduce after a local edit, including clearing voxels so nodes have
  // to fall back from 1 to 0. A reduce that only ever ORs upward passes the
  // full-grid case and fails here.
  seedCounter(0x6606);
  for (let i = 0; i < 600; i++) {
    w.voxSet(nextInt(17, 34), nextInt(17, 34), nextInt(17, 34), 0);
  }
  for (let i = 0; i < 200; i++) {
    w.voxSet(nextInt(17, 34), nextInt(17, 34), nextInt(17, 34), nextInt(1, 42));
  }
  w.reduceBox(17, 17, 17, 34, 34, 34);
  comparePyramid(w, brutePyramid(w.vox), 'partial reduce after a local edit');

  // The contract makes reduceBox responsible for telling the GPU side what
  // moved. A pyramid that is right on the CPU and never reaches the texture is
  // invisible to every comparison above. Either answer is acceptable - a box
  // covering the edit, or fullDirty raised - but silence is not.
  if (dirtyBefore === null) {
    fail(label, ['world.dirty is not an array. The contract requires it for GPU uploads.']);
  }
  if (!w.fullDirty) {
    const boxes = Array.isArray(w.dirty) ? w.dirty : null;
    if (!boxes || boxes.length === 0) {
      fail(label, [
        `function   reduceBox()  (index.html l.${UP.reduceBox})`,
        'expected   world.dirty to hold a box covering [17..34]^3, or world.fullDirty raised',
        `actual     ${boxes ? `empty array (length ${boxes.length})` : String(w.dirty)}, fullDirty = false`,
        '',
        'reduceBox must mark its box dirty (see the module contract), otherwise',
        'the pyramid is correct on the CPU and stale on the GPU.',
      ]);
    }
    const covers = boxes.some((b) => b
      && b.x0 <= 17 && b.x1 >= 34 && b.y0 <= 17 && b.y1 >= 34 && b.z0 <= 17 && b.z1 >= 34);
    if (!covers) {
      fail(label, [
        `function   reduceBox()  (index.html l.${UP.reduceBox})`,
        'input      reduceBox(17, 17, 17, 34, 34, 34) on an already-uploaded world',
        'expected   a dirty box covering x/y/z 17..34 inclusive',
        `actual     ${JSON.stringify(boxes)}`,
        '',
        'A dirty box that misses the edit is worse than no box at all: the GPU',
        'uploads the wrong slab and the stale voxels stay on screen.',
      ]);
    }
  }

  ok(`${label} (N=${N}, ${LMAX} levels, full + partial + clear-down)`);
}

// ─────────────────── done ───────────────────
console.log('');
console.log(`${assertionNo}/${assertionNo} assertions held - the port matches upstream terrain.`);
process.exit(0);
