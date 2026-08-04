import SwiftUI
import SwiftData

@main
struct ParrotMain {
    /// Entry point. `--snapshot <path>` renders the report offscreen to a PNG for
    /// design verification (see SnapshotTool.swift); otherwise the normal app runs.
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { ReportSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--copilot-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { CopilotSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--sidebar-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { SidebarSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--help-shots"), i + 1 < args.count {
            MainActor.assumeIsolated { HelpShots.run(outputDir: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--liveloop-test"), i + 1 < args.count {
            let model = (i + 2 < args.count) ? args[i + 2] : ""
            LiveLoopTest.run(audioPath: args[i + 1], model: model)
            return
        }
        if let i = args.firstIndex(of: "--transcribe-test"), i + 1 < args.count {
            let modelFolder = (i + 2 < args.count) ? args[i + 2] : ""
            TranscribeTest.run(audioPath: args[i + 1], modelFolder: modelFolder)
            return
        }
        if args.contains("--profile-test") {
            MainActor.assumeIsolated { ProfileTest.run() }
            return
        }
        if let i = args.firstIndex(of: "--analyze-test") {
            let provider = (i + 1 < args.count) ? args[i + 1] : nil
            let model = (i + 2 < args.count) ? args[i + 2] : nil
            AnalyzeTest.run(provider: provider, model: model)
            return
        }
        ParrotApp.main()
    }
}

/// Menu-bar-first Dock behavior: LSUIElement launches the app as an accessory
/// (no Dock icon, no window); the icon appears only while the main window is
/// open — opened explicitly from the menu bar or a Finder/Spotlight reopen —
/// and goes away again when that window closes. Recording, auto-record, and
/// the menu bar item keep running throughout.
@MainActor
enum DockVisibility {
    /// Set when the user explicitly opens the window this launch; the
    /// launch-restored window is closed unless this (or onboarding) says so.
    static var userOpenedWindow = false

    static func openMain(using open: (() -> Void)?) {
        userOpenedWindow = true
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()   // window was closed — have SwiftUI recreate it
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called (async, post-close) when a main window closed: back to
    /// menu-bar-only once none are left.
    static func mainWindowGone(excluding closing: NSWindow?) {
        let stillOpen = NSApp.windows.contains {
            $0 !== closing && $0.isVisible
                && $0.identifier?.rawValue.hasPrefix("main") == true
        }
        guard !stillOpen else { return }
        userOpenedWindow = false
        NSApp.setActivationPolicy(.accessory)
    }

    /// Close the window SwiftUI restores at launch — menu-bar-first means
    /// starting with no window at all.
    static func suppressLaunchWindow() {
        mainWindow()?.close()
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }
}

/// Cmd-Q mid-recording used to kill capture mid-flight: the .caf headers never
/// finalized and the meeting stayed `.recording`, feeding the #18 relaunch
/// crash-loop. Quit now runs the same stop path as the Stop button, then
/// terminates. The post-stop report chain is deliberately not awaited — the
/// meeting exits as `.processing` and launch recovery finishes it by design.
@MainActor
final class ParrotAppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingManager: RecordingManager?
    /// Recreates the main window via SwiftUI's openWindow — assigned once the
    /// scene is up; used when the window to reopen no longer exists.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Watch main-window closes so the Dock icon retracts. willClose fires
        // before the window is gone, hence the async hop + explicit exclusion.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let closing = note.object as? NSWindow,
                  closing.identifier?.rawValue.hasPrefix("main") == true else { return }
            DispatchQueue.main.async {
                DockVisibility.mainWindowGone(excluding: closing)
            }
        }
    }

    /// Finder/Spotlight "open" while already running as an accessory: bring
    /// the window (back) up like the menu bar item does.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            DockVisibility.openMain(using: openMainWindow)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = recordingManager, manager.isRecording || manager.isStopping else {
            return .terminateNow
        }
        Task { @MainActor in
            await manager.stopRecording()      // no-op if a stop is already draining…
            while manager.isStopping {         // …so wait that one out instead
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ParrotApp: App {
    @NSApplicationDelegateAdaptor(ParrotAppDelegate.self) private var appDelegate
    @State private var recordingManager = RecordingManager()
    @State private var appSession = AppSession()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    /// Same key/enum as SettingsView's Appearance picker.
    @AppStorage("appearance") private var appearance = Appearance.system
    @Environment(\.openWindow) private var openWindow

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .environment(appSession)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environment(recordingManager)
                        .interactiveDismissDisabled()
                }
                .onAppear {
                    applyAppearance()
                    appDelegate.recordingManager = recordingManager
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                    if showOnboarding {
                        // Fresh install: behave like a normal app for the
                        // permissions walkthrough.
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    } else if !DockVisibility.userOpenedWindow {
                        // Menu-bar-first: drop the window SwiftUI restores at
                        // launch. Async — the NSWindow registers just after
                        // onAppear.
                        DispatchQueue.main.async { DockVisibility.suppressLaunchWindow() }
                    }
                }
                .onChange(of: appearance) { applyAppearance() }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)
        .commands {
            ParrotCommands(
                session: appSession,
                recordingManager: recordingManager,
                modelContext: sharedModelContainer.mainContext
            )
        }

        // A real menu, not a floating panel: instant, keyboard-navigable, native.
        MenuBarExtra {
            MenuBarView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .modelContainer(sharedModelContainer)
        } label: {
            Image(systemName: recordingManager.isRecording ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
        }
        .modelContainer(sharedModelContainer)
    }

    /// Applies the Settings → Appearance choice app-wide (titlebar included).
    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
