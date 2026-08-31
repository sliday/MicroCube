import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

enum SceneGPUResourceError: Error {
    case allocation(String)
}

enum RendererError: Error, LocalizedError {
    case allocation(String)
    case resource(String, String)
    case kernel(String)
    case pipeline(String, String)
    case compiler(String)

    var errorDescription: String? {
        switch self {
        case .allocation(let name):
            "Metal allocation failed for \(name)."
        case .resource(let name, let diagnostic):
            "Metal resource \(name) failed: \(diagnostic)"
        case .kernel(let name):
            "Metal kernel '\(name)' is missing from the runtime library."
        case .pipeline(let name, let diagnostic):
            "Metal pipeline '\(name)' failed: \(diagnostic)"
        case .compiler(let diagnostic):
            "Metal shader compilation failed: \(diagnostic)"
        }
    }
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

struct RendererQAResult {
    let final: Bool
    let failure: String?
    let drawableCapture: QADrawableCapture?
    let gpuMilliseconds: [Double]
    let stepCounters: [String: Int]
    let budgetOverflows: Int
    let commandErrors: Int
    let droppedDrawables: Int
    let semaphoreTimeouts: Int
}

final class Renderer: NSObject, MTKViewDelegate {
    private struct QAExecution {
        let plan: QARenderPlan
        let completion: (RendererQAResult) -> Void
        var submittedFrames = 0
        var gpuMilliseconds: [Double] = []
        var commandErrors = 0
        var droppedDrawables = 0
        var semaphoreTimeouts = 0
    }

    private enum KeyCode {
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let d: UInt16 = 2
        static let q: UInt16 = 12
        static let w: UInt16 = 13
        static let e: UInt16 = 14
    }

    private static let worldSize = 512
    static let initialCameraPosition = SIMD3<Float>(240.75, 117.0, 233.75)
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
    private let autoTourUpdate: (AutoTourSample) -> Void
    private let autoTourFailure: (AutoTourSample) -> Void
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
    private var autoTourController: AutoTourController
    private var presentedAutoTourSectionID: Int?
    private var drawableSizeDirty = true
    private var lastFrameTime = CACurrentMediaTime()
    private var lastHUDTime = 0.0
    private var smoothedFPS = 0.0
    private var smoothedGPUTimeMS = 0.0
    private var qaExecution: QAExecution?

    init(
        metalView: MTKView,
        input: InputState,
        qaScene: QAMode.Scene? = nil,
        autoTourPolicy: AutoTourPolicy = .disabled,
        autoTourUpdate: @escaping (AutoTourSample) -> Void = { _ in },
        autoTourFailure: @escaping (AutoTourSample) -> Void = { _ in },
        hudUpdate: @escaping (String) -> Void
    ) throws {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice() else {
            throw RendererError.resource("Metal device", "No compatible Metal device is available.")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.allocation("command queue")
        }
        guard MemoryLayout<FrameUniforms>.stride == 112 else {
            throw RendererError.resource(
                "FrameUniforms ABI",
                "expected stride 112, found \(MemoryLayout<FrameUniforms>.stride)"
            )
        }
        guard MemoryLayout<FrameCounters>.stride == 48 else {
            throw RendererError.resource(
                "FrameCounters ABI",
                "expected stride 48, found \(MemoryLayout<FrameCounters>.stride)"
            )
        }

        let library: MTLLibrary
        let terrainPipeline: MTLComputePipelineState
        let reductionPipeline: MTLComputePipelineState
        let mixedBuildPipeline: MTLComputePipelineState
        let mixedReductionPipeline: MTLComputePipelineState
        let volumeClearPipeline: MTLComputePipelineState
        let volumeLightingPipeline: MTLComputePipelineState
        let raycastPipeline: MTLComputePipelineState
        library = try Renderer.makeLibrary(device: device)
        terrainPipeline = try Renderer.makePipeline(name: "generateTerrain", library: library, device: device)
        reductionPipeline = try Renderer.makePipeline(name: "reduceOccupancy", library: library, device: device)
        mixedBuildPipeline = try Renderer.makePipeline(name: "buildMixedOccupancy", library: library, device: device)
        mixedReductionPipeline = try Renderer.makePipeline(name: "reduceMixedOccupancy", library: library, device: device)
        volumeClearPipeline = try Renderer.makePipeline(name: "clearVolumeLighting", library: library, device: device)
        volumeLightingPipeline = try Renderer.makePipeline(name: "injectVolumeLighting", library: library, device: device)
        raycastPipeline = try Renderer.makePipeline(name: "raycastHybrid", library: library, device: device)

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
            throw RendererError.allocation("512-cubed occupancy texture")
        }
        let sceneResources: SceneGPUResources
        do {
            let scene = try qaScene.map(Self.makeScene(for:)) ?? SceneData.makeHero()
            sceneResources = try SceneGPUResources(device: device, scene: scene)
        } catch SceneGPUResourceError.allocation(let name) {
            throw RendererError.allocation(name)
        } catch {
            throw RendererError.resource("scene", error.localizedDescription)
        }
        let counterBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<FrameCounters>.stride, options: .storageModeShared)
        }
        guard counterBuffers.count == 3 else {
            throw RendererError.allocation("frame counter buffers")
        }

        self.input = input
        self.hudUpdate = hudUpdate
        self.autoTourUpdate = autoTourUpdate
        self.autoTourFailure = autoTourFailure
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
        self.autoTourController = AutoTourController(
            policy: autoTourPolicy,
            startTime: CACurrentMediaTime()
        )
        self.metalView = metalView
        super.init()

        metalView.device = device
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.presentsWithTransaction = false

        try initializeWorld(terrainFixture: Self.terrainFixture(for: qaScene))
        if let sample = autoTourController.restart(at: CACurrentMediaTime()) {
            applyAutoTourPose(sample)
            presentedAutoTourSectionID = sample.sectionID
        }
    }

    static func makeScene(for qaScene: QAMode.Scene) throws -> SceneData {
        let hero = try SceneData.makeHero()
        switch qaScene {
        case .hero, .mixedFixture:
            return hero
        case .shadowFixture:
            return try SceneData.build(
                sdfInstances: [],
                gaussians: [],
                lights: hero.lights,
                materials: hero.materials
            )
        case .opticsFixture:
            return try SceneData.build(
                sdfInstances: [SceneData.makeOpticsProp()],
                gaussians: [],
                lights: hero.lights,
                materials: hero.materials
            )
        case .fogClear, .fogBlocked, .gaussianFixture:
            return try SceneData.build(
                sdfInstances: [],
                gaussians: hero.gaussians,
                lights: hero.lights,
                materials: hero.materials
            )
        case .fractalFixture:
            return try SceneData.build(
                sdfInstances: [SceneData.makeFractalProp()],
                gaussians: [],
                lights: hero.lights,
                materials: hero.materials
            )
        }
    }

    private static func terrainFixture(for qaScene: QAMode.Scene?) -> UInt32 {
        switch qaScene {
        case .fogClear: 1
        case .fogBlocked: 2
        default: 0
        }
    }

    func resetCamera() {
        stateLock.lock()
        resetPending = true
        stateLock.unlock()
    }

    func currentAutoTourState() -> AutoTourState {
        stateLock.lock()
        let state = autoTourController.state
        stateLock.unlock()
        return state
    }

    func currentAutoTourSample() -> AutoTourSample? {
        stateLock.lock()
        let sample = autoTourController.lastSample
        stateLock.unlock()
        return sample
    }

    func currentCameraPose() -> (position: SIMD3<Float>, yaw: Float, pitch: Float) {
        stateLock.lock()
        let pose = (cameraPosition, yaw, pitch)
        stateLock.unlock()
        return pose
    }

    func takeControl() -> AutoTourSample? {
        stateLock.lock()
        let sample = autoTourController.takeControl()
        if let sample {
            applyAutoTourPose(sample)
        }
        stateLock.unlock()
        return sample
    }

    func restartAutoTour(at time: CFTimeInterval = CACurrentMediaTime()) -> AutoTourSample? {
        stateLock.lock()
        let sample = autoTourController.restart(at: time)
        if let sample {
            applyAutoTourPose(sample)
            presentedAutoTourSectionID = sample.sectionID
        }
        stateLock.unlock()
        return sample
    }

    func setRenderState(_ state: RenderState) {
        stateLock.lock()
        renderState = state
        if !state.counterAggregationEnabled {
            latestCounters = nil
        }
        stateLock.unlock()
    }

    func configureQA(_ mode: QAMode, completion: @escaping (RendererQAResult) -> Void) {
        stateLock.lock()
        qaExecution = QAExecution(plan: QARenderPlan(mode: mode), completion: completion)
        scaleController = RenderScaleController(scale: mode.renderScale, mode: .fixed)
        sceneTime = mode.fixedTime
        switch mode.camera {
        case .reset:
            cameraPosition = Renderer.initialCameraPosition
            yaw = Renderer.initialYaw
            pitch = Renderer.initialPitch
        case .custom(let position, let customYaw, let customPitch):
            cameraPosition = SIMD3(Float(position.x), Float(position.y), Float(position.z))
            yaw = Float(customYaw)
            pitch = Float(customPitch)
        }
        drawableSizeDirty = false
        stateLock.unlock()

        metalView?.autoResizeDrawable = false
        metalView?.drawableSize = CGSize(width: mode.drawablePixels.x, height: mode.drawablePixels.y)
        metalView?.enableSetNeedsDisplay = true
        metalView?.isPaused = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSizeDirty = true
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        let qaFrame = qaExecution.map { ($0.plan, $0.submittedFrames) }
        stateLock.unlock()
        let deltaTime = qaFrame == nil ? min(0.05, max(0.0, now - lastFrameTime)) : 0
        lastFrameTime = now
        var state = currentRenderState()
        if let (plan, frame) = qaFrame {
            sceneTime = plan.time(forFrame: frame)
        } else if !state.paused {
            sceneTime += deltaTime
        }
        if let (plan, _) = qaFrame {
            updateQADrawableSize(view, plan: plan)
        } else {
            if let sample = updateAutoTour(at: now) {
                state.evidenceView = sample.evidenceView
            } else {
                updateCamera(deltaTime: Float(deltaTime))
            }
            updateFrameRate(deltaTime: deltaTime)
            adjustRenderScaleIfNeeded()
            updateDrawableSize(view)
        }

        guard view.drawableSize.width >= 1.0, view.drawableSize.height >= 1.0 else {
            failQA("The requested drawable size is empty.", droppedDrawable: true)
            return
        }
        guard inFlightSemaphore.wait(timeout: .now() + 0.1) == .success else {
            failQA("Timed out waiting for an in-flight Metal frame.", semaphoreTimeout: true)
            return
        }

        guard let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            failQA("MTKView did not provide a drawable.", droppedDrawable: true)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            failQA("Metal command buffer allocation failed.", commandError: true)
            return
        }

        let counterSlot = Int(frameIndex % 3)
        guard prepareCounterSlot(counterSlot) else {
            inFlightSemaphore.signal()
            failQA("The selected frame-counter slot is still in flight.", commandError: true)
            return
        }
        let counterBuffer = counterBuffers[counterSlot]
        let aggregatesCounters = state.counterAggregationEnabled || qaFrame != nil

        let width = drawable.texture.width
        let height = drawable.texture.height
        var uniforms = makeUniforms(
            width: width,
            height: height,
            time: sceneTime,
            state: state,
            qaView: qaFrame?.0.mode.view
        )
        var sceneUniforms = makeSceneUniforms()

        guard let volumeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            releaseCounterSlot(counterSlot)
            inFlightSemaphore.signal()
            failQA("Metal volume encoder allocation failed.", commandError: true)
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
            failQA("Metal ray encoder allocation failed.", commandError: true)
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

        var captureBuffer: MTLBuffer?
        var captureBytesPerRow = 0
        if let (plan, frame) = qaFrame,
           plan.capturesDrawable(frame: frame) {
            captureBytesPerRow = (width * 4 + 255) & ~255
            guard let buffer = commandQueue.device.makeBuffer(
                length: captureBytesPerRow * height,
                options: .storageModeShared
            ), let blit = commandBuffer.makeBlitCommandEncoder() else {
                releaseCounterSlot(counterSlot)
                inFlightSemaphore.signal()
                failQA("Drawable capture allocation failed.", commandError: true)
                return
            }
            blit.label = "Copy completed QA drawable"
            blit.copy(
                from: drawable.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(width: width, height: height, depth: 1),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: captureBytesPerRow,
                destinationBytesPerImage: captureBytesPerRow * height
            )
            blit.endEncoding()
            captureBuffer = buffer
        }

        commandBuffer.label = "MicroCube frame \(frameIndex)"
        commandBuffer.present(drawable)
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            let gpuMilliseconds = completedBuffer.gpuEndTime > completedBuffer.gpuStartTime
                ? (completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1_000.0
                : 0
            if gpuMilliseconds > 0 {
                self?.recordGPUTime(gpuMilliseconds)
            }
            self?.completeCounterSlot(counterSlot, aggregationEnabled: aggregatesCounters)
            if let (plan, frame) = qaFrame {
                let capture = captureBuffer.map {
                    QADrawableCapture(
                        width: width,
                        height: height,
                        bytesPerRow: captureBytesPerRow,
                        bgra8: Data(bytes: $0.contents(), count: captureBytesPerRow * height)
                    )
                }
                self?.completeQAFrame(
                    plan: plan,
                    frame: frame,
                    commandBuffer: completedBuffer,
                    gpuMilliseconds: gpuMilliseconds,
                    drawableCapture: capture
                )
            }
            semaphore.signal()
        }
        commandBuffer.commit()

        if qaFrame != nil {
            stateLock.lock()
            qaExecution?.submittedFrames += 1
            stateLock.unlock()
        }
        frameIndex &+= 1
        if qaFrame == nil {
            updateHUDIfNeeded(now: now, width: width, height: height, state: state)
        }
    }

    private func updateQADrawableSize(_ view: MTKView, plan: QARenderPlan) {
        let size = CGSize(width: plan.drawablePixels.x, height: plan.drawablePixels.y)
        if view.drawableSize != size {
            view.drawableSize = size
        }
    }

    private func failQA(
        _ failure: String,
        commandError: Bool = false,
        droppedDrawable: Bool = false,
        semaphoreTimeout: Bool = false
    ) {
        stateLock.lock()
        guard var execution = qaExecution else {
            stateLock.unlock()
            return
        }
        if commandError { execution.commandErrors += 1 }
        if droppedDrawable { execution.droppedDrawables += 1 }
        if semaphoreTimeout { execution.semaphoreTimeouts += 1 }
        qaExecution = nil
        let counters = latestCounters
        stateLock.unlock()

        let completion = execution.completion
        let result = RendererQAResult(
            final: true,
            failure: failure,
            drawableCapture: nil,
            gpuMilliseconds: execution.gpuMilliseconds,
            stepCounters: counterDictionary(counters),
            budgetOverflows: Int(counters?.budgetOverflows ?? 0),
            commandErrors: execution.commandErrors,
            droppedDrawables: execution.droppedDrawables,
            semaphoreTimeouts: execution.semaphoreTimeouts
        )
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func completeQAFrame(
        plan: QARenderPlan,
        frame: Int,
        commandBuffer: MTLCommandBuffer,
        gpuMilliseconds: Double,
        drawableCapture: QADrawableCapture?
    ) {
        stateLock.lock()
        guard var execution = qaExecution else {
            stateLock.unlock()
            return
        }
        var failure: String?
        if commandBuffer.status != .completed {
            execution.commandErrors += 1
            failure = commandBuffer.error?.localizedDescription
                ?? "Metal command buffer ended with status \(commandBuffer.status.rawValue)."
        } else if plan.measuresGPU(frame: frame) {
            if gpuMilliseconds.isFinite, gpuMilliseconds > 0 {
                execution.gpuMilliseconds.append(gpuMilliseconds)
            } else {
                execution.commandErrors += 1
                failure = "Metal did not provide a finite positive GPU duration."
            }
        }
        let final = failure != nil || plan.isFinal(frame: frame)
        let counters = latestCounters
        if final {
            qaExecution = nil
        } else {
            qaExecution = execution
        }
        stateLock.unlock()

        let result = RendererQAResult(
            final: final,
            failure: failure,
            drawableCapture: drawableCapture,
            gpuMilliseconds: execution.gpuMilliseconds,
            stepCounters: counterDictionary(counters),
            budgetOverflows: Int(counters?.budgetOverflows ?? 0),
            commandErrors: execution.commandErrors,
            droppedDrawables: execution.droppedDrawables,
            semaphoreTimeouts: execution.semaphoreTimeouts
        )
        let completion = execution.completion
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func counterDictionary(_ counters: FrameCounters?) -> [String: Int] {
        guard let counters else {
            return [
                "macroSkips": 0,
                "macroDescents": 0,
                "voxelSteps": 0,
                "sdfSteps": 0,
                "gaussianSamples": 0,
                "secondarySceneRays": 0,
            ]
        }
        return [
            "macroSkips": Int(counters.macroSkips),
            "macroDescents": Int(counters.macroDescents),
            "voxelSteps": Int(counters.voxelSteps),
            "sdfSteps": Int(counters.sdfSamples),
            "gaussianSamples": Int(counters.gaussianSamples),
            "secondarySceneRays": Int(counters.secondaryRays),
            "surfaceSunShadows": Int(counters.surfaceSunShadows),
            "surfaceLocalShadows": Int(counters.surfaceLocalShadows),
            "volumeSunShadows": Int(counters.volumeSunShadows),
            "volumeLocalShadows": Int(counters.volumeLocalShadows),
        ]
    }

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source: String
        do {
            source = try ShaderSourceLoader.load()
        } catch {
            throw RendererError.resource("shader source", error.localizedDescription)
        }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            throw RendererError.compiler(error.localizedDescription)
        }
    }

    private static func makePipeline(
        name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw RendererError.kernel(name)
        }
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = name
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        do {
            return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        } catch {
            throw RendererError.pipeline(name, error.localizedDescription)
        }
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

    private func initializeWorld(terrainFixture: UInt32) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let terrainEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("world construction command encoder")
        }

        terrainEncoder.label = "Generate terrain"
        terrainEncoder.setComputePipelineState(terrainPipeline)
        terrainEncoder.setTexture(volumeTexture, index: 0)
        var terrainFixture = terrainFixture
        terrainEncoder.setBytes(&terrainFixture, length: MemoryLayout<UInt32>.stride, index: 0)
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
                throw RendererError.allocation("occupancy mip encoder \(destinationLevel)")
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
            throw RendererError.allocation("mixed occupancy encoder")
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
                throw RendererError.allocation("mixed occupancy mip encoder \(destinationLevel)")
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
            throw RendererError.allocation("volume clear encoder")
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
        guard commandBuffer.status == .completed else {
            throw RendererError.resource(
                "world construction command buffer",
                commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)"
            )
        }
    }

    func currentRenderState() -> RenderState {
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

    func updateAutoTour(at time: CFTimeInterval) -> AutoTourSample? {
        stateLock.lock()
        let sample = autoTourController.sample(at: time)
        let failure = autoTourController.takeFailure()
        let lastSample = autoTourController.lastSample
        var sectionChanged = false
        if let sample {
            applyAutoTourPose(sample)
            sectionChanged = presentedAutoTourSectionID != sample.sectionID
            presentedAutoTourSectionID = sample.sectionID
        }
        stateLock.unlock()
        if let sample, sectionChanged {
            autoTourUpdate(sample)
        } else if let failure {
            hudUpdate(failure)
            if let lastSample {
                autoTourFailure(lastSample)
            }
        }
        return sample
    }

    private func applyAutoTourPose(_ sample: AutoTourSample) {
        cameraPosition = sample.cameraPosition
        yaw = sample.yaw
        pitch = sample.pitch
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
        state: RenderState,
        qaView: QAMode.View? = nil
    ) -> FrameUniforms {
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let forward = SIMD3<Float>(cosPitch * sinYaw, sinPitch, cosPitch * cosYaw)
        let right = SIMD3<Float>(cosYaw, 0.0, -sinYaw)
        let up = SIMD3<Float>(-sinPitch * sinYaw, cosPitch, -sinPitch * cosYaw)
        let sun = simd_normalize(SIMD3<Float>(-0.30, 0.16, -0.72))
        let aspect = Float(width) / Float(max(1, height))
        let halfFOV = tan(Float(70.0 * .pi / 360.0))

        let evidenceView = qaView?.shaderValue ?? state.evidenceView.rawValue
        var options = state.features.rawValue | (evidenceView << 8) | (1 << 31)
        if state.counterAggregationEnabled || qaView != nil {
            options |= 1 << 16
        }
        return FrameUniforms(
            cameraPositionAndTime: SIMD4<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z, Float(time.truncatingRemainder(dividingBy: 4_096.0))),
            cameraForwardAndFOV: SIMD4<Float>(forward.x, forward.y, forward.z, halfFOV),
            cameraRightAndAspect: SIMD4<Float>(right.x, right.y, right.z, aspect),
            cameraUpAndMaxDistance: SIMD4<Float>(up.x, up.y, up.z, 256.0),
            sunDirectionAndAmbient: SIMD4<Float>(sun.x, sun.y, sun.z, 0.22),
            viewportAndOptions: SIMD4<UInt32>(UInt32(width), UInt32(height), frameIndex, options),
            fogAndExposure: SIMD4<Float>(0.09, 0.85, 0.78, Float(scaleController.scale))
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
