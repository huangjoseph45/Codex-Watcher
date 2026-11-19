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
    private var attentionPositionTask: Task<Void, Never>?
    private var attentionPresentationID = UUID()
    private var attentionIsCompact = false
    private var attentionIsAutomatic = false
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(scheduleVisibilityCheck),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

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
        // A request may update while the previous presentation is still closing.
        // Avoid AppKit animating between obsolete and current anchor geometry.
        attentionPopover.animates = false
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
            button.image = ScoutIcon.menuBarImage
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
        attentionPositionTask?.cancel()
        // Hide while the system moves menu bars between displays or Spaces.
        // Keep the content and answers so it can be re-anchored after layout settles.
        attentionPopover.close()
        screenChangeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self else { return }
            // AppKit's status-item window can use virtual coordinates on mirrored
            // menu bars. Let the system move it; do not reorder it from those frames.
            self.statusItem?.isVisible = true
            self.updateStatusItem()
            self.screenChangeTask = nil
            if self.attentionSessionID != nil {
                self.positionAttentionPopover()
            } else if self.store?.popupsEnabled == true {
                self.showNextAttention()
            }
        }
    }

    private func updateStatusItem() {
        guard let store else { return }
        statusItem?.button?.title = store.configuration.menuBarShowsCount
            ? (store.error == nil ? "\(store.sessions.count)" : "!") : ""
        statusItem?.button?.toolTip = "Session Scout — \(store.sessions.count) active sessions"
        let waiting = store.sessions.filter { $0.needsAttention }.count
        // Let AppKit supply the template color, including while a popup is open.
        statusItem?.button?.contentTintColor = nil
        if waiting > 0 { statusItem?.button?.toolTip = "Session Scout — \(waiting) session(s) need input" }
    }

    private func observeStatus() {
        guard let store else { return }
        withObservationTracking {
            _ = store.popupsEnabled
            _ = store.approvalPopupsEnabled
            _ = store.questionPopupsEnabled
            _ = store.backgroundQuestionPopupsEnabled
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
        let waiting = Set(store.sessions.filter { $0.needsAttention || $0.activity == .unknown }.map(\.id))
        attentionQueue.removeAll { !waiting.contains($0) }
        if let current = attentionSessionID, !waiting.contains(current) {
            dismissAttention()
        }
        if attentionIsAutomatic, let id = attentionSessionID,
           let session = store.sessions.first(where: { $0.id == id }), !store.shouldShowPopup(for: session) {
            dismissAttention()
        }
        let incoming = attentionTracker.update(store.sessions)
        if let id = attentionSessionID, !attentionIsCompact, attentionPopover.isShown,
           let session = store.sessions.first(where: { $0.id == id }),
           session.needsAttention, session.attentionIdentity != displayedPromptIdentity {
            showAttention(for: id, automatic: attentionIsAutomatic)
        }
        for id in incoming where id != attentionSessionID && !attentionQueue.contains(id) { attentionQueue.append(id) }
        if !incoming.isEmpty, store.actionSoundEnabled {
            store.notificationSounds.play(.actionRequired, volume: store.soundVolume)
        }
        if store.popupsEnabled { showNextAttention() }
    }

    private func showNextAttention() {
        guard store?.popupsEnabled == true, !popover.isShown, !attentionPopover.isShown,
              statusItem?.isVisible == true else { return }
        for id in attentionQueue {
            guard let session = store?.sessions.first(where: { $0.id == id && $0.needsAttention }),
                  store?.shouldShowPopup(for: session) == true else { continue }
            let permission = store?.sessions.first(where: { $0.id == id })?.activity == .waitingForApproval
            showAttention(for: id, compact: !permission, automatic: true)
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

    private func showAttention(for sessionID: String, compact: Bool = false, automatic: Bool = false) {
        guard let store, store.sessions.contains(where: { $0.id == sessionID && $0.needsAttention }) else { return }
        guard let anchor = statusAnchor() else {
            // Never let AppKit choose an unrelated display for an off-screen status item.
            if !attentionQueue.contains(sessionID) { attentionQueue.append(sessionID) }
            retryAttentionPresentation(for: sessionID, compact: compact, automatic: automatic)
            return
        }
        popover.close()
        attentionDismissTask?.cancel()
        attentionPositionTask?.cancel()
        attentionPresentationID = UUID()
        attentionQueue.removeAll { $0 == sessionID }
        attentionSessionID = sessionID
        attentionIsCompact = compact
        attentionIsAutomatic = automatic
        displayedPromptIdentity = store.sessions.first(where: { $0.id == sessionID })?.attentionIdentity
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
            positionAttentionPopover()
            scheduleAttentionDismissal(sessionID: sessionID)
            return
        }
        let maximumHeight = max(100, anchor.screen.visibleFrame.height - 60)
        let content = AttentionBubbleView(store: store, sessionID: sessionID,
            onOpenSession: { [weak self] session in self?.focusSession(session) },
            onDismiss: { [weak self] in self?.dismissAttention() })
            .frame(width: settings.bubbleWidth)
        let measure = NSHostingController(rootView: content)
        measure.view.layoutSubtreeIfNeeded()
        let height = min(measure.view.fittingSize.height, maximumHeight)
        let host = NSHostingController(rootView:
            ScrollView { content }.frame(width: settings.bubbleWidth, height: height))
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        attentionPopover.contentViewController = host
        attentionPopover.contentSize = host.view.fittingSize
        NSLog("Session Scout request popup size=%@", NSStringFromSize(attentionPopover.contentSize))
        // Present without activating the app or taking focus from the user's current work.
        positionAttentionPopover()
    }

    /// Status-item windows can briefly have zero or virtual coordinates during
    /// launch, display changes, and Space transitions. Use only a real menu-bar anchor.
    private func statusAnchor() -> (button: NSStatusBarButton, screen: NSScreen, rect: NSRect)? {
        guard screenChangeTask == nil, statusItem?.isVisible == true, let button = statusItem?.button,
              let window = button.window, window.isVisible, !button.isHiddenOrHasHiddenAncestor,
              !button.bounds.isEmpty else { return nil }
        button.layoutSubtreeIfNeeded()
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              let screen = NSScreen.screens.first(where: { screen in
                  let frame = screen.frame
                  let menuBarHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) + 8
                  return frame.contains(NSPoint(x: rect.midX, y: rect.midY))
                      && rect.maxY >= frame.maxY - menuBarHeight
              }) else { return nil }
        return (button, screen, rect)
    }

    private func positionAttentionPopover() {
        guard let sessionID = attentionSessionID else { return }
        guard let anchor = statusAnchor() else {
            attentionPopover.close()
            retryAttentionPresentation(for: sessionID, compact: attentionIsCompact, automatic: attentionIsAutomatic)
            return
        }
        attentionPopover.show(relativeTo: anchor.button.bounds, of: anchor.button, preferredEdge: .minY)
        correctAttentionPosition(anchorRect: anchor.rect, screen: anchor.screen)
        let presentationID = attentionPresentationID
        attentionPositionTask?.cancel()
        attentionPositionTask = Task { @MainActor [weak self] in
            // Give AppKit a layout pass, then refresh the same popover's anchor.
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            guard !Task.isCancelled, let self, self.attentionPresentationID == presentationID,
                  self.attentionSessionID == sessionID, self.attentionPopover.isShown,
                  let anchor = self.statusAnchor() else { return }
            self.attentionPopover.show(relativeTo: anchor.button.bounds, of: anchor.button, preferredEdge: .minY)
            self.correctAttentionPosition(anchorRect: anchor.rect, screen: anchor.screen)
            NSLog("Session Scout request anchor=%@ popup=%@ screen=%@", NSStringFromRect(anchor.rect),
                  NSStringFromRect(self.attentionPopover.contentViewController?.view.window?.frame ?? .zero),
                  NSStringFromRect(anchor.screen.frame))
        }
    }

    private func correctAttentionPosition(anchorRect: NSRect, screen: NSScreen) {
        guard let window = attentionPopover.contentViewController?.view.window else { return }
        let frame = window.frame
        // Allow AppKit's arrow and edge clamping, but reject a detached/origin placement.
        let belowIcon = abs(frame.maxY - anchorRect.minY) <= 40
        let aligned = anchorRect.midX >= frame.minX - 24 && anchorRect.midX <= frame.maxX + 24
        guard !belowIcon || !aligned || !screen.frame.intersects(frame) else { return }
        let available = screen.visibleFrame
        let left = min(max(anchorRect.midX - frame.width / 2, available.minX),
                       max(available.minX, available.maxX - frame.width))
        let top = min(anchorRect.minY, available.maxY)
        window.setFrameTopLeftPoint(NSPoint(x: left, y: top))
        NSLog("Session Scout corrected detached request popup: %@ -> %@", NSStringFromRect(frame), NSStringFromRect(window.frame))
    }

    private func retryAttentionPresentation(for sessionID: String, compact: Bool, automatic: Bool) {
        attentionPositionTask?.cancel()
        attentionPositionTask = Task { @MainActor [weak self] in
            // Retry briefly while the menu bar settles; leave the request queued if it stays hidden.
            for _ in 0..<5 {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                guard let self, self.store?.sessions.contains(where: { $0.id == sessionID && $0.needsAttention }) == true else { return }
                if automatic, let session = self.store?.sessions.first(where: { $0.id == sessionID }),
                   self.store?.shouldShowPopup(for: session) != true { return }
                if self.statusAnchor() != nil {
                    self.showAttention(for: sessionID, compact: compact, automatic: automatic)
                    return
                }
            }
        }
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
        attentionPositionTask?.cancel()
        attentionPresentationID = UUID()
        attentionPopover.close()
        attentionSessionID = nil
        attentionIsCompact = false
        attentionIsAutomatic = false
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
        if session.source?.lowercased() != "vscode" {
            showSessionAppChooser(for: session)
            return
        }
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

    private func showSessionAppChooser(for session: CodexSession) {
        guard let button = statusItem?.button else { return }
        // Codex's writer process is often a daemon and does not identify the
        // client tab. Let the user choose an existing host instead of guessing.
        let hostIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.openai.codex"]
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(hostIDs.contains) == true && $0.activationPolicy == .regular
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let menu = NSMenu(title: "Open session")
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Choose the app running this session", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for app in apps {
            let item = NSMenuItem(title: "Switch to \(app.localizedName ?? "terminal")",
                                  action: #selector(activateSessionApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            menu.addItem(item)
        }
        let hint = NSMenuItem(title: apps.isEmpty ? "No supported session app is running" : "Then select the session’s tab or window", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Session ID", action: #selector(copySessionReference(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = session.id
        menu.addItem(copy)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func activateSessionApp(_ item: NSMenuItem) {
        guard let app = item.representedObject as? NSRunningApplication else { return }
        if app.activate(options: []) {
            popover.performClose(nil)
            dismissAttention()
        } else {
            store?.navigationError = "Couldn’t activate that app. Open the session’s terminal manually."
        }
    }

    @objc private func copySessionReference(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
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
    private(set) var popupsEnabled: Bool
    private(set) var approvalPopupsEnabled: Bool
    private(set) var questionPopupsEnabled: Bool
    private(set) var backgroundQuestionPopupsEnabled: Bool
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
        approvalPopupsEnabled = UserDefaults.standard.object(forKey: "approvalPopupsEnabled") as? Bool ?? true
        questionPopupsEnabled = UserDefaults.standard.object(forKey: "questionPopupsEnabled") as? Bool ?? true
        backgroundQuestionPopupsEnabled = UserDefaults.standard.object(forKey: "backgroundQuestionPopupsEnabled") as? Bool ?? true
        popupsEnabled = UserDefaults.standard.object(forKey: "popupsEnabled") as? Bool
            ?? configuration.attentionSettings.autoShowBubble
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
                if configuration.attentionSettings.enabled, !session.reviewQuestionChecked, !session.activity.needsAttention {
                    session.reviewQuestion = previous[session.id]?.reviewQuestion
                }
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

    func shouldShowPopup(for session: CodexSession) -> Bool {
        guard popupsEnabled else { return false }
        if session.activity == .waitingForApproval {
            return approvalPopupsEnabled
        }
        if session.reviewQuestion != nil {
            return backgroundQuestionPopupsEnabled
        }
        return questionPopupsEnabled
    }

    func setApprovalPopupsEnabled(_ enabled: Bool) {
        approvalPopupsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "approvalPopupsEnabled")
    }

    func setQuestionPopupsEnabled(_ enabled: Bool) {
        questionPopupsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "questionPopupsEnabled")
    }

    func setBackgroundQuestionPopupsEnabled(_ enabled: Bool) {
        backgroundQuestionPopupsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "backgroundQuestionPopupsEnabled")
    }

    func setPopupsEnabled(_ enabled: Bool) {
        popupsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "popupsEnabled")
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
    @State private var selectedTab = Tab.sessions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var pendingRequestCount: Int { store.sessions.filter { $0.needsAttention }.count }
    private enum Tab: String, CaseIterable {
        case sessions = "Sessions", settings = "Settings"
    }

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

            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .background {
                GeometryReader { geometry in
                    let count = CGFloat(Tab.allCases.count)
                    let width = max(0, (geometry.size.width - 4 * (count - 1)) / count)
                    let index = Tab.allCases.firstIndex(of: selectedTab) ?? 0
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.orange.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.orange.opacity(0.45), lineWidth: 1)
                        }
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: CGFloat(index) * (width + 4))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: selectedTab)
                }
                .allowsHitTesting(false)
            }
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)

            if pendingRequestCount > 0 {
                requestNotifier
            }

            switch selectedTab {
            case .settings:
                SettingsView(store: store)
            case .sessions:
                sessionsContent
            }

            Divider()
            HStack(spacing: 12) {
                if selectedTab != .settings {
                    Button {
                        Task { await store.refresh() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                        .buttonHoverFeedback(highlightPadding: 3)
                        .disabled(store.refreshing)
                }
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: { QuitIcon(size: fontSize + 4) }
                    .keyboardShortcut("q")
                    .help("Quit Session Scout (⌘Q)")
                    .accessibilityLabel("Quit Session Scout")
                    .buttonHoverFeedback(highlightPadding: 3)
            }
            .buttonStyle(.borderless).foregroundStyle(.orange)
            .font(.system(size: fontSize - 1)).padding(14)
        }
        .background(.background)
        .font(.system(size: fontSize))
        .tint(.orange)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: fontSize - 3, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
                .foregroundStyle(selected ? Color.orange : Color.primary)
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var requestNotifier: some View {
        let hasRequests = pendingRequestCount > 0
        return Button {
            if let session = store.sessions.first(where: { $0.needsAttention }) {
                onReviewSession(session)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: hasRequests ? "exclamationmark.bubble.fill" : "checkmark.bubble")
                    .font(.system(size: fontSize + 2))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review requests").fontWeight(.semibold)
                    Text(hasRequests ? "Permission requests and questions need your attention." : "No pending requests")
                        .font(.system(size: fontSize - 3)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(pendingRequestCount)")
                    .font(.system(size: fontSize - 2, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(hasRequests ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                Image(systemName: "chevron.right").font(.system(size: fontSize - 4, weight: .semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(hasRequests ? Color.orange : Color.secondary)
            .background(hasRequests ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(hasRequests ? Color.orange.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(hasRequests ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!hasRequests)
        .help(hasRequests ? "Review \(pendingRequestCount) pending request(s)" : "No pending requests")
        .accessibilityLabel(hasRequests ? "Review requests, \(pendingRequestCount) pending" : "Review requests, no pending requests")
        .buttonHoverFeedback()
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var sessionsContent: some View {
        VStack(spacing: 0) {
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
                        .buttonHoverFeedback(highlightPadding: 3)
                        .contextMenu {
                            if session.needsAttention {
                                Button("Review Request") {
                                    onReviewSession(session)
                                }
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

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if stale || session.reviewQuestion != nil { return .orange }
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
                Text(stale ? "Stale" : (session.reviewQuestion != nil ? "Question" : session.activity.label)).foregroundStyle(.secondary)
            }
                .font(.system(size: fontSize - 2))
                .fixedSize()
                .help(stale ? "Session data may be out of date." : (session.reviewQuestion != nil ? "Codex has a clarification question. Open the session to respond." : session.activity.explanation))
        }
        .padding(.vertical, 2)
    }
}
