import Foundation

/// The palette's Open Project: a keyboard-first folder picker, ported from
/// ncode's project finder. It is what ⌘O, the menu bar, the Dock, the
/// sidebar's New Project menu and Settings → Projects open
/// (`AppState.showOpenProject`).
///
/// - With nothing typed: the folders where Claude Code ran (best frecency
///   first), then the repositories that the scan found (newest `.git`
///   first). Folders already in the sidebar are left out.
/// - A name: one ranked list (`SearchIndex` over the name and the parent
///   folder, with a small frecency boost). A folder already in the sidebar
///   is one row: ↩ switches to its project, ⌥↩ adds another project there.
/// - A path (`~`, `/`, `host:~/dir`): `DirectorySource`, unchanged, under a
///   header that names the folder. A protected folder lists nothing.
/// - **Browse in Finder…** is always the last row. It opens the system
///   dialog, in the typed folder when there is one. ⌘O on this screen does
///   the same.
///
/// Every new folder becomes a new project (`AppState.addProject`, always
/// create), which is selected and opened in the sidebar. The candidates load
/// off the main actor (`ProjectCandidates`); the last load shows at once
/// while a new one runs.
@MainActor
final class OpenProjectPaletteScope: PaletteScope {
    /// Rows for a typed name, at most.
    static let shownLimit = 50
    /// Rows of each section with nothing typed.
    static let recentLimit = 5
    static let repositoryLimit = 3
    /// The most that frecency adds to a text match's score. A matched letter
    /// is worth about 16, so the boost only breaks near ties.
    static let boostLimit = 8
    /// Folders that path mode lists here: enough to scroll through, where
    /// the root palette's path mode completes from 10.
    static let childLimit = 200

    /// The row id prefixes that name a folder, for ⇥.
    private static let folderIDPrefixes = ["open-project:", "switch-project:", "dir-open:", "dir-switch:", "dir-new:"]

    private(set) var loading: PaletteLoading?
    private var candidates: [ProjectCandidate]?
    private var session: SearchSession?
    private var task: Task<Void, Never>?
    /// The background load ran for this frame. One load per open: a frame
    /// that returns to the top keeps its rows.
    private var refreshed = false
    private var onChange: (@MainActor () -> Void)?
    private let home: String
    private let latest: (String) -> [ProjectCandidate]?
    private let refresh: @Sendable (String) -> [ProjectCandidate]
    /// The clock of the frecency and the ages in the subtitles. A seam.
    var now: () -> Date = { Date() }

    /// `latest` is the last load to show at once, `refresh` the load that
    /// runs off the main actor (tests pass their own).
    init(
        home: String = ProjectPath.currentHome,
        latest: @escaping (String) -> [ProjectCandidate]? = { ProjectCandidates.latest(home: $0) },
        refresh: @escaping @Sendable (String) -> [ProjectCandidate] = { ProjectCandidates.cached(home: $0) }
    ) {
        self.home = home
        self.latest = latest
        self.refresh = refresh
    }

    var placeholder: String {
        let chord = HotkeyRegistry.selectedShortcutString(for: .openProject)
        guard !HotkeyRegistry.isUnbound(chord) else { return String(localized: "Search projects, or type ~/ to browse folders") }
        return String(localized: "Search projects, ~/ to browse folders, \(HotkeyRegistry.displayString(for: chord)) for Finder")
    }

    // MARK: - Lifecycle

    func activate(context _: PaletteContext, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard !refreshed, task == nil else { return }
        if candidates == nil, let shown = latest(home) {
            show(shown, index: ProjectCandidates.searchIndex(for: shown))
        }
        if candidates == nil {
            loading = PaletteLoading(message: String(localized: "Finding projects…"))
        }
        onChange()
        let refresh = refresh
        let home = home
        task = Task { @MainActor [weak self] in
            // A detached task doesn't inherit cancellation: hand it on.
            let loading = Task.detached(priority: .userInitiated) { () -> ([ProjectCandidate], SearchIndex) in
                let found = refresh(home)
                return (found, ProjectCandidates.searchIndex(for: found))
            }
            let (found, index) = await withTaskCancellationHandler {
                await loading.value
            } onCancel: {
                loading.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            task = nil
            refreshed = true
            self.loading = nil
            if found != candidates { show(found, index: index) }
            self.onChange?()
        }
    }

    func deactivate() {
        task?.cancel()
        task = nil
    }

    private func show(_ found: [ProjectCandidate], index: SearchIndex) {
        candidates = found
        session = SearchSession(index: index)
    }

    // MARK: - Sections

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        if query.looksLikePath { return pathSections(query.trimmed, context: context) }
        let browse = browseItem(directory: nil, context: context)
        // Still loading the first time: Browse is already live.
        guard let candidates, let session else { return [PaletteSection(header: nil, items: [browse])] }
        let sidebar = SidebarFolders(context.projectStore.projects)
        let now = now()
        if query.isEmpty {
            return emptySections(candidates, sidebar: sidebar, now: now, context: context)
                + [PaletteSection(header: nil, items: [browse])]
        }
        let search = SearchQuery(query.trimmed)
        let rows = session.search(query.trimmed).map { match in
            let candidate = candidates[match.index]
            let boost = min(Int(candidate.frecency(now: now)), Self.boostLimit)
            return row(for: candidate, existing: sidebar.project(at: candidate.path), now: now, context: context)
                .with(score: -Int(match.score) - boost, highlights: session.index.highlights(search, at: match.index))
        }
        .rankedByScore()
        .prefix(Self.shownLimit)
        guard !rows.isEmpty else {
            let none = PaletteItem(
                id: "open-project-none",
                title: String(localized: "No projects match “\(query.trimmed)”. Type ~/ to browse folders."),
                score: 0,
                isEnabled: false,
                action: {}
            )
            return [PaletteSection(header: nil, items: [none, browse])]
        }
        return [PaletteSection(header: nil, items: Array(rows) + [browse])]
    }

    /// Nothing typed: the recents of Claude Code, then the repositories
    /// that only the scan found. Folders in the sidebar are left out: going
    /// to them is ⌘P's job, and they come back when you type.
    private func emptySections(
        _ candidates: [ProjectCandidate],
        sidebar: SidebarFolders,
        now: Date,
        context: PaletteContext
    ) -> [PaletteSection] {
        let free = candidates.filter { sidebar.project(at: $0.path) == nil }
        let recents = ProjectCandidates.ranked(free.filter { $0.source == .claude }, now: now)
            .prefix(Self.recentLimit)
            .map { row(for: $0, existing: nil, now: now, context: context) }
        let repositories = free
            .filter { $0.source == .scan && $0.branch != nil }
            .sorted { ($0.gitModified ?? .distantPast, $1.path) > ($1.gitModified ?? .distantPast, $0.path) }
            .prefix(Self.repositoryLimit)
            .map { row(for: $0, existing: nil, now: now, context: context) }
        var sections: [PaletteSection] = []
        if !recents.isEmpty {
            sections.append(PaletteSection(
                header: String(
                    localized: "Recent with Claude",
                    comment: "Open Project screen: the section of folders where Claude Code ran"
                ),
                items: Array(recents)
            ))
        }
        if !repositories.isEmpty {
            sections.append(PaletteSection(
                header: String(localized: "Git repos", comment: "Open Project screen: the section of repositories that a scan found"),
                items: Array(repositories)
            ))
        }
        return sections
    }

    /// A typed path: `DirectorySource`'s rows, under the folder they list,
    /// and Browse in that folder. A protected folder (`~/Documents/…`) is
    /// never listed, so it shows only Browse and macOS asks for nothing.
    private func pathSections(_ text: String, context: PaletteContext) -> [PaletteSection] {
        if PaletteQuery.isRemoteSpecQuery(text) {
            let rows = DirectorySource().items(query: text, context: context).map { revealing($0, context: context) }
            return [PaletteSection(header: nil, items: rows + [browseItem(directory: nil, context: context)])]
        }
        let folder = Self.listedFolder(for: text, home: home)
        let header = folder.map { ProjectCandidates.abbreviated($0, home: home).withTrailingSlash }
        let browse = browseItem(directory: folder, context: context)
        // Normalized, so `~/dev/../Documents/` is `~/Documents` too.
        let expanded = ProjectCandidates.expanded(text, home: home)
        guard !ProjectCandidates.isProtected(ProjectCandidates.normalized(expanded) ?? expanded, home: home) else {
            return [PaletteSection(header: header, items: [browse])]
        }
        let rows = DirectorySource(childLimit: Self.childLimit).items(query: text, context: context)
            .map { revealing($0, context: context) }
        return [PaletteSection(header: header, items: rows + [browse])]
    }

    // MARK: - Rows

    /// A folder's row. A new folder adds a project. A folder that already
    /// backs one (`existing`) is one row: ↩ goes to that project, ⌥↩ adds
    /// another project there — a directory is not an identity.
    private func row(for candidate: ProjectCandidate, existing: Project?, now: Date, context: PaletteContext) -> PaletteItem {
        let appState = context.appState
        let store = context.projectStore
        let details = Self.details(of: candidate, now: now)
        guard let existing else {
            return PaletteItem(
                id: "open-project:\(candidate.path)",
                title: candidate.name,
                subtitle: details.joined(separator: " · "),
                score: 0,
                icon: "folder"
            ) {
                appState.addProject(name: candidate.name, path: candidate.path, store: store)
            }
        }
        let inSidebar = String(localized: "In sidebar", comment: "Open Project screen: a folder that backs a project in the sidebar")
        return PaletteItem(
            id: "switch-project:\(candidate.path)",
            title: candidate.name,
            subtitle: ([inSidebar] + details).joined(separator: " · "),
            score: 0,
            icon: "folder",
            alt: PaletteAltAction(
                title: String(localized: "Add another project: \(ProjectCandidates.abbreviated(candidate.path, home: home))")
            ) {
                appState.addProject(name: candidate.name, path: candidate.path, store: store)
            }
        ) {
            appState.selectProject(existing)
            appState.expandInSidebar(existing.id)
        }
    }

    /// The subtitle's parts: the parent folder, the branch and when Claude
    /// last ran there.
    static func details(of candidate: ProjectCandidate, now: Date) -> [String] {
        var parts = [candidate.parent]
        if let branch = candidate.branch { parts.append("⎇ \(branch)") }
        if let lastUsed = candidate.lastUsed {
            parts.append(ageFormatter.localizedString(for: min(lastUsed, now), relativeTo: now))
        }
        return parts
    }

    /// "2 hr. ago": made one time, since a keystroke builds a row for each match.
    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The last row in every state: the system dialog, in `directory` when
    /// the query names one. It runs after the palette has closed. Its keycap
    /// is Open Project's chord, which does the same on this screen.
    private func browseItem(directory: String?, context: PaletteContext) -> PaletteItem {
        let appState = context.appState
        let store = context.projectStore
        let chord = HotkeyRegistry.selectedShortcutString(for: .openProject)
        let symbols = HotkeyRegistry.displaySymbols(for: chord)
        let subtitle = directory.map {
            String(localized: "Pick a folder in \(ProjectCandidates.abbreviated($0, home: home)) with the macOS dialog")
        } ?? String(localized: "Pick a folder with the macOS dialog")
        return PaletteItem(
            id: "open-project-browse",
            title: String(localized: "Browse in Finder…"),
            subtitle: subtitle,
            keybind: symbols.isEmpty ? nil : HotkeyRegistry.displayString(for: chord),
            keybindSymbols: symbols.isEmpty ? nil : symbols,
            score: 0,
            icon: "ellipsis.circle"
        ) {
            appState.postPaletteAction = { appState.browseForProject(store: store, directory: directory) }
        }
    }

    /// A `DirectorySource` row that also opens the project it selects in
    /// the sidebar, as every row of this screen does.
    private func revealing(_ item: PaletteItem, context: PaletteContext) -> PaletteItem {
        let appState = context.appState
        return item.followed {
            if let projectID = appState.activeProjectID { appState.expandInSidebar(projectID) }
        }
    }

    // MARK: - Completion

    /// ⇥ on a folder's row: its path and a `/`, so the folder lists next.
    /// With `~` for home unless the query is an absolute path.
    func completion(for item: PaletteItem, query: PaletteQuery) -> String? {
        guard let prefix = Self.folderIDPrefixes.first(where: { item.id.hasPrefix($0) }) else { return nil }
        let path = String(item.id.dropFirst(prefix.count))
        guard path.hasPrefix("/") else { return nil }
        let shown = query.trimmed.hasPrefix("/") ? path : ProjectCandidates.abbreviated(path, home: home)
        return shown.withTrailingSlash
    }

    // MARK: - Browse folder

    /// The folder that a typed path lists: the path itself when it is a
    /// folder, else the folder that holds it. Nil for a remote spec or a
    /// query that is no path. A protected path is never checked on disk:
    /// with a trailing `/` it is the folder, else the folder that holds it.
    static func listedFolder(for text: String, home: String) -> String? {
        let query = PaletteQuery(raw: text)
        guard query.looksLikePath, !PaletteQuery.isRemoteSpecQuery(query.trimmed) else { return nil }
        let expanded = ProjectCandidates.expanded(query.trimmed, home: home)
        guard expanded.hasPrefix("/") else { return nil }
        let trimmed = ProjectCandidates.normalized(expanded) ?? expanded
        if expanded.hasSuffix("/") { return trimmed }
        if !ProjectCandidates.isProtected(trimmed, home: home) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue {
                return trimmed
            }
        }
        return (trimmed as NSString).deletingLastPathComponent
    }
}

/// The local projects of the sidebar by folder, for one draw of the
/// screen: one dictionary lookup per candidate, not a path comparison with
/// every project.
@MainActor
struct SidebarFolders {
    private let byPath: [String: Project]

    init(_ projects: [Project]) {
        var byPath: [String: Project] = [:]
        let home = ProjectPath.currentHome
        for project in projects where !project.isRemote {
            // Lexical only: a project in a protected folder is not checked
            // on disk for this.
            guard let path = ProjectCandidates.normalized(ProjectCandidates.expanded(project.path, home: home)) else { continue }
            if byPath[path] == nil { byPath[path] = project }
        }
        self.byPath = byPath
    }

    /// The first project on `path` (absolute, normalized), if any.
    func project(at path: String) -> Project? {
        byPath[path]
    }
}

private extension String {
    var withTrailingSlash: String { hasSuffix("/") ? self : self + "/" }
}
