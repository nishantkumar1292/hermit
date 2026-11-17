import AppKit
import SwiftUI

// MARK: - Tab glyph

/// The single decision about what glyph leads a tab, shared by the sidebar
/// row and the tab switcher's cards (#344) so the two can never disagree about
/// the user's preferences.
///
/// It draws identity only: the chosen tab icon (`tabIconSymbol`, which the
/// sidebar may override per row), or a live AI agent's logo in its place
/// (`showAgentIcons`). Status never changes it. The state of a tab is in its
/// status column at the trailing end (`TabStatusAccessory`), so a row of
/// Claude sessions keeps one logo per row and the column says which one
/// works, which one waits and which one stopped. Reading the preferences in
/// one view is what keeps a second surface from quietly re-deriving them and
/// drifting: the switcher's first cut hardcoded a terminal symbol, honouring
/// none of them.
///
/// `Preferences.noIcon` means the user asked for no icon, so nothing is drawn
/// unless an agent logo is live. In that case it resolves to no view at all
/// rather than an invisible one, which both callers depend on for layout: the
/// sidebar must not let an empty image hold the Label's icon column, and the
/// switcher's title has to start flush with its preview instead of behind a
/// reserved gap.
struct TabGlyph: View {
    let tab: TerminalTab
    /// 1-based row number, for the numbered icon variants.
    let index: Int
    /// Per-row override of the icon preference (pinned rows carry their own).
    var symbolOverride: String?
    /// Color for the symbol, and for an agent logo in place of its brand
    /// color. nil keeps the hierarchical `.secondary` these glyphs have
    /// always used — which is NOT the same as passing `Color.secondary`,
    /// since the hierarchical style resolves against a selected sidebar row's
    /// own foreground (see `SidebarTabRow.iconStyle`). The sidebar passes the
    /// project's tag color; the switcher passes its selected/unselected color.
    var tint: Color?

    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol: String
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons: Bool

    private var symbol: String { symbolOverride ?? tabIconSymbol }
    private var agent: AgentIcon? { showAgentIcons ? tab.agentIcon : nil }

    private var iconStyle: AnyShapeStyle {
        tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    var body: some View {
        // "None" suppresses the user's icon, not the agent logo: the logo
        // says which agent runs, so it survives the preference.
        if symbol != Preferences.noIcon || agent != nil {
            TabRowIcon(symbol: symbol, index: index, agent: agent, agentTint: tint)
                .foregroundStyle(iconStyle)
        }
    }
}

// MARK: - Tab status

extension TabStatus {
    /// The tooltip and VoiceOver label of the status. Nil for an idle tab,
    /// whose slot is empty and says nothing.
    var label: String? {
        switch self {
        case .needsYou:
            String(
                localized: "Needs You",
                comment: "Tooltip and VoiceOver label of a tab whose AI agent waits for an answer. A state, not a button"
            )
        case .running:
            String(localized: "Running")
        case .failed:
            String(localized: "Failed", comment: "Tooltip of a tab whose command failed")
        case .done:
            String(
                localized: "tab.status.done",
                defaultValue: "Done",
                comment: "Tooltip of a tab whose command finished. A state, not a button"
            )
        case .idle:
            nil
        }
    }
}

/// The status glyph of a tab (`TabStatus`), one shape for each state, so no
/// state depends on color alone:
///
/// - Needs You: `questionmark.bubble.fill` in `MactermTheme.warning`. It
///   bounces one time when it arrives, and not under Reduce Motion.
/// - Running: AppKit's own spinner (`StatusSpinner`).
/// - Failed: `xmark.circle.fill` in `MactermTheme.failure`.
/// - Done (the run ended while the user did not look): a dot in
///   `MactermTheme.success`.
/// - Idle: nothing.
///
/// The sidebar draws it in the trailing slot of a tab row and in the roll-up
/// of a collapsed project; the tab switcher draws it at the end of a card's
/// title row.
///
/// Every glyph stays mounted and the status only changes opacities. In a
/// `List` row, a branch that swaps the view tree tears the row down (see
/// `SidebarProjectHeader`), and a spinner that came and went would start
/// again from zero. On a selected row with the accent background, every
/// glyph draws white (`backgroundProminence == .increased`), as the unread
/// dot of Mail does.
///
/// It takes no hits: a click, a drag or a right-click on the slot is the
/// row's. Its tooltip is therefore on the row (`TabStatusColumn`).
struct TabStatusAccessory: View {
    let status: TabStatus

    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSize: SidebarIconSize
    /// The symbols' point size at the medium icon size. A metric, so the
    /// glyphs keep tracking the user's text size as the row's icons do.
    @ScaledMetric(relativeTo: .body)
    private var symbolPoints: CGFloat = 12
    @Environment(\.backgroundProminence)
    private var backgroundProminence
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    /// Counts the arrivals of Needs You. The bounce follows this value and
    /// not `status`, because a symbol effect plays on every change of its
    /// value: the departure of Needs You must not bounce the bubble again.
    @State
    private var needsYouArrivals = 0

    private var isOnAccent: Bool { backgroundProminence == .increased }

    private func color(_ color: Color) -> Color {
        isOnAccent ? .white : color
    }

    var body: some View {
        let scale = iconSize.glyphScale
        ZStack {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: symbolPoints * scale))
                .foregroundStyle(color(MactermTheme.warning))
                .symbolEffect(.bounce, value: needsYouArrivals)
                .opacity(status == .needsYou ? 1 : 0)
            StatusSpinner(
                isSpinning: status == .running,
                controlSize: iconSize.statusSpinnerControlSize,
                isOnAccent: isOnAccent
            )
            .frame(width: iconSize.statusSpinnerSide, height: iconSize.statusSpinnerSide)
            .opacity(status == .running ? 1 : 0)
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: symbolPoints * scale))
                .foregroundStyle(color(MactermTheme.failure))
                .opacity(status == .failed ? 1 : 0)
            Circle()
                .fill(color(MactermTheme.success))
                .frame(width: 7 * scale, height: 7 * scale)
                .opacity(status == .done ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.15), value: status)
        .onChange(of: status) { old, new in
            if new == .needsYou, old != .needsYou, !reduceMotion { needsYouArrivals += 1 }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label ?? "")
        .accessibilityHidden(status == .idle)
    }
}

extension SidebarIconSize {
    /// The spinner is a control, so it steps between AppKit's control sizes
    /// rather than scaling with the icons. `.mini` (10 pt) sits beside the
    /// 12 pt symbols of the small and medium sizes; `.small` (16 pt) beside
    /// the large ones. `.regular` is 32 pt, far past every icon size.
    var statusSpinnerControlSize: NSControl.ControlSize {
        self == .large ? .small : .mini
    }

    /// The side of the spinner at `statusSpinnerControlSize`, measured with
    /// `sizeToFit()`.
    var statusSpinnerSide: CGFloat {
        self == .large ? 16 : 10
    }
}

/// The Running glyph: AppKit's own spinning `NSProgressIndicator`, started and
/// stopped by `isSpinning`. Not a SwiftUI `ProgressView`: every row keeps its
/// spinner mounted at opacity 0, and an `NSProgressIndicator` that is stopped
/// draws nothing and costs nothing (`isDisplayedWhenStopped = false`). N
/// running rows are N AppKit spinners; no SwiftUI body runs for each frame.
///
/// An `NSProgressIndicator` has no tint. A project's tag color does not reach
/// it, and on a selected row with the accent background it takes the dark
/// appearance (`isOnAccent`), which draws it light. It is never redrawn by
/// hand.
struct StatusSpinner: NSViewRepresentable {
    let isSpinning: Bool
    let controlSize: NSControl.ControlSize
    let isOnAccent: Bool

    func makeNSView(context _: Context) -> StatusSpinnerView {
        let view = StatusSpinnerView()
        view.style = .spinning
        view.isIndeterminate = true
        view.isDisplayedWhenStopped = false
        // The accessory gives one label for the whole slot.
        view.setAccessibilityElement(false)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: StatusSpinnerView, context _: Context) {
        apply(to: view)
    }

    private func apply(to view: StatusSpinnerView) {
        if view.controlSize != controlSize { view.controlSize = controlSize }
        let appearance = isOnAccent ? NSAppearance(named: .darkAqua) : nil
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        view.isSpinning = isSpinning
    }
}

/// The view of `StatusSpinner`.
final class StatusSpinnerView: NSProgressIndicator {
    /// Whether the spinner turns. It turns only while it is in a window.
    var isSpinning = false {
        didSet {
            if isSpinning != oldValue { applySpinning() }
        }
    }

    /// Never the target of a click, a drag or a right-click: those belong to
    /// the sidebar row under it. SwiftUI's `allowsHitTesting(false)` does not
    /// reach an AppKit view, which AppKit hit-tests itself.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// The outline view reuses row views: a row that scrolls away or folds
    /// into its project leaves the window and comes back with no SwiftUI
    /// update, so the spinner starts again here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySpinning()
    }

    private func applySpinning() {
        if isSpinning, window != nil {
            startAnimation(nil)
        } else {
            stopAnimation(nil)
        }
    }
}

extension AgentIcon {
    /// The agent's brand tint. These are vendor identity colors, not theme
    /// colors, so they're the one deliberate exception to "all colors come
    /// from MactermTheme". Monochrome brands (Cursor, Grok, opencode) use
    /// `.primary` so they stay black-on-light / white-on-dark like the brand.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // Anthropic coral
        case .codex: Color(red: 0xAB / 255, green: 0xAB / 255, blue: 0xAB / 255) // OpenAI light gray
        case .gemini: Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255) // Google blue
        case .copilot: Color(red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255) // GitHub purple
        case .antigravity: Color(red: 0x31 / 255, green: 0x86 / 255, blue: 0xFF / 255) // Google Antigravity blue
        case .omp: Color(red: 0x93 / 255, green: 0x62 / 255, blue: 0xF4 / 255) // omp violet
        case .opencode,
             .cursor,
             .grok,
             .pi: .primary
        }
    }
}

struct TabRowIcon: View {
    let symbol: String
    let index: Int
    var agent: AgentIcon?
    /// The project tag's color, which outranks the agent's brand color: a
    /// tagged project claims every icon in its rows, so the logo's SHAPE says
    /// which agent and the color says which project. Coral sitting among a
    /// red project's icons read as a mistake rather than as a brand. Nil
    /// (untagged) keeps the brand color.
    var agentTint: Color?
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSize: SidebarIconSize
    /// Scales with the user's text size like the sibling SF Symbols do; a
    /// fixed 15pt would stay small next to enlarged row text.
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    private var size: SidebarIconSize {
        iconSize
    }

    var body: some View {
        if let agent {
            // A live AI agent in the tab overrides the user's chosen icon —
            // the logo is a status signal, tinted with the agent's brand color
            // (overriding the row's .secondary tint) unless the project's own
            // tag claims it.
            let side = agentIconSize * size.glyphScale
            Image(agent.rawValue)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .foregroundStyle(agentTint ?? agent.brandColor)
        } else if Preferences.numberIconChoices.contains(symbol) {
            NumberGlyph(index: index, variant: symbol, size: size)
        } else {
            Image(systemName: symbol)
                .imageScale(size.imageScale)
        }
    }
}

extension SidebarIconSize {
    /// SwiftUI's own symbol scaling, which sizes a symbol against whatever font
    /// the row hands it. `medium` is the default, so the middle case leaves an
    /// icon exactly the size it was before this preference existed rather than
    /// pinning it to a point size of our own.
    var imageScale: Image.Scale {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

private struct NumberGlyph: View {
    let index: Int
    let variant: String
    var size: SidebarIconSize = .medium
    /// The `.body` point size, as a metric so the digits keep tracking the
    /// user's text size once `glyphScale` has been applied — `imageScale` is
    /// no help here, since these variants draw text rather than a symbol.
    @ScaledMetric(relativeTo: .body)
    private var bodyFontSize: CGFloat = 13

    private var digitFont: Font {
        .system(size: bodyFontSize * size.glyphScale).monospacedDigit()
    }

    var body: some View {
        if variant == Preferences.numberIconPlain {
            Text(verbatim: "\(index)")
                .font(digitFont)
        } else if let suffix = shapeSuffix, (1 ... 50).contains(index) {
            // SF Symbols ships `1.<shape>` through `50.<shape>`; beyond that,
            // fall back to plain digits so we don't render a missing glyph.
            Image(systemName: "\(index).\(suffix)")
                .imageScale(size.imageScale)
        } else {
            Text(verbatim: "\(index)")
                .font(digitFont)
        }
    }

    /// Maps the sentinel token (e.g. `number.circle.fill`) to the suffix used
    /// by the indexed SF Symbol (e.g. `circle.fill` in `1.circle.fill`).
    private var shapeSuffix: String? {
        switch variant {
        case Preferences.numberIconCircleFill: "circle.fill"
        case Preferences.numberIconCircle: "circle"
        case Preferences.numberIconSquareFill: "square.fill"
        case Preferences.numberIconSquare: "square"
        default: nil
        }
    }
}
