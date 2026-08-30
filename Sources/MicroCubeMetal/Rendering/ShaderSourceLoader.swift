import Foundation

enum ShaderSourceLoader {
    enum LoaderError: Error, Equatable {
        case missing(String)
    }

    static let fragments = ["SceneTypes", "HybridTraversal", "MicroCube"]

    static func load(bundle: Bundle = .module) throws -> String {
        try fragments.map { name in
            let url = bundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
                ?? bundle.url(forResource: name, withExtension: "metal")
            guard let url else {
                throw LoaderError.missing(name)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
    }
}
