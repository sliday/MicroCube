import XCTest
@testable import MicroCubeMetal

final class SceneABITests: XCTestCase {
    func testSceneUniformsLayoutMatchesMetalABI() {
        XCTAssertEqual(MemoryLayout<SceneUniforms>.size, 64)
        XCTAssertEqual(MemoryLayout<SceneUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<SceneUniforms>.alignment, 16)
        XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.counts), 0)
        XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.grid), 16)
        XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.fog), 32)
        XCTAssertEqual(MemoryLayout<SceneUniforms>.offset(of: \SceneUniforms.budgets), 48)
    }

    func testCellHeaderLayoutMatchesMetalABI() {
        XCTAssertEqual(MemoryLayout<CellHeader>.size, 16)
        XCTAssertEqual(MemoryLayout<CellHeader>.stride, 16)
        XCTAssertEqual(MemoryLayout<CellHeader>.alignment, 4)
        XCTAssertEqual(MemoryLayout<CellHeader>.offset(of: \CellHeader.sdfOffset), 0)
        XCTAssertEqual(MemoryLayout<CellHeader>.offset(of: \CellHeader.gaussianOffset), 4)
        XCTAssertEqual(MemoryLayout<CellHeader>.offset(of: \CellHeader.packedCounts), 8)
        XCTAssertEqual(MemoryLayout<CellHeader>.offset(of: \CellHeader.reserved), 12)
    }

    func testSDFInstanceLayoutMatchesMetalABI() {
        XCTAssertEqual(MemoryLayout<SDFInstance>.size, 96)
        XCTAssertEqual(MemoryLayout<SDFInstance>.stride, 96)
        XCTAssertEqual(MemoryLayout<SDFInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<SDFInstance>.offset(of: \SDFInstance.sweptBoundsMin), 0)
        XCTAssertEqual(MemoryLayout<SDFInstance>.offset(of: \SDFInstance.sweptBoundsMax), 16)
        XCTAssertEqual(MemoryLayout<SDFInstance>.offset(of: \SDFInstance.positionScale), 32)
        XCTAssertEqual(MemoryLayout<SDFInstance>.offset(of: \SDFInstance.rotationQuaternion), 48)
        XCTAssertEqual(MemoryLayout<SDFInstance>.offset(of: \SDFInstance.parameters), 64)
        XCTAssertEqual(MemoryLayout<SDFInstance>.offset(of: \SDFInstance.metadata), 80)
    }

    func testGaussianLightAndMaterialLayoutsMatchMetalABI() {
        XCTAssertEqual(MemoryLayout<Gaussian>.size, 48)
        XCTAssertEqual(MemoryLayout<Gaussian>.stride, 48)
        XCTAssertEqual(MemoryLayout<Gaussian>.alignment, 16)
        XCTAssertEqual(MemoryLayout<Gaussian>.offset(of: \Gaussian.localCenterSigma), 0)
        XCTAssertEqual(MemoryLayout<Gaussian>.offset(of: \Gaussian.colorDensity), 16)
        XCTAssertEqual(MemoryLayout<Gaussian>.offset(of: \Gaussian.motionPhase), 32)

        XCTAssertEqual(MemoryLayout<Light>.size, 32)
        XCTAssertEqual(MemoryLayout<Light>.stride, 32)
        XCTAssertEqual(MemoryLayout<Light>.alignment, 16)
        XCTAssertEqual(MemoryLayout<Light>.offset(of: \Light.positionRadius), 0)
        XCTAssertEqual(MemoryLayout<Light>.offset(of: \Light.colorIntensity), 16)

        XCTAssertEqual(MemoryLayout<Material>.size, 64)
        XCTAssertEqual(MemoryLayout<Material>.stride, 64)
        XCTAssertEqual(MemoryLayout<Material>.alignment, 16)
        XCTAssertEqual(MemoryLayout<Material>.offset(of: \Material.baseColorRoughness), 0)
        XCTAssertEqual(MemoryLayout<Material>.offset(of: \Material.emissionMetalness), 16)
        XCTAssertEqual(MemoryLayout<Material>.offset(of: \Material.opticalAbsorptionIOR), 32)
        XCTAssertEqual(MemoryLayout<Material>.offset(of: \Material.transmissionAcoustic), 48)
    }

    func testFrameCountersLayoutMatchesMetalABI() {
        XCTAssertEqual(MemoryLayout<FrameCounters>.size, 48)
        XCTAssertEqual(MemoryLayout<FrameCounters>.stride, 48)
        XCTAssertEqual(MemoryLayout<FrameCounters>.alignment, 4)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.macroSkips), 0)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.macroDescents), 4)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.voxelSteps), 8)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.sdfSamples), 12)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.gaussianSamples), 16)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.secondaryRays), 20)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.surfaceSunShadows), 24)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.surfaceLocalShadows), 28)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.volumeSunShadows), 32)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.volumeLocalShadows), 36)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.budgetOverflows), 40)
        XCTAssertEqual(MemoryLayout<FrameCounters>.offset(of: \FrameCounters.reserved), 44)
    }

    func testRenderFeatureBitsAndEvidenceValuesMatchShaderContract() {
        XCTAssertEqual(RenderFeatures.shadows.rawValue, 1 << 0)
        XCTAssertEqual(RenderFeatures.lights.rawValue, 1 << 1)
        XCTAssertEqual(RenderFeatures.optics.rawValue, 1 << 2)
        XCTAssertEqual(RenderFeatures.sdf.rawValue, 1 << 3)
        XCTAssertEqual(RenderFeatures.gaussian.rawValue, 1 << 4)
        XCTAssertEqual(RenderFeatures.all.rawValue, 0b1_1111)
        XCTAssertEqual(EvidenceView.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
    }
}
