// ─────────────────────────── RAYCAST ───────────────────────────
//
// The world carries an occupancy mip pyramid: level L stores one byte per 2^L cube,
// non-zero when any voxel inside that cube is solid, so a single read answers "is this
// whole region empty?". A ray walks the pyramid from the coarsest level down: it reads
// the node at its current level and descends while that node is occupied, so it only
// pays for fine detail where detail exists. When a node reads empty the ray jumps
// straight to that node's exit plane, skipping 2^L voxels in one step instead of
// stepping them. After a skip it climbs exactly one level, which lets a ray in open
// sky reach the top in LMAX steps while a ray grazing terrain stays near the surface's
// own level rather than re-descending the full pyramid every voxel.
//
// This is a line-by-line port of index.html l.295-380, kept literal on purpose: the
// GLSL twin in ./shaders/traverse.glsl.js is diffed against this file.

export const EPS = 1e-5;

// Scratch, module-local. exitFast reports the winning axis here (JS has no multiple
// return values and allocating per step would dominate the traversal cost).
const AXIS = { axis: 0 };

// Scratch for trace()'s own clipBox call, so the hot path allocates nothing but the
// returned hit object.
const CLIP_O = [0, 0, 0];
const CLIP_D = [0, 0, 0];
const CLIP_T = { t0: 0, t1: 0 };

const inBox = (N, x, y, z) => (x | y | z) >= 0 && x < N && y < N && z < N;

// Distance along the ray to the exit face of the axis-aligned cube of edge `size`
// whose integer coordinates at that level are (ix, iy, iz). Writes the winning axis
// into `out.axis` (0 = x, 1 = y, 2 = z).
const exitFast = (ox, oy, oz, idx1, idy1, idz1, size, ix, iy, iz, out) => {
  const bx = ix * size, by = iy * size, bz = iz * size;
  let tx = Infinity, ty = Infinity, tz = Infinity;
  if(idx1 > 0) tx = (bx + size - ox) * idx1; else if(idx1 < 0) tx = (bx - ox) * idx1;
  if(idy1 > 0) ty = (by + size - oy) * idy1; else if(idy1 < 0) ty = (by - oy) * idy1;
  if(idz1 > 0) tz = (bz + size - oz) * idz1; else if(idz1 < 0) tz = (bz - oz) * idz1;
  let t = tx, axis = 0;
  if(ty < t) { t = ty; axis = 1; }
  if(tz < t) { t = tz; axis = 2; }
  out.axis = axis;
  return t;
};

// The hierarchical walk can land inside a solid region rather than on its first solid
// voxel, so step backward along the entry axis while the neighbour is also solid.
// Reads and writes hit.vx/vy/vz, writes hit.t and hit.axis.
const snapHit = (world, ox, oy, oz, idx1, idy1, idz1, t0, hit) => {
  const N = world.N;
  let ix = hit.vx, iy = hit.vy, iz = hit.vz;
  for(let k = 0; k < 4; k++) {
    let tb = -Infinity, axis = 0;
    if(idx1 !== 0) tb = ((idx1 > 0 ? ix : ix + 1) - ox) * idx1;
    if(idy1 !== 0) { const ty = ((idy1 > 0 ? iy : iy + 1) - oy) * idy1; if(ty > tb) { tb = ty; axis = 1; } }
    if(idz1 !== 0) { const tz = ((idz1 > 0 ? iz : iz + 1) - oz) * idz1; if(tz > tb) { tb = tz; axis = 2; } }
    hit.axis = axis;
    if(tb <= t0 + 1e-9) { hit.t = t0; break; }
    hit.t = tb;
    const nx = ix - (axis === 0 ? (idx1 > 0 ? 1 : -1) : 0);
    const ny = iy - (axis === 1 ? (idy1 > 0 ? 1 : -1) : 0);
    const nz = iz - (axis === 2 ? (idz1 > 0 ? 1 : -1) : 0);
    if(!inBox(N, nx, ny, nz)) break;
    if(world.voxAt(nx, ny, nz) === 0) break;
    ix = nx; iy = ny; iz = nz;
  }
  hit.vx = ix; hit.vy = iy; hit.vz = iz;
};

// Slab test against the [0, N]^3 world box.
// `o` and `d` are index-addressable triples ([x, y, z], Float32Array, Vector3-like
// with numeric keys). Writes the clipped entry/exit distances into `out.t0` / `out.t1`
// and returns whether the ray touches the box at all. `out.t0` is clamped to 0 after
// the rejection test, so a camera inside the world starts traversing at itself.
export function clipBox(world, o, d, out) {
  const N = world.N;
  const ox = o[0], oy = o[1], oz = o[2];
  const dx = d[0], dy = d[1], dz = d[2];
  let t0 = 0, t1 = 1e9, a, b, q;
  if(Math.abs(dx) < 1e-12) { if(ox < 0 || ox > N) return false; }
  else { a = -ox / dx; b = (N - ox) / dx; if(a > b) { q = a; a = b; b = q; } if(a > t0) t0 = a; if(b < t1) t1 = b; }
  if(Math.abs(dy) < 1e-12) { if(oy < 0 || oy > N) return false; }
  else { a = -oy / dy; b = (N - oy) / dy; if(a > b) { q = a; a = b; b = q; } if(a > t0) t0 = a; if(b < t1) t1 = b; }
  if(Math.abs(dz) < 1e-12) { if(oz < 0 || oz > N) return false; }
  else { a = -oz / dz; b = (N - oz) / dz; if(a > b) { q = a; a = b; b = q; } if(a > t0) t0 = a; if(b < t1) t1 = b; }
  if(t1 <= t0) return false;
  out.t0 = t0 < 0 ? 0 : t0; out.t1 = t1;
  return true;
}

// Returns null on miss, else a fresh { t, vx, vy, vz, axis, type, nx, ny, nz }.
// stopL > 0 means "coarse ray, only the fact of an obstruction matters": the walk
// stops descending at level stopL and returns as soon as any node there is occupied,
// with vx/vy/vz, type and the normal left at 0.
export function trace(world, ox, oy, oz, dx, dy, dz, tMax, stopL = 0) {
  const N = world.N, LMAX = world.LMAX, lv = world.lv;
  const hit = { t: 0, vx: 0, vy: 0, vz: 0, axis: 0, type: 0, nx: 0, ny: 0, nz: 0 };
  CLIP_O[0] = ox; CLIP_O[1] = oy; CLIP_O[2] = oz;
  CLIP_D[0] = dx; CLIP_D[1] = dy; CLIP_D[2] = dz;
  if(!clipBox(world, CLIP_O, CLIP_D, CLIP_T)) return null;
  const clipT0 = CLIP_T.t0;
  let t = clipT0;
  let t1 = CLIP_T.t1;
  if(tMax < t1) t1 = tMax;
  const idx1 = dx !== 0 ? 1 / dx : 0, idy1 = dy !== 0 ? 1 / dy : 0, idz1 = dz !== 0 ? 1 / dz : 0;
  let L = LMAX;
  for(let guard = 0; guard < 20000 && t < t1; guard++) {
    const px = ox + dx * (t + EPS), py = oy + dy * (t + EPS), pz = oz + dz * (t + EPS);
    if(px < 0 || py < 0 || pz < 0 || px >= N || py >= N || pz >= N) break;
    const ix = px | 0, iy = py | 0, iz = pz | 0;
    let v = 0;
    for(;;) {
      const n = N >> L;
      v = L === 0 ? world.voxAt(ix, iy, iz) : lv[L][((iz >> L) * n + (iy >> L)) * n + (ix >> L)];
      if(v === 0 || L === stopL) break;
      L--;
    }
    if(v === 0) {
      t = exitFast(ox, oy, oz, idx1, idy1, idz1, 1 << L, ix >> L, iy >> L, iz >> L, AXIS) + EPS;
      L = Math.min(LMAX, L + 1);
      continue;
    }
    if(stopL > 0) { hit.t = t; hit.axis = AXIS.axis; return hit; }   // coarse ray: only the obstruction matters
    hit.t = t; hit.vx = ix; hit.vy = iy; hit.vz = iz;
    snapHit(world, ox, oy, oz, idx1, idy1, idz1, clipT0, hit);
    hit.type = world.voxAt(hit.vx, hit.vy, hit.vz);
    const a = hit.axis;
    hit.nx = a === 0 ? (dx > 0 ? -1 : 1) : 0;
    hit.ny = a === 1 ? (dy > 0 ? -1 : 1) : 0;
    hit.nz = a === 2 ? (dz > 0 ? -1 : 1) : 0;
    return hit;
  }
  return null;
}
