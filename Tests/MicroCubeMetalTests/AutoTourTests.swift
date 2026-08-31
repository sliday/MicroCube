import AppKit
import MetalKit
import simd
import XCTest
@testable import MicroCubeMetal

final class AutoTourTimelineTests: XCTestCase {
    func testBoundarySamplesSelectSpecifiedSectionsAndEvidenceViews() {
        let timeline = AutoTourTimeline()
        let cases: [(TimeInterval, Int, EvidenceView)] = [
            (0, 0, .final),
            (12, 1, .final),
            (24, 2, .final),
            (36, 3, .final),
            (48, 4, .final),
            (60, 5, .final),
            (72, 6, .final),
            (84, 7, .final),
            (96, 0, .final),
        ]

        for (time, sectionID, evidenceView) in cases {
            let sample = timeline.sample(at: time)
            XCTAssertEqual(sample.sectionID, sectionID, "time=\(time)")
            XCTAssertEqual(sample.evidenceView, evidenceView, "time=\(time)")
        }
    }

    func testLoopReturnsToMatchingCameraPose() {
        let timeline = AutoTourTimeline()

        let opening = timeline.sample(at: 0)
        let looped = timeline.sample(at: timeline.duration)

        XCTAssertEqual(opening.cameraPosition, looped.cameraPosition)
        XCTAssertEqual(opening.lookAtTarget, looped.lookAtTarget)
        XCTAssertEqual(opening.yaw, looped.yaw)
        XCTAssertEqual(opening.pitch, looped.pitch)
    }

    func testRepeatedAndDenseSamplesStayDeterministicFiniteAndInsideWorld() {
        let timeline = AutoTourTimeline()
        let fixed = timeline.sample(at: 13.25)
        XCTAssertEqual(fixed, timeline.sample(at: 13.25))

        for index in 0...9_600 {
            let sample = timeline.sample(at: Double(index) / 100)
            for value in [
                sample.cameraPosition.x, sample.cameraPosition.y, sample.cameraPosition.z,
                sample.lookAtTarget.x, sample.lookAtTarget.y, sample.lookAtTarget.z,
                sample.yaw, sample.pitch,
            ] {
                XCTAssertTrue(value.isFinite, "time=\(Double(index) / 100)")
            }
            XCTAssertGreaterThanOrEqual(sample.cameraPosition.min(), 1.25)
            XCTAssertLessThanOrEqual(sample.cameraPosition.max(), 510.75)
            XCTAssertGreaterThan(simd_length(sample.lookAtTarget - sample.cameraPosition), 0.001)
        }
    }
}

final class AutoTourControllerTests: XCTestCase {
    func testEligibleControllerCancelsOnceAndRestartResetsElapsedTime() {
        var controller = AutoTourController(policy: .enabled, startTime: 100)
        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.sample(at: 115)?.sectionID, 1)

        let handoff = controller.takeControl()

        XCTAssertEqual(handoff?.sectionID, 1)
        XCTAssertEqual(controller.state, .userControlled)
        XCTAssertNil(controller.takeControl())
        XCTAssertNil(controller.sample(at: 117))

        let restarted = controller.restart(at: 200)

        XCTAssertEqual(restarted?.sectionID, 0)
        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.sample(at: 215)?.sectionID, 1)
    }

    func testDisabledPoliciesRejectRestart() {
        for policy in [AutoTourPolicy.disabled, .reduceMotion] {
            var controller = AutoTourController(policy: policy, startTime: 0)
            XCTAssertEqual(controller.state, .disabled)
            XCTAssertNil(controller.sample(at: 8))
            XCTAssertNil(controller.restart(at: 10))
        }
    }

    func testInvalidTimeStopsTourRetainsPoseAndReportsFailureOnce() {
        var controller = AutoTourController(policy: .enabled, startTime: 0)
        let opening = controller.lastSample

        XCTAssertNil(controller.sample(at: .nan))

        XCTAssertEqual(controller.state, .userControlled)
        XCTAssertEqual(controller.lastSample, opening)
        XCTAssertEqual(controller.takeFailure(), "AUTO TOUR STOPPED · INVALID CAMERA SAMPLE")
        XCTAssertNil(controller.takeFailure())
    }

    func testLaunchPolicySeparatesInteractiveReduceMotionAndAutomation() {
        XCTAssertEqual(
            AutoTourPolicy.launch(
                automationRequested: false,
                hasQAMode: false,
                hasStartupError: false,
                reduceMotion: false
            ),
            .enabled
        )
        XCTAssertEqual(
            AutoTourPolicy.launch(
                automationRequested: false,
                hasQAMode: false,
                hasStartupError: false,
                reduceMotion: true
            ),
            .reduceMotion
        )
        for conditions in [
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ] {
            XCTAssertEqual(
                AutoTourPolicy.launch(
                    automationRequested: conditions.0,
                    hasQAMode: conditions.1,
                    hasStartupError: conditions.2,
                    reduceMotion: false
                ),
                .disabled
            )
        }
        XCTAssertEqual(
            AutoTourPolicy.launch(
                automationRequested: false,
                hasQAMode: false,
                hasStartupError: false,
                reduceMotion: false,
                hasMetalDevice: false
            ),
            .disabled
        )
    }
}

final class AutoTourIntegrationTests: XCTestCase {
    func testInteractiveLaunchStartsTourAndActionHandsOffPoseOnce() throws {
        var announcements = [String]()
        let delegate = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
            },
            accessibilityAnnouncementPoster: { announcements.append($0) }
        )
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        let renderer = try XCTUnwrap(delegate.renderer)
        let opening = try XCTUnwrap(renderer.currentAutoTourSample())

        XCTAssertEqual(renderer.currentAutoTourState(), .active)
        XCTAssertEqual(delegate.controlLegendText, "AUTO TOUR · THE SHORE\nMOVE OR CLICK TO TAKE CONTROL")
        XCTAssertEqual(announcements, ["Automatic tour started."])

        delegate.handleRenderAction(.toggleExplainer)

        let pose = renderer.currentCameraPose()
        XCTAssertEqual(renderer.currentAutoTourState(), .userControlled)
        XCTAssertEqual(pose.position, opening.cameraPosition)
        XCTAssertEqual(pose.yaw, opening.yaw)
        XCTAssertEqual(pose.pitch, opening.pitch)
        XCTAssertEqual(delegate.renderState.evidenceView, opening.evidenceView)
        XCTAssertEqual(announcements, [
            "Automatic tour started.",
            "Automatic tour stopped. You have control.",
            "Why Rays explainer opened.",
        ])

        delegate.handleRenderAction(.toggleHUD)
        XCTAssertEqual(announcements.filter { $0 == "Automatic tour stopped. You have control." }.count, 1)
    }

    func testRestartClearsInputAndRestoresOpeningTourState() throws {
        var announcements = [String]()
        let delegate = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
            },
            accessibilityAnnouncementPoster: { announcements.append($0) }
        )
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        let renderer = try XCTUnwrap(delegate.renderer)
        let metalView = try XCTUnwrap(delegate.metalView)
        delegate.handleRenderAction(.toggleHUD)
        metalView.input.setKey(13, down: true)
        metalView.input.setSpeedBoost(true)

        delegate.restartAutoTour(nil)

        let snapshot = metalView.input.snapshot()
        XCTAssertEqual(renderer.currentAutoTourState(), .active)
        XCTAssertEqual(renderer.currentAutoTourSample()?.sectionID, 0)
        XCTAssertFalse(snapshot.keys.contains(13))
        XCTAssertFalse(snapshot.speedBoost)
        XCTAssertEqual(delegate.renderState.evidenceView, .final)
        XCTAssertEqual(delegate.controlLegendText, "AUTO TOUR · THE SHORE\nMOVE OR CLICK TO TAKE CONTROL")
        XCTAssertEqual(announcements.last, "Automatic tour started.")
    }

    func testMenuAndReduceMotionFollowLaunchPolicy() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }
        let normal = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
            }
        )
        normal.configureMenu()
        let normalMenu = try XCTUnwrap(application.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu)
        XCTAssertEqual(normalMenu.item(withTitle: "Restart Auto Tour")?.isEnabled, true)

        let reduced = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: true)
            }
        )
        reduced.configureMenu()
        let reducedMenu = try XCTUnwrap(application.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu)
        XCTAssertEqual(reducedMenu.item(withTitle: "Restart Auto Tour")?.isEnabled, false)
        reduced.configureWindow()
        let reducedWindow = try XCTUnwrap(reduced.window)
        defer { reducedWindow.close() }
        XCTAssertEqual(reduced.renderer?.currentAutoTourState(), .disabled)
        XCTAssertEqual(reduced.controlLegendText, "AUTO TOUR OFF · REDUCE MOTION")

        let automated = AppDelegate(automationRequested: true)
        automated.configureMenu()
        let automatedMenu = try XCTUnwrap(application.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu)
        XCTAssertNil(automatedMenu.item(withTitle: "Restart Auto Tour"))
    }

    func testInputNotifiesOnceBeforeShortcutMovementAndPointerHandling() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let input = InputState()
        let view = MetalInputView(frame: .zero, device: device, input: input)
        var interactionCount = 0
        var actionCount = 0
        var movementShouldBeAbsent = false
        view.onUserInteraction = {
            if movementShouldBeAbsent {
                XCTAssertFalse(input.snapshot().keys.contains(13))
            }
            interactionCount += 1
            return true
        }
        view.onRenderAction = { _ in
            XCTAssertEqual(interactionCount, 1)
            actionCount += 1
            return true
        }
        view.armUserInteractionNotification()
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        ))

        XCTAssertTrue(view.handleRendererShortcut(shortcut))
        XCTAssertTrue(view.handleRendererShortcut(shortcut))
        XCTAssertEqual(interactionCount, 1)
        XCTAssertEqual(actionCount, 2)

        view.armUserInteractionNotification()
        movementShouldBeAbsent = true
        let movement = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))
        view.keyDown(with: movement)
        XCTAssertEqual(interactionCount, 2)
        XCTAssertTrue(input.snapshot().keys.contains(13))

        view.armUserInteractionNotification()
        movementShouldBeAbsent = false
        let pointer = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: pointer)
        view.mouseMoved(with: pointer)
        XCTAssertEqual(interactionCount, 3)
    }

    func testInvalidRendererSampleRestoresUserControlLegend() throws {
        let delegate = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
            }
        )
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        let renderer = try XCTUnwrap(delegate.renderer)
        let rendererFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = renderer.updateAutoTour(at: .nan)
            rendererFinished.signal()
        }

        XCTAssertEqual(rendererFinished.wait(timeout: .now() + 2), .success)
        let callbacksFinished = expectation(description: "autoplay failure callbacks reached main queue")
        DispatchQueue.main.async { callbacksFinished.fulfill() }
        wait(for: [callbacksFinished], timeout: 2)

        XCTAssertEqual(renderer.currentAutoTourState(), .userControlled)
        XCTAssertTrue(delegate.controlLegendText.hasPrefix("CLICK TO LOOK · RETURN/SPACE"))
    }

    func testQueuedSectionUpdateCannotOverwriteHandoffLegend() throws {
        let delegate = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
            }
        )
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        let renderer = try XCTUnwrap(delegate.renderer)
        _ = renderer.restartAutoTour(at: 0)
        let rendererFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = renderer.updateAutoTour(at: 8)
            rendererFinished.signal()
        }

        XCTAssertEqual(rendererFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(delegate.takeControl())
        let callbacksFinished = expectation(description: "queued section callback reached main queue")
        DispatchQueue.main.async { callbacksFinished.fulfill() }
        wait(for: [callbacksFinished], timeout: 2)

        XCTAssertEqual(renderer.currentAutoTourState(), .userControlled)
        XCTAssertTrue(delegate.controlLegendText.hasPrefix("CLICK TO LOOK · RETURN/SPACE"))
    }

    func testQueuedSectionUpdateCannotOverwriteRestartLegend() throws {
        let delegate = AppDelegate(
            accessibilityDisplayOptionsProvider: {
                AccessibilityDisplayOptions(increasedContrast: false, reduceMotion: false)
            }
        )
        delegate.configureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.close() }
        let renderer = try XCTUnwrap(delegate.renderer)
        _ = renderer.restartAutoTour(at: 0)
        let rendererFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = renderer.updateAutoTour(at: 8)
            rendererFinished.signal()
        }

        XCTAssertEqual(rendererFinished.wait(timeout: .now() + 2), .success)
        delegate.restartAutoTour(nil)
        let callbacksFinished = expectation(description: "pre-restart section callback reached main queue")
        DispatchQueue.main.async { callbacksFinished.fulfill() }
        wait(for: [callbacksFinished], timeout: 2)

        XCTAssertEqual(renderer.currentAutoTourState(), .active)
        XCTAssertEqual(delegate.controlLegendText, "AUTO TOUR · THE SHORE\nMOVE OR CLICK TO TAKE CONTROL")
    }
}
