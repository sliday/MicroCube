import Foundation

/// CPU mirror of the shader terrain height (SceneTypes.metal noise helpers +
/// MicroCube.metal terrainHeight), minus the final round() so cameras ride a
/// smooth surface instead of stepping voxel by voxel. The smooth value always
/// sits within 0.5 of the voxelized surface. Formula parity with the GPU is
/// pinned by SceneDataTests.testHeroCreaturesContactProductionTerrainWithinOneVoxel
/// (Swift-predicted creature heights match GPU-probed heights exactly).
enum TerrainField {
    static let seaLevel: Float = 52

    static func smoothHeight(x: Float, z: Float) -> Float {
        let wx = x - 256
        let wz = z - 256
        let n = valueNoise(wx / 48, wz / 48, 7) * 0.55
            + valueNoise(wx / 20, wz / 20, 8) * 0.30
            + valueNoise(wx / 8, wz / 8, 9) * 0.15
        let ridge = 1 - abs(valueNoise(wx / 88, wz / 88, 10) * 2 - 1)
        let land = 72 + (n - 0.5) * 64 + ridge * ridge * 25.6
        let coast = valueNoise(wx / 56, wz / 56, 12) * 40
        let radius = ((wx - 16) * (wx - 16) + (wz - 28) * (wz - 28)).squareRoot()
        var shore = min(1, max(0, (150 + coast - radius) / 72))
        shore = shore * shore * (3 - 2 * shore)
        let seabed: Float = 30 + (n - 0.5) * 12
        return seabed + (land - seabed) * shore
    }

    private static func hash2(_ x: Int32, _ z: Int32, _ seed: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: z) &* 668265263
            &+ UInt32(bitPattern: seed) &* 1274126177
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h) * (1.0 / 4294967296.0)
    }

    private static func valueNoise(_ x: Float, _ z: Float, _ seed: Int32) -> Float {
        let ix = Int32(floor(x))
        let iz = Int32(floor(z))
        let fx = x - Float(ix)
        let fz = z - Float(iz)
        let ux = fx * fx * (3 - 2 * fx)
        let uz = fz * fz * (3 - 2 * fz)
        let a = hash2(ix, iz, seed)
        let b = hash2(ix &+ 1, iz, seed)
        let c = hash2(ix, iz &+ 1, seed)
        let d = hash2(ix &+ 1, iz &+ 1, seed)
        let ab = a + (b - a) * ux
        let cd = c + (d - c) * ux
        return ab + (cd - ab) * uz
    }
}
