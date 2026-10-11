import AppKit

/// The right-click menu on the status item: a read-only status block, then
/// Settings and Quit, which live here and nowhere else.
///
/// The item list is pure so the ordering and the omission rules can be
/// tested without a menu bar; `menu(_:target:settings:quit:)` is the only
/// part that touches AppKit.
enum StatusMenu {
    struct Item: Equatable {
        enum Kind: Equatable {
            case info
            case warning
            case separator
            case settings
            case quit
            /// Relaunch this browser with the occlusion flags. Carries the
            /// bundle id and name, so the item still names the same browser
            /// after a scan replaces the list.
            case relaunchBrowser(ThrottledBrowser)
            /// Drop the saved volume of this output device: it is not
            /// connected, and Insomnia stops waiting for it. Carries the
            /// save the item was built for, its save ID included, so a
            /// later one is not dropped.
            case stopWaitingForOutput(SavedAudioOutput)
        }

        let title: String
        let kind: Kind
    }

    static let settingsTitle = "Настройки\u{2026}"
    static let quitTitle = "Выйти из Insomnia"

    /// Disabled status lines, a separator, then Settings… and Quit. Empty
    /// lines are dropped, and the separator only appears when something
    /// precedes it, so the menu never opens with a stray rule at the top.
    /// `hotspotWarning` is the line about a hotspot password the failover
    /// could not use (`HotspotPasswordProblem.menuLine`).
    /// `lidSimulationBuild` adds the line that marks a build with the
    /// scripts/simulate-lid.sh watcher compiled in (`LidSimulationBuild`),
    /// so such a build is never mistaken for a normal one.
    /// `relaunchProblems` say why browser relaunches did not happen, one
    /// line per browser; they follow the browser lines, since the browsers
    /// they name may no longer be in them.
    /// `outputsWaiting` are output devices still muted from a lid close
    /// because they were not connected to get their volume back; each gets
    /// a line and an item to stop waiting for it.
    static func items(
        sessionActive: Bool,
        sleepHeld: Bool,
        machine: String?,
        actions: String?,
        throttledBrowsers: [ThrottledBrowser],
        relaunchProblems: [String] = [],
        hotspotWarning: String? = nil,
        error: String?,
        commandRunning: String? = nil,
        foreignSleep: String? = nil,
        outputsWaiting: [SavedAudioOutput] = [],
        lidSimulationBuild: Bool = false
    ) -> [Item] {
        var out: [Item] = []
        if let held = SleepHeldLine.line(sessionActive: sessionActive, sleepHeld: sleepHeld) {
            out.append(Item(title: held.text, kind: held.isWarning ? .warning : .info))
        }
        if let machine = present(machine) {
            out.append(Item(title: machine, kind: .info))
        }
        if let actions = present(actions) {
            out.append(Item(title: actions, kind: .info))
        }
        if lidSimulationBuild {
            out.append(Item(title: LidSimulationBuild.marker, kind: .warning))
        }
        if let throttle = present(StatusLines.throttleWarning(throttledBrowsers.map(\.name))) {
            out.append(Item(title: throttle, kind: .warning))
            // The warning alone is a dead end; each throttled browser gets a
            // live item so the relaunch is still one click away, as it was
            // from the popover this menu replaced.
            for browser in throttledBrowsers {
                out.append(Item(title: "Перезапустить \(browser.name) без замедления", kind: .relaunchBrowser(browser)))
            }
        }
        for problem in relaunchProblems.compactMap(present) {
            out.append(Item(title: "\u{26A0} \(problem)", kind: .warning))
        }
        if let hotspot = present(hotspotWarning) {
            out.append(Item(title: hotspot, kind: .warning))
        }
        // The sudo pmset left running comes before the session error: it
        // holds every change and quit until it exits, and the line goes
        // away then.
        if let command = present(commandRunning) {
            out.append(Item(title: "\u{26A0} \(command)", kind: .warning))
        }
        if let error = present(error) {
            out.append(Item(title: "\u{26A0} \(error)", kind: .warning))
        }
        // Its own line, after the error: a restore that failed and a bit
        // someone else set can both be true of the same reconcile.
        if let foreignSleep = present(foreignSleep) {
            out.append(Item(title: "\u{26A0} \(foreignSleep)", kind: .warning))
        }
        for waiting in outputsWaiting {
            out.append(Item(title: "\u{26A0} \(SessionManager.stillMutedLine(waiting))", kind: .warning))
            out.append(Item(title: "Не ждать \(waiting.label)", kind: .stopWaitingForOutput(waiting)))
        }
        if !out.isEmpty {
            out.append(Item(title: "", kind: .separator))
        }
        out.append(Item(title: settingsTitle, kind: .settings))
        out.append(Item(title: quitTitle, kind: .quit))
        return out
    }

    private static func present(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Build the AppKit menu. Status lines are disabled small text; warnings
    /// are orange. `autoenablesItems` is off so the disabled lines stay
    /// disabled and the two actions stay live without validation.
    @MainActor
    static func menu(
        _ items: [Item],
        target: AnyObject?,
        settings: Selector,
        quit: Selector,
        relaunchBrowser: Selector,
        stopWaitingForOutput: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let lineFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .info, .warning:
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                // NSMenuItem has no font of its own; the attributed title is
                // the only way to make one line smaller or orange.
                var attributes: [NSAttributedString.Key: Any] = [.font: lineFont]
                if item.kind == .warning {
                    attributes[.foregroundColor] = NSColor.systemOrange
                }
                entry.attributedTitle = NSAttributedString(string: item.title, attributes: attributes)
                menu.addItem(entry)
            case .settings:
                menu.addItem(action(title: item.title, selector: settings, key: ",", target: target))
            case .quit:
                menu.addItem(action(title: item.title, selector: quit, key: "q", target: target))
            case let .relaunchBrowser(browser):
                let entry = action(title: item.title, selector: relaunchBrowser, key: "", target: target)
                entry.representedObject = browser
                menu.addItem(entry)
            case let .stopWaitingForOutput(waiting):
                let entry = action(title: item.title, selector: stopWaitingForOutput, key: "", target: target)
                entry.representedObject = waiting
                menu.addItem(entry)
            }
        }
        return menu
    }

    @MainActor
    private static func action(title: String, selector: Selector, key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = true
        return item
    }
}

/// What the menu asks before "Relaunch <browser> unthrottled" quits
/// anything. Pure so the copy is testable; the controller shows it as an
/// NSAlert.
struct RelaunchPrompt: Equatable {
    static let confirmTitle = "Перезапустить"
    static let cancelTitle = "Отмена"

    let title: String
    let message: String

    init(browser name: String) {
        title = "Перезапустить \(name)?"
        message = "Insomnia закроет \(name) и откроет снова с настройками, при которых он не замедляет скрытые окна. Окна и вкладки вернутся, только если \(name) умеет открывать их при запуске. Если \(name) не закроется за \(Int(BrowserThrottle.quitTimeout)) с, перезапуска не будет."
    }
}

/// The left-click menu on the eye: one click on a preset starts (or, while
/// a session runs, extends) it; "Своё время…" opens the pills for anything
/// else. The item list is pure so it can be tested without a menu bar.
enum QuickMenu {
    struct Item: Equatable {
        enum Kind: Equatable {
            case info
            case separator
            /// Start or extend by this many seconds.
            case preset(TimeInterval)
            case custom
            case stop
            case settings
            case quit
        }

        let title: String
        let kind: Kind
    }

    static let startHeader = "Не давать Маку спать"
    static let extendHeader = "Добавить время"
    static let customTitle = "Своё время\u{2026}"
    static let stopTitle = "Остановить сейчас"

    /// `remaining` is the live countdown and `endsAt` the clock time it
    /// reaches; both nil while no session runs, which makes this the start
    /// menu.
    static func items(presets: [TimeInterval], remaining: String?, endsAt: String?) -> [Item] {
        var out: [Item] = []
        let running = remaining != nil
        if let remaining {
            let until = endsAt.map { ", до \($0)" } ?? ""
            out.append(Item(title: "Осталось \(remaining)\(until)", kind: .info))
            out.append(Item(title: "", kind: .separator))
        }
        out.append(Item(title: running ? extendHeader : startHeader, kind: .info))
        for p in presets where p > 0 {
            let label = presetTitle(p)
            out.append(Item(title: running ? "+ \(label)" : label, kind: .preset(p)))
        }
        out.append(Item(title: customTitle, kind: .custom))
        out.append(Item(title: "", kind: .separator))
        if running {
            out.append(Item(title: stopTitle, kind: .stop))
            out.append(Item(title: "", kind: .separator))
        }
        out.append(Item(title: StatusMenu.settingsTitle, kind: .settings))
        out.append(Item(title: StatusMenu.quitTitle, kind: .quit))
        return out
    }

    /// "30 минут", "1 час", "1 час 30 минут", "3 дня". Seconds are floored
    /// to the minute.
    static func presetTitle(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds / 60), 0)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) \(plural(days, "день", "дня", "дней"))") }
        if hours > 0 { parts.append("\(hours) \(plural(hours, "час", "часа", "часов"))") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes) \(plural(minutes, "минута", "минуты", "минут"))") }
        return parts.joined(separator: " ")
    }

    /// Russian noun form for `n`: 1 день, 2 дня, 5 дней, 11 дней, 21 день.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100
        if (11...14).contains(tens) { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    @MainActor
    static func menu(
        _ items: [Item],
        target: AnyObject?,
        preset: Selector,
        custom: Selector,
        stop: Selector,
        settings: Selector,
        quit: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let entry: NSMenuItem
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
                continue
            case .info:
                entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
            case let .preset(seconds):
                entry = NSMenuItem(title: item.title, action: preset, keyEquivalent: "")
                entry.representedObject = seconds
            case .custom:
                entry = NSMenuItem(title: item.title, action: custom, keyEquivalent: "")
            case .stop:
                entry = NSMenuItem(title: item.title, action: stop, keyEquivalent: "")
            case .settings:
                entry = NSMenuItem(title: item.title, action: settings, keyEquivalent: ",")
            case .quit:
                entry = NSMenuItem(title: item.title, action: quit, keyEquivalent: "q")
            }
            if item.kind != .info {
                entry.target = target
                entry.isEnabled = true
            }
            menu.addItem(entry)
        }
        return menu
    }
}
