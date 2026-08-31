import Foundation

/// CPU-side wander animation for creature SDF instances (metadata.x == 1).
/// Mirrors the x/z wander and y bob the shader previously applied per ray,
/// plus terrain re-grounding: the foot line tracks TerrainField under the
/// animated x/z, so a figure drifting across a slope never floats above it
/// or sinks into it. The renderer writes this position into the shared SDF
/// instance buffer each frame; the shader keeps only the limb gait phase.
enum CreatureAnimation {
    static func animatedPositionScale(base: SDFInstance, time: Float) -> SIMD4<Float> {
        let phase = base.parameters.y + time * 0.78
        let x = base.positionScale.x + sin(phase) * 2.2
        let z = base.positionScale.z + cos(phase * 0.73) * 1.5
        let footToCenter = base.parameters.x * 0.5 + base.positionScale.w * 0.32
        let y = TerrainField.smoothHeight(x: x, z: z) + footToCenter
            + abs(sin(phase * 1.7)) * 0.22
        return SIMD4<Float>(x, y, z, base.positionScale.w)
    }
}
