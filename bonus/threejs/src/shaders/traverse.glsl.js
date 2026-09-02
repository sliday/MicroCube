// GLSL hierarchical DDA — a line-by-line port of index.html l.295-380 (RAYCAST).
//
// Every deviation from upstream is a GLSL necessity and is marked DEVIATION with
// the reason. Reviewers diffing this against src/trace.js should find nothing else.
//
// PRECONDITIONS supplied by the assembling shader (voxel.js) and common.glsl.js:
//   - `precision highp float;` and `precision highp int;` must be in effect.
//     The 1e30 / -1e30 sentinels below overflow mediump float (ES 3.00 guarantees
//     only +/-2^14 there), and the pyramid index inside pyrAt() overflows mediump
//     int at N >= 64. three.js's ShaderMaterial prelude emits both; pin them anyway.
//   - #defines: N, NF, LMAX, PYR_W, PYR_OFF, PAL_LEN.
//   - from common.glsl.js: inBox(ivec3), voxAt(ivec3), pyrAt(int, ivec3).
//     pyrAt takes the coordinate ALREADY shifted to level L and owns the
//     PYR_OFF lookup and the 2D unpack, so no dynamic const-array index here.

export const TRAVERSE_GLSL = `
// Outer DDA step cap. Upstream l.353 uses 20000, which is CPU paranoia: on the GPU
// that is 20000 dependent texture fetches per pixel on any driver that does not
// early-out. The theoretical bound for a hierarchical DDA over an N-grid is 3N
// level-0 cells (one crossing per axis-plane, N planes, 3 axes) = 768 at N=256.
// Measured worst case over empty / grazing-plane / checkerboard / sparse-pillar
// worlds: 92 steps at N=64, 363 at N=256, 724 at N=512 — always a ray grazing just
// above a flat surface, where descend/ascend churn peaks. That is ~18% of 8*N at
// every N, so this cap carries ~5.6x headroom and derives from the same N every
// other constant derives from. webgpu.html l.700 picked 4096 at N=512, the same
// number. Override in the prelude to tune.
#ifndef TRACE_MAX_STEPS
#define TRACE_MAX_STEPS (8 * N)
#endif

const float EPS = 1e-5;                     // upstream l.297

struct Hit { bool hit; float t; ivec3 v; int axis; uint type; vec3 n; };

// upstream l.332-343
bool clipBox(vec3 o, vec3 d, out float t0, out float t1) {
  // Written before any early return: GLSL leaves unwritten out-params undefined.
  t0 = 0.0;
  t1 = 1e9;                                 // upstream l.333, already finite. Do NOT
                                            // swap this for uMaxDist: the parallel-axis
                                            // branch legitimately leaves t1 at 1e9.
  float a, b, q;

  // 1e-12 is upstream's parallel threshold (l.334). In float32 1.0/1e-12 = 1e12,
  // far inside range, so it is safe as-is. Raising it "for float32" would
  // misclassify near-axis rays and punch a seam through screen centre.
  // The bound is '> NF', not '>= NF' (upstream l.334/336/338): a ray sitting
  // exactly on the far face is accepted here and rejected by the l.355 test below.
  if (abs(d.x) < 1e-12) {
    if (o.x < 0.0 || o.x > NF) return false;
  } else {
    a = -o.x / d.x; b = (NF - o.x) / d.x;
    if (a > b) { q = a; a = b; b = q; }
    if (a > t0) t0 = a;
    if (b < t1) t1 = b;
  }
  if (abs(d.y) < 1e-12) {
    if (o.y < 0.0 || o.y > NF) return false;
  } else {
    a = -o.y / d.y; b = (NF - o.y) / d.y;
    if (a > b) { q = a; a = b; b = q; }
    if (a > t0) t0 = a;
    if (b < t1) t1 = b;
  }
  if (abs(d.z) < 1e-12) {
    if (o.z < 0.0 || o.z > NF) return false;
  } else {
    a = -o.z / d.z; b = (NF - o.z) / d.z;
    if (a > b) { q = a; a = b; b = q; }
    if (a > t0) t0 = a;
    if (b < t1) t1 = b;
  }

  if (t1 <= t0) return false;               // upstream l.340, tested on UNCLAMPED t0
  if (t0 < 0.0) t0 = 0.0;                   // upstream l.341, clamped only after.
                                            // Order matters: clamping first would
                                            // accept rays that should return sky.
  return true;
}

// upstream l.299-310. Exit t of the node the ray currently occupies, computed from
// the node's own planes so no step error accumulates.
float exitFast(vec3 o, vec3 invd, float size, ivec3 i, out int axis) {
  vec3 b = vec3(i) * size;
  // DEVIATION: upstream l.301 seeds with Infinity; GLSL ES 3.00 has no Infinity
  // literal and constant-folding 1.0/0.0 is rejected by several drivers. Every real
  // exit t here is bounded by the world diagonal (< 2N), so a finite 1e30 sentinel
  // compares identically. Needs highp float.
  vec3 t = vec3(1e30);
  if (invd.x > 0.0) t.x = (b.x + size - o.x) * invd.x; else if (invd.x < 0.0) t.x = (b.x - o.x) * invd.x;
  if (invd.y > 0.0) t.y = (b.y + size - o.y) * invd.y; else if (invd.y < 0.0) t.y = (b.y - o.y) * invd.y;
  if (invd.z > 0.0) t.z = (b.z + size - o.z) * invd.z; else if (invd.z < 0.0) t.z = (b.z - o.z) * invd.z;
  float best = t.x; axis = 0;
  if (t.y < best) { best = t.y; axis = 1; }
  if (t.z < best) { best = t.z; axis = 2; }
  return best;                              // upstream l.308 also writes st.axis here,
                                            // but snapHit l.319 always overwrites it
                                            // before l.373 reads it, so that write is
                                            // dead on the hit path. Returned for the
                                            // coarse (stopL) path, which mirrors the
                                            // shared-st behaviour and reads nothing.
}

// upstream l.312-330. The hierarchical DDA can land INSIDE a solid region (it entered
// an occupied coarse node and descended to a voxel that is not the first solid voxel
// along the ray). Walk backward along the entry axis while the neighbour is also
// solid, so the reported face is the exterior one.
// 'd' is unused: upstream derives the step sign from idx1 (l.316-318, l.322-324),
// whose sign matches d's. Kept to match the frozen signature.
void snapHit(vec3 o, vec3 invd, vec3 d, float t0, inout ivec3 iv, out float t, out int axis) {
  ivec3 v = iv;
  // Dead init: upstream's st.t is written on every first iteration (l.320 or l.321),
  // and the loop always runs. Present only so the out-param is never undefined.
  t = t0;
  axis = 0;
  // 4 is upstream's count (l.314): a quality/perf tradeoff, not a correctness bound.
  // The overshoot is bounded by the level-1 block size in practice. Fewer leaves
  // scattered interior normals on grazing surfaces; more is wasted work.
  for (int k = 0; k < 4; k++) {
    // DEVIATION: -Infinity -> -1e30, same reason as exitFast.
    float tb = -1e30;
    int ax = 0;
    if (invd.x != 0.0) tb = (float(invd.x > 0.0 ? v.x : v.x + 1) - o.x) * invd.x;
    if (invd.y != 0.0) { float ty = (float(invd.y > 0.0 ? v.y : v.y + 1) - o.y) * invd.y; if (ty > tb) { tb = ty; ax = 1; } }
    if (invd.z != 0.0) { float tz = (float(invd.z > 0.0 ? v.z : v.z + 1) - o.z) * invd.z; if (tz > tb) { tb = tz; ax = 2; } }
    axis = ax;                              // upstream l.319: written every iteration,
                                            // including ones that then break
    // 1e-9 is below float32 resolution for any t0 > 1e-2, so this degenerates to
    // 'tb <= t0'. Harmless for a "did we walk backwards" test. Do not "fix" it to a
    // float32-meaningful epsilon: that changes which faces snap.
    if (tb <= t0 + 1e-9) { t = t0; break; }
    t = tb;
    // upstream l.322-324 recomputes all three components; the two off-axis ones
    // subtract 0, so this if/else is identical.
    ivec3 n = v;
    if (ax == 0) n.x = v.x - (invd.x > 0.0 ? 1 : -1);
    else if (ax == 1) n.y = v.y - (invd.y > 0.0 ? 1 : -1);
    else n.z = v.z - (invd.z > 0.0 ? 1 : -1);
    if (!inBox(n)) break;                   // upstream l.325. Reachable at the world
                                            // boundary after every shiftWorld, and it
                                            // is what keeps the voxAt below in range —
                                            // texelFetch out of range is undefined.
    if (voxAt(n) == 0u) break;              // upstream l.326
    v = n;
  }
  iv = v;                                   // upstream l.329
}

// upstream l.345-380. stopL > 0 means "coarse ray, only the fact of an obstruction
// matters". Self-contained: no mutable globals, so it is safe to call twice from one
// fragment (primary ray, then shadow ray) without the second clobbering the first.
Hit trace(vec3 o, vec3 d, float tMax, int stopL) {
  Hit h;
  // upstream l.346 zero-inits st before clipBox. Upstream's caller only reads st
  // inside the 'if(trace(...))' branch so it does not matter there; a struct-returning
  // port must keep it or a missed ray shades with the previous ray's leftovers.
  h.hit = false; h.t = 0.0; h.v = ivec3(0); h.axis = 0; h.type = 0u; h.n = vec3(0.0);

  float clipT0, clipT1;
  if (!clipBox(o, d, clipT0, clipT1)) return h;   // upstream l.347

  float t = clipT0;                         // upstream l.348
  float t1 = clipT1;                        // upstream l.349
  if (tMax < t1) t1 = tMax;                 // upstream l.350

  vec3 invd = vec3(                         // upstream l.351
    d.x != 0.0 ? 1.0 / d.x : 0.0,
    d.y != 0.0 ? 1.0 / d.y : 0.0,
    d.z != 0.0 ? 1.0 / d.z : 0.0);

  // L is declared OUTSIDE the loop (upstream l.352) and persists across iterations.
  // It only climbs back by one after an empty skip (l.366). Resetting it to LMAX each
  // iteration renders the same image 3-5x slower; ascending by more than one skips
  // past geometry and punches holes at grazing angles.
  int L = LMAX;
  int axis = 0;                             // exitFast's axis; see exitFast's note

  for (int guard = 0; guard < TRACE_MAX_STEPS && t < t1; guard++) {
    // DEVIATION (float32): at t = 250 a float32 ulp is ~1.5e-5, larger than EPS, so
    // 't + 1e-5 == t' and the ray stops advancing — a black band at distance, and on
    // an unbounded loop a GPU hang. Upstream gets away with the absolute EPS because
    // JS numbers are float64. Scale it, and use the SAME eps for the sample point
    // (l.354) and the step (l.365) so the two cannot disagree by a ulp and oscillate.
    // Mirrors webgpu.html l.702.
    float eps = max(EPS, t * 1e-5);

    vec3 p = o + d * (t + eps);              // upstream l.354: sample point is nudged,
                                             // t itself is NOT advanced here
    if (any(lessThan(p, vec3(0.0))) || any(greaterThanEqual(p, vec3(NF)))) break;   // upstream l.355
    // upstream l.356 uses 'px | 0', which is ToInt32 — truncation toward zero, NOT
    // floor. GLSL int() truncates toward zero too, so they agree for both signs.
    // Do not "fix" this to floor(). The bounds test above must stay directly on top
    // of it: it is what guarantees p is in [0, N), where trunc == floor and where the
    // shifts and texelFetches below are in range.
    ivec3 ip = ivec3(p);

    uint v = 0u;
    // upstream l.358-363. Reads the node at the CURRENT L first, then decrements.
    // Reading after the decrement samples the wrong level and the world renders as
    // giant cubes.
    // DEVIATION: upstream's 'for(;;)' relies on 'L === stopL' to stop the descent. In
    // GLSL an unbounded loop may be rejected by tile-based compilers, and if L ever
    // reached -1 then 'ix >> -1' and '1 << -1' are undefined and hang the driver. So:
    // an explicit L == 0 branch, and an exact iteration bound. Behaviour is identical
    // for every stopL the callers pass (0 primary, uShadowLod = 1 shadow), because
    // upstream also never decrements past stopL for those.
    for (int i = 0; i <= LMAX; i++) {
      if (L == 0) { v = voxAt(ip); break; }
      // Shift unsigned: '>>' on a negative signed int is implementation-defined.
      // ip is non-negative by the bounds test above, so this is exact.
      v = pyrAt(L, ivec3(uvec3(ip) >> uvec3(uint(L))));
      if (v == 0u || L == stopL) break;
      L--;
    }

    if (v == 0u) {                           // upstream l.364-367
      // Shift in integer space, then convert. float(ix) / float(sz) * float(sz) is a
      // different value once float32 rounding enters, and the difference lands exactly
      // on the cell boundaries exitFast is most sensitive to.
      uint uL = uint(L);
      int sz = int(1u << uL);
      float e = exitFast(o, invd, float(sz), ivec3(uvec3(ip) >> uvec3(uL)), axis);
      // DEVIATION (float32): upstream l.365 is 't = exitFast(...) + EPS'. The max()
      // guards exitFast returning a t behind the current position due to float32
      // error in (b + size - o) * invd, which would stall the loop. webgpu.html l.716.
      t = max(e, t) + eps;
      L = min(LMAX, L + 1);                  // upstream l.366, ascend by exactly one
      continue;
    }

    // upstream l.369. Must be '> 0', not '>= 0': at stopL 0 the primary ray would take
    // this early-out too and everything would render as PAL[0].
    if (stopL > 0) {
      h.hit = true;
      h.t = t;
      h.axis = axis;                         // mirrors upstream's shared st.axis, which
                                             // still holds exitFast's value here. The
                                             // caller reads only .hit and .t.
      return h;
    }

    // upstream l.370-377
    h.hit = true;
    h.t = t;
    ivec3 hv = ip;
    int snapAxis;
    float snapT;
    // clipT0, not t: it is snapHit's backward-walk floor and stays live for the whole
    // trace. Passing t instead lets the walk go arbitrarily far back.
    snapHit(o, invd, d, clipT0, hv, snapT, snapAxis);
    h.t = snapT;
    h.v = hv;
    h.axis = snapAxis;
    h.type = voxAt(h.v);                     // upstream l.372, unchecked there and here:
                                             // safe only via the l.355 -> l.325 chain
    // Face normal from the axis snapHit last computed and the ray's sign
    // (upstream l.373-376). Using exitFast's axis instead lights every surface reached
    // through a coarse node as a side face and the terrain reads flat and dark.
    // Exact +/-1.0 and 0.0 literals so shade.glsl.js's 'n.x != 0.0' test is exact.
    h.n = vec3(0.0);
    if (snapAxis == 0) h.n.x = d.x > 0.0 ? -1.0 : 1.0;
    else if (snapAxis == 1) h.n.y = d.y > 0.0 ? -1.0 : 1.0;
    else h.n.z = d.z > 0.0 ? -1.0 : 1.0;
    return h;
  }

  return h;                                  // upstream l.379: miss, h.hit still false
}
`;
