# MicroCube Metal Automatic Fly-Through Design

**Date:** 2026-08-30
**Status:** Draft for written review
**Decision:** Use a renderer-clock tour that yields to the first user interaction.

## Purpose

MicroCube Metal should demonstrate its scene without requiring input. A normal launch starts a 48-second camera tour through the fine voxel terrain, fog creatures, moving lights, glass, SDF forms, and traversal views. The first user interaction stops the tour and gives the user the current camera and render state.

## Goals

- Start the tour on normal interactive launches.
- Show the scene's main visual and technical capabilities in one loop.
- Keep camera motion synchronized with the Metal renderer.
- Transfer control on the first keyboard, pointer, menu, or explainer interaction.
- Preserve deterministic QA captures and benchmarks.
- Respect the macOS Reduce Motion preference.
- Keep the per-frame CPU cost below the renderer's measurement noise.

## Exclusions

- The tour will not alter world geometry, creature motion, lighting formulas, fog density, or ray traversal.
- The tour will not add narration, recorded video, audio, or a separate window.
- The tour will not drive QA captures or benchmarks.
- The tour will not resume after idle time. A user must choose the restart command.

## Launch Policy

`AppDelegate` determines the policy before it creates the renderer.

| Launch condition | Tour behavior |
| --- | --- |
| Normal interactive launch, Reduce Motion off | Start at time zero |
| Normal interactive launch, Reduce Motion on | Keep the opening camera static |
| Any `--qa-*` launch | Disable the tour |
| `--benchmark` or any `--benchmark-*` launch | Disable the tour |
| Startup error or missing Metal device | Disable the tour |

The policy uses existing parsed launch state. It adds no hidden environment variable and no release-only behavior.

## Tour Timeline

The tour lasts 48 seconds and loops without a camera jump. Each waypoint contains a camera position, a look-at target, an evidence view, and a section title. The implementation stores fixed numeric waypoints in code so tests can sample the same path on every Mac.

| Time | View | Subject |
| --- | --- | --- |
| 0 to 8 seconds | FINAL | Opening glide across the fine voxel terrain and hero silhouette |
| 8 to 17 seconds | FINAL | Low pass through fog creatures and moving colored lights |
| 17 to 22 seconds | GRID | Raised view of voxel, SDF, and Gaussian cells sharing the world grid |
| 22 to 27 seconds | PYRAMID | Occupancy hierarchy and empty-space skipping |
| 27 to 32 seconds | RAY STEPS | Ray progress through the traversal slab |
| 32 to 36 seconds | COST | Traversal cost across mixed primitives |
| 36 to 42 seconds | FINAL | Glass, reflection, refraction, and lit fog |
| 42 to 48 seconds | FINAL | SDF fractal orbit that returns to the opening pose |

The path keeps the existing 70-degree field of view. Camera turns use look-at targets instead of interpolated Euler angles. This prevents angle wrapping and keeps each subject centered.

## Camera Sampling

`AutoTourTimeline` is a pure value type. It exposes one operation:

```swift
func sample(at elapsedTime: TimeInterval) -> AutoTourSample
```

`AutoTourSample` contains:

- `cameraPosition`
- `lookAtTarget`
- `evidenceView`
- `sectionID`
- `sectionTitle`

The sampler wraps time into the 48-second interval. It applies a clamped cubic easing curve within each segment, uses Catmull-Rom interpolation for position and look-at target, and derives yaw and pitch from the resulting direction. Hand-tuned control points keep the camera inside the world bounds and outside occupied scene regions.

The renderer passes elapsed renderer time into the sampler. The tour does not integrate frame deltas, so dropped frames cannot change the route or cue timing. Sampling requires a fixed set of vector operations and performs no allocation.

## Components and Ownership

### `AutoTourTimeline`

The timeline owns waypoints, duration, interpolation, section lookup, and evidence-view cues. It has no AppKit or Metal dependency. Unit tests can call it with fixed times.

### `AutoTourController`

The controller owns the state machine:

```text
disabled -> disabled
active -> active | userControlled
userControlled -> active only through Restart Auto Tour
```

The controller records the start time and the last sample. It returns the last camera pose and evidence view when the user takes control.

### `Renderer`

The renderer samples an active tour from its existing frame clock before it builds frame uniforms. While the tour runs, the sample supplies camera position, orientation, and the evidence-view override. On cancellation, the renderer retains the sampled camera pose and removes the override.

The renderer protects tour transitions with its existing state lock. A cancellation request takes effect before the renderer consumes the input snapshot for that frame. A movement key can therefore stop the tour and move the camera during the same frame.

### `MetalInputView`

The view adds an `onUserInteraction` callback. It calls the callback before it processes an event. The callback fires for:

- mouse movement, clicks, drags, and scroll events inside the viewport
- movement keys, Return, Space, and modifier changes
- renderer shortcuts, including evidence-view controls

The callback fires once per active tour. Existing input handling continues after cancellation.

### `AppDelegate`

The delegate selects the launch policy, connects the interaction callback, updates the overlay, and exposes `View > Restart Auto Tour`. Opening the explainer, toggling the HUD, choosing another View command, or moving the window out of key focus also transfers control.

`Restart Auto Tour` clears movement input, releases captured mouse state, restores the first waypoint, and starts at time zero. QA and benchmark launches omit or disable this command.

## Control Handoff

The first qualifying interaction calls `takeControl()` before the app handles the interaction itself.

1. The renderer stops sampling the tour.
2. The renderer keeps the last sampled camera position and orientation.
3. The delegate commits the current tour evidence view to `RenderState`.
4. The original interaction continues through existing input or command handling.

If the triggering interaction selects an evidence view, that selection replaces the committed tour view. The handoff never resets the camera. Resizing the window does not restart the tour.

## HUD and Accessibility

During the tour, the overlay legend shows:

```text
AUTO TOUR · <SECTION TITLE>
MOVE OR CLICK TO TAKE CONTROL
```

After cancellation, the legend returns to the existing controls text. The app posts one VoiceOver announcement when the tour starts and one when the user takes control. Section changes update visible text without posting repeated announcements.

With Reduce Motion enabled, the renderer holds the opening camera pose and uses the normal FINAL view. The overlay reports `AUTO TOUR OFF · REDUCE MOTION`. The restart command stays disabled until the user turns Reduce Motion off and relaunches the app.

## Failure Behavior

An invalid timeline sample, non-finite camera vector, or near-zero look direction ends the tour and keeps the last valid pose. The renderer continues in user-controlled mode and reports the failure through the existing HUD update path. The tour must never terminate the process or block a Metal frame.

## QA and Benchmark Isolation

QA and benchmark launches construct the renderer with the tour disabled. Fixed QA camera, time, feature mask, evidence view, image hashes, GPU samples, and overflow counters retain their current contracts. The capture and benchmark scripts need no new flag.

Release verification must rerun after implementation because normal launch behavior changes. The release gate must also close the existing evidence-binding and one-process verification findings before it can mark the app complete.

## Expected File Scope

- Add `Sources/MicroCubeMetal/Rendering/AutoTour.swift` for timeline and controller types.
- Update `Sources/MicroCubeMetal/Rendering/Renderer.swift` for renderer-clock sampling and handoff.
- Update `Sources/MicroCubeMetal/App/MetalInputView.swift` for interaction notification.
- Update `Sources/MicroCubeMetal/App/AppMain.swift` for launch policy, HUD state, announcements, and restart command.
- Add focused tests under `Tests/MicroCubeMetalTests`.
- Update release documentation after verification.

No shader, scene-data, or package-layout change belongs in this work.

## Test Plan

### Timeline tests

- Samples at 0, 8, 17, 22, 27, 32, 36, 42, and 48 seconds select the intended section and evidence view.
- Samples at 0 and 48 seconds produce matching camera poses within a fixed tolerance.
- Repeated samples at the same time return equal values.
- Position, target, yaw, and pitch remain finite across a dense set of samples.
- The camera remains within world bounds across the loop.

### Controller tests

- A normal eligible launch starts active.
- Cancellation preserves the last sample and changes state once.
- Restart returns to the first sample and resets elapsed time.
- Disabled policies reject restart.

### Input and application tests

- Each supported interaction cancels an active tour before existing handling runs.
- The triggering movement input affects the preserved camera without a reset.
- The explainer and View menu actions cancel the tour.
- Reduce Motion holds the opening camera and disables restart.
- QA and benchmark launch modes never activate the tour.
- HUD and accessibility announcements change only at start and handoff.

### Regression verification

- Run the full XCTest suite.
- Run every GPU correctness probe.
- Build and verify the signed arm64 app.
- Capture the eleven required visual-review rows.
- Run three benchmark passes at 1280 by 800 and 2560 by 1600.
- Review a Metal System Trace and regenerate the completion manifest.

## Acceptance Criteria

1. A normal launch begins the 48-second tour without input.
2. The tour visits every subject and evidence view listed in the timeline.
3. The loop crosses 48 seconds without a visible position or orientation jump.
4. The first supported interaction stops the tour and preserves the current camera pose.
5. The triggering event still performs its normal action.
6. `View > Restart Auto Tour` restarts from the first waypoint.
7. Reduce Motion prevents camera animation.
8. QA captures and benchmarks produce deterministic results with the tour disabled.
9. Unit, integration, GPU, package, visual, benchmark, and trace gates pass.
10. One MicroCube Metal process owns one window after the final packaged launch.
