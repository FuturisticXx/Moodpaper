import SwiftUI
import AppKit

struct WindowScreenObserver: NSViewRepresentable {
    @Binding var screen: NSScreen?

    func makeNSView(context: Context) -> ScreenTrackingView {
        let view = ScreenTrackingView()
        view.onScreenChange = { newScreen in
            DispatchQueue.main.async {
                screen = newScreen
            }
        }
        return view
    }

    func updateNSView(_ nsView: ScreenTrackingView, context: Context) {
        nsView.onScreenChange = { newScreen in
            DispatchQueue.main.async {
                screen = newScreen
            }
        }
        nsView.reportCurrentScreen()
    }
}

final class ScreenTrackingView: NSView {
    var onScreenChange: ((NSScreen?) -> Void)?
    // layout() fires many times per resize; de-dupe so we don't keep
    // re-dispatching the same screen across a single drag.
    private weak var lastReportedScreen: NSScreen?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportCurrentScreen()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportCurrentScreen()
    }

    override func layout() {
        super.layout()
        reportCurrentScreen()
    }

    func reportCurrentScreen() {
        let currentScreen = window?.screen
        guard currentScreen !== lastReportedScreen else { return }
        lastReportedScreen = currentScreen
        onScreenChange?(currentScreen)
    }
}
