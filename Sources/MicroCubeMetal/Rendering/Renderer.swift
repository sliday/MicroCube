import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

enum SceneGPUResourceError: Error {
    case allocation(String)
}

struct SceneGPUResources {
    let scene: SceneData
    let mixedOccupancy: MTLTexture
    let volumeLighting: MTLTexture
    let cellHeaders: MTLBuffer
    let cellSDFRefs: MTLBuffer
    let cellGaussianRefs: MTLBuffer
    let sdfInstances: MTLBuffer
    let gaussians: MTLBuffer
    let lights: MTLBuffer
    let materials: MTLBuffer
    let activeVolumeCells: MTLBuffer

    init(device: MTLDevice, scene: SceneData) throws {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r8Uint
        descriptor.width = SceneData.gridDimension
        descriptor.height = SceneData.gridDimension
        descriptor.depth = SceneData.gridDimension
        descriptor.mipmapLevelCount = 7
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let mixedOccupancy = device.makeTexture(descriptor: descriptor) else {
            throw SceneGPUResourceError.allocation("mixed occupancy")
        }
        descriptor.pixelFormat = .rgba16Float
        descriptor.mipmapLevelCount = 1
        guard let volumeLighting = device.makeTexture(descriptor: descriptor) else {
            throw SceneGPUResourceError.allocation("volume lighting")
        }

        self.scene = scene
        self.mixedOccupancy = mixedOccupancy
        self.volumeLighting = volumeLighting
        cellHeaders = try Self.makeBuffer(device: device, values: scene.cellHeaders, name: "cell headers")
        cellSDFRefs = try Self.makeBuffer(device: device, values: scene.cellSDFRefs, name: "SDF references")
        cellGaussianRefs = try Self.makeBuffer(device: device, values: scene.cellGaussianRefs, name: "Gaussian references")
        sdfInstances = try Self.makeBuffer(device: device, values: scene.sdfInstances, name: "SDF instances")
        gaussians = try Self.makeBuffer(device: device, values: scene.gaussians, name: "Gaussians")
        lights = try Self.makeBuffer(device: device, values: scene.lights, name: "lights")
        materials = try Self.makeBuffer(device: device, values: scene.materials, name: "materials")
        activeVolumeCells = try Self.makeBuffer(
            device: device,
            values: scene.activeVolumeCells,
            name: "active volume cells"
        )
    }

    private static func makeBuffer<T>(device: MTLDevice, values: [T], name: String) throws -> MTLBuffer {
        if values.isEmpty {
            guard let buffer = device.makeBuffer(length: max(1, MemoryLayout<T>.stride), options: .storageModeShared) else {
                throw SceneGPUResourceError.allocation(name)
            }
            return buffer
        }
        return try values.withUnsafeBytes { bytes in
            guard let buffer = device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ) else {
                throw SceneGPUResourceError.allocation(name)
            }
            return buffer
        }
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private enum KeyCode {
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let d: UInt16 = 2
        static let q: UInt16 = 12
        static let w: UInt16 = 13
        static let e: UInt16 = 14
    }

    private enum RendererError: Error {
        case missingShaderSource
        case missingFunction(String)
    }

    private static let worldSize = 512
    private static let initialCameraPosition = SIMD3<Float>(256.5, 112.0, 256.5)
    private static let initialYaw: Float = 0.6
    private static let initialPitch: Float = -0.18

    private let input: InputState
    private let hudUpdate: (String) -> Void
    private let commandQueue: MTLCommandQueue
    private let volumeTexture: MTLTexture
    private let sceneResources: SceneGPUResources
    private let terrainPipeline: MTLComputePipelineState
    private let reductionPipeline: MTLComputePipelineState
    private let mixedBuildPipeline: MTLComputePipelineState
    private let mixedReductionPipeline: MTLComputePipelineState
    private let volumeClearPipeline: MTLComputePipelineState
    private let volumeLightingPipeline: MTLComputePipelineState
    private let raycastPipeline: MTLComputePipelineState
    private let raycastThreadgroupSize: MTLSize
    private let counterBuffers: [MTLBuffer]
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private let stateLock = NSLock()

    private weak var metalView: MTKView?
    private var cameraPosition = Renderer.initialCameraPosition
    private var yaw = Renderer.initialYaw
    private var pitch = Renderer.initialPitch
    private var resetPending = false
    private var renderState = RenderState()
    private var frameIndex: UInt32 = 0
    private var scaleController = RenderScaleController(scale: 0.70, mode: .adaptive)
    private var sceneTime = 0.0
    private var latestCounters: FrameCounters?
    private var counterSlotsInUse = [false, false, false]
    private var drawableSizeDirty = true
    private var lastFrameTime = CACurrentMediaTime()
    private var lastHUDTime = 0.0
    private var smoothedFPS = 0.0
    private var smoothedGPUTimeMS = 0.0

    init?(metalView: MTKView, input: InputState, hudUpdate: @escaping (String) -> Void) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              MemoryLayout<FrameUniforms>.stride == 112,
              MemoryLayout<FrameCounters>.stride == 48 else {
            return nil
        }

        let library: MTLLibrary
        let terrainPipeline: MTLComputePipelineState
        let reductionPipeline: MTLComputePipelineState
        let mixedBuildPipeline: MTLComputePipelineState
        let mixedReductionPipeline: MTLComputePipelineState
        let volumeClearPipeline: MTLComputePipelineState
        let volumeLightingPipeline: MTLComputePipelineState
        let raycastPipeline: MTLComputePipelineState
        do {
            library = try Renderer.makeLibrary(device: device)
            terrainPipeline = try Renderer.makePipeline(name: "generateTerrain", library: library, device: device)
            reductionPipeline = try Renderer.makePipeline(name: "reduceOccupancy", library: library, device: device)
            mixedBuildPipeline = try Renderer.makePipeline(name: "buildMixedOccupancy", library: library, device: device)
            mixedReductionPipeline = try Renderer.makePipeline(name: "reduceMixedOccupancy", library: library, device: device)
            volumeClearPipeline = try Renderer.makePipeline(name: "clearVolumeLighting", library: library, device: device)
            volumeLightingPipeline = try Renderer.makePipeline(name: "injectVolumeLighting", library: library, device: device)
            raycastPipeline = try Renderer.makePipeline(name: "raycastHybrid", library: library, device: device)
        } catch {
            return nil
        }

        let volumeDescriptor = MTLTextureDescriptor()
        volumeDescriptor.textureType = .type3D
        volumeDescriptor.pixelFormat = .r8Uint
        volumeDescriptor.width = Renderer.worldSize
        volumeDescriptor.height = Renderer.worldSize
        volumeDescriptor.depth = Renderer.worldSize
        volumeDescriptor.mipmapLevelCount = 10
        volumeDescriptor.storageMode = .private
        volumeDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let volumeTexture = device.makeTexture(descriptor: volumeDescriptor) else {
            return nil
        }
        let sceneResources: SceneGPUResources
        do {
            sceneResources = try SceneGPUResources(device: device, scene: SceneData.makeHero())
        } catch {
            return nil
        }
        let counterBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<FrameCounters>.stride, options: .storageModeShared)
        }
        guard counterBuffers.count == 3 else {
            return nil
        }

        self.input = input
        self.hudUpdate = hudUpdate
        self.commandQueue = commandQueue
        self.volumeTexture = volumeTexture
        self.sceneResources = sceneResources
        self.terrainPipeline = terrainPipeline
        self.reductionPipeline = reductionPipeline
        self.mixedBuildPipeline = mixedBuildPipeline
        self.mixedReductionPipeline = mixedReductionPipeline
        self.volumeClearPipeline = volumeClearPipeline
        self.volumeLightingPipeline = volumeLightingPipeline
        self.raycastPipeline = raycastPipeline
        self.raycastThreadgroupSize = Renderer.make2DThreadgroupSize(for: raycastPipeline)
        self.counterBuffers = counterBuffers
        self.metalView = metalView
        super.init()

        metalView.device = device
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.presentsWithTransaction = false

        guard initializeWorld() else {
            return nil
        }
    }

    func resetCamera() {
        stateLock.lock()
        resetPending = true
        stateLock.unlock()
    }

    func setRenderState(_ state: RenderState) {
        stateLock.lock()
        renderState = state
        if !state.counterAggregationEnabled {
            latestCounters = nil
        }
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSizeDirty = true
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let deltaTime = min(0.05, max(0.0, now - lastFrameTime))
        lastFrameTime = now
        let state = currentRenderState()
        if !state.paused {
            sceneTime += deltaTime
        }
        updateCamera(deltaTime: Float(deltaTime))
        updateFrameRate(deltaTime: deltaTime)
        adjustRenderScaleIfNeeded()
        updateDrawableSize(view)

        guard view.drawableSize.width >= 1.0,
              view.drawableSize.height >= 1.0,
              inFlightSemaphore.wait(timeout: .now() + 0.1) == .success else {
            return
        }

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let counterSlot = Int(frameIndex % 3)
        guard prepareCounterSlot(counterSlot) else {
            inFlightSemaphore.signal()
            return
        }
        let counterBuffer = counterBuffers[counterSlot]
        let aggregatesCounters = state.counterAggregationEnabled

        let width = drawable.texture.width
        let height = drawable.texture.height
        var uniforms = makeUniforms(width: width, height: height, time: sceneTime, state: state)
        var sceneUniforms = makeSceneUniforms()

        guard let volumeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            releaseCounterSlot(counterSlot)
            inFlightSemaphore.signal()
            return
        }
        volumeEncoder.label = "Inject volume lighting"
        volumeEncoder.setComputePipelineState(volumeLightingPipeline)
        volumeEncoder.setTexture(volumeTexture, index: 0)
        volumeEncoder.setTexture(sceneResources.volumeLighting, index: 2)
        volumeEncoder.setBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        volumeEncoder.setBytes(&sceneUniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        volumeEncoder.setBuffer(sceneResources.gaussians, offset: 0, index: 6)
        volumeEncoder.setBuffer(sceneResources.lights, offset: 0, index: 7)
        volumeEncoder.setBuffer(sceneResources.activeVolumeCells, offset: 0, index: 9)
        volumeEncoder.setBuffer(counterBuffer, offset: 0, index: 10)
        let volumeThreadWidth = min(
            volumeLightingPipeline.threadExecutionWidth,
            volumeLightingPipeline.maxTotalThreadsPerThreadgroup
        )
        volumeEncoder.dispatchThreadgroups(
            MTLSize(
                width: (sceneResources.scene.activeVolumeCells.count + volumeThreadWidth - 1) / volumeThreadWidth,
                height: 1,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(width: volumeThreadWidth, height: 1, depth: 1)
        )
        volumeEncoder.endEncoding()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            releaseCounterSlot(counterSlot)
            inFlightSemaphore.signal()
            return
        }
        encoder.label = "MicroCube raycast"
        encoder.setComputePipelineState(raycastPipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(sceneResources.mixedOccupancy, index: 1)
        encoder.setTexture(sceneResources.volumeLighting, index: 2)
        encoder.setTexture(drawable.texture, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setBytes(&sceneUniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setBuffer(sceneResources.cellHeaders, offset: 0, index: 2)
        encoder.setBuffer(sceneResources.cellSDFRefs, offset: 0, index: 3)
        encoder.setBuffer(sceneResources.cellGaussianRefs, offset: 0, index: 4)
        encoder.setBuffer(sceneResources.sdfInstances, offset: 0, index: 5)
        encoder.setBuffer(sceneResources.gaussians, offset: 0, index: 6)
        encoder.setBuffer(sceneResources.lights, offset: 0, index: 7)
        encoder.setBuffer(sceneResources.materials, offset: 0, index: 8)
        encoder.setBuffer(counterBuffer, offset: 0, index: 10)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + raycastThreadgroupSize.width - 1) / raycastThreadgroupSize.width,
                height: (height + raycastThreadgroupSize.height - 1) / raycastThreadgroupSize.height,
                depth: 1
            ),
            threadsPerThreadgroup: raycastThreadgroupSize
        )
        encoder.endEncoding()

        commandBuffer.label = "MicroCube frame \(frameIndex)"
        commandBuffer.present(drawable)
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            if completedBuffer.gpuEndTime > completedBuffer.gpuStartTime {
                self?.recordGPUTime((completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1_000.0)
            }
            self?.completeCounterSlot(counterSlot, aggregationEnabled: aggregatesCounters)
            semaphore.signal()
        }
        commandBuffer.commit()

        frameIndex &+= 1
        updateHUDIfNeeded(now: now, width: width, height: height, state: state)
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = try ShaderSourceLoader.load()
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        return try device.makeLibrary(source: source, options: options)
    }

    private static func makePipeline(
        name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw RendererError.missingFunction(name)
        }
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = name
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    }

    private static func make2DThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let width = pipeline.threadExecutionWidth
        let height = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width))
        return MTLSize(width: width, height: height, depth: 1)
    }

    private static func make3DThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let width = min(8, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.threadExecutionWidth / width)
        let depth = max(1, min(4, pipeline.maxTotalThreadsPerThreadgroup / (width * height)))
        return MTLSize(width: width, height: height, depth: depth)
    }

    private func initializeWorld() -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let terrainEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        terrainEncoder.label = "Generate terrain"
        terrainEncoder.setComputePipelineState(terrainPipeline)
        terrainEncoder.setTexture(volumeTexture, index: 0)
        terrainEncoder.dispatchThreads(
            MTLSize(width: Renderer.worldSize, height: Renderer.worldSize, depth: 1),
            threadsPerThreadgroup: Renderer.make2DThreadgroupSize(for: terrainPipeline)
        )
        terrainEncoder.endEncoding()

        for destinationLevel in 1..<volumeTexture.mipmapLevelCount {
            guard let source = volumeTexture.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (destinationLevel - 1)..<destinationLevel,
                slices: 0..<1
            ), let destination = volumeTexture.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: destinationLevel..<(destinationLevel + 1),
                slices: 0..<1
            ), let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }

            encoder.label = "Reduce occupancy mip \(destinationLevel)"
            encoder.setComputePipelineState(reductionPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: Renderer.make3DThreadgroupSize(for: reductionPipeline)
            )
            encoder.endEncoding()
        }

        guard let mixedEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        mixedEncoder.label = "Build mixed occupancy"
        mixedEncoder.setComputePipelineState(mixedBuildPipeline)
        mixedEncoder.setTexture(volumeTexture, index: 0)
        mixedEncoder.setTexture(sceneResources.mixedOccupancy, index: 1)
        mixedEncoder.setBuffer(sceneResources.cellHeaders, offset: 0, index: 0)
        mixedEncoder.setBuffer(sceneResources.cellSDFRefs, offset: 0, index: 1)
        mixedEncoder.setBuffer(sceneResources.sdfInstances, offset: 0, index: 2)
        mixedEncoder.dispatchThreads(
            MTLSize(width: 64, height: 64, depth: 64),
            threadsPerThreadgroup: Renderer.make3DThreadgroupSize(for: mixedBuildPipeline)
        )
        mixedEncoder.endEncoding()

        for destinationLevel in 1..<sceneResources.mixedOccupancy.mipmapLevelCount {
            guard let source = sceneResources.mixedOccupancy.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: (destinationLevel - 1)..<destinationLevel,
                slices: 0..<1
            ), let destination = sceneResources.mixedOccupancy.makeTextureView(
                pixelFormat: .r8Uint,
                textureType: .type3D,
                levels: destinationLevel..<(destinationLevel + 1),
                slices: 0..<1
            ), let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }

            encoder.label = "Reduce mixed occupancy mip \(destinationLevel)"
            encoder.setComputePipelineState(mixedReductionPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: destination.width, height: destination.height, depth: destination.depth),
                threadsPerThreadgroup: Renderer.make3DThreadgroupSize(for: mixedReductionPipeline)
            )
            encoder.endEncoding()
        }

        guard let volumeClearEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        volumeClearEncoder.label = "Clear volume lighting"
        volumeClearEncoder.setComputePipelineState(volumeClearPipeline)
        volumeClearEncoder.setTexture(sceneResources.volumeLighting, index: 2)
        volumeClearEncoder.dispatchThreads(
            MTLSize(width: 64, height: 64, depth: 64),
            threadsPerThreadgroup: Renderer.make3DThreadgroupSize(for: volumeClearPipeline)
        )
        volumeClearEncoder.endEncoding()

        commandBuffer.label = "Build MicroCube world"
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    private func currentRenderState() -> RenderState {
        stateLock.lock()
        let state = renderState
        stateLock.unlock()
        return state
    }

    private func prepareCounterSlot(_ slot: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !counterSlotsInUse[slot] else { return false }
        counterSlotsInUse[slot] = true
        counterBuffers[slot].contents().initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<FrameCounters>.stride
        )
        return true
    }

    private func releaseCounterSlot(_ slot: Int) {
        stateLock.lock()
        counterSlotsInUse[slot] = false
        stateLock.unlock()
    }

    private func completeCounterSlot(_ slot: Int, aggregationEnabled: Bool) {
        let counters = counterBuffers[slot].contents()
            .assumingMemoryBound(to: FrameCounters.self).pointee
        stateLock.lock()
        latestCounters = aggregationEnabled ? counters : nil
        counterSlotsInUse[slot] = false
        stateLock.unlock()
    }

    private func updateCamera(deltaTime: Float) {
        stateLock.lock()
        let shouldReset = resetPending
        resetPending = false
        stateLock.unlock()

        if shouldReset {
            cameraPosition = Renderer.initialCameraPosition
            yaw = Renderer.initialYaw
            pitch = Renderer.initialPitch
        }

        let snapshot = input.snapshot()
        yaw += snapshot.mouseDelta.x * 0.0022
        pitch = min(1.5, max(-1.5, pitch - snapshot.mouseDelta.y * 0.0022))

        let horizontalForward = SIMD3<Float>(sin(yaw), 0.0, cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0.0, -sin(yaw))
        var movement = SIMD3<Float>.zero
        if snapshot.keys.contains(KeyCode.w) { movement += horizontalForward }
        if snapshot.keys.contains(KeyCode.s) { movement -= horizontalForward }
        if snapshot.keys.contains(KeyCode.d) { movement += right }
        if snapshot.keys.contains(KeyCode.a) { movement -= right }
        if snapshot.keys.contains(KeyCode.e) { movement.y += 1.0 }
        if snapshot.keys.contains(KeyCode.q) { movement.y -= 1.0 }

        let movementLength = simd_length(movement)
        if movementLength > 0.0 {
            let speed: Float = 18.0 * (snapshot.speedBoost ? 1.9 : 1.0)
            cameraPosition += movement / movementLength * speed * deltaTime
        }

        let minimum: Float = 1.25
        let maximum = Float(Renderer.worldSize) - minimum
        cameraPosition = SIMD3<Float>(
            min(maximum, max(minimum, cameraPosition.x)),
            min(maximum, max(minimum, cameraPosition.y)),
            min(maximum, max(minimum, cameraPosition.z))
        )
    }

    private func makeUniforms(
        width: Int,
        height: Int,
        time: CFTimeInterval,
        state: RenderState
    ) -> FrameUniforms {
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let forward = SIMD3<Float>(cosPitch * sinYaw, sinPitch, cosPitch * cosYaw)
        let right = SIMD3<Float>(cosYaw, 0.0, -sinYaw)
        let up = SIMD3<Float>(-sinPitch * sinYaw, cosPitch, -sinPitch * cosYaw)
        let sun = simd_normalize(SIMD3<Float>(0.42, 0.82, 0.38))
        let aspect = Float(width) / Float(max(1, height))
        let halfFOV = tan(Float(70.0 * .pi / 360.0))

        var options = state.features.rawValue | (state.evidenceView.rawValue << 8) | (1 << 31)
        if state.counterAggregationEnabled {
            options |= 1 << 16
        }
        return FrameUniforms(
            cameraPositionAndTime: SIMD4<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z, Float(time.truncatingRemainder(dividingBy: 4_096.0))),
            cameraForwardAndFOV: SIMD4<Float>(forward.x, forward.y, forward.z, halfFOV),
            cameraRightAndAspect: SIMD4<Float>(right.x, right.y, right.z, aspect),
            cameraUpAndMaxDistance: SIMD4<Float>(up.x, up.y, up.z, 256.0),
            sunDirectionAndAmbient: SIMD4<Float>(sun.x, sun.y, sun.z, 0.42),
            viewportAndOptions: SIMD4<UInt32>(UInt32(width), UInt32(height), frameIndex, options),
            fogAndExposure: SIMD4<Float>(0.83, 1.0, 1.0, Float(scaleController.scale))
        )
    }

    private func makeSceneUniforms() -> SceneUniforms {
        let scene = sceneResources.scene
        return SceneUniforms(
            counts: SIMD4<UInt32>(
                UInt32(scene.sdfInstances.count),
                UInt32(scene.gaussians.count),
                UInt32(scene.lights.count),
                UInt32(scene.materials.count)
            ),
            grid: SIMD4<UInt32>(64, 8, 6, UInt32(scene.activeVolumeCells.count)),
            fog: SIMD4<Float>(0.018, 0.62, 0, 0),
            budgets: SIMD4<UInt32>(24, 32, 48, 8)
        )
    }

    private func updateFrameRate(deltaTime: CFTimeInterval) {
        guard deltaTime > 0.0 else { return }
        let instantaneousFPS = 1.0 / deltaTime
        smoothedFPS = smoothedFPS == 0.0 ? instantaneousFPS : smoothedFPS * 0.9 + instantaneousFPS * 0.1
    }

    private func recordGPUTime(_ milliseconds: Double) {
        stateLock.lock()
        smoothedGPUTimeMS = smoothedGPUTimeMS == 0.0
            ? milliseconds
            : smoothedGPUTimeMS * 0.85 + milliseconds * 0.15
        stateLock.unlock()
    }

    private func adjustRenderScaleIfNeeded() {
        guard frameIndex > 0, frameIndex % 30 == 0 else { return }
        stateLock.lock()
        let gpuTime = smoothedGPUTimeMS
        stateLock.unlock()
        guard gpuTime > 0.0 else { return }

        let oldScale = scaleController.scale
        scaleController.record(gpuMilliseconds: gpuTime)
        if abs(scaleController.scale - oldScale) >= 0.01 {
            drawableSizeDirty = true
        }
    }

    private func updateDrawableSize(_ view: MTKView) {
        let backingBounds = view.convertToBacking(view.bounds)
        let renderScale = CGFloat(scaleController.scale)
        let desiredSize = CGSize(
            width: max(1.0, floor(backingBounds.width * renderScale)),
            height: max(1.0, floor(backingBounds.height * renderScale))
        )
        guard drawableSizeDirty
                || abs(view.drawableSize.width - desiredSize.width) >= 1.0
                || abs(view.drawableSize.height - desiredSize.height) >= 1.0 else {
            return
        }
        drawableSizeDirty = false
        view.drawableSize = desiredSize
    }

    private func updateHUDIfNeeded(
        now: CFTimeInterval,
        width: Int,
        height: Int,
        state: RenderState
    ) {
        guard now - lastHUDTime >= 0.25 else { return }
        lastHUDTime = now
        stateLock.lock()
        let gpuTime = smoothedGPUTimeMS
        let counters = latestCounters
        stateLock.unlock()
        hudUpdate(HUDState(
            renderState: state,
            framesPerSecond: smoothedFPS,
            gpuMilliseconds: gpuTime,
            drawableWidth: width,
            drawableHeight: height,
            renderScale: scaleController.scale,
            counters: state.counterAggregationEnabled ? counters : nil
        ).text)
    }
}
