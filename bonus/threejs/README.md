# MicroCube three.js port

A browser port of [vseplet/microcube](https://github.com/vseplet/microcube) that keeps the upstream
world and moves the raycaster onto the GPU. The terrain generator, the palette, the player physics
and the controls come straight from `../../index.html`. The hierarchical DDA that upstream runs in a
CPU pixel loop runs here inside a three.js `RawShaderMaterial`, one fragment per ray, reading the
voxel volume and the occupancy pyramid out of two integer textures.

Same seed, same noise, same 43-entry palette, same shading model. The image should match the
reference demo at the same camera pose.

## Run it

The deployed build is at <https://microcube.stas6236.workers.dev>. It serves this port at the root,
upstream's CPU original at `/cpu/`, and upstream's WebGPU variant at `/webgpu/`, so you can compare
the three renderers of the same world.

To run it locally: ES modules will not load over `file://`, so serve the repository and open the
port through http:

```sh
python3 -m http.server 8000
```

Then visit <http://localhost:8000/bonus/threejs/>. Any static server works (`npx serve`,
`caddy file-server`, `ruby -run -e httpd . -p 8000`). three.js 0.185.1 and tweakpane 4.0.5 load from
jsdelivr through the import map in `index.html`, so the first run needs network access. Nothing is
installed and there is no build step.

Startup generates the whole grid on the main thread. At the default 256³ that takes a couple of
seconds behind the `generating world…` splash; at 512³ expect ten or more.

## Controls

| Input | Action |
| --- | --- |
| Click | Capture the mouse |
| Mouse | Look around while captured |
| Escape | Release the mouse |
| W / S | Move forward / backward |
| A / D | Strafe left / right |
| Space | Jump |
| Left Shift | Boost movement speed |
| Left click | Dig a sphere of radius 7 out of the terrain |
| Right click | Place a sphere of the selected material |
| 1 to 9 | Select the material that right click places |

The panel in the top right binds resolution scale, field of view, far distance, the four shadow
knobs, ambient occlusion, and the composite toggle. Upstream exposes the first seven; ambient
occlusion and the composite toggle are new here.

## URL parameters

| Parameter | Effect |
| --- | --- |
| `?n=512` | Grid edge in voxels. `readN()` in `src/main.js` clamps the value to 64..512 and snaps it down to a power of two, so `?n=300` gives 256. Default 256. |
| `?composite=0` | Start with the demo meshes hidden. The panel toggles them back on. Default on. |

`N` drives the world extent, the pyramid depth, the `#define` block in the shader, the far plane
default (`N / 2`) and the slider ranges. The metre constants (`GROUND`, `HILLS`, `ISLE_Y` and the
rest) are absolute, so terrain shape does not change with `N`; a smaller grid holds less of it.

## How this differs from upstream

**Dense voxel storage.** Upstream keeps a sparse pool of 16³ cells (`cellB`, `blocks`, `freeB`,
`allocCell`, `index.html` l.75-105) so an empty world costs little RAM. A 3D texture wants a
contiguous array, so `World` in `src/world.js` holds one `Uint8Array(N*N*N)` and the pool is gone.
Every other piece of world logic (terrain, pyramid reduction, chunk shifting, sphere editing) ports
line for line. `test/fidelity.mjs` compares the result against verbatim upstream code and reports
which upstream line diverged.

**N defaults to 256.** Upstream fixes `N = 512`, which costs 128 MB of dense voxels plus the same
again in VRAM. The default here is 256 (16 MB), and `?n=512` restores the upstream extent.

**GPU traversal.** Upstream marches every pixel in JavaScript and pushes the result through
`putImageData`. This port renders one fullscreen triangle whose fragment shader runs the same
traversal against `usampler3D uVol` and `usampler2D uPyr`. `src/trace.js` keeps the CPU raycaster
anyway: the click ray needs it, and `src/shaders/traverse.glsl.js` is written to be diffed against
it line by line. Every deviation in the GLSL is marked `DEVIATION` with its reason, and all of them
come from GLSL ES 3.00 rather than from a choice about the algorithm (no `Infinity` literal, no
unbounded `for(;;)`, float32 epsilon scaling that float64 does not need).

**Depth composite.** The voxel pass writes `gl_FragDepth` from the hit distance, so ordinary
three.js meshes depth-test against the voxel field. The demo group in `buildComposite()`
puts a torus knot and a ring of 14 emissive cubes 36 voxels along the spawn view direction; walk
behind a hill and the terrain occludes them. The standoff matters: anchored to the spawn column
instead, the props land where the player lands, and the knot spans more of the view than the
camera can see past, so the screen goes flat blue and the voxel pass looks broken. Upstream has no
depth buffer and nothing to composite against.

**Debug handle.** `globalThis.__microcube` exposes the world, player, camera, renderer, textures,
material, scene and render target, plus `step(dt)`, which renders one frame synchronously. Module
scope otherwise leaves no way to inspect a running world, and `step()` drives the demo when
`requestAnimationFrame` is throttled, as Chrome does in a background tab.

## Architecture

- `index.html` owns the canvas, the HUD, the crosshair, the panel container, the boot splash, and
  the import map that pins three.js 0.185.1.
- `src/main.js` owns the URL parameters, the renderer, the render target and its blit pass, the
  camera basis, the per-frame uniform writes, the frame loop, the HUD text, the tweakpane panel, and
  the composite demo group.
- `src/world.js` owns the constants, `hash2`/`vnoise`/`noise3`, the palette, the dense volume, the
  occupancy pyramid, terrain generation, chunk shifting, sphere editing, and the dirty-box list that
  feeds partial uploads. It imports nothing and runs under plain `node`.
- `src/gpu.js` owns `pyramidLayout()`, the `#define` prelude in `shaderDefines()`, and
  `WorldTextures`, which holds the two textures and does full or per-box uploads. The partial path
  drops to raw `texSubImage3D`/`texSubImage2D` and calls `renderer.resetState()` afterwards; any
  driver refusal falls back to a full upload rather than killing the frame.
- `src/player.js` owns movement, collision, pointer lock, key and mouse handling, and the dig/place
  edits. No three.js in this module.
- `src/trace.js` owns the CPU hierarchical DDA (`clipBox`, `exitFast`, `snapHit`, `trace`), used by
  the click ray and used as the reference for the GLSL port.
- `src/shaders/voxel.js` assembles the fragment shader in a frozen order (precision prelude,
  defines, common, traverse, shade), builds the `RawShaderMaterial`, and owns the uniform object.
- `src/shaders/common.glsl.js` declares the uniforms and `inBox`, `voxAt`, `pyrAt`, `palette`.
- `src/shaders/traverse.glsl.js` holds the GLSL twin of `src/trace.js`.
- `src/shaders/shade.glsl.js` holds ambient occlusion, the shadow ray, fog, the sky and sun, `main()`
  and the `gl_FragDepth` write.
- `test/three-stub.mjs` stands in for the `three` bare specifier so `glsl-lint.mjs` can call the real
  `buildVoxelMaterial()` without `node_modules`.

## Data layout

Two textures back the traversal. Both are `R8UI` with nearest filtering, no mipmaps and no colour
space, so three.js never touches the bytes.

```
uVol   usampler3D   N x N x N              one byte per voxel: 0 = air, else palette index
       linear index = (z * N + y) * N + x                     x fastest

uPyr   usampler2D   2048 x ceil(total/2048)  one byte per node: 0 = the whole cube is empty
       level L holds (N>>L)^3 nodes at PYR_OFF[L]
       local  = (z * n + y) * n + x,  n = N >> L
       global = PYR_OFF[L] + local
       texel  = ( global % 2048, global / 2048 )
```

Level 0 is the volume texture, so `PYR_OFF[0]` stays 0 and unused. `pyramidLayout()` in `src/gpu.js`
sums the levels in a loop and `shaderDefines()` emits them as `const int PYR_OFF[LMAX + 1]`, the
same trick `webgpu.html` uses to avoid a texture per level.

At N = 256 the packed image runs 2048 x 1171 and the levels sit here:

```
  L           1        2        3        4        5        6        7        8
  size     128³      64³      32³      16³       8³       4³       2³       1³
  nodes 2097152   262144    32768     4096      512       64        8        1
  offset      0  2097152  2359296  2392064  2396160  2396672  2396736  2396744
```

That is 2,396,745 bytes of pyramid against 16,777,216 bytes of voxels, one seventh, as the
geometric series says. At N = 512 the two become 18.3 MB and 128 MB.

The packed-pyramid index reaches 2.4M at N = 256 and 19.2M at N = 512, past the +/-32767 that ES
3.00 guarantees for `mediump int`. `src/shaders/voxel.js` therefore emits `precision highp int;`
above the `#define` block, not merely above `common.glsl.js`, and `test/glsl-lint.mjs` asserts that
ordering.

## Tests

Both run under plain `node` with no install and no flags. From this directory:

```sh
node test/fidelity.mjs
node test/glsl-lint.mjs
```

`fidelity.mjs` carries a verbatim copy of the upstream terrain code and checks `src/world.js`
against it: 10,000 noise samples, a 128x128 height grid straddling the origin, the palette integers,
64 columns at each of N = 64, 128 and 256, and the pyramid against a brute-force recompute. A
failure prints the upstream line number, the input, both values, and a hint about which slip
produces that difference.

`glsl-lint.mjs` imports the real `buildVoxelMaterial()` through a resolve hook and checks the
assembled fragment source: balanced brackets, no duplicate signatures, no call before its
definition, no `Infinity` or `NaN` literal, no stray `#version`, and the GLSL uniform set matched
against the JS uniform object in both directions. It is a text lint, not a compiler; passing it does
not mean the shader compiles on a real driver. It needs `registerHooks` from `node:module`, so Node
22.15 or newer.

## Upstream

[@vseplet](https://github.com/vseplet) wrote the original
[MicroCube browser demo](https://github.com/vseplet/microcube) and licensed it AGPL-3.0. This port
carries the same licence. The reference `index.html` sits two directories up, and
`test/fidelity.mjs` reproduces part of it under the AGPL so the comparison has ground truth to
compare against.
