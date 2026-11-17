import Foundation

/// What the status column of a tab shows (`TabStatusAccessory`): the trailing
/// slot of its sidebar row, the end of its tab switcher card, and the roll-up
/// of a collapsed project. It is a display value over the panes of the tab,
/// not a state of the tracker: `TerminalExecutionState` keeps its three cases,
/// and the CLI's `state` stays what the tracker says.
///
/// The cases are in rank order, lowest first, so `max()` gives the state that
/// a tab shows. Needs You is above Running because only it waits for the user.
/// Failed is above Done, so a split where one pane failed and one passed shows
/// the failure.
enum TabStatus: Int, CaseIterable, Comparable {
    /// Nothing new. The slot is empty.
    case idle
    /// A run ended while the user did not look (`TerminalExecutionState.done`).
    case done
    /// A run ended with an OSC 9;4 ERROR (`Pane.completionFailed`).
    case failed
    /// A run is in progress (`TerminalExecutionState.running`).
    case running
    /// Claude Code waits for an answer (`Pane.awaitingInput`).
    case needsYou

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The status of one pane. The flag of an open question wins over every
    /// state of the tracker, because the flag is independent of it.
    @MainActor
    init(pane: Pane) {
        if pane.awaitingInput {
            self = .needsYou
            return
        }
        switch pane.executionState {
        case .running: self = .running
        case .done: self = pane.completionFailed ? .failed : .done
        case .idle: self = .idle
        }
    }

    /// The highest status in `statuses` and the number of items that have it.
    /// A collapsed project header shows it for its hidden tabs, with the count
    /// when two or more tabs share the status. Nil when every item is idle.
    static func rollUp(_ statuses: some Sequence<TabStatus>) -> RollUp? {
        var top = TabStatus.idle
        var count = 0
        for status in statuses {
            if status > top {
                top = status
                count = 1
            } else if status == top {
                count += 1
            }
        }
        return top == .idle ? nil : RollUp(status: top, count: count)
    }

    /// See `rollUp(_:)`.
    struct RollUp: Equatable {
        let status: TabStatus
        let count: Int
    }
}

/// The desktop notifications (OSC 777) that Claude Code sends, read for the
/// one fact that the sidebar shows: Claude waits for an answer.
///
/// Measured on Claude Code 2.1.326 under a pty. A permission prompt and an
/// AskUserQuestion send the same body, about 6 s after Claude stops (its
/// OSC 9;4 progress goes at once). A turn that ends normally sends nothing.
/// After 60 s with no input, Claude sends `Claude is waiting for your input`.
/// That notice does not count: it follows a turn that ended, and the user can
/// have seen it already. The notification has no type field, only a title and
/// a body, so the body text is the only signal.
enum ClaudeCodeNotice {
    /// The start of the body that a permission prompt and a question send.
    static let answerRequestPrefix = "Claude needs your permission"

    /// Whether a notification body says that Claude waits for an answer.
    static func asksForAnswer(body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(answerRequestPrefix)
    }
}
