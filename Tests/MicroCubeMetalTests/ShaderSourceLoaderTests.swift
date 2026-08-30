import Metal
import XCTest
@testable import MicroCubeMetal

final class ShaderSourceLoaderTests: XCTestCase {
    func testSourceFragmentsLoadInDependencyOrder() throws {
        let source = try ShaderSourceLoader.load()
        let types = try XCTUnwrap(source.range(of: "struct SceneUniforms")?.lowerBound)
        let traversal = try XCTUnwrap(source.range(of: "traceOcclusionExact")?.lowerBound)
        let imageKernel = try XCTUnwrap(source.range(of: "kernel void raycastHybrid")?.lowerBound)

        XCTAssertLessThan(types, traversal)
        XCTAssertLessThan(traversal, imageKernel)
    }

    func testRuntimeLibraryExposesProductionKernels() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: ShaderSourceLoader.load(), options: nil)

        for name in [
            "generateTerrain",
            "reduceOccupancy",
            "buildMixedOccupancy",
            "reduceMixedOccupancy",
            "injectVolumeLighting",
            "raycastHybrid"
        ] {
            XCTAssertNotNil(library.makeFunction(name: name), name)
        }
    }
}
