// MicroCube / three.js port -- application shell.
//
// Upstream reference: ../../index.html (AGPL-3.0, @vseplet).
// The CPU raycaster is replaced by a GPU ShaderMaterial; everything else
// (terrain, palette, physics, controls, HUD) is a faithful port.

import * as THREE from 'three';

import { CONST, World } from './world.js';
import { WorldTextures, pyramidLayout } from './gpu.js';
import { Player } from './player.js';
import { buildVoxelMaterial } from './shaders/voxel.js';

// ───────────────────────────── URL PARAMS ─────────────────────────────

const params = new URLSearchParams(location.search);

function readN() {
  const raw = Number(params.get('n'));
  if (!Number.isFinite(raw) || raw <= 0) return 256;
  // clamp first, then snap down to a power of two so 300 -> 256, not 512
  const clamped = Math.min(512, Math.max(64, raw));
  const n = 1 << (Math.log2(clamped) | 0);
  // GROUND = M(18) = 72 is absolute (port deviation #2 keeps the metre constants), so
  // below N = 128 the terrain surface sits above the grid ceiling: the whole volume is
  // subsurface rock, the player is ejected out of the box and the demo props are buried.
  if (n < 128) console.warn(`[microcube] ?n=${n}: GROUND is 72 voxels, above a ${n}-tall grid. `
    + 'Expect a solid slab with nothing visible. Use ?n=128 or larger.');
  return n;
}

const N = readN();
const COMPOSITE_DEFAULT = params.get('composite') !== '0';

// ───────────────────────────── DOM ─────────────────────────────

function pick(id) { return document.getElementById(id); }

const hudEl = pick('hud') || document.body.appendChild(Object.assign(document.createElement('div'), { id: 'hud' }));
const panelEl = pick('panel') || document.body.appendChild(Object.assign(document.createElement('div'), { id: 'panel' }));

// index.html already ships a #boot splash. Reuse it rather than stacking a second
// overlay on top: creating our own and removing only that one leaves #boot covering
// the canvas forever, swallowing both the view and the click that takes pointer lock.
const overlay = pick('boot') || document.body.appendChild(document.createElement('div'));
overlay.id = 'boot';
overlay.style.cssText =
  'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;' +
  'background:#0a0c10;color:#dfe6f2;font:14px/1.6 monospace;white-space:pre;text-align:center;z-index:99';
const say = (t) => { overlay.textContent = t; };
const hideOverlay = () => { overlay.remove(); };
// Yield long enough for the splash to repaint between boot steps. Chrome stops
// servicing requestAnimationFrame entirely in a hidden tab, so rAF alone would
// leave boot() parked on "generating world" until the tab is looked at; fall
// back to a timer there.
const nextFrame = () => new Promise((r) => {
  if (document.hidden) { setTimeout(r, 0); return; }
  requestAnimationFrame(() => requestAnimationFrame(r));
});

// ───────────────────────────── RENDER SETTINGS ─────────────────────────────
// Upstream l.55-67. These are the tweakpane-editable ones.

const view = {
  renderScale: 1.0,
  fov: 70,
  maxDist: N / 2,
  fogStart: 0.83,
  fogEnd: 1.0,
  ambient: 0.42,
  shadow: true,
  // Upstream's 100 assumes N = 512. At N = 64 or 128 it exceeds the world itself and
  // lands outside the 'shadow far' slider's own range, which is what put an
  // out-of-bounds value into tweakpane at ?n=64.
  shadowDist: Math.min(100, N / 2),
  shadowDark: 0.45,
  shadowLod: 1,
  ao: true,
  aoStrength: 0.6,
  composite: COMPOSITE_DEFAULT,
};

// ───────────────────────────── BOOT ─────────────────────────────

let renderer, camera, scene, voxelMesh, voxelUniforms;
let rt, blitScene, blitCamera, blitMaterial;
let world, textures, player, layout;
let compositeGroup = null;
let detachInput = null;

let RW = 1, RH = 1;         // render-target size, in pixels
let fps = 0, frameMs = 0, hudT = 0, last = 0;

boot().catch((err) => {
  console.error(err);
  say('failed to start\n\n' + (err && err.message ? err.message : String(err)));
});

async function boot() {
  // 1. world ------------------------------------------------------------
  say(`generating ${N}³ world…`);
  await nextFrame();                       // let the message actually paint

  const t0 = performance.now();
  world = new World(N);
  world.generateAll();
  const genMs = performance.now() - t0;

  say(`uploading ${N}³ voxels…`);
  await nextFrame();

  // 2. renderer / scene -------------------------------------------------
  const existing = pick('cv') || pick('c') || document.querySelector('canvas');
  renderer = new THREE.WebGLRenderer({ antialias: false, canvas: existing || undefined });
  if (!existing) document.body.appendChild(renderer.domElement);
  renderer.domElement.id = renderer.domElement.id || 'cv';

  // Colour management: upstream writes raw 0..255 bytes into an ImageData
  // buffer with no transfer function. The GLSL side writes those same values
  // divided by 255 and never calls linearToOutputTexel, so the sRGB drawing
  // buffer stores the identical byte. Pinned explicitly so a later edit does
  // not silently introduce an encode step.
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NoToneMapping;
  renderer.setPixelRatio(1);               // upstream is a small canvas stretched by CSS
  renderer.autoClear = true;

  scene = new THREE.Scene();

  camera = new THREE.PerspectiveCamera(view.fov, 1, 0.05, view.maxDist);
  // The camera orientation is written directly from the upstream basis every
  // frame (see syncCamera), so autoupdate stays off.
  camera.matrixAutoUpdate = false;

  // 3. textures ---------------------------------------------------------
  layout = pyramidLayout(N);
  textures = new WorldTextures(renderer, world);
  textures.uploadAll();

  // 4. voxel material + fullscreen triangle ------------------------------
  const built = buildVoxelMaterial(world, layout, textures);
  const material = built.material;
  voxelUniforms = built.uniforms;

  // The contract asks for "no depth test, but write depth". In WebGL a
  // disabled depth test also disables the depth WRITE (gl.depthMask is
  // ignored while DEPTH_TEST is off), so the only combination that both
  // accepts every fragment and seeds gl_FragDepth is ALWAYS + depthWrite.
  material.depthTest = true;
  material.depthFunc = THREE.AlwaysDepth;
  material.depthWrite = true;

  const tri = new THREE.BufferGeometry();
  tri.setAttribute('position', new THREE.Float32BufferAttribute([-1, 3, 0, -1, -1, 0, 3, -1, 0], 3));
  tri.setAttribute('uv', new THREE.Float32BufferAttribute([0, 2, 0, 0, 2, 0], 2));
  // Belt and braces: an infinite bounding sphere plus frustumCulled = false.
  tri.boundingSphere = new THREE.Sphere(new THREE.Vector3(0, 0, 0), Infinity);
  tri.computeBoundingSphere = () => {};

  voxelMesh = new THREE.Mesh(tri, material);
  voxelMesh.frustumCulled = false;
  voxelMesh.renderOrder = -1;              // seeds the depth buffer before the meshes
  scene.add(voxelMesh);

  // 5. player -----------------------------------------------------------
  player = new Player(world);
  // Five of attach()'s six listeners live on window, so they outlive any teardown of
  // the three.js side. Keep the detach closure: a second boot() would otherwise
  // double-register, doubling every mouse delta and firing each dig twice.
  if (detachInput) detachInput();
  detachInput = player.attach(renderer.domElement);
  player.onShift = (dx, dz) => {
    // shiftWorld(dx, dz) slides the voxel data by -dx/-dz in grid space, so a
    // mesh anchored to the terrain has to follow it.
    if (compositeGroup) { compositeGroup.position.x -= dx; compositeGroup.position.z -= dz; }
  };

  // 6. composite demo ---------------------------------------------------
  compositeGroup = buildComposite();
  if (view.composite) scene.add(compositeGroup);

  // 7. blit pass --------------------------------------------------------
  buildBlit();
  resize();
  addEventListener('resize', resize);

  // 8. panel + loop -----------------------------------------------------
  await buildPane();
  hideOverlay();

  // Debug handle. Modules are scoped, so without this there is no way to inspect a
  // running world from the console.
  globalThis.__microcube = {
    world, player, camera, renderer, textures, material, view, layout,
    scene, voxelMesh, get compositeGroup() { return compositeGroup; },
    // Render one frame synchronously. Lets a headless check drive the app when
    // requestAnimationFrame is throttled, as it is in a background tab.
    step: (dt = 1 / 60) => frame(last + dt * 1000),
    get rt() { return rt; },
    get blitMaterial() { return blitMaterial; },
  };

  console.info(`[microcube] N=${N}, world generated in ${genMs.toFixed(0)} ms`);
  last = performance.now();
  requestAnimationFrame(frame);
}

// ───────────────────────────── COMPOSITE DEMO ─────────────────────────────
// Emissive cube ring + a torus knot, anchored in world coordinates near spawn.
// They exist to prove the voxel pass writes usable gl_FragDepth: terrain in
// front of them must occlude them.

// The camera matrix is mirrored (see syncCamera), which reverses the screen-space
// winding of every triangle, so gl_FrontFacing reads false on geometrically outward
// faces. three.js only flips gl.frontFace from the OBJECT's matrixWorld determinant,
// never the camera's, and its DOUBLE_SIDED path then runs `normal = normal * faceDirection`
// with faceDirection = -1: the sunlit side would shade as if it faced away. Negating
// the attribute once at build time cancels that second negation. Not BackSide (that
// sets FLIP_SIDED, negating in the vertex shader instead) and not a mirrored group
// scale (three then flips frontFace and the error moves rather than leaves).
function unmirrorNormals(geo) {
  const attr = geo.getAttribute('normal');
  if (!attr) return geo;
  const a = attr.array;
  for (let i = 0; i < a.length; i++) a[i] = -a[i];
  attr.needsUpdate = true;
  return geo;
}

function buildComposite() {
  const g = new THREE.Group();
  g.frustumCulled = false;

  // Stand the props off along the spawn view direction. Anchoring them to the
  // spawn column instead puts them exactly where the player lands: the camera ends
  // up inside the torus knot, whose 18-unit span more than fills a 14-unit view
  // height at that range, and DoubleSide leaves no gap to see past. The screen goes
  // flat knot-blue and the voxel pass looks broken when it is not.
  const STANDOFF = CONST.M(9);
  const cx = Math.max(2, Math.min(N - 3, Math.round((N >> 1) + Math.sin(player.yaw) * STANDOFF)));
  const cz = Math.max(2, Math.min(N - 3, Math.round((N >> 1) + Math.cos(player.yaw) * STANDOFF)));
  let top = 1;
  for (let y = N - 1; y >= 0; y--) if (world.getVox(cx, y, cz)) { top = y; break; }
  const baseY = Math.min(N - 12, top + CONST.M(3));

  const sun = new THREE.Vector3(CONST.SUN[0], CONST.SUN[1], CONST.SUN[2]).normalize();

  // Instanced cubes on a ring.
  const COUNT = 14, RING = CONST.M(3.5), CUBE = CONST.SCALE * 0.75;
  const cubeGeo = unmirrorNormals(new THREE.BoxGeometry(CUBE, CUBE, CUBE));
  // setRGB() with no colour-space argument keeps the numbers in the working
  // space verbatim; the hex constructor would convert sRGB -> Linear-sRGB.
  const cubeMat = new THREE.MeshStandardMaterial({
    color: new THREE.Color().setRGB(0.95, 0.82, 0.45),
    emissive: new THREE.Color().setRGB(0.35, 0.22, 0.05),
    roughness: 0.45,
    metalness: 0.1,
    // The render target carries no colour space, so three.js emits linear values
    // here. DoubleSide because the mirrored camera flips triangle winding and
    // FrontSide would cull away exactly the faces meant to be seen; the normal
    // flip that comes with it is cancelled by unmirrorNormals() above.
    side: THREE.DoubleSide,
  });
  const cubes = new THREE.InstancedMesh(cubeGeo, cubeMat, COUNT);
  cubes.frustumCulled = false;
  const m = new THREE.Matrix4(), q = new THREE.Quaternion(), e = new THREE.Euler();
  const p = new THREE.Vector3(), s = new THREE.Vector3(1, 1, 1);
  for (let i = 0; i < COUNT; i++) {
    const a = (i / COUNT) * Math.PI * 2;
    p.set(Math.cos(a) * RING, Math.sin(a * 3) * CONST.SCALE, Math.sin(a) * RING);
    e.set(a, a * 1.7, 0);
    q.setFromEuler(e);
    cubes.setMatrixAt(i, m.compose(p, q, s));
  }
  cubes.instanceMatrix.needsUpdate = true;
  g.add(cubes);

  const knot = new THREE.Mesh(
    unmirrorNormals(new THREE.TorusKnotGeometry(CONST.M(1.8), CONST.M(0.45), 128, 24)),
    new THREE.MeshStandardMaterial({
      color: new THREE.Color().setRGB(0.55, 0.78, 0.98),
      roughness: 0.28,
      metalness: 0.55,
      side: THREE.DoubleSide,
    }),
  );
  knot.frustumCulled = false;
  knot.position.y = CONST.M(2.4);
  g.add(knot);
  g.userData.knot = knot;
  g.userData.cubes = cubes;

  const dir = new THREE.DirectionalLight(0xffffff, 2.4);
  dir.position.copy(sun).multiplyScalar(CONST.M(30));
  // A DirectionalLight points at its target, which defaults to an Object3D sitting
  // at the world origin. Left alone, the demo meshes would be lit from wherever the
  // group happens to be relative to (0,0,0), not from SUN. Parenting the target to
  // the group puts it at the group's own origin, so the light direction is exactly
  // -sun and the meshes agree with the raymarch's shading.
  dir.target.position.set(0, 0, 0);
  g.add(dir.target);
  g.add(dir);
  g.add(new THREE.AmbientLight(0xffffff, view.ambient));

  g.position.set(cx + 0.5, baseY, cz + 0.5);
  return g;
}

// ───────────────────────────── RENDER TARGET + BLIT ─────────────────────────────

function buildBlit() {
  blitCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  blitMaterial = new THREE.ShaderMaterial({
    glslVersion: THREE.GLSL3,
    uniforms: { tCol: { value: null } },
    vertexShader: /* glsl */`
      out vec2 vUv;
      void main() { vUv = uv; gl_Position = vec4(position, 1.0); }
    `,
    // Straight byte passthrough. No linearToOutputTexel, no pow: the voxel
    // pass already wrote display-ready values (upstream semantics).
    fragmentShader: /* glsl */`
      precision highp float;
      uniform sampler2D tCol;
      in vec2 vUv;
      layout(location = 0) out vec4 fragColor;
      void main() { fragColor = texture(tCol, vUv); }
    `,
    depthTest: false,
    depthWrite: false,
  });

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute([-1, 3, 0, -1, -1, 0, 3, -1, 0], 3));
  geo.setAttribute('uv', new THREE.Float32BufferAttribute([0, 2, 0, 0, 2, 0], 2));
  geo.boundingSphere = new THREE.Sphere(new THREE.Vector3(0, 0, 0), Infinity);
  geo.computeBoundingSphere = () => {};

  const quad = new THREE.Mesh(geo, blitMaterial);
  quad.frustumCulled = false;
  blitScene = new THREE.Scene();
  blitScene.add(quad);
}

function resize() {
  const w = Math.max(1, innerWidth), h = Math.max(1, innerHeight);
  renderer.setSize(w, h, false);

  RW = Math.max(1, Math.round(w * view.renderScale));
  RH = Math.max(1, Math.round(h * view.renderScale));

  // index.html declares body.pixelated #cv { image-rendering: pixelated }.
  // The blit samples the target with NearestFilter, but the browser scales the
  // canvas too: setPixelRatio(1) plus #cv { width: 100vw } means a DPR-2 display
  // upscales 2x, and upstream (index.html l.6) is nearest-filtered unconditionally.
  document.body.classList.toggle('pixelated', view.renderScale < 1 || (window.devicePixelRatio || 1) > 1);

  if (rt) rt.dispose();
  // depthBuffer alone: gl_FragDepth needs a depth attachment, nothing samples it,
  // and a renderbuffer costs less than a texture no pass ever reads.
  rt = new THREE.WebGLRenderTarget(RW, RH, {
    format: THREE.RGBAFormat,
    type: THREE.UnsignedByteType,
    minFilter: THREE.NearestFilter,        // reproduces upstream's image-rendering: pixelated
    magFilter: THREE.NearestFilter,
    colorSpace: THREE.NoColorSpace,        // no transfer function anywhere in the chain
    depthBuffer: true,
    stencilBuffer: false,
    samples: 0,
    generateMipmaps: false,
  });
  blitMaterial.uniforms.tCol.value = rt.texture;

  camera.aspect = RW / RH;
  camera.updateProjectionMatrix();
}

// ───────────────────────────── UNIFORMS ─────────────────────────────

const _origin = new THREE.Vector3();
const _basis = new THREE.Matrix3();
const _res = new THREE.Vector2();
const _sun = new THREE.Vector3();
const _sunColor = new THREE.Vector3();
const _fogColor = new THREE.Vector3();
const _skyTop = new THREE.Vector3();
const _skyHor = new THREE.Vector3();

const _fwd = new THREE.Vector3();
const _right = new THREE.Vector3();
const _up = new THREE.Vector3();
const _back = new THREE.Vector3();
const _eye = new THREE.Vector3();

const missingU = new Set();
function setU(name, value) {
  const u = voxelUniforms[name];
  if (!u) {
    if (!missingU.has(name)) { missingU.add(name); console.warn(`[microcube] uniform ${name} not declared by voxel.js`); }
    return;
  }
  u.value = value;
}

const b255 = (v, out) => out.set(v[0] / 255, v[1] / 255, v[2] / 255);

function updateUniforms() {
  const cy = Math.cos(player.yaw), sy = Math.sin(player.yaw);
  const cp = Math.cos(player.pitch), sp = Math.sin(player.pitch);

  // Upstream l.468-471, verbatim. The raymarch basis is derived here, not
  // from the camera matrix, so the GPU trace stays comparable to the CPU one.
  _fwd.set(cp * sy, sp, cp * cy);
  _right.set(cy, 0, -sy);
  _up.set(-sp * sy, cp, -sp * cy);
  _eye.set(player.x, player.y + CONST.EYE, player.z);

  // Matrix3.set() takes row-major arguments; column 0 must be `right`.
  _basis.set(
    _right.x, _up.x, _fwd.x,
    _right.y, _up.y, _fwd.y,
    _right.z, _up.z, _fwd.z,
  );
  _origin.copy(_eye);

  // Before the setU block: syncCamera() is what pushes view.fov / view.maxDist
  // onto the camera, and uNear / uFar below read camera.near / camera.far. Called
  // afterwards, a slider drag would ship last frame's far plane to the shader and
  // the depth composite would disagree with the mesh pass for one frame.
  syncCamera();

  setU('uOrigin', _origin);
  setU('uBasis', _basis);
  setU('uRes', _res.set(RW, RH));
  setU('uFov', Math.tan(view.fov * Math.PI / 360));
  setU('uMaxDist', view.maxDist);
  setU('uFogStart', view.fogStart);
  setU('uFogEnd', view.fogEnd);
  setU('uAmbient', view.ambient);
  setU('uSun', _sun.set(CONST.SUN[0], CONST.SUN[1], CONST.SUN[2]).normalize());
  setU('uSunColor', b255(CONST.SUN_COLOR, _sunColor));
  setU('uFogColor', b255(CONST.FOG_COLOR, _fogColor));
  setU('uSkyTop', b255(CONST.SKY_TOP, _skyTop));
  setU('uSkyHor', b255(CONST.SKY_HOR, _skyHor));
  setU('uSunCos', CONST.SUN_COS);
  setU('uSunGlow', CONST.SUN_GLOW);
  setU('uShadow', view.shadow);
  setU('uShadowDist', view.shadowDist);
  setU('uShadowDark', view.shadowDark);
  setU('uShadowLod', view.shadowLod | 0);
  setU('uAO', view.ao);
  setU('uAOStrength', view.aoStrength);
  setU('uNear', camera.near);
  setU('uFar', camera.far);
  setU('uWriteDepth', view.composite);
}

// Upstream's basis is right-handed as (right, up, forward): right x up = forward
// exactly, det +1 (checked numerically against l.468-471). The mismatch is that a
// three.js camera looks down -Z and so needs (right, up, BACK), the opposite
// pairing. No proper rotation satisfies both -- Euler(pitch, yaw + PI, 0, 'YXZ')
// reproduces upstream's forward and up but negates right -- so the three vectors go
// straight into the camera matrix and its determinant comes out -1. That mirror is
// what makes the mesh pass land where the raymarch says: for rd = right*a + up*b +
// fwd it yields ndc.x = a / (aspect * tanFov) and ndc.y = b / tanFov, which is what
// shade.glsl.js's main() inverts. Consequences: triangle winding flips (hence
// side: DoubleSide) and gl_FrontFacing inverts (hence unmirrorNormals).
function syncCamera() {
  _back.copy(_fwd).negate();
  camera.matrix.makeBasis(_right, _up, _back);
  camera.matrix.setPosition(_eye);
  camera.matrixWorldNeedsUpdate = true;

  if (camera.far !== view.maxDist || camera.fov !== view.fov) {
    camera.far = view.maxDist;
    camera.fov = view.fov;
    camera.updateProjectionMatrix();
  }
}

// ───────────────────────────── LOOP ─────────────────────────────

const VOL_MB = (N * N * N) / 1048576;

function frame(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  if (dt > 0) fps = fps ? fps * 0.9 + 0.1 / dt : 1 / dt;

  player.update(dt);
  world.pumpPending(CONST.LOAD_BUDGET_MS);
  textures.flushDirty();
  updateUniforms();

  if (compositeGroup && view.composite) {
    compositeGroup.userData.knot.rotation.y += dt * 0.4;
    compositeGroup.userData.knot.rotation.x += dt * 0.17;
    compositeGroup.userData.cubes.rotation.y -= dt * 0.25;
  }

  const t0 = performance.now();
  renderer.setRenderTarget(rt);
  renderer.render(scene, camera);
  renderer.setRenderTarget(null);
  renderer.render(blitScene, blitCamera);
  frameMs = frameMs * 0.9 + (performance.now() - t0) * 0.1;

  if (now - hudT > 250) { hudT = now; updateHud(); }
  requestAnimationFrame(frame);
}

function updateHud() {
  const pyrMB = layout.total / 1048576;
  const mem = performance.memory
    ? ` · heap ${(performance.memory.usedJSHeapSize / 1048576).toFixed(0)} MB`
    : '';
  hudEl.textContent =
    `${RW}×${RH} · ${RW * RH} rays · cube ${N}³ · ${fps | 0} fps · frame ${frameMs.toFixed(1)} ms\n` +
    `voxels ${VOL_MB.toFixed(1)} MB · pyramid ${pyrMB.toFixed(1)} MB${mem}\n`;
}

// ───────────────────────────── TWEAKPANE ─────────────────────────────
// Upstream l.577-585, plus AO and the composite toggle.

async function buildPane() {
  let Pane;
  try {
    ({ Pane } = await import('https://cdn.jsdelivr.net/npm/tweakpane@4.0.5/dist/tweakpane.min.js'));
  } catch (err) {
    console.warn('[microcube] tweakpane unavailable, running without the panel', err);
    return;
  }

  // Upstream hardcodes min 40 / min 8 against a fixed N = 512. Here N comes from the
  // URL, so at ?n=64 'far' would get min 40 with max 32: an inverted range, from a
  // slider whose own default sits outside it. Derive the floor from N instead.
  const farMin = Math.max(8, Math.min(40, N / 4));

  const pane = new Pane({ container: panelEl, title: 'MicroCube' });
  pane.addBinding(view, 'renderScale', { label: 'resolution', min: 0.1, max: 1, step: 0.05 })
    .on('change', resize);
  pane.addBinding(view, 'fov', { label: 'fov', min: 40, max: 110, step: 1 });
  pane.addBinding(view, 'maxDist', { label: 'far', min: farMin, max: N / 2, step: 10 });
  pane.addBinding(view, 'shadow', { label: 'shadows' });
  pane.addBinding(view, 'shadowDist', { label: 'shadow far', min: 8, max: N / 2, step: 8 });
  pane.addBinding(view, 'shadowDark', { label: 'shadow dark', min: 0.1, max: 1, step: 0.05 });
  pane.addBinding(view, 'shadowLod', { label: 'shadow lod', min: 0, max: 4, step: 1 });
  pane.addBinding(view, 'ao', { label: 'ao' });
  pane.addBinding(view, 'aoStrength', { label: 'ao strength', min: 0, max: 1, step: 0.05 });
  pane.addBinding(view, 'composite', { label: 'composite' }).on('change', (ev) => {
    if (!compositeGroup) return;
    if (ev.value) scene.add(compositeGroup); else scene.remove(compositeGroup);
  });
  pane.addButton({ title: '@vseplet' }).on('click', () => open('https://x.com/vseplet', '_blank'));
}
