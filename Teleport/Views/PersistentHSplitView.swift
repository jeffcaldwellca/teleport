import AppKit
import SwiftUI

/// A horizontal two-pane split backed directly by `NSSplitView`.
///
/// `HSplitView` offers no control over the divider: it re-derives both widths
/// from its children's ideal sizes whenever their layout changes, so swapping a
/// placeholder pane for a live one visibly resizes both sides. Here the divider
/// belongs to `NSSplitView` — it moves only when the user drags it or the window
/// resizes — and `autosaveName` carries the position across launches.
///
/// Updates swap the hosted SwiftUI root views in place. The split items and
/// their hosting controllers are built once and never replaced, which is what
/// keeps the divider still.
///
/// The panes are hosted in their own `NSHostingController`s, so they start with
/// an empty SwiftUI environment — callers must pass in anything the panes read
/// from it (see `ContentView`).
struct PersistentHSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {

    /// Key under which `NSSplitView` persists the divider position.
    let autosaveName: String

    /// Narrowest either pane can be dragged.
    var minThickness: CGFloat = 280

    private let leading: Leading
    private let trailing: Trailing

    /// The panes are built here rather than stored as closures on purpose:
    /// evaluating them at the call site keeps the state they read (the active
    /// session, say) inside the caller's `body`, where SwiftUI's observation
    /// tracking can see it. Deferring them into `updateNSViewController` would
    /// read that state outside any tracked scope, and the panes would quietly
    /// stop updating.
    init(
        autosaveName: String,
        minThickness: CGFloat = 280,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.autosaveName = autosaveName
        self.minThickness = minThickness
        self.leading      = leading()
        self.trailing     = trailing()
    }

    /// Holds the hosting controllers so updates reach them through a typed
    /// reference. Fishing them back out of `splitViewItems` would mean an `as?`
    /// that fails silently — leaving both panes frozen at their first render.
    final class Coordinator {
        fileprivate var leadingHost:  NSHostingController<Filled<Leading>>?
        fileprivate var trailingHost: NSHostingController<Filled<Trailing>>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical   = true
        controller.splitView.dividerStyle = .thin
        // Set before the items are added — NSSplitView applies the saved
        // position as each subview arrives.
        controller.splitView.autosaveName = autosaveName

        let leadingHost  = makeHost(Filled(content: leading))
        let trailingHost = makeHost(Filled(content: trailing))
        context.coordinator.leadingHost  = leadingHost
        context.coordinator.trailingHost = trailingHost

        controller.addSplitViewItem(makeItem(for: leadingHost))
        controller.addSplitViewItem(makeItem(for: trailingHost))
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        // Only the root views change. Replacing the split items would hand
        // NSSplitView a fresh subview list and it would redistribute widths from
        // scratch — the resize this type exists to prevent.
        context.coordinator.leadingHost?.rootView  = Filled(content: leading)
        context.coordinator.trailingHost?.rootView = Filled(content: trailing)
    }

    /// Take the whole offer; how that width is shared is the divider's call.
    /// An unspecified proposal is asking for an ideal size — two panes at their
    /// minimum, and a height the parent will override in practice.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: NSSplitViewController,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: minThickness * 2, height: 400)
        )
    }

    private func makeHost<Content: View>(_ content: Content) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: content)
        // Without this the hosting controller publishes SwiftUI's ideal size as
        // an Auto Layout intrinsic size and fights the divider for the width.
        host.sizingOptions = []
        // `safeAreaRegions` is deliberately left at its default: these panes sit
        // under the window's toolbar and rely on the safe area to inset their
        // headers, exactly as they did as plain SwiftUI subviews.
        return host
    }

    private func makeItem(for host: NSViewController) -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: host)
        item.minimumThickness = minThickness
        item.canCollapse      = false
        return item
    }
}

/// Makes a pane fill its side of the split, and gives each hosting controller a
/// concrete generic type to be stored and updated under.
private struct Filled<Content: View>: View {
    let content: Content

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
