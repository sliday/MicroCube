# MicroCube Metal

MicroCube Metal is a native macOS 14 port of [vseplet/microcube](https://github.com/vseplet/microcube). It keeps the procedural voxel scene and first-person camera in one AppKit window, then renders the scene with a Metal compute pipeline.

## Requirements

- macOS 14 or newer
- A Metal-capable Mac
- Swift 5.10 or newer command-line tools
- Xcode 15.3 or newer to run the XCTest suite

Check the active toolchain:

```sh
swift --version
```

## Run the app

Build the release app bundle and open its single window:

```sh
./scripts/run.sh
```

Run the executable through Swift Package Manager during development:

```sh
swift run -c release MicroCubeMetal
```

## Controls

| Input | Action |
| --- | --- |
| Click or right-click | Capture the mouse |
| Mouse | Look around while captured |
| Escape | Release the mouse |
| W / S | Move forward / backward |
| A / D | Strafe left / right |
| Q / E | Move down / up |
| Shift | Boost movement speed |
| F | Toggle full screen |
| R | Reset the camera |

## Build a `.app`

```sh
./scripts/build-app.sh
```

The script creates `dist/MicroCube Metal.app`. It performs a release SwiftPM build for the host Mac, installs the `MicroCubeMetal` executable and SwiftPM resource bundles, writes the app metadata, and applies an ad hoc signature when `codesign` exists. Set `SKIP_CODESIGN=1` if you need an unsigned local bundle:

```sh
SKIP_CODESIGN=1 ./scripts/build-app.sh
```

## Tests

```sh
./scripts/test.sh
```

The script selects `/Applications/Xcode.app` when the active command-line tools do not include XCTest. Pass SwiftPM test options after the script name. The tests cover input state, the uniform-buffer layout shared with Metal, exact voxel shadows, and 1-voxel terrain detail on the GPU.

## Architecture

- `Sources/MicroCubeMetal/App/AppMain.swift` owns the application lifecycle, the single `NSWindow`, the `MTKView`, and the text HUD.
- `Sources/MicroCubeMetal/App/MetalInputView.swift` translates AppKit keyboard and mouse events into frame input.
- `Sources/MicroCubeMetal/Rendering/Renderer.swift` owns the Metal resources, camera state, compute dispatch, presentation, adaptive render scale, and HUD timing.
- `Sources/MicroCubeMetal/SharedTypes.swift` defines the CPU-side frame uniforms and input snapshot.
- `Sources/MicroCubeMetal/Shaders/MicroCube.metal` generates terrain, builds occupancy mip levels, and raycasts the scene.

The renderer sends one compute thread to each drawable pixel. GPU traversal reads immutable voxel acceleration data and writes into the `MTKView` drawable, so each frame avoids CPU pixel loops and texture uploads.

## Measure performance

Use the release app for comparisons:

1. Run `./scripts/build-app.sh`, then open `dist/MicroCube Metal.app`.
2. Keep the same window size, display scale, and camera view for each run.
3. Let the adaptive render scale settle before recording the HUD.
4. Record at least 60 seconds and note drawable size, frames per second, GPU frame time, ray count, and render scale.
5. For GPU counters and command-buffer timing, open Instruments, choose **Metal System Trace**, select **MicroCube Metal**, and record the same camera view.

This repository does not publish a performance number because GPU model, drawable size, refresh rate, and camera view change the result.

## Upstream

[@vseplet](https://github.com/vseplet) created the original [microcube browser demo](https://github.com/vseplet/microcube). The upstream `index.html` remains in this repository as the reference implementation.
