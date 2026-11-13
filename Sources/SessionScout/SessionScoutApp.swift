import SwiftUI
import AppKit
import SessionMonitor

@main
enum SessionScoutApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = MenuBarController()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    // AppKit does not retain status items. Keep this alive for the app's lifetime.
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let attentionPopover = NSPopover()
    private var attentionSessionID: String?
    private var attentionDismissTask: Task<Void, Never>?
    private var attentionIsCompact = false
    private var displayedPromptIdentity: String?
    private var attentionQueue: [String] = []
    private var attentionTracker = AttentionTracker()
    private var completionTracker = CompletionTracker()
    private var completionWasAudible = false
    private var announcedCompletedTurns: Set<String> = []
    private var store: SessionStore?
    private var screenChangeTask: Task<Void, Never>?
    // Let AppKit place this with ordinary app items, then remember Command-drag moves.
    private static let statusItemName = "SessionScoutStatus"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.terminate()
            }
        }

        let store = SessionStore(settings: StartupSettings.load())
        self.store = store
        createStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleVisibilityCheck),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        popover.behavior = .transient
        let scale = store.configuration.interfaceScale
        let size = NSSize(width: store.configuration.window.width * scale,
                          height: store.configuration.window.height * scale)
        popover.contentSize = size
        popover.contentViewController = NSHostingController(rootView:
            ContentView(store: store, onFocusSession: { [weak self] session in self?.focusSession(session) },
                        onReviewSession: { [weak self] session in self?.showAttention(for: session.id) })
                .frame(width: store.configuration.window.width, height: store.configuration.window.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped())
        observeStatus()
        attentionPopover.behavior = .applicationDefined
        store.startMonitoring()
        scheduleVisibilityCheck()
    }

    private func createStatusItem() {
        guard let store else { return }
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        statusItem = nil
        let item = NSStatusBar.system.statusItem(withLength: store.configuration.menuBarShowsCount
            ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        item.autosaveName = Self.statusItemName
        item.isVisible = true
        statusItem = item
        if let button = item.button {
            button.image = ScoutIcon.image
                ?? NSImage(systemSymbolName: "binoculars", accessibilityDescription: "Session Scout")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Session Scout")
        }
        updateStatusItem()
    }

    @objc private func scheduleVisibilityCheck() {
        screenChangeTask?.cancel()
        screenChangeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self else { return }
            // AppKit's status-item window can use virtual coordinates on mirrored
            // menu bars. Let the system move it; do not reorder it from those frames.
            self.statusItem?.isVisible = true
            self.updateStatusItem()
            if self.store?.configuration.attentionSettings.autoShowBubble == true { self.showNextAttention() }
        }
    }

    private func updateStatusItem() {
        guard let store else { return }
        statusItem?.button?.title = store.configuration.menuBarShowsCount
            ? (store.error == nil ? "\(store.sessions.count)" : "!") : ""
        statusItem?.button?.toolTip = "Session Scout — \(store.sessions.count) active sessions"
        let waiting = store.sessions.filter { $0.activity.needsAttention }.count
        statusItem?.button?.contentTintColor = waiting > 0 ? .systemOrange : nil
        if waiting > 0 { statusItem?.button?.toolTip = "Session Scout — \(waiting) session(s) need input" }
    }

    private func observeStatus() {
        guard let store else { return }
        withObservationTracking {
            _ = store.sessions
            _ = store.error
            _ = store.completionSoundEnabled
            _ = store.soundVolume
            updateStatusItem()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeStatus()
                self?.processAttention()
                self?.processCompletions()
            }
        }
    }

    private func processAttention() {
        guard let store, store.configuration.attentionSettings.enabled else { return }
        let waiting = Set(store.sessions.filter { $0.activity.needsAttention || $0.activity == .unknown }.map(\.id))
        attentionQueue.removeAll { !waiting.contains($0) }
        if let current = attentionSessionID, !waiting.contains(current) {
            attentionDismissTask?.cancel()
            attentionPopover.performClose(nil)
            attentionSessionID = nil
        }
        let incoming = attentionTracker.update(store.sessions)
        if let id = attentionSessionID, !attentionIsCompact, attentionPopover.isShown,
           let session = store.sessions.first(where: { $0.id == id }),
           session.activity.needsAttention, session.pendingPrompt?.id != displayedPromptIdentity {
            showAttention(for: id)
        }
        for id in incoming where id != attentionSessionID && !attentionQueue.contains(id) { attentionQueue.append(id) }
        if !incoming.isEmpty, store.actionSoundEnabled {
            store.notificationSounds.play(.actionRequired, volume: store.soundVolume)
        }
        if store.configuration.attentionSettings.autoShowBubble { showNextAttention() }
    }

    private func showNextAttention() {
        guard !popover.isShown, !attentionPopover.isShown, statusItem?.isVisible == true else { return }
        for (index, id) in attentionQueue.enumerated() {
            guard store?.sessions.contains(where: { $0.id == id && $0.activity.needsAttention }) == true else { continue }
            attentionQueue.remove(at: index)
            showAttention(for: id, compact: true)
            return
        }
    }

    private func processCompletions() {
        guard let store else { return }
        let audible = store.completionSoundEnabled && store.soundVolume > 0
        if audible && !completionWasAudible { completionTracker = CompletionTracker() }
        completionWasAudible = audible
        let candidates = completionTracker.update(store.sessions)
        guard audible, !candidates.isEmpty else { return }
        let reader = CompletedTurnReader(home: store.home, timeoutMilliseconds: store.configuration.statusTimeout)
        Task { @MainActor [weak self, weak store] in
            var confirmed: [String] = []
            var notificationIDs: Set<String> = []
            for candidate in candidates {
                if let turn = try? await Task.detached(priority: .utility, operation: {
                    try reader.latestCompletedTurnID(threadID: candidate.threadID)
                }).value {
                    let identity = "\(candidate.threadID):\(turn)"
                    confirmed.append(identity)
                    if candidate.shouldNotify { notificationIDs.insert(identity) }
                }
            }
            guard let self, let store else { return }
            let fresh = notificationIDs.filter { !self.announcedCompletedTurns.contains($0) }
            self.announcedCompletedTurns.formUnion(confirmed)
            if !fresh.isEmpty, store.completionSoundEnabled {
                store.notificationSounds.play(.turnFinished, volume: store.soundVolume)
            }
        }
    }

    private func showAttention(for sessionID: String, compact: Bool = false) {
        guard let store, let button = statusItem?.button,
              store.sessions.contains(where: { $0.id == sessionID && $0.activity.needsAttention }) else { return }
        popover.performClose(nil)
        attentionDismissTask?.cancel()
        attentionPopover.performClose(nil)
        attentionQueue.removeAll { $0 == sessionID }
        attentionSessionID = sessionID
        attentionIsCompact = compact
        displayedPromptIdentity = store.sessions.first(where: { $0.id == sessionID })?.pendingPrompt?.id
        store.promptError = nil
        store.promptFeedback = nil
        store.navigationError = nil
        let settings = store.configuration.attentionSettings
        if compact {
            attentionPopover.contentSize = NSSize(width: settings.previewWidth, height: settings.previewHeight)
            attentionPopover.contentViewController = NSHostingController(rootView:
                AttentionPreviewView(store: store, sessionID: sessionID,
                    onReview: { [weak self] in self?.showAttention(for: sessionID) },
                    onOpen: { [weak self] session in self?.focusSession(session) },
                    onDismiss: { [weak self] in self?.dismissAttention() },
                    onHover: { [weak self] hovering in
                        if hovering { self?.attentionDismissTask?.cancel() }
                        else { self?.scheduleAttentionDismissal(sessionID: sessionID) }
                    })
                    .frame(width: settings.previewWidth, height: settings.previewHeight))
            attentionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            scheduleAttentionDismissal(sessionID: sessionID)
            return
        }
        func content(showDetails: Bool) -> AnyView {
            AnyView(AttentionBubbleView(store: store, sessionID: sessionID,
                onOpenSession: { [weak self] session in self?.focusSession(session) },
                onDismiss: { [weak self] in self?.dismissAttention() }, showDetails: showDetails)
                .frame(width: settings.bubbleWidth).fixedSize(horizontal: false, vertical: true))
        }
        let host = NSHostingController(rootView: content(showDetails: true))
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        let maximumHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        if host.view.fittingSize.height > maximumHeight - 60 {
            host.rootView = content(showDetails: false)
            host.view.layoutSubtreeIfNeeded()
        }
        attentionPopover.contentViewController = host
        attentionPopover.contentSize = host.view.fittingSize
        NSLog("Session Scout request popup size=%@", NSStringFromSize(attentionPopover.contentSize))
        // Present without activating the app or taking focus from the user's current work.
        attentionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func scheduleAttentionDismissal(sessionID: String) {
        attentionDismissTask?.cancel()
        guard attentionIsCompact, let delay = store?.configuration.attentionSettings.dismissalDelay else { return }
        attentionDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard self?.attentionSessionID == sessionID, self?.attentionIsCompact == true else { return }
            self?.dismissAttention()
        }
    }

    private func dismissAttention() {
        attentionDismissTask?.cancel()
        attentionPopover.performClose(nil)
        attentionSessionID = nil
        attentionIsCompact = false
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        dismissAttention()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func focusSession(_ session: CodexSession) {
        guard let store else { return }
        store.navigationError = nil
        do {
            let url = try SessionNavigation.projectURL(for: session)
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
                  NSWorkspace.shared.open(url) else {
                store.navigationError = "Couldn’t open the project in VS Code. Make sure VS Code is installed and handles vscode:// links."
                return
            }
            popover.performClose(nil)
            dismissAttention()
        } catch {
            store.navigationError = error.localizedDescription
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct StartupSettings {
    let configuration: AppConfiguration
    let warning: String?

    static func load() -> Self {
        let environment = ProcessInfo.processInfo.environment
        let customPath = environment["SESSION_SCOUT_CONFIG"] ?? environment["CODEX_WATCHER_CONFIG"]
        let defaultURL = FileManager.default.fileExists(atPath: AppConfiguration.userConfigURL.path)
            ? AppConfiguration.userConfigURL
            : (FileManager.default.fileExists(atPath: AppConfiguration.legacyUserConfigURL.path)
                ? AppConfiguration.legacyUserConfigURL : AppConfiguration.userConfigURL)
        let url = customPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? defaultURL
        guard customPath != nil || FileManager.default.fileExists(atPath: url.path) else {
            return Self(configuration: .bundled, warning: nil)
        }
        do { return Self(configuration: try .read(from: url), warning: nil) }
        catch {
            return Self(configuration: .bundled,
                        warning: "Couldn’t load config at \(url.path): \(error.localizedDescription) Using bundled settings.")
        }
    }
}

@MainActor
@Observable
final class SessionStore {
    var sessions: [CodexSession] = []
    var notice: String?
    var error: String?
    var navigationError: String?
    var promptError: String?
    var promptFeedback: String?
    var promptMessageID: String?
    var submittingPromptID: String?
    var submittedPromptIDs: Set<String> = []
    var lastRefresh: Date?
    var refreshing = false
    var home: URL
    private(set) var refreshIntervalSeconds: Double
    private(set) var actionSoundEnabled: Bool
    private(set) var completionSoundEnabled: Bool
    private(set) var soundVolume: Double
    let notificationSounds = NotificationSounds()
    let configuration: AppConfiguration
    let configurationWarning: String?
    private var monitoringTask: Task<Void, Never>?

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(self.refreshIntervalSeconds)) }
                catch { return }
            }
        }
    }

    fileprivate init(settings: StartupSettings) {
        configuration = settings.configuration
        configurationWarning = settings.warning
        actionSoundEnabled = UserDefaults.standard.object(forKey: "actionSoundEnabled") as? Bool
            ?? configuration.soundSettings.actionRequiredEnabled
        completionSoundEnabled = UserDefaults.standard.object(forKey: "completionSoundEnabled") as? Bool
            ?? configuration.soundSettings.turnFinishedEnabled
        if let saved = UserDefaults.standard.object(forKey: "soundVolume") as? Double, saved.isFinite, (0...1).contains(saved) {
            soundVolume = saved
        } else { soundVolume = configuration.soundSettings.volume }
        if let saved = UserDefaults.standard.object(forKey: "refreshIntervalSeconds") as? Double,
           saved.isFinite, (1...3600).contains(saved) {
            refreshIntervalSeconds = saved
        } else {
            refreshIntervalSeconds = configuration.refreshIntervalSeconds
        }
        if let configured = configuration.codexHome {
            home = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        } else if let saved = UserDefaults.standard.string(forKey: "codexHome") {
            home = URL(fileURLWithPath: saved)
        } else {
            home = SessionScanner.defaultHome
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let scanner = SessionScanner(home: home, configuration: configuration)
        do {
            let snapshot = try await Task.detached(priority: .utility) { try scanner.scan() }.value
            let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            sessions = snapshot.sessions.map { scanned in
                var session = scanned
                if session.activity == .unknown { session.pendingPrompt = previous[session.id]?.pendingPrompt }
                return session
            }
            notice = snapshot.notice
            error = nil
            lastRefresh = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setRefreshInterval(_ seconds: Double) {
        guard configuration.refreshOptions.contains(seconds) else { return }
        refreshIntervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "refreshIntervalSeconds")
        restartMonitoring()
    }

    func resetRefreshInterval() {
        UserDefaults.standard.removeObject(forKey: "refreshIntervalSeconds")
        refreshIntervalSeconds = configuration.refreshIntervalSeconds
        restartMonitoring()
    }

    func setActionSoundEnabled(_ enabled: Bool) {
        actionSoundEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "actionSoundEnabled")
    }

    func setCompletionSoundEnabled(_ enabled: Bool) {
        completionSoundEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "completionSoundEnabled")
    }

    func setSoundVolume(_ volume: Double) {
        guard volume.isFinite, (0...1).contains(volume) else { return }
        soundVolume = volume
        UserDefaults.standard.set(volume, forKey: "soundVolume")
    }

    private func restartMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        startMonitoring()
    }

    func chooseHome() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Home"
        panel.message = "Choose the .codex folder, or your custom CODEX_HOME directory."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = home
        guard panel.runModal() == .OK, let url = panel.url else { return }
        home = url
        UserDefaults.standard.set(url.path, forKey: "codexHome")
        sessions = []
        lastRefresh = nil
        Task { await refresh() }
    }

    func resolve(_ prompt: PendingPrompt, with resolution: PromptResolution) async {
        guard submittingPromptID == nil, !submittedPromptIDs.contains(prompt.id) else { return }
        promptMessageID = prompt.id
        guard sessions.contains(where: { $0.id == prompt.threadID && $0.pendingPrompt?.id == prompt.id }) else {
            promptError = "The prompt is no longer current. Refresh or open the session."
            return
        }
        submittingPromptID = prompt.id
        promptError = nil
        promptFeedback = nil
        defer { submittingPromptID = nil }
        let client = PromptClient(home: home, timeoutMilliseconds: configuration.attentionSettings.requestTimeoutMilliseconds)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try client.resolve(prompt, with: resolution)
            }.value
            submittedPromptIDs.insert(prompt.id)
            promptFeedback = result == .confirmed ? "Request resolved." : "Response sent; waiting for Codex to confirm."
            await refresh()
        } catch {
            promptError = error.localizedDescription
            await refresh()
        }
    }
}

struct ContentView: View {
    let store: SessionStore
    let onFocusSession: (CodexSession) -> Void
    let onReviewSession: (CodexSession) -> Void
    private var fontSize: Double { store.configuration.textSize }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ScoutIcon()
                    .frame(width: fontSize + 8, height: fontSize + 8)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Session Scout").font(.system(size: fontSize + 6, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Active local sessions").foregroundStyle(.secondary)
                        Text("\(store.sessions.count)")
                            .fontWeight(.semibold).monospacedDigit().foregroundStyle(.orange)
                    }
                    .font(.system(size: fontSize - 1)).lineLimit(1)
                }
                Spacer()
            }
            .padding(16)
            .background(.orange.opacity(0.05))
            Divider()

            if let waiting = store.sessions.first(where: { $0.activity.needsAttention }) {
                Button {
                    onReviewSession(waiting)
                } label: {
                    Label("Review requests (\(store.sessions.filter { $0.activity.needsAttention }.count))", systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(.orange).padding(12).background(.orange.opacity(0.08))
            }

            if let warning = store.configurationWarning {
                banner(warning, symbol: "exclamationmark.triangle", color: .orange)
            }
            if let error = store.navigationError {
                banner(error, symbol: "arrow.up.forward.app", color: .orange)
            }
            if let error = store.error {
                banner("Couldn’t refresh: \(error). Displayed sessions may be out of date.", symbol: "exclamationmark.triangle", color: .orange)
            } else if let notice = store.notice {
                banner(notice, symbol: "info.circle", color: .secondary)
            }

            if store.lastRefresh == nil && store.error == nil {
                Spacer()
                ProgressView("Looking for sessions…")
                Spacer()
            } else if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(store.error == nil ? "No active sessions" : "Sessions unavailable")
                    } icon: {
                        ScoutIcon().frame(width: 32, height: 32)
                    }
                } description: {
                    Text(store.error == nil ? "Open a local Codex session. It will appear here automatically." : "Check your Codex home folder and file permissions, then refresh.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(store.sessions) { session in
                    Button {
                        onFocusSession(session)
                    } label: {
                        SessionRow(session: session, stale: store.error != nil, fontSize: fontSize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Switch to \(session.title)")
                        .padding(.vertical, 8)
                        .contextMenu {
                            if session.activity.needsAttention {
                                Button("Review Request") { onReviewSession(session) }
                            }
                            Button("Copy Session ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.id, forType: .string)
                            }
                            if let directory = session.workingDirectory {
                                Button("Copy Folder Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(directory, forType: .string)
                                }
                            }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(.orange.opacity(0.025))
            }

            if !store.sessions.contains(where: { $0.activity == .waitingForApproval }) {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        store.chooseHome()
                    } label: { Label("Folder", systemImage: "folder") }
                        .help("Choose Codex Home: \(store.home.path)")
                        .disabled(store.refreshing)
                    Button {
                        Task { await store.refresh() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                        .disabled(store.refreshing)
                    Spacer()
                    SettingsMenu(store: store)
                    Button { NSApplication.shared.terminate(nil) } label: { QuitIcon(size: fontSize + 4) }
                        .keyboardShortcut("q")
                        .help("Quit Session Scout (⌘Q)")
                        .accessibilityLabel("Quit Session Scout")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .font(.system(size: fontSize - 1))
                .padding(14)
            }
        }
        .background(.background)
        .font(.system(size: fontSize))
        .tint(.orange)
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: fontSize - 1)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(color.opacity(0.08))
            .padding(.horizontal, 24).padding(.bottom, 12)
    }
}

private struct SessionRow: View {
    let session: CodexSession
    let stale: Bool
    let fontSize: Double

    private var statusColor: Color {
        if stale { return .orange }
        switch session.activity {
        case .working: return .green
        case .waitingForInput, .waitingForApproval: return .orange
        case .systemError: return .red
        case .idle, .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(.system(size: fontSize + 1, weight: .semibold)).lineLimit(1)
                    .truncationMode(.tail).help(session.title)
                if let directory = session.workingDirectory {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").foregroundStyle(.orange)
                        Text(URL(fileURLWithPath: directory).lastPathComponent.isEmpty
                             ? directory : URL(fileURLWithPath: directory).lastPathComponent)
                            .fontWeight(.medium).foregroundStyle(.primary)
                            .layoutPriority(1)
                        Text(directory)
                            .font(.system(size: fontSize - 2)).foregroundStyle(.secondary)
                            .truncationMode(.head)
                    }
                    .font(.system(size: fontSize)).lineLimit(1).help(directory)
                }
                HStack(spacing: 10) {
                    Text(session.id).font(.system(size: fontSize - 2).monospaced()).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(session.id)
                    if let source = session.source { Text(source).font(.system(size: fontSize - 2)).lineLimit(1) }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(stale ? "Stale" : session.activity.label).foregroundStyle(.secondary)
            }
                .font(.system(size: fontSize - 2))
                .fixedSize()
                .help(stale ? "Session data may be out of date." : session.activity.explanation)
        }
        .padding(.vertical, 2)
    }
}
