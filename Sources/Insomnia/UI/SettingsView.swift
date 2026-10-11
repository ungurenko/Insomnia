import AppKit
import SwiftUI

/// The settings window (spec 10). Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    /// Launch at login as macOS reports it, not as config.json remembers it.
    let loginItem: LoginItem

    @State private var newPreset = ""
    @State private var presetError: String?
    @State private var newFreezeBundle = ""
    @State private var newAgentBundle = ""
    @State private var newTmuxTarget = ""
    /// The password field, saving, what was saved, and the notice under
    /// the field.
    @State private var hotspot = HotspotPasswordField()
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded); refreshed on appear and toggle.
    @State private var wouldFreeze: [String] = []

    var body: some View {
        Form {
            sessionSection
            lidSection
            agentSection
            powerSection
            networkSection
            appSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560, idealHeight: 720)
        .onAppear {
            loadPassword()
            refreshWouldFreeze()
            // The user may have approved or removed the item in System
            // Settings since the launch-time check (LoginItem also re-reads
            // whenever the app becomes active, for a window left open).
            loginItem.refresh()
        }
        // The failover may find the saved password unreadable while the
        // window is open, and an SSID edit makes the notice about another
        // hotspot's item: the notice follows both.
        .onChange(of: manager.services?.status.hotspotPasswordReport) { recheckPassword() }
        .onChange(of: HotspotSSID.normalized(manager.config.hotspotSSID)) { recheckPassword() }
        // The preview depends on the toggle, both lists and what is running:
        // recompute on any config change and whenever an app launches or quits.
        .onChange(of: manager.config) { refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshWouldFreeze() }
    }

    // MARK: Bindings

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: keyPath] },
            set: { value in
                guard manager.config[keyPath: keyPath] != value else { return }
                manager.config[keyPath: keyPath] = value
                save()
            }
        )
    }

    private func save() {
        do {
            try manager.store.saveConfig(manager.config)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }

    private func update(_ change: (inout Config) -> Void) {
        var c = manager.config
        change(&c)
        guard c != manager.config else { return }
        manager.config = c
        save()
    }

    /// The floor steppers go through the Config setters, which move the
    /// other floor when the two would cross.
    private var lowPowerFloor: Binding<Int> {
        Binding(get: { manager.config.lowPowerFloor }, set: { v in update { $0.setLowPowerFloor(v) } })
    }

    private var endFloor: Binding<Int> {
        Binding(get: { manager.config.endFloor }, set: { v in update { $0.setEndFloor(v) } })
    }

    // MARK: Sections

    private var sessionSection: some View {
        Section("Сессия") {
            ForEach(manager.config.presets, id: \.self) { p in
                HStack {
                    Text(chipLabel(for: p))
                        .monospacedDigit()
                    Spacer()
                    if p == manager.config.defaultPreset {
                        Text("по умолчанию").font(.caption).foregroundStyle(.secondary)
                    }
                    removeButton {
                        update { $0.presets.removeAll { $0 == p } }
                    }
                }
            }
            HStack {
                TextField("Добавить время (30м, 2ч, 1ч30м, 3д)", text: $newPreset)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPreset)
                Button("Добавить", action: addPreset)
                    .disabled(DurationParser.seconds(from: newPreset) == nil)
            }
            if let presetError {
                Text(presetError).font(.caption).foregroundStyle(.red)
            }
            Picker("Пресет по умолчанию", selection: bind(\.defaultPreset)) {
                ForEach(manager.config.presets, id: \.self) { p in
                    Text(chipLabel(for: p)).tag(p)
                }
                if !manager.config.presets.contains(manager.config.defaultPreset) {
                    Text(chipLabel(for: manager.config.defaultPreset)).tag(manager.config.defaultPreset)
                }
            }
            LabeledContent("Максимальная длительность сессии") {
                Text(chipLabel(for: manager.config.maxDuration)).foregroundStyle(.secondary)
            }
        }
    }

    private func addPreset() {
        guard let s = DurationParser.seconds(from: newPreset) else { return }
        guard s <= manager.config.maxDuration else {
            presetError = "Пресет не может быть длиннее, чем \(chipLabel(for: manager.config.maxDuration))."
            return
        }
        presetError = nil
        update {
            if !$0.presets.contains(s) {
                $0.presets.append(s)
                $0.presets.sort()
            }
        }
        newPreset = ""
    }

    /// Under the mute toggle and in the README. Apple Platform Security,
    /// "Hardware microphone disconnect".
    static let microphoneNote = "На ноутбуках Mac с чипом Apple или T2 закрытая крышка физически отключает встроенный микрофон. Чтобы записывать встречу с закрытой крышкой, нужны AirPods или внешний микрофон."

    private var lidSection: some View {
        Section {
            // The one-time lid-close update, for a user who has
            // notifications turned off. Stays until dismissed.
            if let notice = manager.config.lidCloseDefaultsNotice {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.settingsLine)
                        .font(.callout)
                    Spacer()
                    Button("Скрыть") { manager.dismissLidCloseNotice() }
                }
            }
            Toggle("Выключать экран и подсветку клавиатуры", isOn: bind(\.darkenDisplayOnLidClose))
            ForEach(manager.darkenRefusals, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            bundleList(
                title: "Замораживать при закрытой крышке",
                items: manager.config.freezeList,
                newValue: $newFreezeBundle,
                add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
            )
            Toggle("Замораживать все остальные приложения при закрытой крышке", isOn: bind(\.freezeAllApps))
            Text(wouldFreezeText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Ставить Docker Desktop на паузу, если нет запущенных контейнеров", isOn: bind(\.dockerRule))
            Text("По умолчанию выключено. Если включить, Docker Desktop встанет на паузу, только когда вторая проверка перед самой паузой тоже не найдёт работающих контейнеров. Контейнер, запустившийся в последний момент, встанет на паузу вместе с ним.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Выключать звук при закрытии крышки", isOn: bind(\.muteOnLidClose))
            Text(Self.microphoneNote)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Режим энергосбережения при закрытой крышке", isOn: bind(\.lowPowerOnLidClose))
                // A floor input: apply it now if the lid is already closed.
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
        } header: {
            Text("Действия при закрытии крышки")
        } footer: {
            Text("Приложения из списка выше останавливаются (SIGSTOP), пока крышка закрыта, и продолжают работу, когда вы её открываете. Если включено «Замораживать все остальные приложения» (по умолчанию выключено), останавливаются и все остальные приложения из Dock, кроме приложений-агентов, приложений Apple, Docker Desktop и встроенных защищённых приложений (редакторы, терминалы, браузеры, ИИ-приложения, менеджеры паролей, локальные базы данных, Tailscale, локальные модели и приложения для встреч, записи и диктовки: Zoom, Teams, Webex, Wispr Flow, Granola, Otter, OBS, Loom). Приложения-агенты не замораживаются никогда. Яркость экрана и подсветка клавиатуры сохраняются, сбрасываются до нуля и возвращаются, когда вы открываете крышку. Если Insomnia не запущена в момент открытия крышки, нажмите клавишу увеличения яркости.")
        }
    }

    private var agentSection: some View {
        Section {
            bundleList(
                title: "Никогда не замедлять и не замораживать",
                items: manager.config.agentList,
                newValue: $newAgentBundle,
                add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                remove: { id in update { $0.agentList.removeAll { $0 == id } } }
            )
            Toggle("Отключать App Nap для этих приложений во время сессии", isOn: bind(\.disableAppNapForAgents))
            Text("При старте сессии записывает NSAppSleepDisabled = YES в настройки каждого приложения из списка, а при завершении возвращает прежнее значение.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Приложения-агенты")
        } footer: {
            Text("Приложения-агенты никогда не замораживаются и не замедляются. Редакторы, ИИ-приложения, терминалы, браузеры, менеджеры паролей, локальные базы данных, Tailscale, локальные модели и приложения для встреч, записи и диктовки тоже защищены от автоматического замораживания при закрытии крышки, даже если их нет в этом списке. Если добавить такое приложение в список заморозки выше, оно всё же будет заморожено.")
        }
    }

    private var wouldFreezeText: String {
        guard manager.config.freezeAllApps else { return "Сейчас были бы заморожены: только приложения из списка выше" }
        return wouldFreeze.isEmpty ? "Сейчас были бы заморожены: больше ничего" : "Сейчас были бы заморожены: \(wouldFreeze.joined(separator: ", "))"
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    private var powerSection: some View {
        Section("Батарея и нагрев") {
            Stepper(value: lowPowerFloor, in: 0...100, step: Config.floorStep) {
                LabeledContent("Энергосбережение ниже", value: "\(manager.config.lowPowerFloor)%")
            }
            Stepper(value: endFloor, in: 0...Config.maxEndFloor, step: Config.floorStep) {
                LabeledContent("Завершить сессию ниже", value: "\(manager.config.endFloor)%")
            }
            Text("0 отключает завершение по заряду. Порог завершения всегда ниже порога энергосбережения. Если подвинуть один порог вплотную к другому, второй сдвинется вместе с ним.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Правила по нагреву (энергосбережение при перегреве, завершение при критическом нагреве)", isOn: bind(\.thermalRules))
        }
    }

    private var networkSection: some View {
        Section {
            TextField("Имя точки доступа (SSID)", text: bind(\.hotspotSSID))
            HStack {
                SecureField("Пароль точки доступа", text: Binding(get: { hotspot.password }, set: { hotspot.edit($0) }))
                    .onSubmit(savePassword)
                Button(hotspot.buttonTitle(ssid: manager.config.hotspotSSID), action: savePassword)
                    .disabled(hotspot.password.isEmpty || hotspot.saving)
            }
            if let notice = hotspot.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Геолокация: \(locationPermission.statusDescription)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if locationPermission.isDenied {
                        Button("Открыть службы геолокации") {
                            locationPermission.openLocationServicesSettings()
                        }
                    }
                }
                // macOS has no when-in-use grant for Mac apps: the grant is
                // recorded as Location Services access for Insomnia.
                Text("macOS записывает это разрешение как доступ Insomnia к службам геолокации. Insomnia использует его только для чтения названий сетей Wi-Fi и никогда не запрашивает ваше местоположение.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                LabeledContent("Подтолкнуть tmux через", value: "\(Int(manager.config.nudgeThreshold)) с без сети")
            }
            Text("Если сети нет так долго, Insomnia вводит «continue» в каждую панель из списка ниже. Подталкиваются только панели, помеченные этой командой tmux. Помечайте отдельную панель, а не ту, в которой вы печатаете сами.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TmuxNudge.markCommand())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Toggle("Нажимать Enter после continue", isOn: bind(\.tmuxNudgePressesEnter))
            Text("Enter отправляет всё, что уже набрано в этой панели, в том числе недописанную строку. Если выключено, «continue» вводится, но не отправляется.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(manager.config.tmuxTargets, id: \.self) { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    removeButton {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    }
                }
            }
            HStack {
                TextField("Цель tmux (сессия:окно.панель)", text: $newTmuxTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTmuxTarget)
                Button("Добавить", action: addTmuxTarget)
                    .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Переключение сети")
        } footer: {
            Text("Пароль хранится в связке ключей входа. Без запроса его может прочитать только та сборка Insomnia, которая его сохранила, поэтому после переустановки введите пароль заново. Разрешение на геолокацию позволяет macOS показывать названия сетей Wi-Fi и находить указанную точку доступа.")
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    /// Fills the field when the window appears (`loadForField`).
    private func loadPassword() {
        let request = hotspot.startLoad(ssid: manager.config.hotspotSSID)
        Task {
            await Self.loadForField(request, secrets: secrets) {
                hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice)
            }
        }
    }

    /// Reads the notice again for the hotspot configured now, without a
    /// prompt and without touching the field.
    private func recheckPassword() {
        recheckPassword(hotspot.startRead(ssid: manager.config.hotspotSSID))
    }

    private func recheckPassword(_ request: HotspotPasswordField.Read) {
        Task {
            await Self.readForField(
                request,
                first: { await recheckedNotice() },
                again: { await recheckedNotice() },
                finish: { hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice) }
            )
        }
    }

    private func recheckedNotice() async -> (password: String, notice: String?) {
        let notice = await Self.hotspotNotice(
            reported: manager.services?.status.hotspotPasswordReport,
            ssid: manager.config.hotspotSSID,
            reread: secrets.peek
        )
        return ("", notice)
    }

    /// Loads the saved password into the field, without a keychain prompt.
    /// An item this build may not read leaves the field empty and says
    /// why, so the user re-enters it; saving then replaces the item (see
    /// `KeychainStore`). The read can wait behind a save, so a field
    /// edited meanwhile is kept, even one typed in and emptied again, and
    /// a password read for an SSID edited away meanwhile is not shown: the
    /// SSID configured now is read instead. That read is a peek: the
    /// account a later save moves the password from stays the one the
    /// window loaded, as it does for any SSID edit, so the old SSID's item
    /// is still removed.
    static func loadForField(
        _ request: HotspotPasswordField.Read,
        secrets: any HotspotSecretStore,
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        await readForField(
            request,
            first: { await loadedPassword(secrets.load) },
            again: { await loadedPassword(secrets.peek) },
            finish: finish
        )
    }

    /// Runs a load or recheck for the field: `first` reads, and `finish`
    /// takes the answer. While the SSID was edited during the read,
    /// `finish` drops the answer, and `again` reads the SSID configured
    /// now, until an answer is used or dropped.
    static func readForField(
        _ request: HotspotPasswordField.Read,
        first: @MainActor () async -> (password: String, notice: String?),
        again: @MainActor () async -> (password: String, notice: String?),
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        var answer = await first()
        var request = request
        while case let .readAgain(next) = finish(request, answer) {
            request = next
            answer = await again()
        }
    }

    /// A prompt-free load: the password for the field, or an empty field
    /// and a notice saying why it cannot be shown.
    static func loadedPassword(_ load: () async throws -> String?) async -> (password: String, notice: String?) {
        do {
            return (try await load() ?? "", nil)
        } catch let error as KeychainError {
            return ("", error.problem.settingsNotice)
        } catch {
            return ("", HotspotPasswordProblem.error(error.localizedDescription).settingsNotice)
        }
    }

    /// The notice under the password field for the hotspot `ssid`
    /// configured now. A problem the failover reports about that hotspot
    /// shows as it is. A report about another SSID, one edited away since,
    /// does not apply, and a cleared report is not taken as "readable": it
    /// also clears when the session ends. Then the keychain is read again,
    /// without a prompt, and the notice says what that read finds. The
    /// field is left as the user has it, and the reread is a peek: a load
    /// would make an SSID typed since then the account a save moves the
    /// password from, and the old SSID's item would stay behind.
    static func hotspotNotice(reported: HotspotPasswordReport?, ssid: String, reread: () async throws -> String?) async -> String? {
        if let problem = reported?.problem(for: ssid) { return problem.settingsNotice }
        return await loadedPassword(reread).notice
    }

    /// Saves, or clears for an empty field. The button shows "Saving..."
    /// until the keychain answers; one save at a time.
    private func savePassword() {
        guard hotspot.startSave() else { return }
        if !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty {
            locationPermission.requestWhenInUse()
        }
        let password = hotspot.password
        Task {
            let outcome = await Self.storePassword(password, in: secrets)
            let recheck = hotspot.finishSave(outcome, ssid: manager.config.hotspotSSID)
            // The failover's report first, so the recheck reads it as the
            // save left it.
            Self.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
            if let recheck { recheckPassword(recheck) }
        }
    }

    /// A save or clear answered. The failover's report goes, and the next
    /// outage notifies afresh, unless the report is about the hotspot
    /// configured now and the save neither stored for it nor removed its
    /// item (`HotspotPasswordReport.stands`).
    static func passwordStored(_ outcome: HotspotStoreOutcome, configuredSSID: String, services: AppServices?) {
        guard case let .stored(stored) = outcome else { return }
        services?.hotspotPasswordChanged(stored.change, configuredSSID: configuredSSID)
    }

    /// Saves `password`, or clears the saved one when it is empty, and
    /// returns what was stored under which SSID and which loaded account
    /// it removed, or the notice for a failure. The store does the keychain work on `KeychainQueue`, so a
    /// save waiting on a keychain dialog waits there while the main actor
    /// (the battery floor, the deadline timer, End) carries on.
    static func storePassword(_ password: String, in secrets: any HotspotSecretStore) async -> HotspotStoreOutcome {
        do {
            let change = if password.isEmpty {
                try await secrets.delete()
            } else {
                try await secrets.save(password)
            }
            return .stored(.init(ssid: change.ssid, password: password, removed: change.removed))
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
            return .failed(notice: "Не удалось сохранить пароль точки доступа: \(error.localizedDescription)")
        }
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var appSection: some View {
        Section("Приложение") {
            Toggle("Запускать при входе в систему", isOn: launchAtLogin)
            loginItemNote
            LabeledContent("Файл настроек") {
                Text(manager.paths.configFile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if LidSimulationBuild.isCompiledIn {
                Text(LidSimulationBuild.marker)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The switch shows what macOS has on file (`LoginItem.isRegistered`:
    /// enabled or waiting for approval), so a registration that an upgrade
    /// dropped reads as off even while config.json still says on, and a
    /// pending one can be withdrawn by turning the switch off; the note
    /// below explains the state.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isRegistered },
            set: { on in
                // Persist only what macOS accepted; a refused change leaves
                // the flag as it was and its error on screen.
                update { config in _ = loginItem.set(on, config: &config) }
            }
        )
    }

    /// One line under the switch: the last error, a pending approval with
    /// the button that opens Login Items, or a flag macOS no longer honours.
    @ViewBuilder
    private var loginItemNote: some View {
        if let error = loginItem.error {
            Text("Автозапуск: \(error)").font(.caption).foregroundStyle(.red)
        } else if loginItem.needsApproval {
            HStack {
                Text("Ждёт подтверждения в Системных настройках: «Основные» > «Объекты входа». Выключите переключатель, чтобы отозвать запрос.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Открыть объекты входа") { loginItem.openLoginItems() }
            }
        } else if manager.config.launchAtLogin, !loginItem.isRegistered {
            Text("Автозапуск: macOS сообщает, что он «\(loginItem.status.description)». Включите переключатель, чтобы зарегистрировать его снова.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Bundle id lists

    private func bundleList(
        title: String,
        items: [String],
        newValue: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Group {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RunningApps.displayName(for: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    removeButton { remove(id) }
                }
            }
            HStack {
                TextField("Идентификатор приложения (bundle ID)", text: newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        add(v)
                        newValue.wrappedValue = ""
                    }
                Button("Добавить") {
                    let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty else { return }
                    add(v)
                    newValue.wrappedValue = ""
                }
                .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Добавить запущенное приложение…") {
                    let apps = RunningApps.candidates(excluding: items)
                    if apps.isEmpty {
                        Text("Других запущенных приложений нет")
                    }
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Удалить")
    }
}

/// Running apps offered by "Add running app…": everything with a bundle id
/// that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                  app.activationPolicy != .prohibited,
                  !excluding.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
