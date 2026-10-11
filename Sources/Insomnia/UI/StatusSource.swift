import Foundation
import Observation

/// Live machine status shown in the right-click menu. The system layer
/// (lid, battery, network, freeze, browser throttle) provides the real
/// object; the UI only ever talks to this protocol.
@MainActor
protocol StatusSource: AnyObject, Observable {
    var lidClosed: Bool { get }
    var batteryPercent: Int? { get }
    var isCharging: Bool { get }
    var wifiSSID: String? { get }
    /// Length of the most recent network outage, nil if none this session.
    var lastGap: TimeInterval? { get }
    var frozenCount: Int { get }
    var dockerPaused: Bool { get }
    /// Browsers running without the occlusion flags.
    var throttledBrowsers: [ThrottledBrowser] { get }
    /// Why each browser's last relaunch did not happen, ordered by
    /// bundle id; one menu warning line each.
    var relaunchProblems: [String] { get }
    /// Why a hotspot join was skipped this session, if one was, and for
    /// which SSID.
    var hotspotPasswordReport: HotspotPasswordReport? { get }

    /// Called when the menu opens; observers refresh anything not pushed.
    func refreshOnDemand()
    /// The part of that refresh that needs no awaiting, so a caller that has
    /// to read the status right now still gets it fresh.
    func refreshInstant()
    /// Battery draw read on demand from AppleSmartBattery. Never polled.
    func instantWatts() -> Double?
    /// Relaunch the browser the user confirmed, as the menu item named it.
    func relaunchUnthrottled(_ browser: ThrottledBrowser)
}

/// Stand-in until the system layer is plugged in. Reports nothing.
@MainActor
@Observable
final class PlaceholderStatus: StatusSource {
    var lidClosed: Bool = false
    var batteryPercent: Int? = nil
    var isCharging: Bool = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount: Int = 0
    var dockerPaused: Bool = false
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil

    init() {}

    func refreshOnDemand() {}
    func refreshInstant() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) {}
}

/// Pure formatting for the menu's status block, kept out of the views so
/// it can be tested.
enum StatusLines {
    /// "Lid: closed · 4.1 W · Wi-Fi: iPhone". Unknown parts are omitted.
    static func machine(lidClosed: Bool, watts: Double?, wifiSSID: String?, batteryPercent: Int?, isCharging: Bool) -> String {
        var parts: [String] = ["Крышка: \(lidClosed ? "закрыта" : "открыта")"]
        if let w = watts {
            parts.append(String(format: "%.1f Вт", w))
        }
        if let p = batteryPercent {
            parts.append(isCharging ? "\(p)% заряжается" : "\(p)%")
        }
        if let ssid = wifiSSID, !ssid.isEmpty {
            parts.append("Wi-Fi: \(ssid)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Russian plural form: "заморожено 1 приложение / 2 приложения / 5 приложений".
    static func frozenApps(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word = (mod10 == 1 && mod100 != 11) ? "приложение" : ((2...4).contains(mod10) && !(12...14).contains(mod100)) ? "приложения" : "приложений"
        return "заморожено \(n) \(word)"
    }

    /// "3 apps frozen · Docker paused", or nil when nothing is held.
    static func actions(frozenCount: Int, dockerPaused: Bool, lastGap: TimeInterval?) -> String? {
        var parts: [String] = []
        if frozenCount > 0 {
            parts.append(Self.frozenApps(frozenCount))
        }
        if dockerPaused {
            parts.append("Docker на паузе")
        }
        if let gap = lastGap, gap > 0 {
            parts.append("последний обрыв \(Int(gap.rounded())) с")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// "⚠ Chrome is throttled" / "⚠ Chrome and Arc are throttled".
    static func throttleWarning(_ browsers: [String]) -> String? {
        guard !browsers.isEmpty else { return nil }
        let names: String
        switch browsers.count {
        case 1: names = browsers[0]
        case 2: names = "\(browsers[0]) и \(browsers[1])"
        default: names = browsers.dropLast().joined(separator: ", ") + " и " + browsers.last!
        }
        return "\u{26A0} \(browsers.count == 1 ? "Замедлен" : "Замедлены"): \(names)"
    }
}

/// The one line about sleep, read from the journal
/// (`RuntimeState.sleepDisabledByUs`) rather than inferred from the presence
/// of a session. The journal records what Insomnia asked pmset to do; it is
/// not live proof, so the line never promises the lid is safe to close.
/// Pure so it can be tested.
enum SleepHeldLine {
    struct Line: Equatable {
        let text: String
        let isWarning: Bool
    }

    static func line(sessionActive: Bool, sleepHeld: Bool) -> Line? {
        switch (sessionActive, sleepHeld) {
        case (true, true):
            Line(text: "Сон отключён по журналу \u{2014} вживую не проверено", isWarning: false)
        case (true, false):
            Line(text: "Сон не отключён \u{2014} эта сессия не удерживает Mac от сна", isWarning: true)
        case (false, true):
            Line(text: "Сон всё ещё отключён, хотя сессии нет", isWarning: true)
        case (false, false):
            nil
        }
    }
}

/// macOS hides Wi-Fi network names until Location is allowed; say so rather
/// than reporting no network at all.
enum WiFiStatusName {
    static func display(ssid: String?, locationAuthorized: Bool) -> String? {
        if let ssid, !ssid.isEmpty { return ssid }
        return locationAuthorized ? nil : "включён (имя скрыто, пока не разрешена геолокация)"
    }
}

/// Short label for a duration: "30m", "2h", "3d". Used by the preset list in
/// Settings.
func chipLabel(for seconds: TimeInterval) -> String {
    SessionMath.formatRemaining(seconds).replacingOccurrences(of: " ", with: "")
}
