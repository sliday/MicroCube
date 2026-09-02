// Player physics, collision, input and editing.
// Port of index.html l.382-431 (PLAYER) and l.521-544 (bootstrap input handlers).
// Pure logic + DOM events: no three.js in this module.

import { CONST } from './world.js';
import { trace } from './trace.js';

const {
  MOVE_SPEED, RUN_MULT, JUMP_V, GRAVITY, EYE, PLAYER_R,
  MOUSE_SENS, REACH, DIG_R, CHUNK, MATS, SHADES,
} = CONST;

// upstream l.181: base = (m) => 1 + m * SHADES
const base = (m) => 1 + m * SHADES;

export class Player {
  constructor(world) {
    this.world = world;
    const N = world.N;
    // upstream P, l.383
    this.x = N / 2 + 0.5;
    this.y = N - 2;
    this.z = N / 2 + 0.5;
    this.vy = 0;
    this.yaw = 0.6;
    this.pitch = -0.15;
    this.onGround = false;
    this.mat = 5;
    this.keys = new Set();
    this.onShift = null;
  }

  // upstream l.385
  collides(x, y, z) {
    const w = this.world;
    const h = EYE + 0.18;
    for (let dy = 0; dy <= h; dy += 0.45) {
      const yy = y + Math.min(dy, h);
      if (w.getVox(Math.floor(x - PLAYER_R), Math.floor(yy), Math.floor(z - PLAYER_R))) return true;
      if (w.getVox(Math.floor(x + PLAYER_R), Math.floor(yy), Math.floor(z - PLAYER_R))) return true;
      if (w.getVox(Math.floor(x - PLAYER_R), Math.floor(yy), Math.floor(z + PLAYER_R))) return true;
      if (w.getVox(Math.floor(x + PLAYER_R), Math.floor(yy), Math.floor(z + PLAYER_R))) return true;
    }
    return false;
  }

  // upstream movePlayer, l.398
  update(dt) {
    const w = this.world;
    const N = w.N;
    const keys = this.keys;

    const sp = MOVE_SPEED * (keys.has('ShiftLeft') ? RUN_MULT : 1);
    let fx = 0, fz = 0;
    if (keys.has('KeyW')) fz += 1;
    if (keys.has('KeyS')) fz -= 1;
    if (keys.has('KeyA')) fx -= 1;
    if (keys.has('KeyD')) fx += 1;
    const l = Math.hypot(fx, fz) || 1;
    const cy = Math.cos(this.yaw), sy = Math.sin(this.yaw);
    const move = (fx || fz) ? sp : 0;
    const vx = ((fz / l) * sy + (fx / l) * cy) * move;
    const vz = ((fz / l) * cy - (fx / l) * sy) * move;
    this.vy -= GRAVITY * dt;
    if (keys.has('Space') && this.onGround) { this.vy = JUMP_V; this.onGround = false; }

    if (this.collides(this.x, this.y, this.z)) {
      for (let k = 0; k < N && this.collides(this.x, this.y, this.z); k++) this.y += 1;
      this.vy = 0;
    }
    const nx = this.x + vx * dt;
    if (!this.collides(nx, this.y, this.z)) this.x = nx;
    const nz = this.z + vz * dt;
    if (!this.collides(this.x, this.y, nz)) this.z = nz;
    const ny = this.y + this.vy * dt;
    if (!this.collides(this.x, ny, this.z)) { this.y = ny; this.onGround = false; }
    else { if (this.vy < 0) this.onGround = true; this.vy = 0; }
    if (this.y < 1) { this.y = 1; this.vy = 0; this.onGround = true; }

    const mid = N / 2, trip = CHUNK * 0.5;
    if (this.x - mid > trip) { w.shiftWorld(CHUNK, 0); this.x -= CHUNK; if (this.onShift) this.onShift(CHUNK, 0); }
    else if (mid - this.x > trip) { w.shiftWorld(-CHUNK, 0); this.x += CHUNK; if (this.onShift) this.onShift(-CHUNK, 0); }
    if (this.z - mid > trip) { w.shiftWorld(0, CHUNK); this.z -= CHUNK; if (this.onShift) this.onShift(0, CHUNK); }
    else if (mid - this.z > trip) { w.shiftWorld(0, -CHUNK); this.z += CHUNK; if (this.onShift) this.onShift(0, -CHUNK); }
  }

  // upstream l.521-544. Returns a detach function that removes every listener added here.
  attach(canvas) {
    const w = this.world;

    const onKeyDown = (e) => {
      this.keys.add(e.code);
      if (e.code === 'Space') e.preventDefault();
      const n = Number(e.key);
      if (n >= 1 && n <= MATS) this.mat = n - 1;
    };
    const onKeyUp = (e) => { this.keys.delete(e.code); };
    const onClick = () => {
      if (document.pointerLockElement !== canvas) canvas.requestPointerLock();
    };
    const onMouseMove = (e) => {
      if (document.pointerLockElement !== canvas) return;
      this.yaw += e.movementX * MOUSE_SENS;
      this.pitch = Math.max(-1.5, Math.min(1.5, this.pitch - e.movementY * MOUSE_SENS));
    };
    const onContextMenu = (e) => { e.preventDefault(); };
    const onMouseDown = (e) => {
      if (document.pointerLockElement !== canvas) return;
      const cyy = Math.cos(this.yaw), syy = Math.sin(this.yaw);
      const cpp = Math.cos(this.pitch), spp = Math.sin(this.pitch);
      const dx = cpp * syy, dy = spp, dz = cpp * cyy;
      const hit = trace(w, this.x, this.y + EYE, this.z, dx, dy, dz, REACH, 0);
      if (!hit) return;

      const px = this.x + dx * hit.t, py = this.y + EYE + dy * hit.t, pz = this.z + dz * hit.t;
      const off = e.button === 0 ? -0.5 : 0.5;
      w.sphereEdit(px + hit.nx * off, py + hit.ny * off, pz + hit.nz * off, DIG_R,
        e.button === 0 ? 0 : base(this.mat) + 1);
    };

    addEventListener('keydown', onKeyDown);
    addEventListener('keyup', onKeyUp);
    canvas.addEventListener('click', onClick);
    addEventListener('mousemove', onMouseMove);
    addEventListener('contextmenu', onContextMenu);
    addEventListener('mousedown', onMouseDown);

    return () => {
      removeEventListener('keydown', onKeyDown);
      removeEventListener('keyup', onKeyUp);
      canvas.removeEventListener('click', onClick);
      removeEventListener('mousemove', onMouseMove);
      removeEventListener('contextmenu', onContextMenu);
      removeEventListener('mousedown', onMouseDown);
      this.keys.clear();
    };
  }
}
