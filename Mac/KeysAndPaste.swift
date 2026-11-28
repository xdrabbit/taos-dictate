import AppKit
import SwiftUI

/// Watches the Right Option key from any app (needs Accessibility).
/// Right Option alone is the talk key; any other key while it's down cancels,
/// so ⌥-shortcuts and accented letters still work.
final class HotkeyMonitor {
    /// Right Option. NX_DEVICERALTKEYMASK tells it apart from Left Option.
    private static let keyCode: UInt16 = 61
    private static let rightOptionMask: UInt = 0x40

    private var monitors: [Any] = []
    private var isDown = false

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let flags: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.keyCode == Self.keyCode else { return }
            let down = e.modifierFlags.rawValue & Self.rightOptionMask != 0
            guard down != self.isDown else { return }
            self.isDown = down
            DispatchQueue.main.async { down ? onDown() : onUp() }
        }
        let key: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isDown else { return }
            DispatchQueue.main.async { onCancel() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(m) }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }
}

/// Types text where the cursor is: put it on the clipboard, press ⌘V, then put
/// the old clipboard back. Returns false (text left on the clipboard) without
/// Accessibility permission.
enum Inserter {
    @MainActor
    static func insert(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return false }
        let ours = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // "V"
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the app time to read the clipboard, then restore what was there
        // (unless something else has written to it since).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours, !saved.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
        return true
    }
}

/// A small pill at the bottom of the screen while listening / writing.
@MainActor
final class HUD {
    enum Look { case listening, working }
    static let shared = HUD()
    private var panel: NSPanel?

    func show(_ look: Look) {
        let view = NSHostingView(rootView: HUDPill(look: look))
        let size = NSSize(width: 170, height: 40)
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        panel.contentView = view
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 60))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }
}

private struct HUDPill: View {
    let look: HUD.Look
    var body: some View {
        HStack(spacing: 8) {
            if look == .listening {
                Circle().fill(.red).frame(width: 10, height: 10)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(L(look == .listening ? "mac.hud_listening" : "speak.working"))
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(width: 170, height: 40)
        .background(.regularMaterial, in: Capsule())
    }
}
