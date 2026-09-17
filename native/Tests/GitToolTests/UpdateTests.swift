// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0
import XCTest
@testable import GitTool

final class UpdateTests: XCTestCase {
    func testOnlyCompleteHTTPSUpdateConfigurationCanStart() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        func config(_ url: String, _ publicKey: String = "") -> UpdateConfiguration? {
            UpdateConfiguration(info: ["SUFeedURL": url, "SUPublicEDKey": publicKey.isEmpty ? key : publicKey])
        }
        XCTAssertNotNil(config("https://github.com/example/sprig/releases/latest/download/appcast.xml"))
        XCTAssertNil(config("http://example.com/feed.xml"))
        XCTAssertNil(config("https://user:password@example.com/feed.xml"))
        XCTAssertNil(config("file:///tmp/feed.xml"))
        XCTAssertNil(config("https://example.com/feed.xml", "not-a-key"))
        XCTAssertNil(config("https://example.com/feed.xml", Data(repeating: 0, count: 31).base64EncodedString()))
        XCTAssertNil(UpdateConfiguration(info: [:]))
    }

    @MainActor func testInstallationWaitsUntilOperationFinishesAndRunsOnce() {
        let gate = UpdateInstallationGate()
        var installs = 0
        XCTAssertTrue(gate.postpone(if: true) { installs += 1 })
        gate.resume(ifReady: false)
        gate.resume(ifReady: false)
        XCTAssertEqual(installs, 0)
        gate.resume(ifReady: true)
        gate.resume(ifReady: true)
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(gate.postpone(if: false) { installs += 1 })
        XCTAssertEqual(installs, 1, "An unblocked install remains owned by Sparkle")
    }

    @MainActor func testSparkleRelaunchDelegateSelectorIsExposed() {
        XCTAssertTrue(AppUpdater.shared.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
    }
}
