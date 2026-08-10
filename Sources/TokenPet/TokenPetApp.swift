import AppKit
import Combine
import Darwin
import SwiftUI
import TokenPetCore

private enum AppVersion {
    static let label = "v0.1.0"
    static let displayName = "Codex Session Guardian"
}

private extension Notification.Name {
    static let petAnimationThemeDidChange = Notification.Name("PetAnimationThemeDidChange")
}

private enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = Darwin.open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

@main
@MainActor
final class TokenPetAppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: TokenPetAppDelegate?
    private var model: DashboardModel?
    private var floatingPet: FloatingPetController?
    private var statusItem: StatusItemController?

    static func main() {
        guard SingleInstance.acquire() else { return }
        let application = NSApplication.shared
        let delegate = TokenPetAppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        delegate.start()
        application.run()
    }

    private func start() {
        let model = DashboardModel()
        let floatingPet = FloatingPetController(model: model)
        self.model = model
        self.floatingPet = floatingPet
        statusItem = StatusItemController(model: model)
        floatingPet.show()
    }
}

@MainActor
private final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: DashboardModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var quotaSubscription: AnyCancellable?
    private var themeSubscription: AnyCancellable?

    init(model: DashboardModel) {
        self.model = model
        statusItem = Self.makeStatusItem()
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 470, height: 680)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(model: model).frame(width: 470, height: 680))
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.image = Self.makeMenuIcon()
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        Self.setMenuQuota("—", level: nil, on: button)
        button.toolTip = "\(AppVersion.displayName) \(AppVersion.label) · Session health radar"
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        themeSubscription = NotificationCenter.default.publisher(for: .petAnimationThemeDidChange)
            .sink { [weak self] _ in
                self?.statusItem.button?.image = Self.makeMenuIcon()
            }
        quotaSubscription = model.$snapshot.sink { [weak self] snapshot in
            guard let button = self?.statusItem.button else { return }
            let quota = snapshot.latestQuota.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
            button.image = Self.makeMenuIcon()
            Self.setMenuQuota(quota, level: snapshot.latestQuota?.level, on: button)
            button.toolTip = "\(AppVersion.displayName) · \(quota) quota remaining"
            button.setAccessibilityLabel("\(AppVersion.displayName) · \(quota) quota remaining")
        }
    }

    private static func setMenuQuota(_ text: String, level: QuotaLevel?, on button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: quotaNSColor(level),
            ])
    }

    private static func makeStatusItem() -> NSStatusItem {
        let autosaveName = "TokenPetPrimary"
        let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: preferredPositionKey) == nil {
            // AppKit has no public API for first-run ordering. Seed the same persisted
            // position used by autosaveName so a new item starts on the visible side
            // of notched menu bars; subsequent user Command-drags remain authoritative.
            defaults.set(420, forKey: preferredPositionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosaveName
        item.isVisible = true
        return item
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.setPanelVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPanelVisible(false)
    }

    private static func makeMenuIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let result = NSImage(size: size)
        result.lockFocus()
        let theme = PetAnimationTheme.selected
        let source = PetAsset.frames(for: .guardian, theme: theme)[0]
        if theme == .codexPixel {
            source.draw(
                in: NSRect(x: 1.9, y: 1, width: 18.2, height: 20),
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1)
        } else {
            source.draw(
                in: NSRect(x: 1, y: 1, width: 20, height: 20),
                from: NSRect(x: 12, y: 10, width: 82, height: 82),
                operation: .sourceOver,
                fraction: 1)
        }
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var snapshot = DashboardSnapshot(active: [], recent: [], indexedFiles: 0, updatedAt: Date())
    @Published var resumeWarning: SessionSummary?
    @Published var migratingSessionID: String?
    @Published var migrationProgress: String?
    @Published var isIndexing = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var isManualRefreshing = false
    @Published private(set) var manualRefreshCompletionTick = 0
    @Published var errorMessage: String?
    private var scanner: SessionScanner?
    private var activePaths: [String] = []
    private var timer: Timer?
    private var started = false
    private var refreshTick = 0
    private var refreshAfterCurrent = false
    private var queuedManualRefresh = false
    private var panelVisible = false

    init() {
        Task { @MainActor [weak self] in self?.start() }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            let store = try SQLiteStore(path: SessionScanner.defaultDatabasePath())
            scanner = SessionScanner(store: store, codexHome: SessionScanner.defaultCodexHome())
            refresh(initial: true)
            scheduleRefreshTimer()
        } catch {
            isIndexing = false
            errorMessage = String(describing: error)
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        scheduleRefreshTimer()
        if visible { refresh(forceDiscover: true) }
    }

    private func scheduleRefreshTimer() {
        timer?.invalidate()
        let interval: TimeInterval = panelVisible ? 2 : 10
        let refreshTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(initial: false) }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    func requestManualRefresh() {
        guard scanner != nil else { return }
        isManualRefreshing = true
        refresh(forceDiscover: true, manual: true)
    }

    func refresh(initial: Bool = false, forceDiscover: Bool = false, manual: Bool = false) {
        guard let scanner else { return }
        guard !isRefreshing else {
            if forceDiscover { refreshAfterCurrent = true }
            if manual { queuedManualRefresh = true }
            return
        }
        isRefreshing = true
        if manual { isManualRefreshing = true }
        if initial { isIndexing = true }
        let paths = activePaths
        refreshTick += 1
        let discoverNew = forceDiscover || initial || refreshTick % 3 == 0
        let work = Task.detached(priority: .background) {
            let result = try initial
                ? scanner.initialIndex()
                : scanner.refresh(activePaths: paths, discoverNew: discoverNew)
            let shouldSnapshot = initial || discoverNew || result.changedTurns > 0
            let next = try shouldSnapshot ? scanner.snapshot() : nil
            if initial { _ = malloc_zone_pressure_relief(nil, 0) }
            return (result, next)
        }
        Task { [weak self] in
            do {
                let (result, next) = try await work.value
                guard let self else { return }
                self.activePaths = result.activePaths
                if let next {
                    if self.resumeWarning == nil,
                       let resumed = next.resumedGuardedSession(from: self.snapshot) {
                        self.resumeWarning = resumed
                    }
                    self.snapshot = next
                }
                self.isIndexing = false
                self.isRefreshing = false
                if manual {
                    self.isManualRefreshing = false
                    self.manualRefreshCompletionTick += 1
                }
                self.errorMessage = nil
                if self.refreshAfterCurrent {
                    let queuedManual = self.queuedManualRefresh
                    self.refreshAfterCurrent = false
                    self.queuedManualRefresh = false
                    self.refresh(forceDiscover: true, manual: queuedManual)
                }
            } catch {
                self?.isIndexing = false
                self?.isRefreshing = false
                if manual { self?.isManualRefreshing = false }
                self?.errorMessage = String(describing: error)
                if self?.refreshAfterCurrent == true {
                    let queuedManual = self?.queuedManualRefresh == true
                    self?.refreshAfterCurrent = false
                    self?.queuedManualRefresh = false
                    self?.refresh(forceDiscover: true, manual: queuedManual)
                }
            }
        }
    }

    func taskTitle(_ turn: TurnRecord) -> String {
        snapshot.title(for: turn)
    }

    func projectContext(_ turn: TurnRecord) -> String {
        projectContext(cwd: turn.cwd)
    }

    func projectContext(cwd: String) -> String {
        let components = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }
        let shortPath = components.suffix(3).joined(separator: "/")
        let project = URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
            ? "Unknown project" : URL(fileURLWithPath: cwd).lastPathComponent
        return "\(project) · …/\(shortPath)"
    }

    func openSession(_ sessionID: String) {
        guard let url = URL(string: "codex://threads/\(sessionID)") else { return }
        NSWorkspace.shared.open(url)
    }

    func prepareFreshSession(_ session: SessionSummary) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Summarize context and start a fresh task?"
        alert.informativeText = "Reason: \(session.reason)\n\n\(AppVersion.displayName) asks Codex Desktop for a structured handoff, validates it, creates a fresh task, and delivers the summary. If the source task is still producing output, its current turn is interrupted first. The source task is never archived or deleted automatically."
        alert.addButton(withTitle: "Summarize & start fresh")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        migrate(session)
    }

    private func migrate(_ session: SessionSummary) {
        guard migratingSessionID == nil else { return }
        migratingSessionID = session.sessionID
        migrationProgress = "Preparing a fresh task"
        let sourceThreadID = session.sessionID
        let sourceTitle = session.title
        let cwd = session.cwd
        let currentTurnID = session.latestTurn?.turnID
        // Ensure Codex Desktop owns and displays the source before follower IPC.
        openSession(sourceThreadID)
        Task { @MainActor [weak self] in
            do {
                let migrator = try CodexHandoffMigrator()
                try await Task.sleep(for: .milliseconds(500))
                let result = try await Task.detached(priority: .userInitiated) {
                    return try migrator.migrate(
                        sourceThreadID: sourceThreadID,
                        sourceTitle: sourceTitle,
                        cwd: cwd,
                        interruptActiveTurn: session.isActive,
                        currentTurnID: currentTurnID)
                }.value
                guard let self else { return }
                self.migratingSessionID = nil
                self.migrationProgress = nil
                self.openSession(result.newThreadID)
            } catch {
                guard let self else { return }
                self.migratingSessionID = nil
                self.migrationProgress = nil
                let failure = NSAlert(error: error)
                failure.messageText = "Could not start a fresh task"
                failure.informativeText = "\(error.localizedDescription)\n\nThe source task was not archived or deleted and remains available."
                failure.runModal()
            }
        }
    }

    func dismissResumeWarning() {
        resumeWarning = nil
    }

    func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }
}

private enum PetAnimationTheme: String, CaseIterable {
    case classicDance
    case codexPixel

    static let storageKey = "XiaoxinSessionManagerPetAnimationTheme"

    static var selected: PetAnimationTheme {
        PetAnimationTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "")
            ?? .classicDance
    }

    var displayName: String {
        switch self {
        case .classicDance: "Dance Shin-chan"
        case .codexPixel: "Pixel Shin-chan"
        }
    }

    var next: PetAnimationTheme {
        self == .classicDance ? .codexPixel : .classicDance
    }

    var resourceDirectory: String {
        switch self {
        case .classicDance: "PetAnimations"
        case .codexPixel: "PetAnimations/shinchan-codex-v1"
        }
    }

    func frameCount(for state: PetAnimationState) -> Int {
        guard self == .codexPixel else { return state.classicFrameCount }
        return switch state {
        case .idle, .working, .multitask, .thinking: 6
        case .success: 5
        case .guardian: 4
        }
    }
}

private struct PetAssetKey: Hashable {
    let theme: PetAnimationTheme
    let state: PetAnimationState
}

private enum PetAsset {
    private static let loaded: [PetAssetKey: [NSImage]] = Dictionary(
        uniqueKeysWithValues: PetAnimationTheme.allCases.flatMap { theme in
            PetAnimationState.allCases.map { state in
                let key = PetAssetKey(theme: theme, state: state)
                return (key, loadSequence(state, theme: theme))
            }
        })

    static func frames(for state: PetAnimationState, theme: PetAnimationTheme) -> [NSImage] {
        loaded[PetAssetKey(theme: theme, state: state)] ?? [fallback]
    }

    private static func loadSequence(_ state: PetAnimationState, theme: PetAnimationTheme) -> [NSImage] {
        (0..<theme.frameCount(for: state)).map {
            load(
                String(format: "frame-%02d", $0),
                subdirectory: "\(theme.resourceDirectory)/\(state.rawValue)")
        }
    }

    private static func load(_ name: String, subdirectory: String) -> NSImage {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var appURL = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        appURL.appendPathComponent(subdirectory, isDirectory: true)
        appURL.appendPathComponent(name)
        appURL.appendPathExtension("png")
        if let image = NSImage(contentsOf: appURL) { return image }
        let packageURL = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: subdirectory)
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        if let packageURL, let image = NSImage(contentsOf: packageURL) { return image }
        return fallback
    }

    private static let fallback = NSImage(
        systemSymbolName: "face.smiling",
        accessibilityDescription: "Session guardian mascot")!
}

private extension PetAnimationState {
    var classicFrameCount: Int {
        switch self {
        case .idle: 6
        case .working: 4
        case .multitask: 8
        case .thinking: 10
        case .success: 12
        case .guardian: 5
        }
    }

    var frameDurationMilliseconds: Int64 {
        switch self {
        case .idle: 220
        case .working: 180
        case .multitask: 160
        case .thinking: 190
        case .success: 120
        case .guardian: 210
        }
    }

    var loops: Bool { self != .success }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Shin-chan running animation"
        case .working: "Shin-chan waiting animation"
        case .multitask: "Shin-chan idle animation"
        case .thinking: "Shin-chan high-risk review animation"
        case .success: "Shin-chan completion animation"
        case .guardian: "Shin-chan hover animation"
        }
    }
}

private struct PetImage: View {
    let theme: PetAnimationTheme

    var body: some View {
        Image(nsImage: PetAsset.frames(for: .guardian, theme: theme)[0])
            .resizable()
            .scaledToFit()
            .accessibilityLabel(AppVersion.displayName)
    }
}

private struct PetSequencePlayer: View {
    let state: PetAnimationState
    let theme: PetAnimationTheme
    let paused: Bool
    @State private var frameIndex = 0

    private struct PlaybackKey: Hashable {
        let state: PetAnimationState
        let theme: PetAnimationTheme
        let paused: Bool
    }

    var body: some View {
        let frames = PetAsset.frames(for: state, theme: theme)
        Image(nsImage: frames[min(frameIndex, frames.count - 1)])
            .resizable()
            .interpolation(theme == .codexPixel ? .none : .high)
            .scaledToFit()
            .accessibilityLabel(state.accessibilityLabel)
            .transaction { $0.animation = nil }
            .onChange(of: state) { _, _ in frameIndex = 0 }
            .onChange(of: theme) { _, _ in frameIndex = 0 }
            .task(id: PlaybackKey(state: state, theme: theme, paused: paused)) {
                guard !paused, frames.count > 1 else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(state.frameDurationMilliseconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    if frameIndex + 1 < frames.count {
                        frameIndex += 1
                    } else if state.loops {
                        frameIndex = 0
                    } else {
                        return
                    }
                }
            }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("XiaoxinSessionManagerDarkMode") private var darkMode = false
    @AppStorage(PetAnimationTheme.storageKey) private var petThemeRawValue = PetAnimationTheme.classicDance.rawValue
    @State private var detailSessionID: String?
    @State private var startFreshExpanded = true
    @State private var recentExpanded = false
    @State private var manualRefreshFeedback = false

    var body: some View {
        let sessions = model.snapshot.sessions
        let activeSessions = sessions.filter(\.isActive)
        let startFreshSessions = sessions.filter { !$0.isActive && $0.risk != .green }
        let recentSessions = sessions.filter { !$0.isActive && $0.risk == .green }

        VStack(spacing: 0) {
            header(activeCount: activeSessions.count)
            Divider()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).padding()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    DashboardOverviewCard(
                        quota: model.snapshot.latestQuota,
                        policy: model.snapshot.healthPolicy)

                    sectionHeader("Active", count: activeSessions.count, note: "Most recent first")
                    if activeSessions.isEmpty {
                        Text("No running or recently active sessions")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        sessionCards(activeSessions)
                    }

                    if !startFreshSessions.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { startFreshExpanded.toggle() }
                        } label: {
                            HStack {
                                Label("Start fresh before continuing", systemImage: "shield.lefthalf.filled")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("Before you resume")
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: startFreshExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        if startFreshExpanded {
                            sessionCards(startFreshSessions)
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { recentExpanded.toggle() }
                    } label: {
                        HStack {
                            sectionHeader("Safe to resume", count: recentSessions.count, note: "Healthy context")
                            Image(systemName: recentExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if recentExpanded { sessionCards(recentSessions) }

                    if activeSessions.isEmpty && startFreshSessions.isEmpty && recentSessions.isEmpty {
                        ContentUnavailableView(
                            "Your guardian is taking a break",
                            systemImage: "moon.zzz",
                            description: Text("No unarchived Codex sessions to display"))
                            .frame(height: 180)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.orange.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
        .preferredColorScheme(darkMode ? .dark : .light)
        .onChange(of: model.manualRefreshCompletionTick) { _, _ in
            manualRefreshFeedback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                manualRefreshFeedback = false
            }
        }
    }

    private func header(activeCount: Int) -> some View {
        HStack(spacing: 14) {
            PetImage(theme: PetAnimationTheme(rawValue: petThemeRawValue) ?? .classicDance)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Session health").font(.title3.weight(.bold))
                    Text(AppVersion.label)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text(activeCount == 0 ? "No active sessions" : "\(activeCount) active session\(activeCount == 1 ? "" : "s") · See cards for details")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            headerStatusControls
        }
        .padding(18)
    }

    private var headerStatusControls: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if let quota = model.snapshot.latestQuota {
                Text("\(Int(quota.remainingPercent.rounded()))% left")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(quotaColor(quota.level))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ProgressView(value: quota.remainingPercent, total: 100)
                    .tint(quotaColor(quota.level))
                    .frame(width: 150)
            } else {
                Text("— left")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(headerQuotaDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 160, alignment: .trailing)
    }

    private var headerQuotaDetail: String {
        guard let quota = model.snapshot.latestQuota else { return "Waiting for Codex quota data" }
        var parts = ["\(Int(quota.usedPercent.rounded()))% used"]
        if let resetsAt = quota.resetsAt {
            parts.append("resets \(Self.resetFormatter.string(from: resetsAt))")
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        let petTheme = PetAnimationTheme(rawValue: petThemeRawValue) ?? .classicDance
        return HStack {
            Text("\(model.snapshot.sessions.count) sessions · 2s refresh / 30s discovery")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isIndexing { ProgressView().controlSize(.small) }
            Button {
                petThemeRawValue = petTheme.next.rawValue
                NotificationCenter.default.post(name: .petAnimationThemeDidChange, object: nil)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Switch to the \(petTheme.next.displayName) animation set")
            .accessibilityLabel("Switch animation set")

            Button { darkMode.toggle() } label: {
                Image(systemName: darkMode ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.borderless)
            .help(darkMode ? "Use light appearance" : "Use dark appearance")

            Button { model.requestManualRefresh() } label: {
                if model.isManualRefreshing {
                    ProgressView().controlSize(.small)
                } else if manualRefreshFeedback {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isManualRefreshing)
            .help(model.isManualRefreshing ? "Refreshing session status" : "Refresh now")

            Divider().frame(height: 22)
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
                .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    @ViewBuilder private func sessionCards(_ sessions: [SessionSummary]) -> some View {
        ForEach(sessions, id: \.renderIdentity) { session in
            SessionCard(
                session: session,
                model: model,
                expanded: detailSessionID == session.id,
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        detailSessionID = detailSessionID == session.id ? nil : session.id
                    }
                })
        }
    }

    private func sectionHeader(_ title: String, count: Int, note: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DashboardOverviewCard: View {
    let quota: QuotaSnapshot?
    let policy: HealthPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Personalized health thresholds", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 8)
            {
                policyMetric("Watch from", "\(Int((policy.amberContext * 100).rounded()))%")
                policyMetric("Start fresh", "\(Int((policy.redContext * 100).rounded()))%")
                policyMetric(
                    "Fresh-input reference",
                    policy.freshInputReferenceThreshold.map(compactTokenCount) ?? "Learning")
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(policy.isCalibrated ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(policy.isCalibrated
                    ? "Calibrated from \(policy.effectiveSampleCount) local samples"
                    : "Local samples \(policy.effectiveSampleCount)/20 · Using safe cold-start thresholds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RotatingTipText(
                tips: DynamicTipCatalog.tips(policy: policy, quota: quota),
                foreground: .secondary,
                iconColor: .green)
        }
        .padding(13)
        .background(
            LinearGradient(
                colors: [Color.green.opacity(0.16), Color(nsColor: .controlBackgroundColor).opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.green.opacity(0.34)))
    }

    private func policyMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

}

private enum DynamicTipCatalog {
    static func tips(policy: HealthPolicy, quota: QuotaSnapshot?) -> [String] {
        var values = [
            "A high cache-hit rate saves fresh input, but does not guarantee a healthy context.",
            "Fresh-input anomalies use your local history instead of a universal fixed limit.",
            "One compaction triggers attention; two compactions suggest starting fresh.",
            "Context thresholds adapt only within conservative safety bounds.",
        ]
        if let quota {
            values.append("Global quota remaining: \(Int(quota.remainingPercent.rounded()))%. It is shared across tasks.")
        }
        if let threshold = policy.freshInputReferenceThreshold {
            values.append("The current global fresh-input anomaly reference is about \(compactTokenCount(threshold)).")
        }
        return values
    }
}

private struct RotatingTipText: View {
    let tips: [String]
    let foreground: Color
    let iconColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 6)) { context in
            let index = tips.isEmpty ? 0 : Int(context.date.timeIntervalSince1970 / 6) % tips.count
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(iconColor)
                Text(tips.isEmpty ? "Your guardian is learning your session patterns." : tips[index])
                    .foregroundStyle(foreground)
                    .lineLimit(2)
                    .id(index)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Dynamic tip: \(tips.isEmpty ? "Your guardian is learning your session patterns" : tips[index])")
        }
    }
}

private func compactTokenCount(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return String(value)
}

private struct SessionCard: View {
    let session: SessionSummary
    @ObservedObject var model: DashboardModel
    let expanded: Bool
    let onToggle: () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Circle().fill(riskColor(session.risk)).frame(width: 9, height: 9).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(session.title).font(.body.weight(.semibold)).lineLimit(2)
                        activityBadge(session.activity)
                    }
                    Text(model.projectContext(cwd: session.cwd))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(relativeDate(session.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: adviceIcon(session.advice)).foregroundStyle(riskColor(session.risk))
                VStack(alignment: .leading, spacing: 2) {
                    Text(adviceTitle(session.advice)).font(.subheadline.weight(.bold))
                    Text(session.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .background(riskColor(session.risk).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if let latest = session.latestTurn {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                    metric("Context", latest.contextPressure.map { "\(Int($0 * 100))%" } ?? "—")
                    metric("Compactions", "\(session.compactions)")
                    metric("Fresh input", model.compact(latest.usage.freshInput))
                    metric("Total input", model.compact(latest.usage.input))
                    metric("Output", model.compact(latest.usage.output))
                    metric("Cache hit", "\(Int(latest.usage.cacheHitRate * 100))%")
                }
            }

            HStack {
                Button {
                    model.openSession(session.sessionID)
                } label: {
                    Label("Open source task", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                if !session.isActive && session.risk != .green {
                    Button { model.prepareFreshSession(session) } label: {
                        if model.migratingSessionID == session.sessionID {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text(model.migrationProgress ?? "Preparing fresh task")
                            }
                        } else {
                            Label("Summarize & start fresh", systemImage: "arrow.triangle.branch")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.migratingSessionID != nil)
                }
                Spacer()
                Button(action: onToggle) {
                    Label("Token usage details", systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }

            if expanded, let latest = session.latestTurn {
                Divider()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                    metric("Cache write", model.compact(latest.usage.cacheWriteInput))
                    metric("Reasoning", model.compact(latest.usage.reasoningOutput))
                    metric("Calls", "\(latest.calls)")
                    metric("Session total", model.compact(session.usage.total))
                    metric("Status", turnStatus(latest.status))
                    metric("Data quality", latest.confidence)
                }
            }
        }
        .padding(15)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.84),
            in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06)))
        .onTapGesture(count: 2) { model.openSession(session.sessionID) }
        .help("Double-click to open the source task. Cards show the latest turn; older turns inform background trends only.")
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter.tokenPet.localizedString(for: date, relativeTo: Date())
    }

    private func activityBadge(_ activity: SessionActivity) -> some View {
        let label: String
        let color: Color
        switch activity {
        case .executing: (label, color) = ("Running", .green)
        case .waiting: (label, color) = ("Recently active", .orange)
        case .interrupted: (label, color) = ("Interrupted", .red)
        case .stopped: (label, color) = ("Stopped", .secondary)
        }
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
    }
}

private extension RelativeDateTimeFormatter {
    static let tokenPet: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct NativePetDragSurface: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> NativePetDragView {
        NativePetDragView(
            onHover: onHover,
            onDragBegan: onDragBegan,
            onDragEnded: onDragEnded)
    }

    func updateNSView(_ view: NativePetDragView, context: Context) {
        view.onHover = onHover
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

private final class NativePetDragView: NSView {
    var onHover: (Bool) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: (Bool) -> Void
    private var trackingArea: NSTrackingArea?
    private var dragActive = false

    init(
        onHover: @escaping (Bool) -> Void,
        onDragBegan: @escaping () -> Void,
        onDragEnded: @escaping (Bool) -> Void
    ) {
        self.onHover = onHover
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard !dragActive else { return }
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragActive else { return }
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let window else { return }
        let startPointer = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        dragActive = true
        onDragBegan()

        // Let AppKit/WindowServer own the tracking loop. This avoids routing
        // every pointer sample through SwiftUI state and transparent-panel
        // compositing, matching Codex Desktop's native macOS drag bridge.
        window.performDrag(with: event)

        let endPointer = NSEvent.mouseLocation
        let endOrigin = window.frame.origin
        let pointerDistance = hypot(endPointer.x - startPointer.x, endPointer.y - startPointer.y)
        let windowDistance = hypot(endOrigin.x - startOrigin.x, endOrigin.y - startOrigin.y)
        let moved = pointerDistance >= 4 || windowDistance >= 1
        dragActive = false
        onDragEnded(moved)

        let windowPoint = window.convertPoint(fromScreen: endPointer)
        onHover(bounds.contains(convert(windowPoint, from: nil)))
    }
}

@MainActor
private final class FloatingPetController {
    private let panel: NSPanel
    private let collapsedSize = NSSize(width: 116, height: 126)
    private var petAnchor = NSPoint.zero
    private var layoutSignature: (mode: FloatingPanelMode, sessionCount: Int)?
    private let savedXKey = "TokenPetFloatingAnchorX"
    private let savedYKey = "TokenPetFloatingAnchorY"

    init(model: DashboardModel) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        let hoverPanel = panel
        panel.contentView = NSHostingView(rootView: FloatingPetView(
            model: model,
            onLayoutChange: { [weak self] mode, sessionCount in
                self?.resize(mode: mode, sessionCount: sessionCount)
            },
            onNativeDragEnded: { [weak self] in
                self?.nativeDragEnded()
            },
            isPointerInsidePanel: { [weak hoverPanel] in
                guard let hoverPanel else { return false }
                return hoverPanel.frame.contains(NSEvent.mouseLocation)
            }))
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let defaults = UserDefaults.standard
        let proposedAnchor: NSPoint
        if defaults.object(forKey: savedXKey) != nil, defaults.object(forKey: savedYKey) != nil {
            proposedAnchor = NSPoint(x: defaults.double(forKey: savedXKey), y: defaults.double(forKey: savedYKey))
        } else {
            proposedAnchor = NSPoint(x: frame.maxX - 28, y: frame.minY + 220)
        }
        petAnchor = FloatingPetGeometry.constrainedPetAnchor(
            proposedAnchor,
            petSize: collapsedSize,
            visibleFrame: frame)
        panel.setFrameOrigin(origin(for: petAnchor, size: collapsedSize))
        panel.orderFrontRegardless()
    }

    private func resize(mode: FloatingPanelMode, sessionCount: Int) {
        let signature = (mode: mode, sessionCount: sessionCount)
        guard layoutSignature?.mode != signature.mode ||
                layoutSignature?.sessionCount != signature.sessionCount else { return }
        layoutSignature = signature
        let size: NSSize
        switch mode {
        case .collapsed:
            size = collapsedSize
        case .stacked:
            size = NSSize(width: 640, height: sessionCount == 1 ? 330 : 350)
        case .spread:
            let visibleCards = min(4, max(1, sessionCount))
            size = NSSize(width: 640, height: min(760, 130 + CGFloat(visibleCards) * 146))
        }
        if petAnchor == .zero { petAnchor = NSPoint(x: panel.frame.maxX, y: panel.frame.minY) }
        let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        // `petAnchor` belongs to the mascot, not to the temporary card size.
        // Re-clamping it with the expanded 640pt panel made the mascot move
        // when hover collapse switched back to the 116pt footprint.
        petAnchor = FloatingPetGeometry.constrainedPetAnchor(
            petAnchor,
            petSize: collapsedSize,
            visibleFrame: screenFrame)
        panel.setFrame(NSRect(origin: origin(for: petAnchor, size: size), size: size), display: true, animate: false)
        panel.displayIfNeeded()
    }

    private func nativeDragEnded() {
        let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let proposed = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        petAnchor = FloatingPetGeometry.constrainedPetAnchor(
            proposed,
            petSize: collapsedSize,
            visibleFrame: screenFrame)
        let constrainedOrigin = origin(for: petAnchor, size: panel.frame.size)
        if panel.frame.origin != constrainedOrigin {
            panel.setFrameOrigin(constrainedOrigin)
        }
        UserDefaults.standard.set(petAnchor.x, forKey: savedXKey)
        UserDefaults.standard.set(petAnchor.y, forKey: savedYKey)
    }

    private func origin(for anchor: NSPoint, size: NSSize) -> NSPoint {
        FloatingPetGeometry.panelOrigin(forPetAnchor: anchor, panelSize: size)
    }
}

private enum FloatingPanelMode: Equatable {
    case collapsed
    case stacked
    case spread
}

private struct FloatingPetView: View {
    @ObservedObject var model: DashboardModel
    let onLayoutChange: (FloatingPanelMode, Int) -> Void
    let onNativeDragEnded: () -> Void
    let isPointerInsidePanel: () -> Bool
    @State private var mode: FloatingPanelMode = .collapsed
    @State private var pinned = false
    @State private var dragInProgress = false
    @State private var petHovered = false
    @State private var frozenSessions: [SessionSummary] = []
    @State private var collapseGeneration = 0
    @State private var previousActiveSessionIDs = Set<String>()
    @State private var celebrationActive = false
    @State private var celebrationGeneration = 0
    @State private var displayedAnimationState: PetAnimationState = .idle
    @AppStorage(PetAnimationTheme.storageKey) private var petThemeRawValue = PetAnimationTheme.classicDance.rawValue

    private var petTheme: PetAnimationTheme {
        PetAnimationTheme(rawValue: petThemeRawValue) ?? .classicDance
    }

    private var displayedSessions: [SessionSummary] {
        FloatingPetGeometry.stabilizedSessions(
            frozen: frozenSessions,
            current: model.snapshot.activeSessions)
    }

    private var desiredAnimationState: PetAnimationState {
        model.snapshot.petAnimationState(
            isHovered: petHovered,
            hasResumeWarning: model.resumeWarning != nil,
            isCelebrating: celebrationActive)
    }

    private var animationPaused: Bool { dragInProgress }

    private var activityFingerprint: String {
        model.snapshot.sessions
            .map { "\($0.sessionID):\($0.activity.rawValue):\($0.risk.rawValue)" }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if mode != .collapsed {
                VStack(alignment: .trailing, spacing: 10) {
                    if let warning = model.resumeWarning {
                        FloatingResumeWarningCard(session: warning, model: model)
                    } else if displayedSessions.isEmpty {
                        FloatingEmptyCard(
                            policy: model.snapshot.healthPolicy,
                            quota: model.snapshot.latestQuota)
                    } else if displayedSessions.count == 1, let session = displayedSessions.first {
                        FloatingSessionCard(session: session, model: model, isFocus: true)
                    } else if mode == .spread {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(displayedSessions) { session in
                                    FloatingSessionCard(session: session, model: model, isFocus: false)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: CGFloat(min(4, displayedSessions.count)) * 124)
                    } else {
                        FloatingSessionStack(sessions: displayedSessions, model: model)
                            .onHover { inside in
                                guard inside, displayedSessions.count > 1, mode != .spread else { return }
                                mode = .spread
                                onLayoutChange(.spread, displayedSessions.count)
                            }
                    }
                }
                .frame(width: 556, alignment: .trailing)
                .padding(.trailing, 58)
                .padding(.bottom, 98)
                .foregroundStyle(.white)
                // The card area must not acquire hover/click state while the
                // pet drag handle is moving underneath a stationary pointer.
                .allowsHitTesting(!dragInProgress)
            }

            ZStack {
                PetSequencePlayer(state: displayedAnimationState, theme: petTheme, paused: animationPaused)
                    // Every frame is pre-normalized into this stable canvas and one
                    // foot baseline; per-sequence effective scale is baked into PNGs.
                    .frame(width: 106, height: 116, alignment: .bottomTrailing)
                    .shadow(color: .black.opacity(0.24), radius: 7, y: 5)

                NativePetDragSurface(
                    onHover: { petHovered = $0 },
                    onDragBegan: {
                        invalidatePendingCollapse()
                        dragInProgress = true
                    },
                    onDragEnded: { moved in
                        onNativeDragEnded()
                        dragInProgress = false
                        if !moved { togglePanel() }
                        reconcileHoverAfterDrag()
                    })
            }
            .frame(width: 106, height: 116, alignment: .bottomTrailing)
            .help(pinned ? "Click to collapse session cards" : "Click to pin session cards")
            .accessibilityLabel(pinned ? "Collapse guardian session cards" : "Pin guardian session cards")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { togglePanel() }
        }
        .padding(5)
        // The content group has a smaller natural height than the expanded
        // panel. Expand the root to the hosting bounds and explicitly pin that
        // group to the same bottom-trailing pet anchor in every mode.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .transaction { transaction in
            if dragInProgress { transaction.disablesAnimations = true }
        }
        .onHover { inside in
            guard !dragInProgress else {
                invalidatePendingCollapse()
                return
            }
            if inside {
                invalidatePendingCollapse()
                guard mode == .collapsed else { return }
                frozenSessions = model.snapshot.activeSessions
                mode = .stacked
                onLayoutChange(.stacked, displayedSessions.count)
            } else {
                scheduleCollapse()
            }
        }
        .onReceive(model.$resumeWarning.compactMap { $0 }) { warning in
            invalidatePendingCollapse()
            frozenSessions = [warning]
            pinned = true
            mode = .stacked
            onLayoutChange(.stacked, 1)
        }
        .onAppear {
            previousActiveSessionIDs = Set(model.snapshot.activeSessions.map(\.sessionID))
            displayedAnimationState = desiredAnimationState
        }
        .onChange(of: activityFingerprint) { _, _ in
            observeSessionActivity()
        }
        .onChange(of: desiredAnimationState) { _, state in
            guard !animationPaused else { return }
            displayedAnimationState = state
        }
        .onChange(of: animationPaused) { _, paused in
            guard !paused else { return }
            displayedAnimationState = desiredAnimationState
        }
    }

    private func observeSessionActivity() {
        let completed = model.snapshot.completedSessionIDs(previouslyActive: previousActiveSessionIDs)
        previousActiveSessionIDs = Set(model.snapshot.activeSessions.map(\.sessionID))
        guard !completed.isEmpty else { return }
        celebrationGeneration &+= 1
        let generation = celebrationGeneration
        celebrationActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard generation == celebrationGeneration else { return }
            celebrationActive = false
        }
    }

    private func invalidatePendingCollapse() {
        collapseGeneration &+= 1
    }

    private func scheduleCollapse() {
        invalidatePendingCollapse()
        let generation = collapseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard generation == collapseGeneration,
                  !dragInProgress,
                  !pinned,
                  !isPointerInsidePanel()
            else { return }
            collapse()
        }
    }

    private func reconcileHoverAfterDrag() {
        invalidatePendingCollapse()
        DispatchQueue.main.async {
            guard !dragInProgress, !pinned else { return }
            if isPointerInsidePanel() {
                if mode == .collapsed {
                    frozenSessions = model.snapshot.activeSessions
                    mode = .stacked
                    onLayoutChange(.stacked, displayedSessions.count)
                }
            } else {
                scheduleCollapse()
            }
        }
    }

    private func collapse() {
        invalidatePendingCollapse()
        mode = .collapsed
        onLayoutChange(.collapsed, 0)
        frozenSessions.removeAll()
    }

    private func togglePanel() {
        invalidatePendingCollapse()
        if mode == .collapsed {
            frozenSessions = model.snapshot.activeSessions
            pinned = true
            mode = .stacked
            onLayoutChange(.stacked, model.snapshot.activeSessions.count)
        } else if !pinned {
            // Hover already opened the panel; a click pins it without collapsing.
            pinned = true
        } else {
            pinned = false
            collapse()
        }
    }
}

private struct FloatingGlobalRail: View {
    let sessions: [SessionSummary]
    let quota: QuotaSnapshot?

    private var highestRisk: TurnRisk { sessions.map(\.risk).max() ?? .green }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(.white.opacity(0.72))
            Text("\(sessions.count) active")
                .font(.subheadline.weight(.semibold))
            Circle().fill(riskColor(highestRisk)).frame(width: 8, height: 8)
            Text(riskTitle(highestRisk))
                .font(.caption.weight(.semibold))
                .foregroundStyle(riskColor(highestRisk))
            Spacer(minLength: 14)
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(quota.map { quotaColor($0.level) } ?? .secondary)
            Text(quota.map { "Quota \(Int($0.remainingPercent.rounded()))%" } ?? "Quota —")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(quota.map { quotaColor($0.level) } ?? .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .frame(width: 420)
        .background(.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.13)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .help("Quota is a global window shared by all sessions")
    }
}

private struct FloatingSessionStack: View {
    let sessions: [SessionSummary]
    @ObservedObject var model: DashboardModel

    private var visible: ArraySlice<SessionSummary> { sessions.prefix(3) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visible.enumerated()).reversed(), id: \.element.id) { index, session in
                FloatingSessionCard(session: session, model: model, isFocus: index == 0)
                    .scaleEffect(1 - CGFloat(index) * 0.025, anchor: .top)
                    .offset(x: CGFloat(index) * 7, y: CGFloat(index) * 12)
                    .opacity(1 - Double(index) * 0.2)
                    .zIndex(Double(visible.count - index))
                    .allowsHitTesting(index == 0)
            }
        }
        .frame(width: 556, height: 145, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) {
            if sessions.count > 3 {
                Text("+\(sessions.count - 3) more")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.86), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12)))
                    .padding(.leading, 18)
            }
        }
        .help("Hover the stack to show every active session")
    }
}

private struct FloatingSessionCard: View {
    let session: SessionSummary
    @ObservedObject var model: DashboardModel
    let isFocus: Bool
    @State private var hovered = false

    var body: some View {
        Button { model.openSession(session.sessionID) } label: {
            VStack(alignment: .leading, spacing: isFocus ? 10 : 8) {
                HStack(spacing: 8) {
                    Circle().fill(riskColor(session.risk)).frame(width: 9, height: 9)
                    Text(activityTitle(session.activity))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(activityColor(session.activity))
                    Text(relativeDate(session.updatedAt))
                        .font(.caption).foregroundStyle(.white.opacity(0.58))
                    Text(adviceTitle(session.advice))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(riskColor(session.risk))
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(hovered ? 1 : 0.62))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(isFocus ? .title3.weight(.bold) : .headline.weight(.bold))
                        .lineLimit(1)
                    Text(model.projectContext(cwd: session.cwd))
                        .font(isFocus ? .subheadline : .caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                if let latest = session.latestTurn {
                    HStack(spacing: 8) {
                        floatingMetric("Context", latest.contextPressure.map { "\(Int($0 * 100))%" } ?? "—", emphasized: true)
                        floatingMetric("Compactions", "\(session.compactions)", emphasized: false)
                        floatingMetric("Fresh input", model.compact(latest.usage.freshInput), emphasized: true)
                        floatingMetric("Cache hit", "\(Int(latest.usage.cacheHitRate * 100))%", emphasized: false)
                        floatingMetric("Total input", model.compact(latest.usage.input), emphasized: false)
                        floatingMetric("Output", model.compact(latest.usage.output), emphasized: false)
                    }
                }
            }
            .padding(.horizontal, isFocus ? 20 : 17)
            .padding(.vertical, isFocus ? 13 : 11)
            .frame(width: 556, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.95), Color(nsColor: .darkGray).opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(hovered ? .white.opacity(0.28) : .white.opacity(0.13), lineWidth: 1))
            .shadow(color: .black.opacity(hovered ? 0.42 : 0.32), radius: hovered ? 20 : 14, y: 8)
            .scaleEffect(hovered ? 1.008 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovered = inside }
        }
        .help("Open the source Codex task · \(session.reason)")
        .accessibilityLabel("Open task \(session.title), \(activityTitle(session.activity)), \(adviceTitle(session.advice))")
    }

    private func floatingMetric(_ name: String, _ value: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(emphasized ? .body.weight(.bold) : .subheadline.weight(.semibold))
                .monospacedDigit()
            Text(name).font(.caption2).foregroundStyle(.white.opacity(0.68))
        }
        .frame(width: 78, alignment: .leading)
    }
}

private struct FloatingResumeWarningCard: View {
    let session: SessionSummary
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text("A high-risk session was resumed")
                    .font(.headline)
                Spacer()
                Text("Your confirmation is required")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
            Text(session.title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Text(session.reason)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
            Text("This task is still producing output. If you choose “Interrupt & start fresh,” the guardian asks Codex Desktop to stop the current turn, waits for it to become idle, then creates a validated handoff and fresh task.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button("Open source task") {
                    model.openSession(session.sessionID)
                    model.dismissResumeWarning()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Interrupt & start fresh") {
                    model.prepareFreshSession(session)
                    model.dismissResumeWarning()
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Continue anyway") { model.dismissResumeWarning() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(18)
        .frame(width: 556, height: 218, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.97), .red.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.red.opacity(0.42)))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

private struct FloatingEmptyCard: View {
    let policy: HealthPolicy
    let quota: QuotaSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("Your guardian is taking a break").font(.headline)
                Spacer()
                Text(policy.calibrationLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            RotatingTipText(
                tips: DynamicTipCatalog.tips(policy: policy, quota: quota),
                foreground: .white.opacity(0.68),
                iconColor: .yellow)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 556, height: 96, alignment: .leading)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.13)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }
}

private func riskColor(_ risk: TurnRisk) -> Color {
    switch risk { case .green: .green; case .amber: .orange; case .red: .red }
}

private func quotaColor(_ level: QuotaLevel) -> Color {
    Color(nsColor: quotaNSColor(level))
}

private func quotaNSColor(_ level: QuotaLevel?) -> NSColor {
    switch level {
    case .healthy: .systemGreen
    case .caution: .systemOrange
    case .critical: .systemRed
    case nil: .secondaryLabelColor
    }
}

private func riskTitle(_ risk: TurnRisk) -> String {
    switch risk { case .green: "Healthy"; case .amber: "Context is filling up"; case .red: "Prepare a fresh task" }
}

private func riskExplanation(_ risk: TurnRisk) -> String {
    switch risk {
    case .green: "Active sessions are safe to continue."
    case .amber: "At least one active session needs attention."
    case .red: "At least one active session should move to a fresh task."
    }
}

private func adviceTitle(_ advice: SessionAdvice) -> String {
    switch advice {
    case .continueCurrent: "Continue current task"
    case .watch: "Watch"
    case .startFresh: "Start fresh"
    }
}

private func adviceIcon(_ advice: SessionAdvice) -> String {
    switch advice {
    case .continueCurrent: "checkmark.circle.fill"
    case .watch: "eye.fill"
    case .startFresh: "arrow.triangle.branch"
    }
}

private func turnStatus(_ status: TurnStatus) -> String {
    switch status {
    case .running: "Running"
    case .completed: "Completed"
    case .interrupted: "Interrupted"
    }
}

private func activityTitle(_ activity: SessionActivity) -> String {
    switch activity {
    case .executing: "Running"
    case .waiting: "Recently active"
    case .interrupted: "Interrupted"
    case .stopped: "Stopped"
    }
}

private func activityColor(_ activity: SessionActivity) -> Color {
    switch activity {
    case .executing: .green
    case .waiting: .orange
    case .interrupted: .red
    case .stopped: .secondary
    }
}

private func relativeDate(_ date: Date) -> String {
    RelativeDateTimeFormatter.tokenPet.localizedString(for: date, relativeTo: Date())
}
