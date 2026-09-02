// GLSL: ambient occlusion, shadow, fog, sky/sun, main().
//
// Ports index.html l.433-518 (occAt, vAO, voxAO, and the render-loop body).
// Concatenated AFTER common.glsl.js and traverse.glsl.js by shaders/voxel.js, so
// everything below may use, and must NOT redeclare:
//   uniforms (uVol, uPyr, uPal, uOrigin, uBasis, uRes, uFov, uMaxDist, uFogStart,
//             uFogEnd, uAmbient, uSun, uSunColor, uFogColor, uSkyTop, uSkyHor,
//             uSunCos, uSunGlow, uShadow, uShadowDist, uShadowDark, uShadowLod,
//             uAO, uAOStrength, uNear, uFar, uWriteDepth)          [common.glsl.js]
//   bool inBox(ivec3), uint voxAt(ivec3), vec3 palette(uint)       [common.glsl.js]
//   struct Hit, Hit trace(vec3, vec3, float, int)                  [traverse.glsl.js]
//   #define N NF LMAX PYR_W PYR_OFF PAL_LEN                        [voxel.js prelude]
//
// Precision qualifiers are deliberately absent here. A `precision highp int;` in this
// file would take effect only from this point onward and would not protect the integer
// pyramid indexing in traverse.glsl.js, which is concatenated earlier. The prelude in
// voxel.js owns `precision highp float/int/usampler3D/usampler2D` (research brief H6).

export const SHADE_GLSL = /* glsl */ `
layout(location = 0) out vec4 fragColor;

// ---- ambient occlusion ------------------------------------------------------
// upstream l.434. Bounds-guarded on purpose: voxAO's eight taps reach x-1 .. x+1
// around the hit voxel and legitimately leave the grid on a world-boundary face,
// where an unguarded texelFetch is undefined (research brief H7).
float occAt(ivec3 p) {
  if (!inBox(p)) return 0.0;
  return voxAt(p) != 0u ? 1.0 : 0.0;
}

// upstream l.435: (s1 && s2) ? 0 : (3 - (s1 + s2 + c)).
// s1/s2/c are the 0.0/1.0 output of occAt, so JS truthiness becomes "> 0.0".
float vAO(float s1, float s2, float c) {
  if (s1 > 0.0 && s2 > 0.0) return 0.0;
  return 3.0 - (s1 + s2 + c);
}

// upstream voxAO l.437-452: four vertex-AO terms, bilinearly blended across the face.
float voxAO(vec3 p, vec3 nrm) {
  const float e = 0.5;

  // Math.floor, NOT truncation. p - nrm*0.5 steps a half voxel into the surface and
  // can land just below 0 at the world edge, where int() would give 0 and floor()
  // gives -1; the fu/fv fractions below then leave [0,1] and the blend extrapolates
  // into a bright or black one-voxel rim (research brief H8).
  ivec3 v = ivec3(floor(p - nrm * e));
  ivec3 b = v + ivec3(nrm);           // nrm components are exactly -1.0 / 0.0 / +1.0

  ivec3 uu, ww;
  float fu, fv;
  if (nrm.x != 0.0) {
    uu = ivec3(0, 1, 0); ww = ivec3(0, 0, 1);
    fu = p.y - float(v.y); fv = p.z - float(v.z);
  } else if (nrm.y != 0.0) {
    uu = ivec3(1, 0, 0); ww = ivec3(0, 0, 1);
    fu = p.x - float(v.x); fv = p.z - float(v.z);
  } else {
    uu = ivec3(1, 0, 0); ww = ivec3(0, 1, 0);
    fu = p.x - float(v.x); fv = p.y - float(v.y);
  }

  float sUm = occAt(b - uu),      sUp = occAt(b + uu);
  float sWm = occAt(b - ww),      sWp = occAt(b + ww);
  float cMM = occAt(b - uu - ww), cPM = occAt(b + uu - ww);
  float cMP = occAt(b - uu + ww), cPP = occAt(b + uu + ww);

  float a00 = vAO(sUm, sWm, cMM);
  float a10 = vAO(sUp, sWm, cPM);
  float a01 = vAO(sUm, sWp, cMP);
  float a11 = vAO(sUp, sWp, cPP);

  float ao = ((a00 * (1.0 - fu) + a10 * fu) * (1.0 - fv)
            + (a01 * (1.0 - fu) + a11 * fu) * fv) / 3.0;
  return 1.0 - (1.0 - ao) * uAOStrength;
}

// ---- sky --------------------------------------------------------------------
// upstream l.503-513: vertical gradient, horizon fog wash, sun disk + pow-4 glow.
vec3 skyColor(vec3 d) {
  float k = clamp(d.y * 1.6 + 0.15, 0.0, 1.0);
  vec3 c = uSkyHor + (uSkyTop - uSkyHor) * k;

  float hz = max(0.0, 1.0 - abs(d.y) * 6.0);
  c += (uFogColor - c) * hz;

  float sd = dot(d, uSun);
  // ** 4 as three multiplies. pow(x, 4.0) is undefined for x < 0 in GLSL ES 3.00,
  // and the max(0.0, ...) that guards it upstream is kept here anyway.
  // max() on the denominator: at uSunGlow == 1.0 this is 0/0, and ES 3.00 4.5.1 does
  // not require clamp/min to behave on a NaN, so the result would vary by driver.
  float glow = max(0.0, (sd - uSunGlow) / max(1e-6, 1.0 - uSunGlow));
  glow *= glow; glow *= glow;
  // Hard step, matching upstream's (sd > SUN_COS ? 1 : 0). Not step(), which is >= ,
  // and not smoothstep(): softening it would change the sun silhouette and break parity.
  float disk = sd > uSunCos ? 1.0 : 0.0;
  float lit = min(1.0, disk + glow);
  if (lit > 0.0) c += (uSunColor - c) * lit;
  return c;
}

// ---- surface shading --------------------------------------------------------
// upstream l.490-501.
vec3 shadeHit(Hit h, vec3 ro, vec3 rd) {
  // Copy every live field out of the hit BEFORE the shadow trace runs, mirroring
  // upstream l.490-492. Hit is passed and returned by value here, so the shadow
  // trace cannot clobber it, but the ordering is preserved deliberately.
  vec3  c   = palette(h.type);
  float ht  = h.t;
  vec3  nrm = h.n;
  vec3  hp  = ro + rd * ht;

  float lam = max(0.0, dot(nrm, uSun));
  float k = uAmbient + (1.0 - uAmbient) * lam;

  // upstream l.495: ny > 0 ? 1 : (ny < 0 ? 0.62 : (nx ? 0.82 : 0.9))
  k *= nrm.y > 0.0 ? 1.0
     : (nrm.y < 0.0 ? 0.62
     : (nrm.x != 0.0 ? 0.82 : 0.9));

  if (uAO) k *= voxAO(hp, nrm);

  // upstream l.498: second ray toward the sun from the hit point lifted off the face.
  // Only when lam > 0; a back-facing surface is already dark and the trace is skipped.
  if (uShadow && lam > 0.0) {
    Hit s = trace(hp + nrm * 0.03, uSun, uShadowDist, uShadowLod);
    if (s.hit) k *= uShadowDark;
  }

  vec3 col = c * k;

  float fogA = uMaxDist * uFogStart;
  float fogB = uMaxDist * uFogEnd;
  // Same NaN guard as skyColor's glow: uFogStart == uFogEnd collapses this to 0/0.
  float f = clamp((ht - fogA) / max(1e-6, fogB - fogA), 0.0, 1.0);
  col += (uFogColor - col) * f;
  return col;
}

// ---- entry point ------------------------------------------------------------
void main() {
  // upstream l.480-486. gl_FragCoord is bottom-origin and already at the pixel
  // centre, while upstream's py is top-origin and adds its own +0.5; the two
  // reconcile to (2*fc.y/RH - 1) with no extra half-pixel (research brief H14).
  float aspect = uRes.x / uRes.y;
  float u = (2.0 * gl_FragCoord.x / uRes.x - 1.0) * uFov * aspect;
  float v = (2.0 * gl_FragCoord.y / uRes.y - 1.0) * uFov;

  vec3 rd = normalize(uBasis[0] * u + uBasis[1] * v + uBasis[2]);

  Hit h = trace(uOrigin, rd, uMaxDist, 0);
  vec3 col = h.hit ? shadeHit(h, uOrigin, rd) : skyColor(rd);

  // gl_FragDepth must be written on every path; it is undefined otherwise.
  if (uWriteDepth && h.hit) {
    // View-space depth along the camera forward axis. Clamped to the near plane so a
    // t == 0 hit (camera inside a voxel) cannot divide by zero.
    float zv = max(h.t * dot(rd, uBasis[2]), uNear);
    gl_FragDepth = ((1.0 / zv) - (1.0 / uNear)) / ((1.0 / uFar) - (1.0 / uNear));
  } else {
    gl_FragDepth = 1.0;
  }

  // uPal / uSunColor / uFogColor / uSkyTop / uSkyHor arrive normalised to 0..1, so
  // there is no divide by 255 here. The floor() reproduces upstream's (r|0) channel
  // truncation at l.514 rather than the GPU's round-to-nearest; every value on both
  // branches is already within [0,255] before truncation, so no wrap occurs.
  fragColor = vec4(floor(col * 255.0) / 255.0, 1.0);
}
`;
