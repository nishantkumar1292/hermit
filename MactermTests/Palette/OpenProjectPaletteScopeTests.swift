import Foundation
@testable import Macterm
import Testing

/// The palette's Open Project screen: its rows over the candidates, the
/// folded row of a folder already in the sidebar, path mode, Browse in
/// Finder…, ⇥, and the routing of ⌘O and Escape.
@MainActor
struct OpenProjectPaletteScopeTests {
    private struct Fixture {
        let home: String
        let state: AppState
        let store: ProjectStore
        let window: WindowState
        var context: PaletteContext { PaletteContext(appState: state, projectStore: store) }
    }

    /// A home directory and an app with one key window, so that a new
    /// project's sidebar section has somewhere to open. The dialog is
    /// stubbed: a test never runs a modal panel.
    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-open-project-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true).path(percentEncoded: false)
        let trimmedHome = String(home.dropLast())
        try FileManager.default.createDirectory(atPath: trimmedHome, withIntermediateDirectories: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: base.appendingPathComponent("w.json")),
            projectFiles: ProjectFileStore(directoryURL: base.appendingPathComponent("projects", isDirectory: true))
        )
        state.chooseProjectFolder = { _ in
            Issue.record("the dialog ran without a stub")
            return nil
        }
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)
        let store = ProjectStore(fileURL: base.appendingPathComponent("p.json"))
        store.autoAssignsColors = { false }
        return Fixture(home: trimmedHome, state: state, store: store, window: window)
    }

    private func candidate(
        _ path: String,
        home: String,
        source: ProjectCandidate.Source = .claude,
        hoursAgo: Double? = nil,
        uses: Int = 0,
        branch: String? = nil,
        gitModified: Date? = nil
    ) -> ProjectCandidate {
        ProjectCandidate(
            path: path,
            source: source,
            lastUsed: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) },
            uses: uses,
            branch: branch,
            gitModified: gitModified,
            parent: ProjectCandidates.abbreviated((path as NSString).deletingLastPathComponent, home: home)
        )
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Where the load ran, recorded from off the main actor.
    private final class LoadThread: @unchecked Sendable {
        private let lock = NSLock()
        private var isMain: Bool?
        var ranOnMain: Bool? { lock.withLock { isMain } }
        func record(isMain: Bool) {
            lock.withLock { self.isMain = isMain }
        }
    }

    /// A scope over `candidates`, shown at once (as a warm cache does).
    private func makeScope(_ fixture: Fixture, candidates: [ProjectCandidate]) -> OpenProjectPaletteScope {
        let scope = OpenProjectPaletteScope(home: fixture.home, latest: { _ in candidates }, refresh: { _ in candidates })
        let fixed = now
        scope.now = { fixed }
        scope.activate(context: fixture.context) {}
        return scope
    }

    private func rows(_ scope: OpenProjectPaletteScope, _ query: String, _ fixture: Fixture) -> [PaletteItem] {
        scope.sections(for: PaletteQuery(raw: query), context: fixture.context).flatMap(\.items)
    }

    // MARK: - Registration

    @Test
    func open_project_is_a_built_in_screen_and_its_command_opens_it() {
        #expect(PaletteScopeID.builtIn.contains(.openProject))
        #expect(PaletteScopeID.openProject.command == .openProject)
        #expect(AppCommand.openProject.paletteScope == .openProject)
        #expect(AppCommand.openProject.category == .palettes)
        #expect(AppCommand.openProject.hotkeyAction == .openProject, "⌘O stays its chord")
        #expect(PaletteScopeID.openProject.pill == PalettePill(title: "Open Project", icon: "folder.badge.plus"))
        #expect(PaletteFrame(.openProject).scope is OpenProjectPaletteScope)
        let palettes = AppCommand.allCases.prefix { $0.category == .palettes }
        #expect(palettes.contains(.openProject), "declared with the other screens, at the head of allCases")
    }

    // MARK: - Nothing typed

    @Test
    func nothing_typed_lists_recents_then_repositories_then_browse_without_sidebar_folders() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        let recents = (1 ... 7).map { candidate("\(home)/dev/recent\($0)", home: home, hoursAgo: Double($0)) }
        let repositories = [
            candidate("\(home)/dev/repo-old", home: home, source: .scan, branch: "main", gitModified: now.addingTimeInterval(-900)),
            candidate("\(home)/dev/repo-new", home: home, source: .scan, branch: "main", gitModified: now.addingTimeInterval(-10)),
            candidate("\(home)/dev/not-git", home: home, source: .scan, gitModified: nil),
            candidate("\(home)/dev/repo-mid", home: home, source: .scan, branch: "dev", gitModified: now.addingTimeInterval(-60)),
            candidate("\(home)/dev/repo-oldest", home: home, source: .scan, branch: "main", gitModified: now.addingTimeInterval(-9000)),
        ]
        fixture.store.add(Project(name: "one", path: "\(home)/dev/recent1", sortOrder: 0))
        let scope = makeScope(fixture, candidates: recents + repositories)

        let sections = scope.sections(for: PaletteQuery(raw: ""), context: fixture.context)
        #expect(sections.map(\.header) == ["Recent with Claude", "Git repos", nil])
        #expect(
            sections[0].items.map(\.title) == ["recent2", "recent3", "recent4", "recent5", "recent6"],
            "5 by frecency, the sidebar's folder left out"
        )
        #expect(sections[1].items.map(\.title) == ["repo-new", "repo-mid", "repo-old"], "3 repositories, newest .git first")
        #expect(sections[2].items.map(\.id) == ["open-project-browse"], "Browse in Finder… is always last")
        #expect(sections[0].items[0].subtitle?.hasPrefix("~/dev · ") == true, "the parent, then when Claude last ran there")
        #expect(sections[1].items[0].subtitle == "~/dev · ⎇ main")
        #expect(scope.loading == nil, "a warm cache shows at once")
    }

    // MARK: - Typed

    @Test
    func a_name_ranks_by_the_folder_name_before_its_parent_never_the_full_path() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        let scope = makeScope(fixture, candidates: [
            candidate("\(home)/dev/mine/applet-hub", home: home, hoursAgo: 1, uses: 50),
            candidate("\(home)/dev/maplekids-worktrees/french", home: home, hoursAgo: 1, uses: 50),
            candidate("\(home)/dev/mine/maple-content", home: home, hoursAgo: 900),
            candidate("\(home)/dev/mine/maplekids", home: home, hoursAgo: 2, uses: 20),
        ])

        let titles = rows(scope, "maple", fixture).map(\.title)
        #expect(!titles.contains("applet-hub"), "`maple` is no match for `mine/applet-hub`: the full path is not searched")
        #expect(titles.firstIndex(of: "french") == titles.count - 2, "a parent-only match ranks below every name match, above Browse")
        #expect(titles.last == "Browse in Finder…")
        let top = try #require(rows(scope, "maple", fixture).first)
        #expect(top.highlights == [0, 1, 2, 3, 4], "the matched letters are drawn semibold")
    }

    @Test
    func frecency_breaks_a_tie_but_never_beats_a_clearly_better_match() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        let scope = makeScope(fixture, candidates: [
            candidate("\(home)/dev/api-one", home: home),
            candidate("\(home)/dev/api-two", home: home, hoursAgo: 1, uses: 100),
            candidate("\(home)/dev/a-long-path-index", home: home, hoursAgo: 1, uses: 1000, branch: "main"),
        ])
        let titles = rows(scope, "api", fixture).map(\.title)
        #expect(Array(titles.prefix(2)) == ["api-two", "api-one"], "an equal match goes to the folder used more")
        #expect(titles.firstIndex(of: "a-long-path-index").map { $0 >= 2 } ?? true, "the boost is capped")
    }

    @Test
    func a_folder_in_the_sidebar_is_one_row_that_switches_and_adds_another_under_option() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        let path = "\(home)/dev/otter"
        let existing = Project(name: "otter", path: path, sortOrder: 0)
        fixture.store.add(existing)
        let scope = makeScope(fixture, candidates: [
            candidate(path, home: home, hoursAgo: 1, branch: "main"),
            candidate("\(home)/dev/otter-ops", home: home, hoursAgo: 5),
        ])

        let found = rows(scope, "otter", fixture)
        #expect(found.count(where: { $0.title == "otter" }) == 1, "one row, not a switch and add-another pair")
        let row = try #require(found.first)
        #expect(row.id == "switch-project:\(path)")
        #expect(row.isEnabled, "dimmed by its subtitle, still selectable")
        #expect(row.subtitle?.hasPrefix("In sidebar · ~/dev") == true)
        #expect(row.alt?.title == "Add another project: ~/dev/otter")

        row.action()
        #expect(fixture.state.activeProjectID == existing.id, "↩ switches to the project")
        #expect(fixture.store.projects.count == 1, "and adds nothing")

        try #require(row.alt).action()
        #expect(fixture.store.projects.count == 2, "⌥↩ always creates")
        let added = try #require(fixture.store.projects.last)
        #expect(added.id != existing.id && added.path == path && added.name == "otter")
        #expect(fixture.state.activeProjectID == added.id)
        #expect(fixture.window.expandedProjects.contains(added.id), "and opens its section in the sidebar")
    }

    @Test
    func a_new_folder_creates_selects_and_expands_its_project() throws {
        let fixture = try makeFixture()
        let path = "\(fixture.home)/dev/fresh"
        let scope = makeScope(fixture, candidates: [candidate(path, home: fixture.home, hoursAgo: 1)])

        let row = try #require(rows(scope, "", fixture).first)
        #expect(row.id == "open-project:\(path)")
        #expect(row.alt == nil)
        row.action()
        let project = try #require(fixture.store.projects.first)
        #expect(project.path == path && project.name == "fresh")
        #expect(fixture.state.activeProjectID == project.id)
        #expect(fixture.window.expandedProjects.contains(project.id))
    }

    @Test
    func no_match_says_so_and_browse_stays() throws {
        let fixture = try makeFixture()
        let scope = makeScope(fixture, candidates: [candidate("\(fixture.home)/dev/alpha", home: fixture.home)])
        let found = rows(scope, "zzzq", fixture)
        #expect(found.map(\.id) == ["open-project-none", "open-project-browse"])
        #expect(found[0].isEnabled == false)
        #expect(found[0].title == "No projects match “zzzq”. Type ~/ to browse folders.")
    }

    // MARK: - Path mode

    @Test
    func a_path_hands_off_to_directory_source_under_its_folder_and_a_protected_folder_lists_nothing() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        for folder in ["dev/one", "dev/two", "Documents/secret"] {
            try FileManager.default.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
        }
        fixture.store.add(Project(name: "two", path: "\(home)/dev/two", sortOrder: 0))
        let scope = makeScope(fixture, candidates: [])

        let sections = scope.sections(for: PaletteQuery(raw: "\(home)/dev/"), context: fixture.context)
        #expect(sections.map(\.header) == ["~/dev/"])
        let ids = sections.flatMap(\.items).map(\.id)
        #expect(ids == [
            "dir-open:\(home)/dev", "dir-open:\(home)/dev/one", "dir-switch:\(home)/dev/two", "dir-new:\(home)/dev/two",
            "open-project-browse",
        ], "DirectorySource's rows, its switch and add-another pair unchanged, then Browse")
        #expect(sections[0].items.last?.subtitle == "Pick a folder in ~/dev with the macOS dialog")

        let open = try #require(sections[0].items.first { $0.id == "dir-open:\(home)/dev/one" })
        open.action()
        let created = try #require(fixture.store.projects.first { $0.path == "\(home)/dev/one" })
        #expect(fixture.window.expandedProjects.contains(created.id), "a folder opened in path mode opens in the sidebar too")

        let protected = scope.sections(for: PaletteQuery(raw: "\(home)/Documents/"), context: fixture.context)
        #expect(protected.map(\.header) == ["~/Documents/"])
        #expect(protected.flatMap(\.items).map(\.id) == ["open-project-browse"], "a protected folder is never listed")
        #expect(scope.sections(for: PaletteQuery(raw: "\(home)/Documents"), context: fixture.context).flatMap(\.items).count == 1)
    }

    @Test
    func the_listed_folder_is_the_typed_folder_or_the_one_that_holds_it() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        try FileManager.default.createDirectory(atPath: "\(home)/dev/one", withIntermediateDirectories: true)
        #expect(OpenProjectPaletteScope.listedFolder(for: "\(home)/dev/one", home: home) == "\(home)/dev/one")
        #expect(OpenProjectPaletteScope.listedFolder(for: "\(home)/dev/on", home: home) == "\(home)/dev")
        #expect(OpenProjectPaletteScope.listedFolder(for: "~/dev/", home: home) == "\(home)/dev")
        #expect(OpenProjectPaletteScope.listedFolder(for: "\(home)/Documents/x", home: home) == "\(home)/Documents")
        #expect(OpenProjectPaletteScope.listedFolder(for: "devbox:~/api", home: home) == nil)
        #expect(OpenProjectPaletteScope.listedFolder(for: "maple", home: home) == nil)
    }

    // MARK: - Browse and ⇥

    @Test
    func browse_runs_the_dialog_after_the_palette_closes_in_the_typed_folder() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        try FileManager.default.createDirectory(atPath: "\(home)/dev/picked", withIntermediateDirectories: true)
        var asked: [String?] = []
        fixture.state.chooseProjectFolder = { directory in
            asked.append(directory)
            return URL(fileURLWithPath: "\(home)/dev/picked", isDirectory: true)
        }
        let scope = makeScope(fixture, candidates: [])

        let browse = try #require(rows(scope, "\(home)/dev/pi", fixture).last)
        #expect(browse.id == "open-project-browse")
        #expect(browse.keybindSymbols == ["⌘", "O"], "the chord that does the same on this screen")
        browse.action()
        #expect(asked.isEmpty, "not while the palette is up")
        let afterClose = try #require(fixture.state.postPaletteAction)
        afterClose()
        #expect(asked == ["\(home)/dev"])
        let project = try #require(fixture.store.projects.first)
        #expect(project.path == "\(home)/dev/picked" && project.name == "picked")
        #expect(fixture.state.activeProjectID == project.id)
        #expect(fixture.window.expandedProjects.contains(project.id))
    }

    @Test
    func tab_completes_the_selected_folder_and_a_slash() throws {
        let fixture = try makeFixture()
        let home = fixture.home
        let path = "\(home)/dev/mine/maplekids"
        let scope = makeScope(fixture, candidates: [candidate(path, home: home)])
        let row = try #require(rows(scope, "maple", fixture).first)
        #expect(scope.completion(for: row, query: PaletteQuery(raw: "maple")) == "~/dev/mine/maplekids/")
        #expect(scope.completion(for: row, query: PaletteQuery(raw: "/abs")) == "\(path)/")
        let folder = PaletteItem(id: "dir-open:\(home)/dev", title: "dev", action: {})
        #expect(scope.completion(for: folder, query: PaletteQuery(raw: "~/de")) == "~/dev/")
        let browse = try #require(rows(scope, "maple", fixture).last)
        #expect(scope.completion(for: browse, query: PaletteQuery(raw: "maple")) == nil)
        #expect(PasswordPaletteScope().completion(for: row, query: PaletteQuery(raw: "x")) == nil, "other screens keep ⇥ for focus")
    }

    // MARK: - Loading

    @Test
    func a_cold_open_shows_browse_while_the_folders_load_off_the_main_actor() async throws {
        let fixture = try makeFixture()
        let path = "\(fixture.home)/dev/late"
        let found = [candidate(path, home: fixture.home, hoursAgo: 1)]
        let thread = LoadThread()
        let scope = OpenProjectPaletteScope(home: fixture.home, latest: { _ in nil }, refresh: { _ in
            thread.record(isMain: Thread.isMainThread)
            return found
        })
        var redraws = 0
        scope.activate(context: fixture.context) { redraws += 1 }
        #expect(scope.loading != nil)
        #expect(rows(scope, "", fixture).map(\.id) == ["open-project-browse"], "Browse is live at once")

        for _ in 0 ..< 200 where scope.loading != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scope.loading == nil)
        #expect(thread.ranOnMain == false, "the load never blocks the main thread")
        #expect(rows(scope, "", fixture).map(\.id) == ["open-project:\(path)", "open-project-browse"])
        #expect(redraws == 2)

        scope.activate(context: fixture.context) { redraws += 1 }
        #expect(redraws == 2, "a frame back on top keeps its rows and loads nothing again")
    }

    // MARK: - ⌘O and Escape

    @Test
    func open_project_opens_the_screen_alone_and_escape_closes_the_palette() throws {
        let fixture = try makeFixture()
        fixture.state.showOpenProject(store: fixture.store)
        #expect(fixture.window.isCommandPaletteVisible)
        #expect(fixture.window.paletteScope == .openProject)
        #expect(fixture.window.leavingClosesPalette, "opened directly: Escape closes the palette")

        // Entered from ⌘P's row, Escape steps back to ⌘P, as Files does.
        let fromRoot = WindowState()
        fromRoot.pushPaletteFrame(PaletteFrame(.openProject))
        #expect(!fromRoot.leavingClosesPalette)
        // A screen's own chord keeps stepping back to the root.
        fromRoot.showPaletteScope(.files)
        #expect(!fromRoot.leavingClosesPalette)
    }

    @Test
    func open_project_again_on_the_screen_closes_it_and_opens_the_dialog_in_the_typed_folder() throws {
        let fixture = try makeFixture()
        let typed = "\(fixture.home)/dev"
        try FileManager.default.createDirectory(atPath: typed, withIntermediateDirectories: true)
        var asked: [String?] = []
        fixture.state.chooseProjectFolder = { directory in
            asked.append(directory)
            return nil
        }
        fixture.state.showOpenProject(store: fixture.store)
        fixture.state.commandPaletteQuery = "\(typed)/"

        fixture.state.showOpenProject(store: fixture.store)
        #expect(!fixture.window.isCommandPaletteVisible, "⌘O again closes the palette")
        #expect(asked.isEmpty, "the dialog waits for the palette to close")
        let afterClose = try #require(fixture.state.postPaletteAction)
        afterClose()
        #expect(asked == [typed])
        #expect(fixture.store.projects.isEmpty, "a cancelled dialog adds nothing")
    }

    @Test
    func open_project_with_no_window_runs_the_dialog() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-open-project-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: base.appendingPathComponent("w.json")),
            projectFiles: ProjectFileStore(directoryURL: base.appendingPathComponent("projects", isDirectory: true))
        )
        let store = ProjectStore(fileURL: base.appendingPathComponent("p.json"))
        store.autoAssignsColors = { false }
        var asked: [String?] = []
        state.chooseProjectFolder = { directory in
            asked.append(directory)
            return URL(fileURLWithPath: "/tmp/macterm-picked", isDirectory: true)
        }
        AppCommand.openProject.action(in: AppCommandContext(appState: state, projectStore: store))?()
        #expect(asked == [nil])
        #expect(store.projects.map(\.path) == ["/tmp/macterm-picked"])
    }
}
