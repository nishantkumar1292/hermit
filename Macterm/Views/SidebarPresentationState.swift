import Foundation
import Observation

enum SidebarItem: Hashable {
    case project(UUID)
    case tab(projectID: UUID, tabID: UUID)
}

enum SidebarRenameTarget: Equatable {
    case project(UUID)
    case tab(UUID)
}

/// The initial values to open inline rename for one sidebar row.
struct SidebarRenameSeed: Equatable {
    let target: SidebarRenameTarget
    let text: String
    var originalCustomTitle: String?
}

/// Transient UI state shared by every presentation of `SidebarContent`.
///
/// The native split-view sidebar remains mounted while the hover overlay shows
/// a second copy of the same content. Keeping this state on either view would
/// give the copies different selection state and two competing rename fields.
/// `MainWindow` tells each copy whether it is interactive; this shared state
/// makes them one logical sidebar without lifecycle arbitration. Which project
/// sections are open is not here: it is per window and persisted, so it lives
/// on `WindowState.expandedProjects`, which both copies read.
@MainActor @Observable
final class SidebarPresentationState {
    var selection: Set<SidebarItem> = []
    var scrollPosition: SidebarItem?
    var renameText = ""

    private(set) var renameTarget: SidebarRenameTarget?
    private(set) var originalCustomTitle: String?

    func beginRename(
        _ target: SidebarRenameTarget,
        text: String,
        originalCustomTitle: String? = nil
    ) {
        renameTarget = target
        renameText = text
        self.originalCustomTitle = originalCustomTitle
        // A rename opened by double-clicking an inactive row also switches to
        // it, and the pane that becomes focused asks for first responder on a
        // retry loop that can outlive this gesture. See the flag's own notes.
        FocusRestoration.isEditingInlineName = true
    }

    /// Starts inline rename for the single row reported by the sidebar list's
    /// `primaryAction` (double-click).
    ///
    /// Multi-selections and unresolved rows (such as unloaded pinned rows) are
    /// ignored. Triggering the row that already has an open rename field keeps
    /// the current draft intact.
    @discardableResult
    func beginPrimaryActionRename(
        for items: Set<SidebarItem>,
        resolve: (SidebarItem) -> SidebarRenameSeed?
    ) -> Bool {
        guard items.count == 1,
              let item = items.first,
              let seed = resolve(item),
              renameTarget != seed.target
        else { return false }
        beginRename(
            seed.target,
            text: seed.text,
            originalCustomTitle: seed.originalCustomTitle
        )
        return true
    }

    func isRenaming(_ target: SidebarRenameTarget) -> Bool {
        renameTarget == target
    }

    func completeRename(_ target: SidebarRenameTarget) -> (text: String, originalCustomTitle: String?)? {
        guard isRenaming(target) else { return nil }
        let result = (renameText, originalCustomTitle)
        clearRename()
        return result
    }

    func cancelRename(_ target: SidebarRenameTarget) -> Bool {
        guard isRenaming(target) else { return false }
        clearRename()
        return true
    }

    /// Drop any draft when a temporary overlay closes without being promoted.
    /// Promotion deliberately skips this so the native presentation can carry
    /// the same editor forward.
    func discardRename() {
        clearRename()
    }

    private func clearRename() {
        renameTarget = nil
        renameText = ""
        originalCustomTitle = nil
        FocusRestoration.isEditingInlineName = false
    }
}
