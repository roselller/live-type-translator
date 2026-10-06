import AppKit
import SwiftUI

@MainActor
final class ActivityIndicator {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var generation = UUID()

    func begin(at point: NSPoint, waitingForModifiers: Bool = false) {
        dismissTask?.cancel()
        dismissTask = nil
        // A new attempt replaces a previous completion/error badge. Without
        // ordering out the old panel, rapid retries can leave duplicates onscreen.
        panel?.orderOut(nil)
        panel = nil
        generation = UUID()
        show(message: waitingForModifiers ? "Let go of the shortcut keys to start…" : "Reading your selection…",
             busy: true, near: point)
    }

    func capturing() { update("Reading your selection…") }
    func translating(contextFallback: Bool = false) {
        update(contextFallback
            ? "Long text is translating… please wait."
            : "Translating on this Mac… don't type, click, or switch apps.")
    }
    func inserting(contextFallback: Bool = false) {
        update(contextFallback ? "Adding translations · long-text fallback…" : "Adding translations…")
    }

    func finish(_ result: String) {
        update(result, busy: false)
        dismiss(after: .seconds(2.5))
    }

    func fail(_ text: String) {
        if panel == nil { show(message: text, busy: false, near: NSEvent.mouseLocation) }
        else { update(text, busy: false) }
        dismiss(after: .seconds(5))
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        generation = UUID()
        panel?.orderOut(nil)
        panel = nil
    }

    private func update(_ message: String, busy: Bool = true) {
        guard let panel, let host = panel.contentView as? NSHostingView<ActivityBadge> else { return }
        let root = ActivityBadge(message: message, busy: busy)
        host.rootView = root
        panel.setFrame(Self.frame(size: host.fittingSize, near: NSEvent.mouseLocation), display: true)
    }

    private func show(message: String, busy: Bool, near point: NSPoint) {
        let root = ActivityBadge(message: message, busy: busy)
        let host = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: Self.frame(size: host.fittingSize, near: point),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func dismiss(after duration: Duration) {
        let current = generation
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            self.dismissTask = nil
        }
    }

    private static func frame(size: NSSize, near point: NSPoint) -> NSRect {
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(max(size.width, 250), max(250, visible.width - 16))
        let height = min(max(size.height, 48), max(48, visible.height - 16))
        return NSRect(
            x: min(max(point.x + 18, visible.minX + 8), visible.maxX - width - 8),
            y: min(max(point.y - height - 20, visible.minY + 8), visible.maxY - height - 8),
            width: width, height: height)
    }
}

private struct ActivityBadge: View {
    let message: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: message.hasPrefix("Done") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(message.hasPrefix("Done") ? .green : .orange)
            }
            Text(message).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .frame(minWidth: 250, maxWidth: 390, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.primary.opacity(0.1)) }
        .padding(2)
    }
}
