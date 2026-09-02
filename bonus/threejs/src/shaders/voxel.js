// Shader assembly for the MicroCube three.js port.
//
// Pastes the three GLSL chunks into one fragment shader, pairs it with a
// fullscreen-triangle vertex shader, and hands back a three.js material plus the
// uniform object main.js writes into every frame.
//
// Concatenation order (frozen by the module contract):
//   precision prelude -> #defines (gpu.js shaderDefines) -> common -> traverse -> shade
//
// The precision prelude is NOT decoration. ESSL 3.00 4.5.4 gives the fragment
// language a predeclared `precision mediump int;`, whose guaranteed range is only
// +/-32767, and gpu.js emits `const int PYR_OFF[LMAX + 1] = int[](...)` inside the
// #define block. At N = 256 that array already holds 2097152; at N = 512 it holds
// 19173376. Declared under mediump those constants are out of range with no
// diagnostic, and every pyramid fetch reads the wrong texel. So `precision highp
// int;` has to be in effect BEFORE the defines, not merely before common.glsl.js.
// common.glsl.js repeats the same four statements; repeating a precision statement
// is legal and the second one is a no-op.
//
// Material choice: RawShaderMaterial. three.js prepends only `#version 300 es`
// and two SHADER_TYPE/SHADER_NAME defines to a raw material, so what compiles is
// what is written here. A plain ShaderMaterial would additionally inject
// modelMatrix/viewMatrix/cameraPosition, the colour-space helpers and a pile of
// texture2D aliases -- all unused, and all extra surface for a name collision.
// Verified against three 0.185.1 WebGLProgram.js: with glslVersion === GLSL3
// three emits no `pc_fragColor`, so shade.glsl.js owns the fragment output.

import * as THREE from 'three';

import { COMMON_GLSL } from './common.glsl.js';
import { TRAVERSE_GLSL } from './traverse.glsl.js';
import { SHADE_GLSL } from './shade.glsl.js';
import { shaderDefines } from '../gpu.js';

// Must precede the #define block; see the note above.
export const PRECISION_GLSL = [
  'precision highp float;',
  'precision highp int;',
  'precision highp usampler3D;',
  'precision highp usampler2D;',
  '',
].join('\n');

// A RawShaderMaterial gets no attribute declarations from three.js, so `position`
// is declared here. The geometry main.js builds is the standard oversized triangle
// (-1,3) (-1,-1) (3,-1) already in clip space, so there is no matrix to apply.
export const VERTEX_GLSL = /* glsl */ `
precision highp float;

in vec3 position;

void main() {
  gl_Position = vec4(position, 1.0);
}
`;

/**
 * The fragment source exactly as buildVoxelMaterial compiles it, minus the
 * `#version 300 es` line three.js prepends.
 *
 * Exported so a reviewer (or test/glsl-lint.mjs) can print the assembled string.
 * It takes the world and layout because the prelude is N-dependent: PYR_OFF, N,
 * NF and LMAX all change with grid size, so there is no single constant string to
 * export.
 */
export function buildFragmentSource(world, layout) {
  return PRECISION_GLSL
    + shaderDefines(world, layout)
    + COMMON_GLSL
    + TRAVERSE_GLSL
    + SHADE_GLSL;
}

/**
 * The uniform object, with the exact key set the GLSL declares.
 *
 * Initial values are deliberately neutral rather than copies of CONST: main.js
 * writes every one of these before the first renderer.render() call, and
 * duplicating the palette/sun/fog constants here would create a second place for
 * them to drift. Only uMaxDist is seeded meaningfully, from the world itself.
 */
function buildUniforms(world, textures) {
  return {
    uVol: { value: textures.volumeTex },
    uPyr: { value: textures.pyrTex },
    uPal: { value: world.pal },

    uOrigin: { value: new THREE.Vector3(world.N / 2, world.N / 2, world.N / 2) },
    uBasis: { value: new THREE.Matrix3() },       // identity: right/up/forward = x/y/z
    uRes: { value: new THREE.Vector2(1, 1) },
    uFov: { value: Math.tan(70 * Math.PI / 360) },
    uMaxDist: { value: world.N / 2 },

    uFogStart: { value: 0.83 },
    uFogEnd: { value: 1.0 },
    uAmbient: { value: 0.42 },

    uSun: { value: new THREE.Vector3(0, 1, 0) },
    uSunColor: { value: new THREE.Vector3(1, 1, 1) },
    uFogColor: { value: new THREE.Vector3(0.5, 0.5, 0.5) },
    uSkyTop: { value: new THREE.Vector3(0.5, 0.5, 0.5) },
    uSkyHor: { value: new THREE.Vector3(0.5, 0.5, 0.5) },
    uSunCos: { value: 0.9985 },
    uSunGlow: { value: 0.96 },

    uShadow: { value: true },
    uShadowDist: { value: 100 },
    uShadowDark: { value: 0.45 },
    uShadowLod: { value: 1 },

    uAO: { value: true },
    uAOStrength: { value: 0.6 },

    uNear: { value: 0.05 },
    uFar: { value: world.N / 2 },
    uWriteDepth: { value: true },
  };
}

// common.glsl.js sizes uPal with PAL_LEN, which gpu.js derives from world.pal, so a
// different count no longer overruns the array. 43 (1 + MATS * SHADES) is still the
// only count that matches upstream's palette, and a port that drifts off it is a
// fidelity bug worth naming. Say so once, loudly.
const PAL_ENTRIES = 43;

/**
 * @param {World} world       from ../world.js
 * @param {object} layout     from pyramidLayout() in ../gpu.js
 * @param {WorldTextures} textures
 * @returns {{ material: THREE.RawShaderMaterial, uniforms: object,
 *             fragmentSource: string, vertexSource: string }}
 */
export function buildVoxelMaterial(world, layout, textures) {
  const entries = world.pal ? (world.pal.length / 3) | 0 : 0;
  if (entries !== PAL_ENTRIES) {
    console.warn(
      `[voxel.js] world.pal holds ${entries} colours, not the ${PAL_ENTRIES} upstream builds; `
      + 'uPal is sized to match, so voxel colours will differ from the reference instead.',
    );
  }

  const fragmentSource = buildFragmentSource(world, layout);
  const uniforms = buildUniforms(world, textures);

  const material = new THREE.RawShaderMaterial({
    name: 'MicroCubeVoxel',
    glslVersion: THREE.GLSL3,
    uniforms,
    vertexShader: VERTEX_GLSL,
    fragmentShader: fragmentSource,
    // Per the contract. main.js overrides depthTest to ALWAYS, because WebGL
    // ignores glDepthMask while GL_DEPTH_TEST is disabled -- with depthTest
    // false nothing reaches the depth buffer and the composite meshes lose
    // their occlusion. Kept as specified here so the contract reads true.
    depthTest: false,
    depthWrite: true,
    transparent: false,
    blending: THREE.NoBlending,
    side: THREE.FrontSide,
    toneMapped: false,
  });

  material.userData.fragmentSource = fragmentSource;
  material.userData.vertexSource = VERTEX_GLSL;

  return { material, uniforms, fragmentSource, vertexSource: VERTEX_GLSL };
}
