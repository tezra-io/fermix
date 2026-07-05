import SwiftUI

@main
struct FermixPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = CompanionState()

    init() {
        // Preload mascot PNGs before SwiftUI builds the first view body.
        // App.init runs on the main actor before any view is evaluated,
        // so the cache is hot by the time MascotImage queries it.
        PetAssetCache.shared.preload()
    }

    var body: some Scene {
        WindowGroup {
            PetView()
                .environmentObject(state)
                .frame(width: 180, height: 168)
                .background(Color.clear)
                .background(WindowConfigurator())
                .onAppear { appDelegate.companionState = state }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var companionState: CompanionState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        NSApp.setActivationPolicy(.regular)
        observeWindowOcclusion()
    }

    // Pause the pet's animation timeline whenever the window isn't actually
    // on-screen (other Space, minimized, fully covered). object: nil is safe
    // here — FermixPet has a single window.
    private func observeWindowOcclusion() {
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.companionState?.setWindowVisible(window.occlusionState.contains(.visible))
            }
        }
    }

    private func installApplicationIcon() {
        guard
            let url = Bundle.module.url(forResource: "FermixPetIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: url)
        else {
            assertionFailure("Missing FermixPetIcon.png resource")
            return
        }

        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    // willTerminate is delivered synchronously and gives us a guaranteed
    // window to tear down voice processing before the process exits. The
    // willTerminateNotification observer in CompanionState may not run in
    // time on every macOS version; this is the belt to its braces.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            companionState?.shutdown()
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.styleMask = [.borderless, .fullSizeContentView]

            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView?.superview?.wantsLayer = true
            window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
