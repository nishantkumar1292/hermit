import Foundation
@testable import Macterm
import Testing

@MainActor
struct SidebarPresentationStateTests {
    @Test
    func completing_rename_returns_one_shared_draft_and_clears_it() {
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft", originalCustomTitle: "old")
        state.renameText = "final"

        let result = state.completeRename(.tab(tabID))
        #expect(result?.text == "final")
        #expect(result?.originalCustomTitle == "old")
        #expect(state.renameTarget == nil)
    }

    @Test
    func unrelated_row_cannot_consume_the_shared_rename_draft() {
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")

        #expect(state.completeRename(.project(UUID())) == nil)
        #expect(state.isRenaming(.tab(tabID)))
        #expect(state.renameText == "draft")
    }

    @Test
    func ordinary_overlay_dismissal_discards_the_rename_draft() {
        let state = SidebarPresentationState()
        state.beginRename(.tab(UUID()), text: "draft")

        state.discardRename()

        #expect(state.renameTarget == nil)
        #expect(state.renameText.isEmpty)
    }

    @Test
    func selection_lives_on_the_shared_state() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()

        state.selection = [.tab(projectID: projectID, tabID: tabID)]
        state.scrollPosition = .tab(projectID: projectID, tabID: tabID)

        #expect(state.selection == [.tab(projectID: projectID, tabID: tabID)])
        #expect(state.scrollPosition == .tab(projectID: projectID, tabID: tabID))
    }

    @Test
    func primary_action_opens_inline_rename_for_a_single_tab() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()

        let started = state.beginPrimaryActionRename(for: [.tab(projectID: projectID, tabID: tabID)]) { _ in
            SidebarRenameSeed(target: .tab(tabID), text: "API", originalCustomTitle: "API")
        }

        #expect(started)
        #expect(state.isRenaming(.tab(tabID)))
        #expect(state.renameText == "API")
        #expect(state.originalCustomTitle == "API")
    }

    @Test
    func primary_action_opens_inline_rename_for_a_single_project() {
        let state = SidebarPresentationState()
        let projectID = UUID()

        let started = state.beginPrimaryActionRename(for: [.project(projectID)]) { _ in
            SidebarRenameSeed(target: .project(projectID), text: "Hermit")
        }

        #expect(started)
        #expect(state.isRenaming(.project(projectID)))
        #expect(state.renameText == "Hermit")
        #expect(state.originalCustomTitle == nil)
    }

    @Test
    func primary_action_ignores_multi_selection_and_empty_selection() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let first = SidebarItem.tab(projectID: projectID, tabID: UUID())
        let second = SidebarItem.tab(projectID: projectID, tabID: UUID())

        #expect(!state.beginPrimaryActionRename(for: []) { _ in
            SidebarRenameSeed(target: .project(projectID), text: "Hermit")
        })
        #expect(!state.beginPrimaryActionRename(for: [first, second]) { _ in
            SidebarRenameSeed(target: .project(projectID), text: "Hermit")
        })
        #expect(state.renameTarget == nil)
    }

    @Test
    func primary_action_ignores_an_unresolved_row() {
        let state = SidebarPresentationState()
        let item = SidebarItem.tab(projectID: PinnedTabs.projectID, tabID: UUID())

        let started = state.beginPrimaryActionRename(for: [item]) { _ in nil }

        #expect(!started)
        #expect(state.renameTarget == nil)
    }

    @Test
    func primary_action_on_the_already_renaming_row_keeps_the_draft() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()
        state.beginRename(.tab(tabID), text: "old", originalCustomTitle: "old")
        state.renameText = "in progress"

        let started = state.beginPrimaryActionRename(for: [.tab(projectID: projectID, tabID: tabID)]) { _ in
            SidebarRenameSeed(target: .tab(tabID), text: "old", originalCustomTitle: "old")
        }

        #expect(!started)
        #expect(state.renameText == "in progress")
    }

    @Test
    func primary_action_on_another_row_switches_the_rename_target() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let firstTab = UUID()
        let secondTab = UUID()
        state.beginRename(.tab(firstTab), text: "first")

        let started = state.beginPrimaryActionRename(for: [.tab(projectID: projectID, tabID: secondTab)]) { _ in
            SidebarRenameSeed(target: .tab(secondTab), text: "", originalCustomTitle: nil)
        }

        #expect(started)
        #expect(state.isRenaming(.tab(secondTab)))
        #expect(state.renameText.isEmpty)
    }

    /// The flag is one process-wide value (it gates a global retry loop), so
    /// these two set it from a known state and hand it back — a sibling test
    /// that leaves a rename open must not decide whether they pass.
    @Test
    func an_open_rename_holds_focus_restoration_off_until_it_ends() {
        FocusRestoration.isEditingInlineName = false
        defer { FocusRestoration.isEditingInlineName = false }
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")
        #expect(FocusRestoration.isEditingInlineName)

        _ = state.completeRename(.tab(tabID))
        #expect(!FocusRestoration.isEditingInlineName)
    }

    @Test
    func cancelling_a_rename_also_releases_focus_restoration() {
        FocusRestoration.isEditingInlineName = false
        defer { FocusRestoration.isEditingInlineName = false }
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")
        #expect(state.cancelRename(.tab(tabID)))

        #expect(!FocusRestoration.isEditingInlineName)
    }
}
