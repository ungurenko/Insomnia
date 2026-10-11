import XCTest
@testable import Insomnia

final class QuickMenuTests: XCTestCase {
    func testPresetTitlesUseRussianPlurals() {
        XCTAssertEqual(QuickMenu.presetTitle(1800), "30 минут")
        XCTAssertEqual(QuickMenu.presetTitle(60), "1 минута")
        XCTAssertEqual(QuickMenu.presetTitle(3600), "1 час")
        XCTAssertEqual(QuickMenu.presetTitle(7200), "2 часа")
        XCTAssertEqual(QuickMenu.presetTitle(5400), "1 час 30 минут")
        XCTAssertEqual(QuickMenu.presetTitle(12 * 3600), "12 часов")
        XCTAssertEqual(QuickMenu.presetTitle(21 * 3600), "21 час")
        XCTAssertEqual(QuickMenu.presetTitle(86400), "1 день")
        XCTAssertEqual(QuickMenu.presetTitle(3 * 86400), "3 дня")
        XCTAssertEqual(QuickMenu.presetTitle(11 * 86400), "11 дней")
    }

    /// Idle offers presets to start; a running session shows what is left,
    /// the same presets as extensions, and a stop.
    func testItemsForIdleAndRunning() {
        let idle = QuickMenu.items(presets: [1800, 3600], remaining: nil, endsAt: nil)
        XCTAssertEqual(idle.map(\.kind), [.info, .preset(1800), .preset(3600), .custom, .separator, .settings, .quit])
        XCTAssertEqual(idle.first?.title, QuickMenu.startHeader)

        let running = QuickMenu.items(presets: [1800], remaining: "1:23:45", endsAt: "15:40")
        XCTAssertEqual(running.first?.title, "Осталось 1:23:45, до 15:40")
        XCTAssertTrue(running.contains(QuickMenu.Item(title: "+ 30 минут", kind: .preset(1800))))
        XCTAssertTrue(running.contains { $0.kind == .stop })
    }
}
