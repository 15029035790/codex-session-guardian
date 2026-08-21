import AppKit
import Combine
import Darwin
import SwiftUI
import TokenPetCore

private enum AppVersion {
    static let label = "v0.3.9"
    static let displayName = "Codex Session Guardian"
}

private let appLocalizationBundle: Bundle = {
    let available = Bundle.module.localizations
    let localization = Bundle.preferredLocalizations(
        from: available,
        forPreferences: Locale.preferredLanguages).first ?? "zh-Hans"
    guard let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
          let bundle = Bundle(path: path)
    else { return .module }
    return bundle
}()

private func L(_ key: String) -> String {
    appLocalizationBundle.localizedString(forKey: key, value: key, table: nil)
}

private func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: .autoupdatingCurrent, arguments: arguments)
}

private extension Notification.Name {
    static let petAnimationThemeDidChange = Notification.Name("PetAnimationThemeDidChange")
}

private enum FloatingPetPreference {
    static let storageKey = "CodexSessionGuardianFloatingPetVisible"

    static var isVisible: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: storageKey) == nil || defaults.bool(forKey: storageKey)
    }

    static func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: storageKey)
    }
}

private enum XiaoxinSpeechPreference {
    static let storageKey = "CodexSessionGuardianXiaoxinSpeechIntensity"
    static let defaultValue = XiaoxinSpeechIntensity.light.rawValue
}

private extension XiaoxinSpeechIntensity {
    var localizedName: String {
        switch self {
        case .off: L("pet.personality.intensity.off")
        case .light: L("pet.personality.intensity.light")
        case .active: L("pet.personality.intensity.active")
        }
    }
}

private func xiaoxinSpeechIntensity(_ rawValue: String) -> XiaoxinSpeechIntensity {
    XiaoxinSpeechIntensity(rawValue: rawValue) ?? .light
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
        statusItem = StatusItemController(
            model: model,
            onFloatingPetVisibilityChange: { [weak floatingPet] isVisible in
                floatingPet?.setVisible(isVisible)
            })
        floatingPet.setVisible(FloatingPetPreference.isVisible)
        // Accessory apps can receive their first screen notification just after
        // `finishLaunching`; give the panel one post-launch chance to come to
        // the front once AppKit has attached the display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            floatingPet.setVisible(FloatingPetPreference.isVisible)
            floatingPet.refreshPlacementAfterLaunch()
        }
    }
}

@MainActor
private final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: DashboardModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var quotaSubscription: AnyCancellable?
    private var themeSubscription: AnyCancellable?

    init(model: DashboardModel, onFloatingPetVisibilityChange: @escaping (Bool) -> Void) {
        self.model = model
        statusItem = Self.makeStatusItem()
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 470, height: 680)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                model: model,
                onFloatingPetVisibilityChange: onFloatingPetVisibilityChange)
                .frame(width: 470, height: 680))
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.image = Self.makeMenuIcon()
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        Self.setMenuQuota("—", level: nil, on: button)
        button.toolTip = LF("%@ %@ · Session health radar", AppVersion.displayName, AppVersion.label)
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        themeSubscription = NotificationCenter.default.publisher(for: .petAnimationThemeDidChange)
            .sink { [weak self] _ in self?.statusItem.button?.image = Self.makeMenuIcon() }
        quotaSubscription = model.$snapshot.sink { [weak self] snapshot in
            guard let button = self?.statusItem.button else { return }
            let quota = snapshot.latestQuota.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
            button.image = Self.makeMenuIcon()
            Self.setMenuQuota(
                quota,
                level: snapshot.latestQuota?.level,
                on: button)
            let statusDescription = LF("%@ · %@ quota remaining", AppVersion.displayName, quota)
            button.toolTip = statusDescription
            button.setAccessibilityLabel(statusDescription)
        }
    }

    private static func setMenuQuota(
        _ text: String,
        level: QuotaLevel?,
        on button: NSStatusBarButton
    ) {
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
    @Published var isIndexing = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var isManualRefreshing = false
    @Published private(set) var manualRefreshCompletionTick = 0
    @Published private(set) var liveActivities: [String: SessionLiveActivity] = [:]
    @Published private(set) var multiAgentFindings: [MultiAgentAuditFinding] = []
    @Published private(set) var activeExecutionAdvisory: MultiAgentAuditFinding?
    /// Lifecycle Hook diagnostics are exposed to the floating guardian only;
    /// subagent turns remain excluded from the menu-bar task list.
    @Published private(set) var subagentHookHealth: SubagentHookHealthSnapshot?
    @Published private(set) var executionAdvisoryTick = 0
    private var routingPreferenceProfile: RoutingPreferenceProfile?
    @Published private(set) var routingPreflights: [RoutingPreflightObservation] = []
    @Published private(set) var routingPostflights: [String: RoutingPostflightAssessment] = [:]
    @Published private(set) var pendingRoutingReplays: [String: PendingRoutingReplay] = [:]
    @Published private(set) var replayingRoutingSessionID: String?
    @Published private(set) var routingReplayErrors: [String: String] = [:]
    @Published var errorMessage: String?
    private var scanner: SessionScanner?
    private var liveActivityMonitor: SessionLiveActivityMonitor?
    private var routingBridge: RoutingPreflightBridgeServer?
    private var activePaths: [String] = []
    private var timer: Timer?
    private var started = false
    private var refreshTick = 0
    private var refreshAfterCurrent = false
    private var queuedManualRefresh = false
    private var panelVisible = false
    private var floatingWorkspaceVisible = false
    private var resumeWarningSuppressions = ResumeWarningSuppressions()
    private var resumeWarningBudget = ResumeWarningBudget()
    private var suppressedExecutionAdvisoryIDs = Set<String>()
    private var announcedExecutionAdvisoryIDs = Set<String>()
    private var codexHookMetadata: [CodexHookMetadata] = []
    private var codexHookMetadataCheckedAt: Date?
    private var codexHooksFileModifiedAt: Date?

    init() {
        Task { @MainActor [weak self] in self?.start() }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            let store = try SQLiteStore(path: SessionScanner.defaultDatabasePath())
            routingPreferenceProfile = try store.loadRoutingPreferenceProfile()
            routingPreflights = try store.routingPreflights(limit: 100)
            subagentHookHealth = try store.subagentHookHealthDiagnostics(limit: 1).first?.snapshot
            scanner = SessionScanner(store: store, codexHome: SessionScanner.defaultCodexHome())
            let bridge = RoutingPreflightBridgeServer { [weak self] replay in
                Task { @MainActor [weak self] in
                    self?.pendingRoutingReplays[replay.sessionID] = replay
                    self?.routingReplayErrors.removeValue(forKey: replay.sessionID)
                    self?.refresh(forceDiscover: true)
                }
            }
            if (try? bridge.start()) != nil {
                routingBridge = bridge
            }
            liveActivityMonitor = SessionLiveActivityMonitor { [weak self] sessionID, event in
                Task { @MainActor [weak self] in
                    self?.applyLiveActivity(event, sessionID: sessionID)
                }
            }
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

    func setFloatingWorkspaceVisible(_ visible: Bool) {
        guard floatingWorkspaceVisible != visible else { return }
        floatingWorkspaceVisible = visible
        scheduleRefreshTimer()
        if visible { refresh(forceDiscover: true) }
    }

    private func scheduleRefreshTimer() {
        timer?.invalidate()
        let interval = SessionRefreshCadence.interval(
            statusPanelVisible: panelVisible,
            floatingWorkspaceVisible: floatingWorkspaceVisible)
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
        let previousSnapshot = snapshot
        refreshTick += 1
        let discoverNew = forceDiscover || initial || refreshTick % 3 == 0
        let codexHome = SessionScanner.defaultCodexHome()
        let hooksFile = codexHome.appendingPathComponent("hooks.json")
        let hooksModifiedAt = try? hooksFile.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let refreshHookMetadata = initial || codexHookMetadataCheckedAt == nil ||
            hooksModifiedAt != codexHooksFileModifiedAt ||
            Date().timeIntervalSince(codexHookMetadataCheckedAt ?? .distantPast) >= 5 * 60
        let cachedHookMetadata = codexHookMetadata
        let work = Task.detached(priority: .background) {
            let result = try initial
                ? scanner.initialIndex()
                : scanner.refresh(activePaths: paths, discoverNew: discoverNew)
            let shouldSnapshot = initial || discoverNew || result.changedTurns > 0
            let next = try shouldSnapshot ? scanner.snapshot() : nil
            if let next, !initial {
                try scanner.recordShadowCompletions(from: previousSnapshot, to: next)
            } else if initial {
                try scanner.backfillRoutingOutcomes()
                try scanner.backfillExecutionWasteObservations()
                try scanner.store.reconcilePendingHandoffCosts()
            }
            let preflights = try scanner.store.routingPreflights(limit: 100)
            let auditTurns = try scanner.store.turns(limit: 2_000)
            let auditFindings = MultiAgentAuditPolicy.evaluate(turns: auditTurns)
            let appServerHooks = refreshHookMetadata
                ? ((try? CodexHooksListReader.read(cwds: [codexHome.path])) ?? [])
                : cachedHookMetadata
            let hookHealth = try? scanner.subagentHookHealth(appServerHooks: appServerHooks)
            if let hookHealth {
                try? scanner.store.recordSubagentHookHealthDiagnostic(
                    SubagentHookHealthDiagnostic(snapshot: hookHealth))
            }
            if initial { _ = malloc_zone_pressure_relief(nil, 0) }
            return (
                result, next, preflights, auditFindings,
                hookHealth, appServerHooks)
        }
        Task { [weak self] in
            do {
                let (
                    result, next, preflights, auditFindings,
                    hookHealth, appServerHooks
                ) = try await work.value
                guard let self else { return }
                self.activePaths = result.activePaths
                self.routingPreflights = preflights
                self.synchronizeMultiAgentFindings(auditFindings)
                if let hookHealth { self.subagentHookHealth = hookHealth }
                if refreshHookMetadata {
                    self.codexHookMetadata = appServerHooks
                    self.codexHookMetadataCheckedAt = Date()
                    self.codexHooksFileModifiedAt = hooksModifiedAt
                }
                if let next {
                    self.recordRoutingPostflights(from: self.snapshot, to: next)
                    self.resumeWarningSuppressions.reconcile(with: next.sessions)
                    if let warning = self.resumeWarning {
                        let current = next.sessions.first(where: { $0.sessionID == warning.sessionID })
                        let stillWaitingForUser = self.liveActivities[warning.sessionID]?.kind == .waitingForUser
                        if current == nil || current?.risk == .green || current?.activity == .executing || !stillWaitingForUser {
                            self.resumeWarning = nil
                        }
                    }
                    let excluded = self.resumeWarningSuppressions.allSessionIDs
                    let waitingForUser = Set(self.liveActivities.compactMap { sessionID, activity in
                        activity.kind == .waitingForUser ? sessionID : nil
                    })
                    if self.resumeWarning == nil,
                       let resumed = next.resumedGuardedSession(
                        from: self.snapshot,
                        excluding: excluded,
                        requiringUserAttention: waitingForUser),
                       self.resumeWarningBudget.consumeIfAllowed(
                        sessionID: resumed.sessionID,
                        at: next.updatedAt) {
                        self.resumeWarning = resumed
                    }
                    self.snapshot = next
                    self.synchronizeLiveActivityMonitor()
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

    func liveActivity(for sessionID: String) -> SessionLiveActivity? {
        liveActivities[sessionID]
    }

    func routingPreflight(for sessionID: String) -> RoutingPreflightObservation? {
        guard let latest = routingPreflights.first(where: { $0.belongs(to: sessionID) }),
              latest.blocked,
              Date().timeIntervalSince(latest.observedAt) < 30 * 60,
              !latest.isSuperseded(by: snapshot.sessions.first(where: {
                  $0.sessionID == sessionID
              })?.latestTurn)
        else { return nil }
        return latest
    }

    func pendingRoutingReplay(for sessionID: String) -> PendingRoutingReplay? {
        pendingRoutingReplays[sessionID]
    }

    func routingReplayError(for sessionID: String) -> String? {
        routingReplayErrors[sessionID]
    }

    func routingPostflight(for sessionID: String) -> RoutingPostflightAssessment? {
        guard !snapshot.active.contains(where: { $0.sessionID == sessionID }),
              let assessment = routingPostflights[sessionID],
              Date().timeIntervalSince(assessment.observedAt) < 30 * 60
        else { return nil }
        return assessment
    }

    func replayWithRecommendation(_ replay: PendingRoutingReplay) {
        performReplay(replay, using: replay.recommended)
    }

    func replayWithOriginalConfiguration(_ replay: PendingRoutingReplay) {
        performReplay(replay, using: replay.current)
    }

    func continueObserving(_ finding: MultiAgentAuditFinding) {
        suppressedExecutionAdvisoryIDs.insert(finding.id)
        if activeExecutionAdvisory?.id == finding.id { activeExecutionAdvisory = nil }
    }

    private func performReplay(_ replay: PendingRoutingReplay, using selection: RoutingSelection) {
        guard replayingRoutingSessionID == nil else { return }
        replayingRoutingSessionID = replay.sessionID
        routingReplayErrors.removeValue(forKey: replay.sessionID)
        let databasePath = SessionScanner.defaultDatabasePath()
        Task { [weak self] in
            let result: Result<CodexDesktopReplayReceipt, Error> = await Task.detached(priority: .userInitiated) {
                do {
                let store = try SQLiteStore(path: databasePath)
                try store.saveRoutingPreflightBypass(RoutingPreflightBypass(
                    sessionID: replay.sessionID,
                    prompt: replay.prompt))
                let receipt = try CodexDesktopTurnReplay.replay(
                    sessionID: replay.sessionID,
                    prompt: replay.prompt,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    previousSelection: replay.current)
                    try? store.recordRoutingHookDiagnostic(RoutingHookDiagnostic(
                        sessionID: replay.sessionID,
                        outcome: .allowed,
                        reasonCode: "replay_configuration_verified",
                        requestedSelection: selection,
                        actualSelection: receipt.actual))
                    return .success(receipt)
                } catch {
                    if let store = try? SQLiteStore(path: databasePath) {
                        _ = try? store.consumeRoutingPreflightBypass(
                            sessionID: replay.sessionID,
                            prompt: replay.prompt)
                        try? store.recordRoutingHookDiagnostic(RoutingHookDiagnostic(
                            sessionID: replay.sessionID,
                            outcome: .failed,
                            reasonCode: "replay_configuration_not_verified",
                            requestedSelection: selection,
                            actualSelection: (error as? CodexDesktopReplayError)?.actualSelection))
                    }
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.replayingRoutingSessionID = nil
            switch result {
            case .success:
                self.pendingRoutingReplays.removeValue(forKey: replay.sessionID)
                self.routingReplayErrors.removeValue(forKey: replay.sessionID)
                self.refresh(forceDiscover: true)
            case let .failure(error):
                let message = LF("Could not verify switch and replay: %@", error.localizedDescription)
                self.routingReplayErrors[replay.sessionID] = message
                self.errorMessage = message
            }
        }
    }

    private func applyLiveActivity(_ event: LiveActivityEvent, sessionID: String) {
        let previous = liveActivities[sessionID]
        guard previous == nil || event.occurredAt >= previous!.updatedAt else { return }
        liveActivities[sessionID] = SessionLiveActivity(
            event: event,
            previousSummary: previous?.publicSummary)
    }

    private func recordRoutingPostflights(from previous: DashboardSnapshot, to next: DashboardSnapshot) {
        let runningIDs = Set(previous.active.map(\.id))
        guard !runningIDs.isEmpty else { return }
        for turn in next.recent where turn.status != .running && runningIDs.contains(turn.id) {
            guard let outcome = RoutingOutcomeObservation.derive(
                from: turn,
                routingPreferenceProfile: routingPreferenceProfile)
            else { continue }
            routingPostflights[turn.sessionID] = RoutingPostflightAssessment.evaluate(outcome)
        }
    }


    private func synchronizeLiveActivityMonitor() {
        guard let scanner, let liveActivityMonitor else { return }
        let activeIDs = Set(snapshot.activeSessions.map(\.sessionID))
        let paths = scanner.visibleRolloutPaths(sessionIDs: activeIDs)
        liveActivityMonitor.synchronize(pathsBySessionID: paths)
        let visibleIDs = Set(snapshot.sessions.map(\.sessionID))
        liveActivities = liveActivities.filter { visibleIDs.contains($0.key) }
    }

    private func synchronizeMultiAgentFindings(_ findings: [MultiAgentAuditFinding]) {
        multiAgentFindings = findings
        let next = findings.first {
            $0.isActive &&
                $0.severity == .observeDuringExecution &&
                !suppressedExecutionAdvisoryIDs.contains($0.id)
        }
        activeExecutionAdvisory = next
        if let next, announcedExecutionAdvisoryIDs.insert(next.id).inserted {
            executionAdvisoryTick &+= 1
        }
    }

    func projectContext(_ turn: TurnRecord) -> String {
        projectContext(cwd: turn.cwd)
    }

    func projectContext(cwd: String) -> String {
        let components = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }
        let shortPath = components.suffix(3).joined(separator: "/")
        let project = URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
            ? L("Unknown project") : URL(fileURLWithPath: cwd).lastPathComponent
        return "\(project) · …/\(shortPath)"
    }

    func openSession(_ sessionID: String) {
        guard let url = URL(string: "codex://threads/\(sessionID)") else { return }
        NSWorkspace.shared.open(url)
    }

    func prepareFreshSession(_ session: SessionSummary) {
        guard !session.isActive else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Wait until the task is idle")
            alert.informativeText = L("Guardian will not interrupt a running task. When it is idle, ask Codex to summarize the necessary context and open a new task.")
            alert.runModal()
            return
        }
        guard let turn = session.latestTurn,
              let model = turn.model,
              let effort = turn.reasoningEffort
        else {
            errorMessage = L("Could not read this task's current model configuration.")
            return
        }
        let selection = RoutingSelection(model: model, reasoningEffort: effort)
        let handoffInstruction = PendingRoutingReplay(
            sessionID: session.sessionID,
            prompt: CodexManagedHandoff.instruction,
            current: selection,
            recommended: selection,
            reasonCode: "codex_managed_handoff",
            upgradeCondition: nil)
        performReplay(handoffInstruction, using: selection)
    }

    func dismissResumeWarning() {
        if let sessionID = resumeWarning?.sessionID {
            resumeWarningSuppressions.suppress(sessionID)
        }
        resumeWarning = nil
    }

    func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }

    func localizedReason(for session: SessionSummary) -> String {
        let policy = snapshot.healthPolicy
        let pressure = session.latestTurn?.contextPressure
        if session.postCompactionRebound {
            return L("Context rose quickly after a recent compaction. Keep observing task continuity.")
        }
        if let pressure, pressure >= policy.redContext {
            return LF(
                "Context %d%% reached your personalized high-pressure threshold of %d%%.",
                Int(pressure * 100),
                Int(policy.redContext * 100))
        }
        if session.recentCompactions > 0 {
            return L("This session compacted recently. Watch whether context rebounds quickly.")
        }
        if let pressure, pressure >= policy.amberContext {
            return LF(
                "Context %d%% reached your personalized watch threshold of %d%%.",
                Int(pressure * 100),
                Int(policy.amberContext * 100))
        }
        if session.freshInputAnomaly {
            return L("Fresh input for this turn is well above this session's personal baseline.")
        }
        if session.risk == .green {
            return LF(
                "Context is below %d%%, with no compaction or recent input anomaly.",
                Int(policy.amberContext * 100))
        }
        return L("Watch this session for health changes.")
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
        case .classicDance: L("Dance Shin-chan")
        case .codexPixel: L("Pixel Shin-chan")
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
        accessibilityDescription: L("Session guardian mascot"))!
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
        case .idle: L("Shin-chan running animation")
        case .working: L("Shin-chan waiting animation")
        case .multitask: L("Shin-chan idle animation")
        case .thinking: L("Shin-chan high-risk review animation")
        case .success: L("Shin-chan completion animation")
        case .guardian: L("Shin-chan hover animation")
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
    let onFloatingPetVisibilityChange: (Bool) -> Void
    @AppStorage("XiaoxinSessionManagerDarkMode") private var darkMode = false
    @AppStorage(PetAnimationTheme.storageKey) private var petThemeRawValue = PetAnimationTheme.classicDance.rawValue
    @AppStorage(FloatingPetPreference.storageKey) private var floatingPetVisible = true
    @AppStorage(XiaoxinSpeechPreference.storageKey) private var speechIntensityRawValue = XiaoxinSpeechPreference.defaultValue
    @State private var detailSessionID: String?
    @State private var manualRefreshFeedback = false

    var body: some View {
        let sessions = model.snapshot.sessions
        let activeSessions = sessions.filter(\.isActive)

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
                        policy: model.snapshot.healthPolicy,
                        speechIntensity: xiaoxinSpeechIntensity(speechIntensityRawValue))

                    sectionHeader(L("Tasks"), count: sessions.count, note: L("Most recently executed first"))
                    if sessions.isEmpty {
                        Text(L("No unarchived Codex sessions to display"))
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        sessionCards(sessions)
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
                    Text(L("Session health")).font(.title3.weight(.bold))
                    Text(AppVersion.label)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.orange.opacity(0.14), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text(activeCount == 0
                    ? L("No active sessions")
                    : LF("%d active sessions · See cards for details", activeCount))
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
                Text(LF("%d%% left", Int(quota.remainingPercent.rounded())))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(quotaColor(quota.level))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ProgressView(value: quota.remainingPercent, total: 100)
                    .tint(quotaColor(quota.level))
                    .frame(width: 150)
            } else {
                Text(L("— left"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(headerQuotaDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 160, alignment: .trailing)
    }

    private var headerQuotaDetail: String {
        guard let quota = model.snapshot.latestQuota else { return L("Waiting for Codex quota data") }
        guard let resetsAt = quota.resetsAt else { return L("Reset time —") }
        return LF("Resets at %@", Self.resetFormatter.string(from: resetsAt))
    }

    private var footer: some View {
        let petTheme = PetAnimationTheme(rawValue: petThemeRawValue) ?? .classicDance
        return HStack {
            Text(LF("%d sessions · 2s refresh / 30s discovery", model.snapshot.sessions.count))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isIndexing { ProgressView().controlSize(.small) }
            Button {
                floatingPetVisible.toggle()
                onFloatingPetVisibilityChange(floatingPetVisible)
            } label: {
                Label(
                    floatingPetVisible ? L("Hide pet") : L("Show pet"),
                    systemImage: floatingPetVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(floatingPetVisible ? L("Hide the floating guardian") : L("Show the floating guardian"))
            .accessibilityLabel(floatingPetVisible ? L("Hide floating guardian") : L("Show floating guardian"))

            Button {
                petThemeRawValue = petTheme.next.rawValue
                NotificationCenter.default.post(name: .petAnimationThemeDidChange, object: nil)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help(LF("Switch to the %@ animation set", petTheme.next.displayName))
            .accessibilityLabel(L("Switch animation set"))

            Menu {
                ForEach(XiaoxinSpeechIntensity.allCases, id: \.rawValue) { intensity in
                    Button {
                        speechIntensityRawValue = intensity.rawValue
                    } label: {
                        if speechIntensityRawValue == intensity.rawValue {
                            Label(intensity.localizedName, systemImage: "checkmark")
                        } else {
                            Text(intensity.localizedName)
                        }
                    }
                }
            } label: {
                Image(systemName: "quote.bubble")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(LF(
                "pet.personality.help.format",
                xiaoxinSpeechIntensity(speechIntensityRawValue).localizedName))
            .accessibilityLabel(L("pet.personality.accessibility"))

            Button { darkMode.toggle() } label: {
                Image(systemName: darkMode ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(.borderless)
            .help(darkMode ? L("Use light appearance") : L("Use dark appearance"))

            Button(action: quickRestart) {
                Label(L("Quick restart"), systemImage: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Restart the guardian without changing session data"))
            .accessibilityLabel(L("Quick restart"))

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
            .help(model.isManualRefreshing ? L("Refreshing session status") : L("Refresh now"))

            Divider().frame(height: 22)
            Button { NSApplication.shared.terminate(nil) } label: {
                Label(L("Quit"), systemImage: "power")
            }
                .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private func quickRestart() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            model.errorMessage = L("Quick restart is available in the installed app.")
            return
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$2\"",
            "codex-session-guardian-restart",
            "\(ProcessInfo.processInfo.processIdentifier)",
            bundleURL.path,
        ]
        do {
            try relaunch.run()
            NSApplication.shared.terminate(nil)
        } catch {
            model.errorMessage = LF("Could not restart the guardian: %@", error.localizedDescription)
        }
    }

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

private func multiAgentFindingText(_ finding: MultiAgentAuditFinding) -> String {
    switch finding.reason {
    case .genericWorkerInheritedFullHistory:
        return L("A generic worker inherited the full conversation. Next time use a bounded agent with fork_turns:none and an exact task envelope.")
    case .boundedWorkerInheritedFullHistory:
        return L("A bounded agent inherited the full conversation. Prefer fork_turns:none when the task has a frozen input contract.")
    case .unknownAgentInheritedFullHistory:
        return L("A child agent inherited the full conversation. Codex did not expose a specific agent type for this full-history fork.")
    case .largeTokenBurn:
        return LF("This child task has consumed %@ provider tokens (%@ weighted). This is observed usage, not an estimate of avoidable cost.", compactTokenCount(finding.usage.total), compactTokenCount(finding.weightedTokenBurn))
    case .broadParallelFanout:
        return L("Several child agents are active under one parent task. Keep only independently useful lanes running.")
    }
}

private struct DashboardOverviewCard: View {
    let quota: QuotaSnapshot?
    let policy: HealthPolicy
    let speechIntensity: XiaoxinSpeechIntensity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Personalized health thresholds"), systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 8)
            {
                policyMetric(L("Watch from"), "\(Int((policy.amberContext * 100).rounded()))%")
                policyMetric(L("High pressure"), "\(Int((policy.redContext * 100).rounded()))%")
                policyMetric(
                    L("Fresh-input reference"),
                    policy.freshInputReferenceThreshold.map(compactTokenCount) ?? L("Learning"))
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(policy.isCalibrated ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(policy.isCalibrated
                    ? LF("Calibrated from %d local samples", policy.effectiveSampleCount)
                    : LF("Local samples %d/20 · Using safe cold-start thresholds", policy.effectiveSampleCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RotatingTipText(
                tips: DynamicTipCatalog.tips(
                    policy: policy,
                    quota: quota,
                    speechIntensity: speechIntensity),
                foreground: .secondary,
                iconColor: .orange)
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
    static func tips(
        policy: HealthPolicy,
        quota: QuotaSnapshot?,
        speechIntensity: XiaoxinSpeechIntensity
    ) -> [String] {
        var values = [
            L("A high cache-hit rate saves fresh input, but does not guarantee a healthy context."),
            L("Fresh-input anomalies use your local history instead of a universal fixed limit."),
            L("A compaction is normal; watch whether context rebounds quickly afterward."),
            L("Context thresholds adapt only within conservative safety bounds."),
        ]
        if let quota {
            values.append(LF(
                "Global quota remaining: %d%%. It is shared across tasks.",
                Int(quota.remainingPercent.rounded())))
        }
        if let threshold = policy.freshInputReferenceThreshold {
            values.append(LF(
                "The current global fresh-input anomaly reference is about %@.",
                compactTokenCount(threshold)))
        }
        let personality = XiaoxinSpeechCatalog.lines(for: .idle, intensity: speechIntensity)
            .map { L($0.localizationKey) }
        values.insert(contentsOf: personality, at: 0)
        return values
    }
}

private struct RotatingTipText: View {
    let tips: [String]
    let foreground: Color
    let iconColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 12)) { context in
            let index = tips.isEmpty ? 0 : Int(context.date.timeIntervalSince1970 / 12) % tips.count
            let message = tips.isEmpty ? L("Your guardian is learning your session patterns.") : tips[index]
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(iconColor)
                Text(message)
                    .foregroundStyle(foreground)
                    .lineLimit(2)
                    .id(index)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(LF(
                "Dynamic tip: %@",
                tips.isEmpty ? L("Your guardian is learning your session patterns") : tips[index]))
        }
    }
}

private func compactTokenCount(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return String(value)
}

private func hasProviderTokenData(_ turn: TurnRecord) -> Bool {
    turn.calls > 0 || turn.usage.total > 0
}

private func providerMetric(_ turn: TurnRecord, _ value: @autoclosure () -> String) -> String {
    hasProviderTokenData(turn) ? value() : L("Collecting")
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
                    Text(model.localizedReason(for: session)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .background(riskColor(session.risk).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if let latest = session.latestTurn {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                    metric(
                        L("Context"),
                        providerMetric(latest, latest.contextPressure.map { "\(Int($0 * 100))%" } ?? "—"))
                    metric(L("Compactions"), "\(session.compactions)")
                    metric(L("Fresh input"), providerMetric(latest, model.compact(latest.usage.freshInput)))
                    metric(L("Total input"), providerMetric(latest, model.compact(latest.usage.input)))
                    metric(L("Output"), providerMetric(latest, model.compact(latest.usage.output)))
                    metric(L("Cache hit"), providerMetric(latest, "\(Int(latest.usage.cacheHitRate * 100))%"))
                }
            }

            HStack {
                Button {
                    model.openSession(session.sessionID)
                } label: {
                    Label(L("Open source task"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                if !session.isActive {
                    Button { model.prepareFreshSession(session) } label: {
                        if model.replayingRoutingSessionID == session.sessionID {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text(L("Asking Codex…"))
                            }
                        } else {
                            Label(L("Ask Codex to summarize & start fresh"), systemImage: "arrow.triangle.branch")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.replayingRoutingSessionID != nil)
                }
                Spacer()
                Button(action: onToggle) {
                    Label(L("Token usage details"), systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }

            if expanded, let latest = session.latestTurn {
                Divider()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                    metric(L("Cache write"), providerMetric(latest, model.compact(latest.usage.cacheWriteInput)))
                    metric(L("Reasoning"), providerMetric(latest, model.compact(latest.usage.reasoningOutput)))
                    metric(L("Calls"), providerMetric(latest, "\(latest.calls)"))
                    metric(L("Session total"), providerMetric(latest, model.compact(session.usage.total)))
                    metric(L("Status"), turnStatus(latest.status))
                    metric(L("Data quality"), localizedConfidence(latest.confidence))
                }
            }
        }
        .padding(15)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.84),
            in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06)))
        .onTapGesture(count: 2) { model.openSession(session.sessionID) }
        .help(L("Double-click to open the source task. Cards show the latest turn; older turns inform background trends only."))
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
        case .executing: (label, color) = (L("Running"), .green)
        case .waiting: (label, color) = (L("Recently active"), .orange)
        case .interrupted: (label, color) = (L("Interrupted"), .red)
        case .stopped: (label, color) = (L("Stopped"), .secondary)
        }
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
    }
}

private extension RelativeDateTimeFormatter {
    static let tokenPet: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct NativePetDragSurface: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (Bool) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NativePetDragView {
        NativePetDragView(
            onHover: onHover,
            onDragBegan: onDragBegan,
            onDragEnded: onDragEnded,
            onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ view: NativePetDragView, context: Context) {
        view.onHover = onHover
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
    }
}

private final class NativePetDragView: NSView {
    var onHover: (Bool) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: (Bool) -> Void
    var onDoubleClick: () -> Void
    private var trackingArea: NSTrackingArea?
    private var dragActive = false
    private var pointerInside = false
    private var pendingSingleClick: DispatchWorkItem?

    init(
        onHover: @escaping (Bool) -> Void,
        onDragBegan: @escaping () -> Void,
        onDragEnded: @escaping (Bool) -> Void,
        onDoubleClick: @escaping () -> Void
    ) {
        self.onHover = onHover
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { pendingSingleClick?.cancel() }

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
        updateHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragActive else { return }
        updateHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let window else { return }
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick()
            return
        }
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
        if moved {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDragEnded(true)
        } else {
            let action = DispatchWorkItem { [weak self] in
                self?.pendingSingleClick = nil
                self?.onDragEnded(false)
            }
            pendingSingleClick?.cancel()
            pendingSingleClick = action
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval,
                execute: action)
        }

        let windowPoint = window.convertPoint(fromScreen: endPointer)
        updateHover(bounds.contains(convert(windowPoint, from: nil)))
    }

    private func updateHover(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        onHover(inside)
    }
}

@MainActor
private final class FloatingPetController {
    private let panel: NSPanel
    private let collapsedSize = NSSize(width: 116, height: 126)
    private var petAnchor = NSPoint.zero
    private var layoutSignature: (mode: FloatingPanelMode, sessionCount: Int)?
    private var visibilityLifecycle = FloatingPetVisibilityLifecycle()
    private var initialPlacementDone = false
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
                model.setFloatingWorkspaceVisible(mode != .collapsed)
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

    func setVisible(_ visible: Bool) {
        if visible {
            if !initialPlacementDone {
                showInitially()
            } else {
                _ = visibilityLifecycle.nextShowPlacement()
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }

    func refreshPlacementAfterLaunch() {
        guard initialPlacementDone else {
            showInitially()
            return
        }
        let isOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !isOnScreen {
            initialPlacementDone = false
            showInitially()
        }
        panel.orderFrontRegardless()
    }

    private func showInitially() {
        guard !NSScreen.screens.isEmpty else {
            // At process launch an accessory app may not have a main screen
            // yet. Retry after AppKit finishes attaching the window server.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showInitially()
            }
            return
        }
        let defaults = UserDefaults.standard
        let savedAnchor: NSPoint?
        if defaults.object(forKey: savedXKey) != nil, defaults.object(forKey: savedYKey) != nil {
            savedAnchor = NSPoint(x: defaults.double(forKey: savedXKey), y: defaults.double(forKey: savedYKey))
        } else {
            savedAnchor = nil
        }
        let screen: NSScreen = {
            if let savedAnchor,
               let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(savedAnchor) }) {
                return matchingScreen
            }
            if let mouseScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) }) {
                return mouseScreen
            }
            return NSScreen.main ?? NSScreen.screens[0]
        }()
        let frame = screen.visibleFrame
        let proposedAnchor = savedAnchor ?? NSPoint(x: frame.maxX - 28, y: frame.minY + 220)
        petAnchor = FloatingPetGeometry.constrainedPetAnchor(
            proposedAnchor,
            petSize: collapsedSize,
            visibleFrame: frame)
        panel.setFrame(
            NSRect(origin: origin(for: petAnchor, size: collapsedSize), size: collapsedSize),
            display: false)
        initialPlacementDone = true
        panel.orderFrontRegardless()
    }

    private func resize(mode: FloatingPanelMode, sessionCount: Int) {
        let signature = (mode: mode, sessionCount: sessionCount)
        guard layoutSignature?.mode != signature.mode ||
                layoutSignature?.sessionCount != signature.sessionCount else { return }
        let previousMode = layoutSignature?.mode
        layoutSignature = signature
        let size: NSSize
        switch mode {
        case .collapsed:
            size = collapsedSize
        case .stacked:
            size = NSSize(width: 640, height: sessionCount == 1 ? 370 : 390)
        case .spread:
            let visibleCards = min(4, max(1, sessionCount))
            size = NSSize(width: 640, height: min(796, 166 + CGFloat(visibleCards) * 146))
        }
        if petAnchor == .zero { petAnchor = NSPoint(x: panel.frame.maxX, y: panel.frame.minY) }
        let screenFrame = visibleFrame(forPetAnchor: petAnchor)
        // `petAnchor` belongs to the mascot, not to the temporary card size.
        // Re-clamping it with the expanded 640pt panel made the mascot move
        // when hover collapse switched back to the 116pt footprint.
        petAnchor = FloatingPetGeometry.constrainedPetAnchor(
            petAnchor,
            petSize: collapsedSize,
            visibleFrame: screenFrame)
        let animatesCardTransition =
            (previousMode == .stacked && mode == .spread) ||
            (previousMode == .spread && mode == .stacked)
        panel.setFrame(
            NSRect(origin: origin(for: petAnchor, size: size), size: size),
            display: true,
            animate: animatesCardTransition)
        panel.displayIfNeeded()
    }

    private func nativeDragEnded() {
        let proposed = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        let screenFrame = visibleFrame(forPetAnchor: proposed)
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

    private func visibleFrame(forPetAnchor anchor: NSPoint) -> NSRect {
        FloatingPetGeometry.visibleFrame(
            forPetAnchor: anchor,
            petSize: collapsedSize,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame)) ??
            NSScreen.main?.visibleFrame ?? panel.frame
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
    @State private var speechKey: String?
    @State private var speechGeneration = 0
    @State private var speechScheduler = XiaoxinSpeechScheduler()
    @AppStorage(PetAnimationTheme.storageKey) private var petThemeRawValue = PetAnimationTheme.classicDance.rawValue
    @AppStorage(XiaoxinSpeechPreference.storageKey) private var speechIntensityRawValue = XiaoxinSpeechPreference.defaultValue

    private var petTheme: PetAnimationTheme {
        PetAnimationTheme(rawValue: petThemeRawValue) ?? .classicDance
    }

    private var displayedSessions: [SessionSummary] {
        let stabilized = FloatingPetGeometry.stabilizedSessions(
            frozen: frozenSessions,
            current: model.snapshot.activeSessions)
        let routingPending = model.pendingRoutingReplays.values
            .map { ($0.sessionID, $0.observedAt) }
        guard let pendingID = routingPending
            .max(by: { $0.1 < $1.1 })?.0,
              let pendingSession = model.snapshot.sessions.first(where: { $0.sessionID == pendingID })
        else { return stabilized }
        return [pendingSession] + stabilized.filter { $0.sessionID != pendingID }
    }

    private var displayedSessionIDs: [String] {
        displayedSessions.map(\.sessionID)
    }

    private var desiredAnimationState: PetAnimationState {
        model.snapshot.petAnimationState(
            liveActivities: model.liveActivities,
            isHovered: petHovered,
            hasResumeWarning: model.resumeWarning != nil,
            isCelebrating: celebrationActive)
    }

    private var animationPaused: Bool { dragInProgress }

    private var speechIntensity: XiaoxinSpeechIntensity {
        xiaoxinSpeechIntensity(speechIntensityRawValue)
    }

    private var currentSpeechContext: XiaoxinSpeechContext {
        let active = model.snapshot.activeSessions
        if let attentionLiveActivity { return attentionLiveActivity.kind.speechContext }
        if active.contains(where: { $0.risk == .red }) { return .danger }
        if active.contains(where: { $0.risk == .amber }) { return .watch }
        if let latestLiveActivity,
           Date().timeIntervalSince(latestLiveActivity.updatedAt) < 60 {
            return latestLiveActivity.kind.speechContext
        }
        if active.count > 1 { return .multitask }
        if !active.isEmpty { return .working }
        return .idle
    }

    private var activityFingerprint: String {
        model.snapshot.sessions
            .map { "\($0.sessionID):\($0.activity.rawValue):\($0.risk.rawValue)" }
            .sorted()
            .joined(separator: "|")
    }

    private var activeLiveActivities: [SessionLiveActivity] {
        let activeIDs = Set(model.snapshot.activeSessions.map(\.sessionID))
        return model.liveActivities
            .filter { activeIDs.contains($0.key) }
            .map(\.value)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var latestLiveActivity: SessionLiveActivity? {
        activeLiveActivities.first
    }

    private var attentionLiveActivity: SessionLiveActivity? {
        activeLiveActivities.first(where: { $0.kind.needsUserAttention })
    }

    private var liveActivityFingerprint: String {
        model.liveActivities
            .map { "\($0.key):\($0.value.kind.rawValue):\($0.value.updatedAt.timeIntervalSince1970)" }
            .sorted()
            .joined(separator: "|")
    }

    private var routingAttentionSessionID: String? {
        if let pending = model.pendingRoutingReplays.values.max(by: { $0.observedAt < $1.observedAt }) {
            return pending.sessionID
        }
        return displayedSessions.first { model.routingPreflight(for: $0.sessionID) != nil }?.sessionID
    }

    private var routingAttentionFingerprint: String {
        let routing = model.pendingRoutingReplays.values
            .map { "\($0.sessionID):\($0.observedAt.timeIntervalSince1970):\($0.recommended.model):\($0.recommended.reasoningEffort)" }
        return routing
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if mode != .collapsed {
                VStack(alignment: .trailing, spacing: 10) {
                    HStack {
                        Text(L("Active task cards"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        Button(action: collapse) {
                            Label(L("Collapse cards"), systemImage: "rectangle.compress.vertical")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.white.opacity(0.18))
                        .help(L("Collapse floating task cards"))
                    }
                    .frame(width: 556)
                    if let finding = model.activeExecutionAdvisory {
                        FloatingExecutionAdvisoryCard(finding: finding, model: model)
                    }
                    if let hookHealth = model.subagentHookHealth, hookHealth.requiresAttention {
                        FloatingSubagentHookHealthCard(snapshot: hookHealth)
                    }
                    if let warning = model.resumeWarning {
                        FloatingResumeWarningCard(session: warning, model: model)
                    } else if displayedSessions.isEmpty {
                        FloatingEmptyCard(
                            policy: model.snapshot.healthPolicy,
                            quota: model.snapshot.latestQuota,
                            speechIntensity: speechIntensity)
                    } else if displayedSessions.count == 1, let session = displayedSessions.first {
                        FloatingSessionCard(session: session, model: model, isFocus: true)
                    } else if mode == .spread {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(displayedSessions) { session in
                                    FloatingSessionCard(session: session, model: model, isFocus: false)
                                        .transition(
                                            .opacity.combined(with: .offset(y: -14)))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        // The system scroll view paints an opaque content well on macOS.
                        // Cards already own their surfaces, so that extra rectangle makes
                        // the expanded workspace look like it has a second background.
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .scrollIndicators(.hidden)
                        .frame(height: min(570, CGFloat(min(4, displayedSessions.count)) * 196))
                    } else {
                        FloatingSessionStack(
                            sessions: displayedSessions,
                            model: model,
                            onExpand: expandSessionStack)
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

            ZStack(alignment: .top) {
                PetSequencePlayer(state: displayedAnimationState, theme: petTheme, paused: animationPaused)
                    // Every frame is pre-normalized into this stable canvas and one
                    // foot baseline; per-sequence effective scale is baked into PNGs.
                    .frame(width: 106, height: 116, alignment: .bottomTrailing)
                    .shadow(color: .black.opacity(0.24), radius: 7, y: 5)
                    .overlay(alignment: .topTrailing) {
                        if model.activeExecutionAdvisory != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.red, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                                .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                                .padding(.top, 3)
                                .padding(.trailing, 2)
                                .allowsHitTesting(false)
                                .accessibilityLabel(L("Execution strategy needs attention"))
                        } else if let hookHealth = model.subagentHookHealth, hookHealth.requiresAttention {
                            Image(systemName: "link.badge.plus")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.orange, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                                .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                                .padding(.top, 3)
                                .padding(.trailing, 2)
                                .allowsHitTesting(false)
                                .accessibilityLabel(L("Subagent lifecycle monitoring"))
                        } else if routingAttentionSessionID != nil {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.orange, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                                .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                                .padding(.top, 3)
                                .padding(.trailing, 2)
                                .allowsHitTesting(false)
                                .accessibilityLabel(L("Task configuration needs switching"))
                        } else if let attentionLiveActivity {
                            Image(systemName: liveActivityIcon(attentionLiveActivity.kind))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(liveActivityColor(attentionLiveActivity.kind), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                                .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
                                .padding(.top, 3)
                                .padding(.trailing, 2)
                                .allowsHitTesting(false)
                                .accessibilityLabel(liveActivityTitle(
                                    attentionLiveActivity.kind,
                                    detailCount: attentionLiveActivity.detailCount))
                        }
                    }

                NativePetDragSurface(
                    onHover: { inside in
                        petHovered = inside
                        if inside {
                            showSpeech(
                                for: .hover,
                                minimumGap: 20,
                                bypassRepeatCooldown: true)
                        }
                    },
                    onDragBegan: {
                        invalidatePendingCollapse()
                        dragInProgress = true
                    },
                    onDragEnded: { moved in
                        onNativeDragEnded()
                        dragInProgress = false
                        if moved {
                            showSpeech(
                                for: .drag,
                                bypassMinimumGap: true,
                                bypassRepeatCooldown: true)
                        } else {
                            togglePanel()
                        }
                        reconcileHoverAfterDrag()
                    },
                    onDoubleClick: {
                        playDoubleClickReaction()
                    })

                if let speechKey, !dragInProgress {
                    XiaoxinSpeechBubble(text: L(speechKey))
                        .padding(.top, 1)
                        .offset(
                            x: mode == .collapsed ? -6 : -52,
                            y: mode == .collapsed ? -4 : -16)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 106, height: 116, alignment: .bottomTrailing)
            .help(pinned ? L("Click to collapse session cards") : L("Click to pin session cards"))
            .accessibilityLabel(pinned ? L("Collapse guardian session cards") : L("Pin guardian session cards"))
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                showSpeech(for: .welcome, bypassMinimumGap: true)
            }
        }
        .onChange(of: activityFingerprint) { _, _ in
            observeSessionActivity()
        }
        .onChange(of: liveActivityFingerprint) { _, _ in
            observeLiveActivity()
        }
        .onChange(of: routingAttentionFingerprint) { _, fingerprint in
            guard !fingerprint.isEmpty, let sessionID = routingAttentionSessionID else { return }
            invalidatePendingCollapse()
            if let session = model.snapshot.sessions.first(where: { $0.sessionID == sessionID }) {
                frozenSessions = [session] + model.snapshot.activeSessions.filter { $0.sessionID != sessionID }
            } else {
                frozenSessions = model.snapshot.activeSessions
            }
            pinned = true
            mode = .stacked
            onLayoutChange(.stacked, max(1, displayedSessions.count))
        }
        .onChange(of: displayedSessionIDs) { _, ids in
            guard mode != .collapsed else { return }
            onLayoutChange(mode, ids.count)
        }
        .onChange(of: desiredAnimationState) { _, state in
            guard !animationPaused else { return }
            displayedAnimationState = state
        }
        .onChange(of: animationPaused) { _, paused in
            guard !paused else { return }
            displayedAnimationState = desiredAnimationState
        }
        .onChange(of: model.manualRefreshCompletionTick) { _, _ in
            showSpeech(for: .refresh)
        }
        .onChange(of: model.executionAdvisoryTick) { _, _ in
            invalidatePendingCollapse()
            pinned = true
            mode = .stacked
            onLayoutChange(.stacked, max(1, displayedSessions.count))
            showSpeech(for: .executionAdvisory, bypassMinimumGap: true)
        }
        .onChange(of: speechIntensityRawValue) { _, _ in
            if speechIntensity == .off {
                speechGeneration &+= 1
                speechKey = nil
            } else {
                showSpeech(for: currentSpeechContext, bypassMinimumGap: true)
            }
        }
    }

    private func observeSessionActivity() {
        let completed = model.snapshot.completedSessionIDs(previouslyActive: previousActiveSessionIDs)
        previousActiveSessionIDs = Set(model.snapshot.activeSessions.map(\.sessionID))
        guard !completed.isEmpty else {
            showSpeech(
                for: currentSpeechContext,
                bypassMinimumGap: currentSpeechContext == .danger)
            return
        }
        celebrationGeneration &+= 1
        let generation = celebrationGeneration
        celebrationActive = true
        let recentLiveCompletion = model.liveActivities.values.contains {
            $0.kind == .completed && Date().timeIntervalSince($0.updatedAt) < 10
        }
        if !recentLiveCompletion { showSpeech(for: .success, bypassMinimumGap: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard generation == celebrationGeneration else { return }
            celebrationActive = false
        }
    }

    private func observeLiveActivity() {
        guard let (sessionID, latest) = model.liveActivities.max(by: { $0.value.updatedAt < $1.value.updatedAt }),
              abs(Date().timeIntervalSince(latest.updatedAt)) < 5
        else { return }

        if latest.kind == .completed {
            celebrationGeneration &+= 1
            let generation = celebrationGeneration
            celebrationActive = true
            showSpeech(for: .success, bypassMinimumGap: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                guard generation == celebrationGeneration else { return }
                celebrationActive = false
            }
            return
        }

        if latest.kind.needsUserAttention {
            presentAttention(for: sessionID)
        }

        showSpeech(
            for: latest.kind.speechContext,
            minimumGap: 12,
            bypassMinimumGap: latest.kind.needsUserAttention)
    }

    private func presentAttention(for sessionID: String) {
        guard let session = model.snapshot.sessions.first(where: { $0.sessionID == sessionID }) else { return }
        invalidatePendingCollapse()
        frozenSessions = [session] + model.snapshot.activeSessions.filter { $0.sessionID != sessionID }
        pinned = true
        mode = .stacked
        onLayoutChange(.stacked, max(1, displayedSessions.count))
    }

    private func showSpeech(
        for context: XiaoxinSpeechContext,
        minimumGap: TimeInterval = 8,
        bypassMinimumGap: Bool = false,
        bypassRepeatCooldown: Bool = false
    ) {
        guard !dragInProgress,
              let line = speechScheduler.nextLine(
                for: context,
                intensity: speechIntensity,
                minimumGap: minimumGap,
                bypassMinimumGap: bypassMinimumGap,
                bypassRepeatCooldown: bypassRepeatCooldown)
        else { return }
        speechGeneration &+= 1
        let generation = speechGeneration
        withAnimation(.easeOut(duration: 0.16)) {
            speechKey = line.localizationKey
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard generation == speechGeneration else { return }
            withAnimation(.easeIn(duration: 0.18)) { speechKey = nil }
        }
    }

    private func playDoubleClickReaction() {
        invalidatePendingCollapse()
        celebrationGeneration &+= 1
        let generation = celebrationGeneration
        celebrationActive = true
        showSpeech(
            for: .doubleClick,
            bypassMinimumGap: true,
            bypassRepeatCooldown: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
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

    private func expandSessionStack() {
        guard mode == .stacked, displayedSessions.count > 1 else { return }
        invalidatePendingCollapse()
        pinned = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            mode = .spread
        }
        onLayoutChange(.spread, displayedSessions.count)
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

private struct XiaoxinSpeechBubble: View {
    let text: String

    private let ink = Color(red: 0.10, green: 0.15, blue: 0.24)
    private let paper = Color(red: 1.00, green: 0.96, blue: 0.72)
    private let shirtRed = Color(red: 0.92, green: 0.18, blue: 0.20)

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
            .foregroundStyle(ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 12)
            .frame(maxWidth: 104)
            .background {
                XiaoxinCartoonBubbleShape()
                    .fill(paper)
                    .shadow(color: shirtRed.opacity(0.72), radius: 0, x: 2.5, y: 3)
            }
            .overlay {
                XiaoxinCartoonBubbleShape()
                    .stroke(ink, style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            }
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(shirtRed)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(ink, lineWidth: 1.4))
                    .offset(x: 7, y: -2)
            }
            .rotationEffect(.degrees(-1.2))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            .accessibilityLabel(LF("pet.speech.accessibility.format", text))
    }
}

private struct XiaoxinCartoonBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(
            x: 1.5,
            y: 1.5,
            width: max(0, rect.width - 3),
            height: max(0, rect.height - 10))
        path.addRoundedRect(
            in: body,
            cornerSize: CGSize(width: 13, height: 13))
        path.move(to: CGPoint(x: body.maxX - 30, y: body.maxY - 1))
        path.addLine(to: CGPoint(x: body.maxX - 19, y: rect.maxY - 1.5))
        path.addLine(to: CGPoint(x: body.maxX - 40, y: body.maxY - 2))
        path.closeSubpath()
        return path
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
            Text(LF("%d active", sessions.count))
                .font(.subheadline.weight(.semibold))
            Circle().fill(riskColor(highestRisk)).frame(width: 8, height: 8)
            Text(riskTitle(highestRisk))
                .font(.caption.weight(.semibold))
                .foregroundStyle(riskColor(highestRisk))
            Spacer(minLength: 14)
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(quota.map { quotaColor($0.level) } ?? .secondary)
            Text(quota.map { LF("Quota %d%%", Int($0.remainingPercent.rounded())) } ?? L("Quota —"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(quota.map { quotaColor($0.level) } ?? .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .frame(width: 420)
        .background(.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.13)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .help(L("Quota is a global window shared by all sessions"))
    }
}

private struct FloatingSessionStack: View {
    let sessions: [SessionSummary]
    @ObservedObject var model: DashboardModel
    let onExpand: () -> Void
    @State private var hovered = false

    private var layerCount: Int { min(3, sessions.count) }
    private var backingLayerIndices: [Int] { Array((1..<layerCount).reversed()) }

    var body: some View {
        ZStack(alignment: .top) {
            backingLayers

            if let first = sessions.first {
                FloatingSessionCard(session: first, model: model, isFocus: true)
                    .allowsHitTesting(false)
                    .scaleEffect(hovered ? 1.006 : 1)
            }

            taskCountBadge
        }
        .frame(width: 556, height: 220, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovered = inside }
        }
        .help(L("pet.stack.click_to_expand"))
        .accessibilityLabel(LF("pet.stack.task_count.format", sessions.count))
        .accessibilityHint(L("pet.stack.click_to_expand"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onExpand() }
    }

    private var backingLayers: some View {
        ForEach(backingLayerIndices, id: \.self) { layer in
            RoundedRectangle(cornerRadius: 24)
                .fill(stackLayerGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.34), radius: 12, y: 7)
                .padding(.horizontal, CGFloat(layer) * 13)
                .frame(height: 190)
                .offset(y: CGFloat(layer) * 13)
        }
    }

    private var stackLayerGradient: LinearGradient {
        LinearGradient(
            colors: [Color(nsColor: .darkGray).opacity(0.96), .black.opacity(0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private var taskCountBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.stack.fill")
            Text(LF("pet.stack.task_count.format", sessions.count))
            Image(systemName: "chevron.down")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.84), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
        .offset(y: 178 + CGFloat(max(0, layerCount - 1)) * 7)
    }
}

private struct FloatingSessionCard: View {
    let session: SessionSummary
    @ObservedObject var model: DashboardModel
    let isFocus: Bool
    @State private var hovered = false

    var body: some View {
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

                if let replay = model.pendingRoutingReplay(for: session.sessionID) {
                    FloatingRoutingPreflightView(
                        current: replay.current,
                        recommended: replay.recommended,
                        reasonCode: replay.reasonCode,
                        canReplay: true,
                        isReplaying: model.replayingRoutingSessionID == session.sessionID,
                        errorMessage: model.routingReplayError(for: session.sessionID),
                        onReplay: { model.replayWithRecommendation(replay) },
                        onKeepCurrent: { model.replayWithOriginalConfiguration(replay) })
                } else if let decision = model.routingPreflight(for: session.sessionID),
                          let recommended = decision.recommended {
                    FloatingRoutingPreflightView(
                        current: decision.current,
                        recommended: recommended,
                        reasonCode: decision.reasonCode,
                        canReplay: false,
                        isReplaying: false,
                        errorMessage: nil,
                        onReplay: {},
                        onKeepCurrent: nil)
                } else if let assessment = model.routingPostflight(for: session.sessionID) {
                    FloatingRoutingPostflightView(assessment: assessment)
                } else {
                    FloatingLiveActivityView(activity: model.liveActivity(for: session.sessionID))
                }

                if let latest = session.latestTurn {
                    HStack(spacing: 8) {
                        floatingMetric(
                            L("Context"),
                            providerMetric(latest, latest.contextPressure.map { "\(Int($0 * 100))%" } ?? "—"),
                            emphasized: true)
                        floatingMetric(L("Compactions"), "\(session.compactions)", emphasized: false)
                        floatingMetric(
                            L("Fresh input"),
                            providerMetric(latest, model.compact(latest.usage.freshInput)),
                            emphasized: true)
                        floatingMetric(
                            L("Cache hit"),
                            providerMetric(latest, "\(Int(latest.usage.cacheHitRate * 100))%"),
                            emphasized: false)
                        floatingMetric(
                            L("Total input"),
                            providerMetric(latest, model.compact(latest.usage.input)),
                            emphasized: false)
                        floatingMetric(
                            L("Output"),
                            providerMetric(latest, model.compact(latest.usage.output)),
                            emphasized: false)
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
        .onTapGesture { model.openSession(session.sessionID) }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovered = inside }
        }
        .help(LF("Open the source Codex task · %@", model.localizedReason(for: session)))
        .accessibilityLabel(LF(
            "Open task %@, %@, %@",
            session.title,
            activityTitle(session.activity),
            adviceTitle(session.advice)))
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

private struct FloatingRoutingPreflightView: View {
    let current: RoutingSelection
    let recommended: RoutingSelection
    let reasonCode: String
    let canReplay: Bool
    let isReplaying: Bool
    let errorMessage: String?
    let onReplay: () -> Void
    let onKeepCurrent: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Configuration mismatch · task paused before execution"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Text(LF(
                    "%@/%@ → %@/%@",
                    shortRoutingModel(current.model),
                    current.reasoningEffort,
                    shortRoutingModel(recommended.model),
                    recommended.reasoningEffort))
                    .font(.caption.monospaced().weight(.semibold))
                Text(routingPreflightReason(reasonCode))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if canReplay {
                VStack(alignment: .trailing, spacing: 5) {
                    Button(
                        isReplaying ? L("Applying configuration…") : L("Switch configuration & continue"),
                        action: onReplay)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    if let onKeepCurrent {
                        Button(L("Continue with original configuration"), action: onKeepCurrent)
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                    .disabled(isReplaying)
            } else {
                Text(L("Open task to resend"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 70)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.34)))
    }
}

private struct FloatingRoutingPostflightView: View {
    let assessment: RoutingPostflightAssessment

    private var color: Color {
        switch assessment.quality {
        case .passed: .green
        case .failed: .red
        case .insufficientEvidence: .orange
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: assessment.quality == .passed
                ? "checkmark.seal.fill"
                : assessment.quality == .failed ? "exclamationmark.triangle.fill" : "questionmark.diamond.fill")
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(postflightTitle(assessment))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(LF(
                    "%@/%@ · %@ Token · %@",
                    shortRoutingModel(assessment.executed.model),
                    assessment.executed.reasoningEffort,
                    compactMetric(assessment.usage.total),
                    durationMetric(assessment.durationSeconds)))
                    .font(.caption.monospaced().weight(.semibold))
                Text(postflightDetail(assessment))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 70)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.34)))
    }

    private func compactMetric(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func durationMetric(_ seconds: Double) -> String {
        seconds >= 60 ? String(format: "%.1f min", seconds / 60) : String(format: "%.0f s", seconds)
    }
}

private struct FloatingLiveActivityView: View {
    let activity: SessionLiveActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: liveActivityIcon(activity?.kind ?? .thinking))
                    .foregroundStyle(liveActivityColor(activity?.kind ?? .thinking))
                Text(liveActivityTitle(activity?.kind ?? .thinking, detailCount: activity?.detailCount))
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                if let activity {
                    Text(activity.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.56))
                        .monospacedDigit()
                } else {
                    Text(L("Waiting for live activity"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
            Text(activity?.publicSummary ?? L("No public output yet"))
                .font(.caption)
                .foregroundStyle(.white.opacity(activity?.publicSummary == nil ? 0.5 : 0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: 70, alignment: .topLeading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
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
                Text(L("A high-risk session was resumed"))
                    .font(.headline)
                Spacer()
                Text(L("Your confirmation is required"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
            Text(session.title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Text(model.localizedReason(for: session))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
            Text(L("This task is still producing output. Guardian will not interrupt it or create a task. When it becomes idle, you can ask Codex itself to summarize the necessary context and open a new task."))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button(L("Open source task")) {
                    model.openSession(session.sessionID)
                    model.dismissResumeWarning()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button(L("Ask Codex to summarize & start fresh")) {
                    model.prepareFreshSession(session)
                    model.dismissResumeWarning()
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(L("Continue anyway")) { model.dismissResumeWarning() }
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

private struct FloatingExecutionAdvisoryCard: View {
    let finding: MultiAgentAuditFinding
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("Child-agent context needs attention"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text(L("Observation only"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(finding.taskName).font(.title3.weight(.bold)).lineLimit(1)
            Text(multiAgentFindingText(finding))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(L("Got it")) { model.continueObserving(finding) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 556, height: 184, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.97), .orange.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.orange.opacity(0.42)))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

private struct FloatingSubagentHookHealthCard: View {
    let snapshot: SubagentHookHealthSnapshot

    private func stateText(_ state: SubagentHookHealthState) -> String {
        switch state {
        case .notInstalled: L("Not installed")
        case .installedButUntrusted: L("Installed but not trusted")
        case .awaitingFirstEvent: L("Awaiting first lifecycle event")
        case .healthy: L("Healthy")
        case .stale: L("Stale")
        }
    }

    private var guidance: String {
        if snapshot.start.state == .installedButUntrusted || snapshot.stop.state == .installedButUntrusted {
            return L("Open Codex /hooks to review and trust both handlers. Guardian does not edit config.toml.")
        }
        if snapshot.start.state == .stale || snapshot.stop.state == .stale {
            return L("Rollout activity was observed without a recent lifecycle event. Fully restart Codex Desktop; Guardian does not edit config.toml.")
        }
        return L("Review the lifecycle handlers in Codex /hooks. Guardian does not edit config.toml.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("Subagent lifecycle monitoring"), systemImage: "link.badge.plus")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text(L("Observation only"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 14) {
                hookStatus(label: L("Start Hook"), state: snapshot.start.state)
                hookStatus(label: L("Stop Hook"), state: snapshot.stop.state)
            }
            Text(guidance)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(minWidth: 556, maxWidth: 556, minHeight: 150, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.97), .orange.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.orange.opacity(0.42)))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    private func hookStatus(label: String, state: SubagentHookHealthState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.62))
            Text(stateText(state)).font(.subheadline.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FloatingEmptyCard: View {
    let policy: HealthPolicy
    let quota: QuotaSnapshot?
    let speechIntensity: XiaoxinSpeechIntensity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Circle().fill(.green).frame(width: 9, height: 9)
                Text(L("Your guardian is taking a break")).font(.headline)
                Spacer()
                Text(localizedCalibrationLabel(policy))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            RotatingTipText(
                tips: DynamicTipCatalog.tips(
                    policy: policy,
                    quota: quota,
                    speechIntensity: speechIntensity),
                foreground: .white.opacity(0.68),
                iconColor: .orange)
            Text(L("Default entry: sol/medium · Xiaoxin checks every task before execution"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange.opacity(0.88))
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 556, height: 116, alignment: .leading)
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
    switch risk {
    case .green: L("Healthy")
    case .amber: L("Context is filling up")
    case .red: L("Context is highly loaded")
    }
}

private func riskExplanation(_ risk: TurnRisk) -> String {
    switch risk {
    case .green: L("Active sessions are safe to continue.")
    case .amber: L("At least one active session needs attention.")
    case .red: L("At least one active session has limited context headroom.")
    }
}

private func adviceTitle(_ advice: SessionAdvice) -> String {
    switch advice {
    case .continueCurrent: L("Continue current task")
    case .watch: L("Watch")
    case .startFresh: L("Start fresh")
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
    case .running: L("Running")
    case .completed: L("Completed")
    case .interrupted: L("Interrupted")
    }
}

private func liveActivityTitle(_ kind: LiveActivityKind, detailCount: Int?) -> String {
    switch kind {
    case .thinking: L("Thinking")
    case .readingFile: L("Reading files")
    case .runningCommand: L("Running a command")
    case .callingTool: L("Calling a tool")
    case .editingFiles:
        if let detailCount, detailCount > 0 { LF("Editing %d files", detailCount) }
        else { L("Editing files") }
    case .waitingForUser: L("Waiting for you")
    case .responding: L("Generating a response")
    case .completed: L("Completed")
    case .failed: L("Failed")
    }
}

private func liveActivityIcon(_ kind: LiveActivityKind) -> String {
    switch kind {
    case .thinking: "brain.head.profile"
    case .readingFile: "doc.text.magnifyingglass"
    case .runningCommand: "terminal"
    case .callingTool: "wrench.and.screwdriver"
    case .editingFiles: "square.and.pencil"
    case .waitingForUser: "person.crop.circle.badge.questionmark"
    case .responding: "text.bubble"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
}

private func liveActivityColor(_ kind: LiveActivityKind) -> Color {
    switch kind {
    case .waitingForUser: .orange
    case .completed: .green
    case .failed: .red
    default: .cyan
    }
}

private func shortRoutingModel(_ model: String) -> String {
    model.replacingOccurrences(of: "gpt-5.6-", with: "")
}

private func routingPreflightReason(_ reasonCode: String) -> String {
    switch reasonCode {
    case "simple_task_on_expensive_route", "simple_translation":
        return L("A lower-cost configuration is sufficient for this bounded task.")
    case "frozen_mechanical_task_on_frontier_route":
        return L("The contract is frozen and the result can be mechanically verified.")
    case "frozen_judgment_dense_cross_module":
        return L("This frozen cross-module task has concrete repair risk on the lighter route.")
    case "architecture_requires_frontier":
        return L("Architecture or strategy work needs the frontier route.")
    case "authority_requires_frontier":
        return L("Authority-bearing or irreversible work needs the frontier route.")
    case "judgment_dense_requires_high_effort":
        return L("Cross-module judgment needs more reasoning effort.")
    default:
        return L("The recommended configuration matched this task with high confidence.")
    }
}

private func postflightTitle(_ assessment: RoutingPostflightAssessment) -> String {
    switch assessment.quality {
    case .passed: return L("Quality passed · route retained")
    case .failed: return L("Quality did not pass · review task contract")
    case .insufficientEvidence: return L("Task completed · quality not yet proven")
    }
}

private func postflightDetail(_ assessment: RoutingPostflightAssessment) -> String {
    switch assessment.action {
    case .keepRoute:
        return L("Quality passed first; Token and duration are now eligible for comparison.")
    case .requireVerification:
        return L("Completion alone is not success. Add tests or explicit acceptance before learning from it.")
    case .reviewTaskContract:
        return L("Review this task contract before retrying; no configuration is inferred for a future task.")
    }
}

private func activityTitle(_ activity: SessionActivity) -> String {
    switch activity {
    case .executing: L("Running")
    case .waiting: L("Recently active")
    case .interrupted: L("Interrupted")
    case .stopped: L("Stopped")
    }
}

private func localizedCalibrationLabel(_ policy: HealthPolicy) -> String {
    policy.isCalibrated
        ? LF("Personal baseline · %d samples", policy.effectiveSampleCount)
        : LF("Cold-start rules · %d/20", policy.effectiveSampleCount)
}

private func localizedConfidence(_ confidence: String) -> String {
    switch confidence {
    case "exact": L("Exact")
    case "inferred-from-last-call": L("Inferred from last call")
    case "lower-bound": L("Lower bound")
    case "interrupted-archived": L("Interrupted and archived")
    case "interrupted-stale-log": L("Interrupted with a stale log")
    default: confidence
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
