import Foundation
import XCTest
@testable import MicroCubeMetal

final class ExplainerResourceTests: XCTestCase {
    func testPackagedEnglishCopyMatchesSpecExtraction() throws {
        XCTAssertEqual(try ExplainerCopy.packagedBytes(), try specAppendixBytes())
    }

    func testPackagedEnglishCopyUsesRequiredUTF8LineEndings() throws {
        let bytes = try ExplainerCopy.packagedBytes()

        XCTAssertFalse(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertFalse(bytes.contains(0x0D))
        XCTAssertEqual(bytes.last, 0x0A)
        XCTAssertNotNil(String(data: bytes, encoding: .utf8))
    }

    private func specAppendixBytes() throws -> Data {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let specURL = projectRoot.appendingPathComponent(
            "docs/superpowers/specs/2026-08-30-microcube-visual-proof-design.md"
        )
        let source = try String(contentsOf: specURL, encoding: .utf8)
        var passages = [[String]]()
        var current: [String]?
        var inAppendix = false

        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "## Appendix B: English explainer copy" {
                inAppendix = true
                continue
            }
            guard inAppendix else { continue }
            if line.hasPrefix("## ") { break }
            if line.hasPrefix("### Passage ") {
                if let current { passages.append(current) }
                current = []
            } else if line == ">" {
                current?.append("")
            } else if line.hasPrefix("> ") {
                current?.append(String(line.dropFirst(2)))
            }
        }
        if let current { passages.append(current) }

        let extracted = passages
            .map { passage in
                passage.drop(while: { $0.isEmpty }).reversed().drop(while: { $0.isEmpty }).reversed()
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n") + "\n"
        return try XCTUnwrap(extracted.data(using: .utf8))
    }
}
