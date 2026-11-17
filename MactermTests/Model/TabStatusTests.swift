import Foundation
@testable import Macterm
import Testing

@MainActor
struct TabStatusTests {
    // MARK: - Claude Code's notices

    @Test
    func a_permission_prompt_or_a_question_asks_for_an_answer() {
        // Claude Code sends the same body for both, about 6 s after it stops.
        #expect(ClaudeCodeNotice.asksForAnswer(body: "Claude needs your permission"))
        #expect(ClaudeCodeNotice.asksForAnswer(body: "Claude needs your permission to use Bash"))
        #expect(ClaudeCodeNotice.asksForAnswer(body: "  Claude needs your permission\n"))
    }

    @Test
    func the_idle_notice_and_other_text_do_not_ask() {
        // Sent 60 s after a turn that ended: the user can have seen it.
        #expect(!ClaudeCodeNotice.asksForAnswer(body: "Claude is waiting for your input"))
        #expect(!ClaudeCodeNotice.asksForAnswer(body: ""))
        #expect(!ClaudeCodeNotice.asksForAnswer(body: "Build finished"))
        #expect(!ClaudeCodeNotice.asksForAnswer(body: "Note: Claude needs your permission"))
    }

    // MARK: - Ranking

    @Test
    func the_ranks_are_needs_you_running_failed_done_idle() {
        #expect(TabStatus.allCases.sorted(by: >) == [.needsYou, .running, .failed, .done, .idle])
    }

    private enum Seed {
        case idle
        case done
        case failed
        case running
        case needsYou
    }

    /// A pane in the given state, set through the pane's own paths.
    private func pane(_ seed: Seed) -> Pane {
        let p = Pane(projectPath: "/", projectID: UUID())
        switch seed {
        case .idle:
            break
        case .done:
            p.restoreNeedsAttention()
        case .failed:
            p.restoreNeedsAttention(failed: true)
        case .running:
            p.recordUserInteraction()
            p.markCommandRunning()
        case .needsYou:
            p.applyForegroundRefresh(name: "claude", foregroundPID: 4242)
            p.noteDesktopNotification(body: ClaudeCodeNotice.answerRequestPrefix)
        }
        return p
    }

    /// A tab of two panes side by side.
    private func split(_ first: Seed, _ second: Seed) -> TerminalTab {
        let a = pane(first)
        let b = pane(second)
        let root = SplitNode.split(SplitBranch(direction: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b)))
        return TerminalTab(id: UUID(), splitRoot: root, focusedPaneID: a.id)
    }

    @Test
    func each_pane_state_maps_to_its_status() {
        #expect(TabStatus(pane: pane(.idle)) == .idle)
        #expect(TabStatus(pane: pane(.done)) == .done)
        #expect(TabStatus(pane: pane(.failed)) == .failed)
        #expect(TabStatus(pane: pane(.running)) == .running)
        #expect(TabStatus(pane: pane(.needsYou)) == .needsYou)
    }

    /// The highest pane wins, whichever pane has the focus.
    @Test
    func a_split_shows_its_highest_pane() {
        #expect(split(.running, .needsYou).status == .needsYou)
        #expect(split(.needsYou, .running).status == .needsYou)
        #expect(split(.failed, .running).status == .running)
        #expect(split(.done, .failed).status == .failed)
        #expect(split(.idle, .done).status == .done)
        #expect(split(.idle, .idle).status == .idle)
    }

    /// The flag outranks a pane's own done state too: Claude's progress ends
    /// (the tab looks finished), then the question comes about 6 s later.
    @Test
    func needs_you_replaces_done_in_the_same_pane() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "claude", foregroundPID: 4242)
        p.restoreNeedsAttention()
        #expect(TabStatus(pane: p) == .done)
        p.noteDesktopNotification(body: ClaudeCodeNotice.answerRequestPrefix)
        #expect(TabStatus(pane: p) == .needsYou)
        #expect(p.executionState == .done)
    }

    // MARK: - Roll-up of a collapsed project

    @Test
    func an_idle_project_rolls_up_to_nothing() {
        #expect(TabStatus.rollUp([]) == nil)
        #expect(TabStatus.rollUp([.idle, .idle]) == nil)
    }

    @Test
    func the_roll_up_counts_the_tabs_that_share_the_top_status() {
        #expect(TabStatus.rollUp([.running, .done, .running]) == .init(status: .running, count: 2))
        #expect(TabStatus.rollUp([.done, .needsYou, .running, .running]) == .init(status: .needsYou, count: 1))
        #expect(TabStatus.rollUp([.done, .idle, .failed, .done]) == .init(status: .failed, count: 1))
        #expect(TabStatus.rollUp([.done, .idle, .done]) == .init(status: .done, count: 2))
    }
}
