// Lint-only stand-in for the `three` bare specifier.
//
// src/gpu.js and src/shaders/voxel.js both do `import * as THREE from 'three'`,
// which node cannot resolve (three arrives through the importmap in index.html,
// and this port has no node_modules on purpose). test/glsl-lint.mjs installs a
// resolve hook that points that specifier here, so it can exercise the REAL
// buildVoxelMaterial() instead of re-implementing the concatenation and then
// linting a string that is not what the browser compiles.
//
// Only the members buildVoxelMaterial() touches are stubbed. Nothing here renders,
// nothing here validates: a lint that constructs a fake material learns nothing
// about GL state, and does not claim to.

export class Vector2 {
  constructor(x = 0, y = 0) { this.x = x; this.y = y; }
}

export class Vector3 {
  constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
}

export class Matrix3 {
  constructor() { this.elements = [1, 0, 0, 0, 1, 0, 0, 0, 1]; }
}

export class RawShaderMaterial {
  constructor(params = {}) {
    Object.assign(this, params);
    this.isRawShaderMaterial = true;
    this.userData = {};
  }
}

export const GLSL3 = '300 es';
export const NoBlending = 0;
export const FrontSide = 0;
export const DoubleSide = 2;
export const BackSide = 1;
