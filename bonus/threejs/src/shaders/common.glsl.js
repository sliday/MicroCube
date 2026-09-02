// Shared GLSL preamble for the MicroCube three.js port.
//
// Compile-time constants (N, NF, LMAX, PYR_W, PYR_OFF, PAL_LEN) are injected by
// voxel.js ahead of this chunk, so they are used freely here and never defined.
// No #version line: three.js prepends it (GLSL3 for ShaderMaterial).

export const COMMON_GLSL = /* glsl */ `
// The fragment default int precision is mediump, whose guaranteed range is only
// +/-32767. The packed pyramid index reaches ~2.4M at N=256 and ~19.2M at N=512,
// so mediump would wrap silently with no compile error. Declare highp explicitly:
// redundant under three.js ShaderMaterial (its prelude already emits these), but
// required if voxel.js ever assembles with RawShaderMaterial.
precision highp float;
precision highp int;
precision highp usampler3D;
precision highp usampler2D;

uniform highp usampler3D uVol;
uniform highp usampler2D uPyr;
uniform vec3  uPal[PAL_LEN];   // (MATS*SHADES)+1 entries, 0..1 linear-ish, index 0 is air
uniform vec3  uOrigin;         // eye position in voxel space
uniform mat3  uBasis;          // column 0 = right, column 1 = up, column 2 = forward
uniform vec2  uRes;            // render target size in pixels
uniform float uFov;            // tan(FOV_DEG * PI / 360)
uniform float uMaxDist;
uniform float uFogStart;       // fraction, upstream FOG_START
uniform float uFogEnd;
uniform float uAmbient;
uniform vec3  uSun;            // normalised
uniform vec3  uSunColor;       // 0..1
uniform vec3  uFogColor;       // 0..1
uniform vec3  uSkyTop;         // 0..1
uniform vec3  uSkyHor;         // 0..1
uniform float uSunCos;
uniform float uSunGlow;
uniform bool  uShadow;
uniform float uShadowDist;
uniform float uShadowDark;
uniform int   uShadowLod;
uniform bool  uAO;
uniform float uAOStrength;
uniform float uNear;           // camera near, for gl_FragDepth
uniform float uFar;            // camera far
uniform bool  uWriteDepth;     // composite toggle

// Grid bounds test. texelFetch has no clamp-to-edge, and an out-of-range fetch is
// undefined per ES 3.00 8.9, so every escapable coordinate must pass through here
// first. Mirrors the CPU getVox/voxAt split in world.js.
bool inBox(ivec3 p) {
  return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, ivec3(N)));
}

// Unchecked, exactly like the CPU voxAt: callers guarantee 0 <= p < N.
uint voxAt(ivec3 p) {
  return texelFetch(uVol, p, 0).r;
}

// The occupancy pyramid is one flat R8UI 2D texture PYR_W texels wide, not a mip
// chain: level L occupies [PYR_OFF[L], PYR_OFF[L] + (N>>L)^3) in x-fastest order,
// and that global index is unwrapped into (i % PYR_W, i / PYR_W) rows.
// p is already reduced to level L (i.e. the caller passed ivec3(ip >> L)).
uint pyrAt(int L, ivec3 p) {
  int n = N >> L;
  int i = PYR_OFF[L] + (p.z * n + p.y) * n + p.x;
  return texelFetch(uPyr, ivec2(i % PYR_W, i / PYR_W), 0).r;
}

// Clamped so a corrupt voxel byte (0..255) cannot index past the uniform array.
// The array is sized with the same PAL_LEN the clamp uses, so the bound and the
// declaration cannot drift apart into ES 3.00 4.1.9 undefined behaviour.
vec3 palette(uint t) {
  int i = clamp(int(t), 0, PAL_LEN - 1);
  return uPal[i];
}
`;
