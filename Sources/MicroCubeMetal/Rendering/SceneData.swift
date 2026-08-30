import Foundation

enum SceneBuildError: Error, Equatable {
    case capExceeded(name: String, count: Int, maximum: Int)
    case referenceCountOverflow(kind: String, count: Int)
    case referenceOffsetOverflow(kind: String, count: Int)
    case invalidBounds(kind: String, index: Int)
}

struct SceneData {
    static let gridDimension = 64
    static let leafSize: Float = 8

    let cellHeaders: [CellHeader]
    let cellSDFRefs: [UInt32]
    let cellGaussianRefs: [UInt32]
    let sdfInstances: [SDFInstance]
    let gaussians: [Gaussian]
    let lights: [Light]
    let materials: [Material]
    let activeVolumeCells: [UInt32]

    static func makeHero() throws -> SceneData {
        let sculpture = SDFInstance(
            sweptBoundsMin: SIMD4<Float>(274, 88, 286, 0),
            sweptBoundsMax: SIMD4<Float>(288, 108, 300, 0),
            positionScale: SIMD4<Float>(281, 98, 293, 7),
            rotationQuaternion: SIMD4<Float>(0, 0, 0, 1),
            parameters: SIMD4<Float>(5, 8, 2, 0),
            metadata: SIMD4<UInt32>(0, 1, 0, 0)
        )
        let fractal = SDFInstance(
            sweptBoundsMin: SIMD4<Float>(292, 86, 314, 0),
            sweptBoundsMax: SIMD4<Float>(306, 110, 328, 0),
            positionScale: SIMD4<Float>(299, 98, 321, 7),
            rotationQuaternion: SIMD4<Float>(0, 0, 0, 1),
            parameters: SIMD4<Float>(8, 0, 0, 0),
            metadata: SIMD4<UInt32>(3, 2, 0, 1)
        )
        let creatureCenters = [
            SIMD3<Float>(270, 96, 292),
            SIMD3<Float>(281, 95, 300),
            SIMD3<Float>(293, 96, 294),
            SIMD3<Float>(275, 95, 310),
            SIMD3<Float>(287, 96, 316),
            SIMD3<Float>(299, 95, 308)
        ]
        let creatures = creatureCenters.enumerated().map { index, center in
            SDFInstance(
                sweptBoundsMin: SIMD4<Float>(center.x - 5, center.y - 11, center.z - 5, 0),
                sweptBoundsMax: SIMD4<Float>(center.x + 5, center.y + 11, center.z + 5, 0),
                positionScale: SIMD4<Float>(center.x, center.y, center.z, 3),
                rotationQuaternion: SIMD4<Float>(0, 0, 0, 1),
                parameters: SIMD4<Float>(12, Float(index) * 0.83, 0, 0),
                metadata: SIMD4<UInt32>(1, 3, 1, UInt32(index + 2))
            )
        }
        let lightColors = [
            SIMD3<Float>(1.0, 0.22, 0.08),
            SIMD3<Float>(0.18, 0.62, 1.0),
            SIMD3<Float>(0.88, 0.16, 0.48),
            SIMD3<Float>(0.35, 1.0, 0.42),
            SIMD3<Float>(1.0, 0.62, 0.12),
            SIMD3<Float>(0.54, 0.28, 1.0)
        ]
        let lights = creatureCenters.enumerated().map { index, center in
            let color = lightColors[index]
            return Light(
                positionRadius: SIMD4<Float>(center.x, center.y + 7.2, center.z, 22),
                colorIntensity: SIMD4<Float>(color.x, color.y, color.z, 10)
            )
        }
        let gaussians = (0..<8).map { index -> Gaussian in
            let angle = Float(index) * (.pi * 2 / 8)
            return Gaussian(
                localCenterSigma: SIMD4<Float>(
                    283 + cos(angle) * 9,
                    96 + Float(index % 2) * 4,
                    302 + sin(angle) * 7,
                    3.2
                ),
                colorDensity: SIMD4<Float>(0.52, 0.64, 0.72, 0.34),
                motionPhase: SIMD4<Float>(angle, Float(index % 3), 0, Float(index))
            )
        }
        let materials = [
            Material(
                baseColorRoughness: SIMD4<Float>(0.42, 0.48, 0.40, 0.72),
                emissionMetalness: .zero,
                opticalAbsorptionIOR: SIMD4<Float>(0, 0, 0, 1),
                transmissionAcoustic: .zero
            ),
            Material(
                baseColorRoughness: SIMD4<Float>(0.34, 0.37, 0.32, 0.38),
                emissionMetalness: .zero,
                opticalAbsorptionIOR: SIMD4<Float>(0, 0, 0, 1),
                transmissionAcoustic: .zero
            ),
            Material(
                baseColorRoughness: SIMD4<Float>(0.24, 0.20, 0.18, 0.58),
                emissionMetalness: SIMD4<Float>(0.03, 0.01, 0, 0),
                opticalAbsorptionIOR: SIMD4<Float>(0, 0, 0, 1),
                transmissionAcoustic: .zero
            ),
            Material(
                baseColorRoughness: SIMD4<Float>(0.12, 0.11, 0.10, 0.46),
                emissionMetalness: SIMD4<Float>(0.35, 0.05, 0.02, 0),
                opticalAbsorptionIOR: SIMD4<Float>(0, 0, 0, 1),
                transmissionAcoustic: .zero
            )
        ]
        return try build(
            sdfInstances: [sculpture, fractal] + creatures,
            gaussians: gaussians,
            lights: lights,
            materials: materials
        )
    }

    static func build(
        sdfInstances: [SDFInstance],
        gaussians: [Gaussian],
        lights: [Light],
        materials: [Material]
    ) throws -> SceneData {
        try validateCap(name: "SDF instances", count: sdfInstances.count, maximum: 16)
        try validateCap(name: "Gaussians", count: gaussians.count, maximum: 48)
        try validateCap(name: "lights", count: lights.count, maximum: 6)

        let cellCount = gridDimension * gridDimension * gridDimension
        var sdfCells = [[UInt32]](repeating: [], count: cellCount)
        var gaussianCells = [[UInt32]](repeating: [], count: cellCount)
        var densityCells = Set<UInt32>()

        let sdfOrder = sdfInstances.indices.sorted {
            sdfInstances[$0].metadata.w < sdfInstances[$1].metadata.w
        }
        for index in sdfOrder {
            let instance = sdfInstances[index]
            let minimum = instance.sweptBoundsMin.xyz
            let maximum = instance.sweptBoundsMax.xyz
            guard let cells = try cellsForBounds(minimum: minimum, maximum: maximum, kind: "SDF", index: index) else {
                continue
            }
            for cell in cells {
                sdfCells[Int(cell)].append(UInt32(index))
            }
        }

        let gaussianOrder = gaussians.indices.sorted {
            gaussians[$0].motionPhase.w < gaussians[$1].motionPhase.w
        }
        for index in gaussianOrder {
            let gaussian = gaussians[index]
            let sigma = gaussian.localCenterSigma.w
            guard sigma.isFinite, sigma > 0 else {
                throw SceneBuildError.invalidBounds(kind: "Gaussian", index: index)
            }
            let radius = SIMD3<Float>(repeating: sigma * 3)
            let center = gaussian.localCenterSigma.xyz
            guard let cells = try cellsForBounds(
                minimum: center - radius,
                maximum: center + radius,
                kind: "Gaussian",
                index: index
            ) else {
                continue
            }
            for cell in cells {
                gaussianCells[Int(cell)].append(UInt32(index))
                densityCells.insert(cell)
            }
        }

        var cellHeaders = [CellHeader]()
        var cellSDFRefs = [UInt32]()
        var cellGaussianRefs = [UInt32]()
        cellHeaders.reserveCapacity(cellCount)
        for index in 0..<cellCount {
            let sdfRefs = sdfCells[index]
            let gaussianRefs = gaussianCells[index]
            try validateCap(name: "SDF references per leaf", count: sdfRefs.count, maximum: 8)
            try validateCap(name: "Gaussian references per leaf", count: gaussianRefs.count, maximum: 16)
            guard cellSDFRefs.count <= Int(UInt32.max) else {
                throw SceneBuildError.referenceOffsetOverflow(kind: "sdf", count: cellSDFRefs.count)
            }
            guard cellGaussianRefs.count <= Int(UInt32.max) else {
                throw SceneBuildError.referenceOffsetOverflow(kind: "gaussian", count: cellGaussianRefs.count)
            }
            cellHeaders.append(CellHeader(
                sdfOffset: UInt32(cellSDFRefs.count),
                gaussianOffset: UInt32(cellGaussianRefs.count),
                packedCounts: try packCounts(sdfCount: sdfRefs.count, gaussianCount: gaussianRefs.count),
                reserved: 0
            ))
            cellSDFRefs.append(contentsOf: sdfRefs)
            cellGaussianRefs.append(contentsOf: gaussianRefs)
        }

        var activeVolumeCells = Set<UInt32>()
        for cell in densityCells {
            let position = cellPosition(cell)
            for z in max(0, position.z - 1)...min(gridDimension - 1, position.z + 1) {
                for y in max(0, position.y - 1)...min(gridDimension - 1, position.y + 1) {
                    for x in max(0, position.x - 1)...min(gridDimension - 1, position.x + 1) {
                        activeVolumeCells.insert(linearIndex(x: x, y: y, z: z))
                    }
                }
            }
        }
        try validateCap(name: "active volume cells", count: activeVolumeCells.count, maximum: 4_096)

        return SceneData(
            cellHeaders: cellHeaders,
            cellSDFRefs: cellSDFRefs,
            cellGaussianRefs: cellGaussianRefs,
            sdfInstances: sdfInstances,
            gaussians: gaussians,
            lights: lights,
            materials: materials,
            activeVolumeCells: activeVolumeCells.sorted()
        )
    }

    static func packCounts(sdfCount: Int, gaussianCount: Int) throws -> UInt32 {
        guard sdfCount >= 0, sdfCount <= Int(UInt16.max) else {
            throw SceneBuildError.referenceCountOverflow(kind: "sdf", count: sdfCount)
        }
        guard gaussianCount >= 0, gaussianCount <= Int(UInt16.max) else {
            throw SceneBuildError.referenceCountOverflow(kind: "gaussian", count: gaussianCount)
        }
        return UInt32(sdfCount) | (UInt32(gaussianCount) << 16)
    }

    static func linearIndex(x: Int, y: Int, z: Int) -> UInt32 {
        UInt32(x + gridDimension * (y + gridDimension * z))
    }

    private static func validateCap(name: String, count: Int, maximum: Int) throws {
        guard count <= maximum else {
            throw SceneBuildError.capExceeded(name: name, count: count, maximum: maximum)
        }
    }

    private static func cellsForBounds(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        kind: String,
        index: Int
    ) throws -> [UInt32]? {
        guard minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
              maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite,
              all(minimum .< maximum) else {
            throw SceneBuildError.invalidBounds(kind: kind, index: index)
        }
        let worldMaximum = Float(gridDimension) * leafSize
        if any(maximum .<= 0) || any(minimum .>= worldMaximum) {
            return nil
        }

        let lower = SIMD3<Int>(
            max(0, Int(floor(minimum.x / leafSize))),
            max(0, Int(floor(minimum.y / leafSize))),
            max(0, Int(floor(minimum.z / leafSize)))
        )
        let upper = SIMD3<Int>(
            min(gridDimension - 1, Int(ceil(maximum.x / leafSize)) - 1),
            min(gridDimension - 1, Int(ceil(maximum.y / leafSize)) - 1),
            min(gridDimension - 1, Int(ceil(maximum.z / leafSize)) - 1)
        )
        var cells = [UInt32]()
        for z in lower.z...upper.z {
            for y in lower.y...upper.y {
                for x in lower.x...upper.x {
                    cells.append(linearIndex(x: x, y: y, z: z))
                }
            }
        }
        return cells
    }

    private static func cellPosition(_ index: UInt32) -> SIMD3<Int> {
        let value = Int(index)
        let x = value % gridDimension
        let y = (value / gridDimension) % gridDimension
        return SIMD3<Int>(x, y, value / (gridDimension * gridDimension))
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}
