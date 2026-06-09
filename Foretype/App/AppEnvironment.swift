import Combine
import SwiftUI

/// The composition root. Constructs every long-lived service exactly once and
/// retains it for the process lifetime. Services are never recreated during a
/// session; a settings change reconfigures existing services rather than
/// rebuilding them.
///
/// UI surfaces observe the services held here; they never construct them.
@MainActor
final class AppEnvironment: ObservableObject {
    // Permission + settings sources of truth.
    let permissions: PermissionMonitor
    let settings: SettingsStore

    // Capability services.
    let focus: FocusWatcher
    let inputGuard: SyntheticInputGuard
    let keyboardTap: KeyboardTap
    let inserter: TextInserter
    let overlay: GhostTextOverlay

    // Engines + router.
    let openAIEngine: OpenAIEngine
    let appleIntelligenceEngine: AppleIntelligenceEngine
    let engineRouter: EngineRouter

    // The orchestrator and the on-demand window surfaces.
    let coordinator: CompletionCoordinator
    let windowManager: WindowManager

    private var cancellables = Set<AnyCancellable>()

    init() {
        let permissions = PermissionMonitor()
        let settings = SettingsStore()
        let focus = FocusWatcher(settings: settings)
        let inputGuard = SyntheticInputGuard()
        let keyboardTap = KeyboardTap(guard: inputGuard)
        let inserter = TextInserter(guard: inputGuard)
        let overlay = GhostTextOverlay(settings: settings)

        let openAIEngine = OpenAIEngine()
        let appleIntelligenceEngine = AppleIntelligenceEngine()
        let engineRouter = EngineRouter(openAI: openAIEngine, appleIntelligence: appleIntelligenceEngine)

        let coordinator = CompletionCoordinator(
            focus: focus,
            input: keyboardTap,
            permissions: permissions,
            settings: settings,
            engine: engineRouter,
            overlay: overlay,
            inserter: inserter
        )

        self.permissions = permissions
        self.settings = settings
        self.focus = focus
        self.inputGuard = inputGuard
        self.keyboardTap = keyboardTap
        self.inserter = inserter
        self.overlay = overlay
        self.openAIEngine = openAIEngine
        self.appleIntelligenceEngine = appleIntelligenceEngine
        self.engineRouter = engineRouter
        self.coordinator = coordinator
        self.windowManager = WindowManager(
            permissions: permissions,
            settings: settings,
            coordinator: coordinator
        )
    }

    /// Called from `applicationDidFinishLaunching`. Starts the permission poll,
    /// configures the router from current settings, starts the coordinator, and
    /// shows onboarding on first launch.
    func start() {
        permissions.start()

        let snapshot = settings.current
        let apiKey = settings.apiKey()
        Task {
            await engineRouter.updateSettings(snapshot, apiKey: apiKey)
        }

        coordinator.start()

        // Start the OS-facing input streams. The coordinator holds these behind
        // capability protocols that do not expose start(), so the composition
        // root owns their lifecycle. FocusWatcher self-guards on AX trust each
        // poll (returns nil snapshots until granted); KeyboardTap.start() is a
        // no-op without Input Monitoring and is (re)installed when the grant
        // flips below — so granting after launch needs no relaunch.
        focus.start()
        if permissions.inputMonitoringGranted {
            keyboardTap.start()
        }

        // React to permission changes via the @Published properties (Combine),
        // not permissions.changes — the coordinator is the single consumer of
        // that AsyncStream, and a second iterator would split its events.
        permissions.$inputMonitoringGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                guard let self else { return }
                if granted { self.keyboardTap.start() } else { self.keyboardTap.stop() }
            }
            .store(in: &cancellables)

        if !hasCompletedFirstRun {
            windowManager.showOnboarding()
            hasCompletedFirstRun = true
        }
    }

    // MARK: - First-run flag

    private var hasCompletedFirstRun: Bool {
        get { UserDefaults.standard.bool(forKey: Self.firstRunKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.firstRunKey) }
    }

    private static let firstRunKey = "com.foretype.hasCompletedFirstRun"
}
