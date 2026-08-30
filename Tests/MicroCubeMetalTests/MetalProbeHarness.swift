import Foundation
import Metal
import XCTest
@testable import MicroCubeMetal

enum MetalProbeHarness {
    static func makeLibrary(extraSource: String = "") throws -> (MTLDevice, MTLLibrary) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let source = try ShaderSourceLoader.load() + "\n" + extraSource
        return (device, try device.makeLibrary(source: source, options: nil))
    }

    static func makePipeline(
        name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: name)))
    }

    static func writeEvidence(
        _ data: Data,
        named name: String,
        directory: String? = ProcessInfo.processInfo.environment["MICROCUBE_EVIDENCE_DIR"]
    ) throws {
        guard let directory else { return }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: directoryURL.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
