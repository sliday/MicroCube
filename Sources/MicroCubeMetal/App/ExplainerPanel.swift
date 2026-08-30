import AppKit
import Foundation

enum ExplainerCopy {
    enum CopyError: Error {
        case missingResource
    }

    static func packagedBytes(bundle: Bundle = .module) throws -> Data {
        let url = bundle.url(forResource: "WhyRays.en", withExtension: "txt", subdirectory: "Resources")
            ?? bundle.url(forResource: "WhyRays.en", withExtension: "txt")
        guard let url else { throw CopyError.missingResource }
        return try Data(contentsOf: url)
    }

    static func text(bundle: Bundle = .module) throws -> String {
        guard let text = String(data: try packagedBytes(bundle: bundle), encoding: .utf8) else {
            throw CopyError.missingResource
        }
        return text
    }
}

enum ExplainerLayout {
    enum State: Equatable {
        case collapsed
        case expanded(width: CGFloat)
    }

    enum Presentation: Equatable {
        case hidden
        case rail
        case panel
    }

    static let hudClearance: CGFloat = 16

    static func state(windowWidth: CGFloat) -> State {
        windowWidth < 1100 ? .collapsed : .expanded(width: 424)
    }

    static func presentation(windowWidth: CGFloat, explainerVisible: Bool) -> Presentation {
        if explainerVisible {
            return .panel
        }
        return state(windowWidth: windowWidth) == .collapsed ? .rail : .hidden
    }
}

enum ExplainerAppearance {
    static func overlayAlpha(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 1 : 0.92
    }
}

struct ExplainerSource: Equatable {
    let title: String
    let availability: String
    let url: URL
}

final class ExplainerActionButton: NSButton {
    var handler: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(invokeHandler)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func invokeHandler() {
        handler?()
    }
}

final class ExplainerPanel: NSVisualEffectView {
    static let disclosures = [
        "SOURCE QUOTE · ORIGINAL AUTHOR'S DEMO",
        "SOURCE CLAIM · NOT A RESULT FROM THIS MAC APP",
        "CURRENT MAC APP · 1 HYBRID IMAGE KERNEL + 1 VOLUME LIGHT KERNEL",
        "CONCEPT IN THIS MAC DEMO · NO PHYSICS OR AUDIO SYSTEM RUNS HERE",
    ]

    let sourceLinks = [
        ExplainerSource(
            title: "Iñigo Quilez · Distance functions",
            availability: "USER-SUPPLIED LINK · PAGE UNAVAILABLE WHEN CHECKED 2026-08-30",
            url: URL(string: "https://iquilezles.org/articles/raymarchingdf/")!
        ),
        ExplainerSource(
            title: "Ken Silverman · Voxlap",
            availability: "SOURCE LINK · AVAILABLE",
            url: URL(string: "https://advsys.net/ken/voxlap.htm")!
        ),
        ExplainerSource(
            title: "GPC · Raytracing Voxels in Teardown and Beyond",
            availability: "SOURCE LINK · AVAILABLE",
            url: URL(string: "https://www.youtube.com/watch?v=IM1Dr98f3xU")!
        ),
    ]

    private(set) var evidenceButtons = [NSButton]()
    private(set) var featureButtons = [NSButton]()
    private(set) var bodyTextFields = [NSTextField]()
    private(set) var disclosureLabels = [NSTextField]()
    private(set) var passageDisclosureTexts = [[String]]()
    private(set) var sourceLinkFields = [NSTextField]()
    let closeButton: NSButton

    init(copy: String, actionHandler: @escaping (RenderAction) -> Void) {
        closeButton = ExplainerActionButton(title: "×") {
            actionHandler(.toggleExplainer)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        setAccessibilityElement(true)
        setAccessibilityLabel("Why Rays explainer")

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("Close Why Rays explainer")
        closeButton.toolTip = "Close Why Rays explainer"

        let title = NSTextField(labelWithString: "WHY RAYS")
        title.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        title.textColor = .white

        let header = NSStackView(views: [title, NSView(), closeButton])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10

        addHeading("IN THIS MAC DEMO", to: contentStack)
        addBody(
            "Five live evidence views inspect the hybrid voxel, SDF, Gaussian, shadow, and optical renderer running in this Mac window.",
            to: contentStack
        )
        let evidenceRow = NSStackView()
        evidenceRow.orientation = .horizontal
        evidenceRow.spacing = 5
        evidenceRow.distribution = .fillEqually
        for (index, view) in EvidenceView.allCases.enumerated() {
            let button = ExplainerActionButton(title: "\(index + 1)") {
                actionHandler(.evidence(view))
            }
            button.setAccessibilityLabel("\(index + 1) · \(view.title) evidence view")
            evidenceButtons.append(button)
            evidenceRow.addArrangedSubview(button)
        }
        contentStack.addArrangedSubview(evidenceRow)
        evidenceRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let featureRow = NSStackView()
        featureRow.orientation = .horizontal
        featureRow.spacing = 5
        featureRow.distribution = .fillEqually
        let features: [(String, String, RenderFeatures)] = [
            ("G", "Toggle Gaussian volumes", .gaussian),
            ("K", "Toggle exact shadows", .shadows),
            ("L", "Toggle local lights", .lights),
            ("O", "Toggle optics", .optics),
            ("X", "Toggle SDF surfaces", .sdf),
        ]
        for (key, label, feature) in features {
            let button = ExplainerActionButton(title: key) {
                actionHandler(.toggleFeature(feature))
            }
            button.setAccessibilityLabel(label)
            featureButtons.append(button)
            featureRow.addArrangedSubview(button)
        }
        contentStack.addArrangedSubview(featureRow)
        featureRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        addDisclosure(Self.disclosures[2], to: contentStack)

        addHeading("FROM THE AUTHOR'S POSTS", to: contentStack)
        let passages = Self.passages(from: copy)
        if passages.isEmpty {
            addDisclosure(Self.disclosures[0], to: contentStack)
            addBody(copy, to: contentStack)
            addDisclosure(Self.disclosures[1], to: contentStack)
        }
        for passage in passages {
            var placedDisclosures = [Self.disclosures[0]]
            addDisclosure(Self.disclosures[0], to: contentStack)
            for paragraph in passage.components(separatedBy: "\n\n") {
                addBody(paragraph, to: contentStack)
                if paragraph.contains("one pass") || paragraph.contains("one frame") {
                    addDisclosure(Self.disclosures[2], to: contentStack)
                    placedDisclosures.append(Self.disclosures[2])
                }
                if paragraph.contains("1,073,741,824 colored voxels") {
                    addDisclosure(Self.disclosures[1], to: contentStack)
                    placedDisclosures.append(Self.disclosures[1])
                }
                if paragraph.contains("collisions and force directions") {
                    addDisclosure(Self.disclosures[3], to: contentStack)
                    placedDisclosures.append(Self.disclosures[3])
                }
            }
            passageDisclosureTexts.append(placedDisclosures)
        }

        addHeading("CONCEPT FOR THIS MAC DEMO", to: contentStack)
        addDisclosure(Self.disclosures[3], to: contentStack)
        addBody(
            "Collision fields, force directions, and spatial audio describe a possible extension. This Mac app renders the image and runs no physics or audio system.",
            to: contentStack
        )

        addHeading("AUTHOR'S SOURCES", to: contentStack)
        for source in sourceLinks {
            let field = Self.makeLinkField(source)
            sourceLinkFields.append(field)
            bodyTextFields.append(field)
            contentStack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        addSubview(header)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])

        closeButton.nextKeyView = evidenceButtons.first
        for (button, nextButton) in zip(evidenceButtons, evidenceButtons.dropFirst()) {
            button.nextKeyView = nextButton
        }
        evidenceButtons.last?.nextKeyView = featureButtons.first
        for (button, nextButton) in zip(featureButtons, featureButtons.dropFirst()) {
            button.nextKeyView = nextButton
        }
        featureButtons.last?.nextKeyView = closeButton
        updateAppearance(increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    static func makeCollapsedRail(actionHandler: @escaping () -> Void) -> NSButton {
        let button = ExplainerActionButton(title: "I · WHY RAYS", handler: actionHandler)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Open Why Rays explainer")
        button.toolTip = "Open Why Rays explainer"
        return button
    }

    func updateAppearance(increasedContrast: Bool) {
        alphaValue = ExplainerAppearance.overlayAlpha(increasedContrast: increasedContrast)
    }

    private func addHeading(_ text: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        stack.addArrangedSubview(label)
    }

    private func addBody(_ text: String, to stack: NSStackView) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        bodyTextFields.append(label)
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addDisclosure(_ text: String, to stack: NSStackView) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .systemTeal
        label.maximumNumberOfLines = 0
        disclosureLabels.append(label)
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func passages(from copy: String) -> [String] {
        let starts = [
            "Why do I use ray tracing",
            "I set myself a condition",
            "I managed to feel my way",
        ]
        return starts.enumerated().compactMap { index, start in
            guard let lower = copy.range(of: start)?.lowerBound else { return nil }
            let upper = index + 1 < starts.count
                ? copy.range(of: starts[index + 1])?.lowerBound ?? copy.endIndex
                : copy.endIndex
            return copy[lower..<upper].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func makeLinkField(_ source: ExplainerSource) -> NSTextField {
        let string = "\(source.title)\n\(source.availability)"
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white,
            ]
        )
        attributed.addAttribute(.link, value: source.url, range: NSRange(location: 0, length: source.title.utf16.count))
        let field = NSTextField(labelWithAttributedString: attributed)
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setAccessibilityLabel("\(source.title). \(source.availability)")
        return field
    }
}
