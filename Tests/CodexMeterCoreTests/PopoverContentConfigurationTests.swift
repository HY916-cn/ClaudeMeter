import XCTest
@testable import CodexMeterCore

final class PopoverContentConfigurationTests: XCTestCase {
    func testDefaultsShowEverySectionAndQuotaWindow() {
        let configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "claude-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(
            id: "claude-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 30
        )
        let reserve = makeWindow(
            id: "claude-sonnet-only-primary",
            name: "Sonnet · Weekly quota",
            duration: 10_080,
            used: 0
        )

        XCTAssertTrue(configuration.isSectionVisible(.quotaWindows))
        XCTAssertTrue(configuration.isSectionVisible(.resetCredits))
        XCTAssertTrue(configuration.isSectionVisible(.quotaHistory))
        XCTAssertTrue(configuration.isSectionVisible(.tokenActivity))
        XCTAssertEqual(
            configuration.sectionOrder,
            [.quotaWindows, .resetCredits, .quotaHistory, .tokenActivity]
        )
        XCTAssertTrue(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertTrue(configuration.isQuotaWindowVisible(reserve))
        XCTAssertNil(configuration.menuBarQuotaWindowID)
    }

    func testQuotaWindowsCanBeHiddenIndependentlyByStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "claude-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(id: "claude-secondary", name: "Weekly", duration: 10_080, used: 30)

        configuration.setQuotaWindow(fiveHour, visible: false)

        XCTAssertFalse(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertEqual(configuration.visibleQuotaWindows(from: [fiveHour, weekly]), [weekly])
    }

    func testSelectedMenuBarWindowUsesPersistedStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "claude-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "claude-secondary", name: "Weekly", duration: 10_080, used: 20)

        configuration.menuBarQuotaWindowID = weekly.historyID

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), weekly)
    }

    func testMissingMenuBarSelectionFallsBackToLowestRemainingQuota() {
        var configuration = PopoverContentConfiguration.defaultValue
        configuration.menuBarQuotaWindowID = "duration:999:missing"
        let fiveHour = makeWindow(id: "claude-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "claude-secondary", name: "Weekly", duration: 10_080, used: 20)

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [weekly, fiveHour]), fiveHour)
    }

    func testAutomaticSelectionUsesWeeklyQuotaWhenItHasLessRemaining() {
        let configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "claude-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(
            id: "claude-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 90
        )

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), weekly)
    }

    func testAutomaticSelectionUsesLowestRemainingAcrossWeeklyBuckets() {
        let configuration = PopoverContentConfiguration.defaultValue
        let reserve = makeWindow(
            id: "claude-sonnet-only-primary",
            name: "Sonnet · Weekly quota",
            duration: 10_080,
            used: 90
        )
        let weekly = makeWindow(
            id: "claude-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 76
        )

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [reserve, weekly]), reserve)
    }

    func testHistoryDefaultIgnoresOtherWeeklyBuckets() {
        let reserve = QuotaHistoryWindow(
            id: "duration:10080:claude-sonnet-only",
            name: "Sonnet · Weekly quota",
            windowDurationMins: 10_080,
            resetsAt: nil
        )
        let weekly = QuotaHistoryWindow(
            id: "duration:10080:claude",
            name: "Weekly quota",
            windowDurationMins: 10_080,
            resetsAt: nil
        )

        XCTAssertEqual(QuotaWindowSelection.preferredDefault(from: [reserve, weekly]), weekly)
    }

    func testMovingSectionChangesOnlyItsStoredOrder() {
        var configuration = PopoverContentConfiguration.defaultValue

        configuration.moveSection(.tokenActivity, by: -1)

        XCTAssertEqual(
            configuration.sectionOrder,
            [.quotaWindows, .resetCredits, .tokenActivity, .quotaHistory]
        )
        XCTAssertTrue(configuration.isSectionVisible(.resetCredits))
        XCTAssertTrue(configuration.isSectionVisible(.tokenActivity))
    }

    func testDecodingOlderEmptyPreferencesUsesCurrentDefaults() throws {
        let configuration = try JSONDecoder().decode(
            PopoverContentConfiguration.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(configuration, .defaultValue)
    }

    private func makeWindow(
        id: String,
        name: String,
        duration: Int,
        used: Int
    ) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: name,
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}
