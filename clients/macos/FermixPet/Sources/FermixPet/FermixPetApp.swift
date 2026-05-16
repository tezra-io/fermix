import SwiftUI

@main
struct FermixPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = CompanionState()

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
        NSApp.setActivationPolicy(.regular)
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
