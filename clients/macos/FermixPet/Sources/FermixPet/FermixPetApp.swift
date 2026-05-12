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
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
