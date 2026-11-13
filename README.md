# Codex Watcher

<img src="Assets/AppIcon.png" alt="Codex Watcher app icon" width="96" />

A native SwiftUI macOS menu bar app that lists active local Codex sessions. It refreshes every 15 seconds by default, including while the dropdown is closed. Click the terminal icon in the menu bar to view titles, working folders, sources, and IDs. Requires macOS 14 or newer and Xcode 16 or newer (Swift 6).

The app runs without a Dock icon or main window. The dropdown includes Refresh, Folder, Settings, and a power icon to Quit; right-click a session to copy its ID. The footer hides during permission requests. Hover over truncated text to read it in full. The menu bar icon stays compact by default; hover over it for the session count, or enable `showMenuBarSessionCount` to display the count alongside it (or `!` on scan errors).

Use **Settings → Refresh interval** to choose 1, 2, 5, 15, 30, or 60 seconds. The selection takes effect immediately and persists across launches. **Use config default** clears the saved choice. The dropdown omits the refresh-frequency and last-update status strip.

Each session shows its live status: **Working**, **Idle**, **Needs input**, **Approval**, **Error**, or **Unknown**. Hover over the status for its meaning. Idle means no turn is running and the session is ready for another prompt; Needs input means Codex explicitly paused a running turn to ask a question. Status refreshes with the session list at the chosen interval. Nonblocking questions that do not set a waiting flag are not detected as input alerts.

When a session needs input or approval, the menu icon turns amber and an anchored bubble appears without activating the app. It shows the session and folder, the pending command or question, and the supported response controls. Command approvals offer **Allow once**, **Decline**, and **Stop turn**. Questions offer the original choices or a text field, with no choice selected automatically. Secret text answers use a secure field. **Open session** switches to its VS Code project window for context. File approvals require reviewing the changes in the session before allowing them; the bubble can still decline or stop them. Other request types provide Open session.

Automatic alerts use a compact 300 × 132 point preview with only the session, folder, **Review**, and **Open session**. The preview hides after six seconds; hovering pauses dismissal. Review opens the response form (340 × 360 points), which stays open while you interact. Dismissing a preview never answers the request; the menu icon remains amber while input is outstanding.

**Later** dismisses the bubble without answering. Alerts are deduplicated per pending request, and multiple sessions queue separately. To revisit a dismissed request, click **Review requests** in the dropdown or right-click the session and choose **Review Request**. Responding in the original client also clears the bubble on the next scan. Responses are sent only after an explicit click, only after replaying and verifying the same pending request, and never retried automatically if confirmation is lost.

Click a session to open its working folder in VS Code using its [project URL handler](https://code.visualstudio.com/docs/configure/command-line#_opening-vs-code-with-urls). VS Code brings forward the window for that project (or opens the folder if it is no longer open). The dropdown closes after the link is accepted. This targets the project window, not an individual terminal tab; sessions in the same folder share a destination. Only sessions recorded with source `vscode` are supported for switching; other sources show a message rather than opening an unrelated app or resuming a second copy of a session.

Build a launchable app:

```sh
bash scripts/run-app.sh
```

For development, open `Package.swift` in Xcode and run the `CodexWatcher` executable scheme, or use `swift run CodexWatcher`.

The launch script builds the app, quits any running copy, and opens the new build. Opening the `.app` directly while an older copy is running reuses that process. To build without launching, use `bash scripts/build-app.sh`.

The app icon is bundled as `AppIcon.icns`. Its editable source is [`Assets/AppIcon.svg`](Assets/AppIcon.svg); run `bash scripts/build-icon.sh` to regenerate the PNG preview and macOS icon sizes. App builds regenerate the icon when its source changes. Rendering uses native macOS tools and does not require additional dependencies.

The app defaults to `~/.codex`, honors `CODEX_HOME` when launched from a shell, and remembers a custom folder chosen using the toolbar's folder button. Finder launches generally don't inherit shell environment variables, so use the folder button for a custom home.

### Configuration

App settings live in [`Sources/SessionMonitor/Resources/config.json`](Sources/SessionMonitor/Resources/config.json): refresh interval, optional Codex home path, database busy timeout, menu bar count visibility, and dropdown dimensions (`window.width` and `window.height`). `window.scale` defaults to `0.85`, scaling the entire interface, including text, spacing, and controls, down by 15%. The final dropdown dimensions are width and height multiplied by scale (374 × 442 points by default). The existing `window` configuration key is retained for compatibility; its minimum dimensions remain validation bounds for the unscaled size. Older configs without the new keys inherit their bundled defaults. Edit this file and rebuild to change bundled defaults.

To customize settings without rebuilding, copy that JSON file to `~/Library/Application Support/CodexWatcher/config.json`, edit it, and relaunch the app. Alternatively, set `CODEX_WATCHER_CONFIG` to the path of a complete config file when launching from a shell. Invalid config files produce a visible warning and fall back to bundled settings.

`codexHome: null` uses the remembered folder, then `CODEX_HOME`, then `~/.codex`. A configured path takes priority at startup; the folder picker can change it for the current run. Refresh intervals must be at least one second; database timeouts are in milliseconds. Window dimensions are in points. Visual styling and Codex protocol filenames remain implementation constants.

`refreshIntervalOptionsSeconds` defines the choices in Settings. A saved Settings selection overrides `refreshIntervalSeconds` until **Use config default** is chosen. Scans never overlap; the selected interval is the pause after a scan completes, so slow scans or prompt-query timeouts can extend the effective refresh period.

`fontSize` controls the base text size before interface scaling (16 points by default; valid range 10–24). Session titles are slightly larger, while metadata is slightly smaller. The interface uses system foreground/background colors with small green or amber status indicators.

The menu item saves its position under the stable autosave name `CodexWatcherStatus`. `menuBarPreferredPosition` is its fallback distance from the menu bar's right edge (default 240 points). The app seeds that position on first launch, preserves Command-drag placement, and checks after display changes for an off-screen item or one behind a camera notch. If needed, it recreates the item at the fallback position. The position preference is AppKit's macOS-specific saved-position key.

`liveStatusTimeoutMilliseconds` limits the entire live-status query (default 2000 ms, valid range 100–10000). A missing socket, timeout, unsupported protocol, or session owned by a different server produces Unknown status and a notice; activity is never guessed from timestamps.

`attention` controls input alerts: `enabled` enables prompt retrieval and alerts, `autoShowBubble` enables automatic presentation, `playSound` adds a sound (off by default), `bubbleWidth`/`bubbleHeight` set the bubble dimensions, and `requestTimeoutMilliseconds` bounds each prompt retrieval or response. Set `autoShowBubble` to false to review requests manually through the dropdown. No macOS notification permission is needed because alerts use an in-app popover anchored to the menu icon.

`notificationWidth`, `notificationHeight`, and `autoDismissSeconds` control the compact preview. Older configuration files inherit the bundled preview settings automatically.

### What counts as active

An active session has an exclusive writer lock held by a local Codex process in `thread-writer-locks/<session-id>.lock`. This includes open sessions waiting for input; it does not indicate that the model is currently generating. Stale, unlocked files are excluded. Session titles and other details come from read-only queries against the latest `state_*.sqlite` database. If metadata is missing or unavailable, the app still lists active IDs with a notice.

This follows Codex's [local writer-lock implementation](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/writer_lock.rs). These are internal file formats and may change. Older Codex versions without writer locks and sessions running on remote machines are not detected. A retained writer in a background Codex server also counts as active, even if its client window is closed.

The app probes locks without waiting and releases successful probes immediately. For live status it connects to the existing `app-server-control/app-server-control.sock` using Codex's WebSocket transport, initializes a client, and issues metadata-only `thread/read` requests. This uses the existing server's live `Thread.status`, including `waitingOnUserInput` and `waitingOnApproval` flags.

For waiting sessions, input alerts attach through `thread/resume` with `excludeTurns: true`, using no configuration overrides, to receive the server's replayed pending requests. Connections close after retrieval. On an explicit response, a fresh connection replays the prompt again and compares its request ID, method, and complete parameters before sending a response on that connection. The app waits for `serverRequest/resolved` confirmation. It does not start a new turn or save broader approval policies. Metadata-only status polling remains read-only; answering a prompt changes that live session as directed by the user.

The app does not modify Codex files, read authentication credentials, or start a second Codex server. The local app is ad hoc signed and runs without App Sandbox so it can inspect the chosen home folder. Distribution would require your own signing and notarization.

### Verification

```sh
swift test
CODEX_WATCHER_LIVE_TEST=1 swift test --filter testLocalSessionSmokeCheckWhenRequested
CODEX_WATCHER_BENCHMARK=1 swift test --filter testLocalScannerPerformanceWhenRequested
```

Tests exercise actual OS locks, stale-file exclusion, metadata lookup, live status mapping, WebSocket framing, alert deduplication, complete question responses, stale and resolved prompts, overlapping client/server RPC IDs, and lost response confirmations. The optional live test reads status and pending prompts only; it never sends an approval or answer.

The optional benchmark measures 20 scans and reports mean elapsed time and CPU time in the watcher process. It excludes Codex server CPU. Faster polling increases socket connections, database reads, server work, and timer wakeups; 1 second causes roughly 15 times as many scans as the default, with the actual rate bounded by scan duration. These reads do not start model-generation turns. Waiting prompts cost more than ordinary metadata/status scans because their requests must be replayed.
