import SwiftUI

/// A sidebar tab title that wraps onto a second line instead of being cut
/// off. Claude Code names its tab after the session ("Fix the flaky checkout
/// test on Safari"), and at the default sidebar width one line showed only
/// the first two or three words of it, so every agent tab looked alike.
///
/// A title that fits on one line keeps today's one-line row, so a short
/// shell tab stays compact. A title that needs more than two lines ends in
/// an ellipsis, and only then does the row get a tooltip with the full title.
///
/// The wrap is plain `Text` layout, so it follows the sidebar's own font,
/// including the system "Sidebar icon size" setting, with no measuring of
/// glyphs here. The overflow check compares the two-line height with the
/// height the whole title would need at the same width, both read by
/// `onGeometryChange`.
struct WrappingTitle: View {
    private let text: String
    private let lineLimit: Int
    @State
    private var fittedHeight: CGFloat = 0
    @State
    private var fullHeight: CGFloat = 0

    /// - Parameter lineLimit: the most lines the title takes before it ends
    ///   in an ellipsis.
    init(_ text: String, lineLimit: Int = 2) {
        self.text = text
        self.lineLimit = lineLimit
    }

    private var isTruncated: Bool { fullHeight > fittedHeight + 0.5 }

    var body: some View {
        Text(text)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fittedHeight = $0 }
            .background(alignment: .topLeading) {
                // The whole title at the same width, never drawn: it only
                // says whether the visible copy had to cut anything.
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            }
            // A value change, not a conditional modifier: swapping view
            // types in a List row tears the row down (see
            // `SidebarProjectHeader`). An empty help string shows no tooltip.
            .help(isTruncated ? text : "")
    }
}
