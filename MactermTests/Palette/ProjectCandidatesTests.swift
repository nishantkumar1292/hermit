import Foundation
@testable import Macterm
import Testing

/// The folders of the Open Project screen: Claude Code's recents from every
/// config directory, the scan of the code folders, and the folders the load
/// must never touch. Every test builds its own home directory.
struct ProjectCandidatesTests {
    /// A throwaway home directory. It is under the temporary folder, which
    /// `isNoise` drops only outside home.
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-candidates-\(UUID().uuidString)", isDirectory: true)
            .path(percentEncoded: false)
        let trimmed = String(home.hasSuffix("/") ? home.dropLast() : home[...])
        try FileManager.default.createDirectory(atPath: trimmed, withIntermediateDirectories: true)
        return trimmed
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// A repository on `branch`, as `git init` leaves `.git/HEAD`.
    private func makeRepository(_ path: String, branch: String = "main") throws {
        try write("ref: refs/heads/\(branch)\n", to: "\(path)/.git/HEAD")
    }

    /// A `history.jsonl` line as Claude Code writes it, prompt text included.
    private func historyLine(_ project: String, at milliseconds: Double, prompt: String = "a secret prompt") -> String {
        let object: [String: Any] = [
            "display": prompt, "pastedContents": [String: String](), "project": project,
            "sessionId": UUID().uuidString, "timestamp": milliseconds,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// A config file with these `projects` start times (nil: no start time).
    private func configFile(_ projects: [String: Double?]) -> String {
        var entries: [String: Any] = [:]
        for (path, time) in projects {
            var entry: [String: Any] = ["allowedTools": [String](), "lastSessionFirstPrompt": "another secret"]
            if let time { entry["lastStartTime"] = time }
            entries[path] = entry
        }
        let data = try? JSONSerialization.data(withJSONObject: ["projects": entries, "numStartups": 3])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }

    // MARK: - Config directories

    @Test
    func the_config_dirs_are_the_default_and_every_claude_dash_dir_that_holds_history_or_a_config_file() throws {
        let home = try makeHome()
        try write("{}", to: "\(home)/.claude.json")
        try makeFolder("\(home)/.claude")
        try write("", to: "\(home)/.claude-work/history.jsonl")
        try write("{}", to: "\(home)/.claude-team/.claude.json")
        try makeFolder("\(home)/.claude-cache/plugins")
        try write("not a directory", to: "\(home)/.claude-notes")

        let dirs = ProjectCandidates.configDirs(home: home)
        #expect(dirs.map(\.root) == ["\(home)/.claude", "\(home)/.claude-team", "\(home)/.claude-work"])
        #expect(dirs[0].configFile == "\(home)/.claude.json", "the default dir's config file is beside it, in home")
        #expect(dirs[1].configFile == "\(home)/.claude-team/.claude.json")
        #expect(dirs[2].historyFile == "\(home)/.claude-work/history.jsonl")
        #expect(try ProjectCandidates.configDirs(home: makeHome()).isEmpty, "no Claude Code, no recents")
    }

    // MARK: - Recents

    @Test
    func recents_merge_across_config_dirs_the_latest_time_wins_and_the_uses_add_up() throws {
        let home = try makeHome()
        let now = Date()
        let alpha = "\(home)/dev/alpha"
        let beta = "\(home)/dev/beta"
        let gamma = "\(home)/work/gamma"
        try makeRepository(alpha, branch: "feature/x")
        try makeFolder(beta)
        try makeFolder(gamma)
        let old = milliseconds(now.addingTimeInterval(-30 * 86400))
        let newer = milliseconds(now.addingTimeInterval(-2 * 86400))
        let newest = milliseconds(now.addingTimeInterval(-3600))

        try write(configFile([alpha: old, "\(home)/dev/gone": newest, beta: nil]), to: "\(home)/.claude.json")
        try write(
            [historyLine(alpha, at: newer), historyLine(alpha, at: old), historyLine(beta, at: old), historyLine(home, at: newest)]
                .joined(separator: "\n"),
            to: "\(home)/.claude/history.jsonl"
        )
        try write(
            [historyLine(alpha + "/", at: newest), historyLine(alpha, at: old), historyLine(alpha, at: old), "not json"]
                .joined(separator: "\n"),
            to: "\(home)/.claude-work/history.jsonl"
        )
        try write(configFile([gamma: newer, "\(home)/dev/.claude/worktrees/agent-1": newest]), to: "\(home)/.claude-team/.claude.json")

        let candidates = ProjectCandidates.load(home: home, now: now)
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })

        let merged = try #require(byPath[alpha])
        #expect(merged.source == .claude)
        #expect(merged.uses == 5, "2 prompts in ~/.claude and 3 in ~/.claude-work, a trailing slash the same folder")
        #expect(merged.lastUsed.map(milliseconds) == newest, "the latest time across every config dir")
        #expect(merged.branch == "feature/x")
        #expect(merged.name == "alpha")
        #expect(merged.parent == "~/dev")

        #expect(byPath[beta]?.uses == 1)
        #expect(byPath[beta]?.lastUsed.map(milliseconds) == old, "a config key without a start time takes the history's")
        #expect(byPath[gamma]?.source == .claude, "a config dir other than the default counts too")
        #expect(byPath["\(home)/dev/gone"] == nil, "a recent that is gone is dropped")
        #expect(byPath[home] == nil, "home is never a project")
        #expect(!candidates.contains { $0.path.contains("/.claude/worktrees/") }, "Claude's worktrees are noise")
        #expect(candidates.first?.path == alpha, "best frecency first")
        #expect(!String(describing: candidates).contains("secret"), "prompt text is never kept")
    }

    @Test
    func a_protected_recent_is_kept_unchecked_and_its_git_is_never_read() throws {
        let home = try makeHome()
        let notes = "\(home)/Documents/notes"
        let cloud = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/plan"
        let real = "\(home)/Desktop/real"
        let missing = "\(home)/dev/missing"
        let container = "\(home)/Library/Containers/com.example/Data/app"
        try makeRepository(real)
        try makeRepository("\(home)/Desktop/sibling")
        try write(configFile([notes: 1, cloud: 1, real: 1, missing: 1, container: 1]), to: "\(home)/.claude.json")

        let byPath = Dictionary(uniqueKeysWithValues: ProjectCandidates.load(home: home).map { ($0.path, $0) })
        #expect(byPath[notes] != nil, "not checked on disk, so a protected recent stays though nothing is there")
        #expect(byPath[cloud] != nil)
        #expect(byPath[container] != nil, "nothing in ~/Library is checked either")
        #expect(byPath[real]?.branch == nil, "its .git/HEAD exists but is never read")
        #expect(byPath[missing] == nil, "an unprotected recent that is gone is dropped")
        #expect(byPath["\(home)/Desktop/sibling"] == nil, "a protected folder is never a scan root")
    }

    @Test
    func protected_and_off_limits_paths() {
        let home = "/Users/me"
        for path in [
            "/Users/me/Desktop", "/Users/me/Documents/a", "/Users/me/Downloads/b/c",
            "/Users/me/Library/Mobile Documents/x", "/Users/me/Library/CloudStorage/Drive/y",
            "/Users/me/documents/a", "/USERS/ME/DESKTOP",
        ] {
            #expect(ProjectCandidates.isProtected(path, home: home), "\(path)")
        }
        for path in ["/Users/me/Doc", "/Users/me/Documentsfoo", "/Users/me/dev/Documents", "/Users/me/Library/Containers/x"] {
            #expect(!ProjectCandidates.isProtected(path, home: home), "\(path)")
        }
        #expect(ProjectCandidates.isOffLimits("/Users/me/Library/Containers/x", home: home))
        #expect(ProjectCandidates.isOffLimits("/Volumes/USB/project", home: home))
        #expect(!ProjectCandidates.isOffLimits("/Users/me/dev/project", home: home))
        #expect(ProjectCandidates.isNoise("/private/tmp/x", home: home))
        #expect(ProjectCandidates.isNoise("/Users/me", home: home))
        #expect(!ProjectCandidates.isNoise("/private/var/folders/home/dev/x", home: "/private/var/folders/home"))
    }

    @Test
    func paths_normalize_without_reading_the_disk() {
        #expect(ProjectCandidates.normalized("/a/b/") == "/a/b")
        #expect(ProjectCandidates.normalized("/a/./b/../c//d") == "/a/c/d")
        #expect(ProjectCandidates.normalized("/") == "/")
        #expect(ProjectCandidates.normalized("relative/path") == nil)
        #expect(ProjectCandidates.expanded("~/dev", home: "/h") == "/h/dev")
        #expect(ProjectCandidates.expanded("~", home: "/h") == "/h")
        #expect(ProjectCandidates.abbreviated("/h/dev/x", home: "/h") == "~/dev/x")
        #expect(ProjectCandidates.abbreviated("/opt/x", home: "/h") == "/opt/x")
    }

    // MARK: - Scan

    @Test
    func the_scan_finds_marked_folders_in_its_depth_and_skips_hidden_dependency_and_linked_folders() throws {
        let home = try makeHome()
        try makeRepository("\(home)/dev/a")
        try makeRepository("\(home)/dev/a/inner")
        try write("{}", to: "\(home)/dev/group/b/package.json")
        try write("", to: "\(home)/dev/x/y/z/deep/Cargo.toml")
        try write("{}", to: "\(home)/dev/node_modules/d/package.json")
        try makeRepository("\(home)/dev/.hidden/e")
        try makeRepository("\(home)/elsewhere/f")
        try FileManager.default.createSymbolicLink(atPath: "\(home)/dev/link", withDestinationPath: "\(home)/elsewhere")

        let found = ProjectCandidates.load(home: home).filter { $0.source == .scan }
        #expect(Set(found.map(\.path)) == ["\(home)/dev/a", "\(home)/dev/group/b"])
        let repository = try #require(found.first { $0.path == "\(home)/dev/a" })
        #expect(repository.branch == "main")
        #expect(repository.gitModified != nil)
        #expect(repository.lastUsed == nil && repository.uses == 0)
        #expect(found.first { $0.path == "\(home)/dev/group/b" }?.branch == nil, "a marker that is not git has no branch")
        #expect(ProjectCandidates.scan(roots: ["\(home)/dev"], home: home, visitLimit: 1).isEmpty, "the visit limit ends the scan")

        // A code folder linked into Documents is not listed: the listing
        // would follow the link into a protected folder.
        try makeRepository("\(home)/Documents/code/g")
        try FileManager.default.createSymbolicLink(atPath: "\(home)/code", withDestinationPath: "\(home)/Documents/code")
        #expect(ProjectCandidates.linksOffLimits("\(home)/code", home: home))
        #expect(!ProjectCandidates.linksOffLimits("\(home)/dev", home: home))
        #expect(!ProjectCandidates.load(home: home).contains { $0.path.hasSuffix("/g") })
    }

    @Test
    func the_scan_also_starts_beside_each_recent() throws {
        let home = try makeHome()
        let recent = "\(home)/clients/acme/site"
        try makeFolder(recent)
        try makeRepository("\(home)/clients/acme/api")
        try write(historyLine(recent, at: 1), to: "\(home)/.claude/history.jsonl")

        let byPath = Dictionary(uniqueKeysWithValues: ProjectCandidates.load(home: home).map { ($0.path, $0) })
        #expect(byPath["\(home)/clients/acme/api"]?.source == .scan)
        #expect(byPath[recent]?.source == .claude, "a recent the scan also finds stays a recent")
        #expect(
            ProjectCandidates.scanRoots(home: home, recents: ["\(home)/a/b", "\(home)/top", "\(home)/Documents/x"])
                == ProjectCandidates.scanFolders.map { "\(home)/\($0)" } + ["\(home)/a"],
            "never home itself, never a protected folder"
        )
    }

    @Test
    func a_worktree_reads_the_head_of_its_git_directory() throws {
        let home = try makeHome()
        let worktree = "\(home)/dev/wt"
        try write("ref: refs/heads/topic\n", to: "\(home)/dev/main/.git/worktrees/wt/HEAD")
        try write("gitdir: \(home)/dev/main/.git/worktrees/wt\n", to: "\(worktree)/.git")
        #expect(ProjectCandidates.gitInfo(at: worktree, home: home).branch == "topic")
        try write("0123456789abcdef\n", to: "\(home)/dev/detached/.git/HEAD")
        #expect(ProjectCandidates.gitInfo(at: "\(home)/dev/detached", home: home).branch == "0123456")
        #expect(ProjectCandidates.gitInfo(at: "\(home)/dev/none", home: home).branch == nil)

        // A worktree of a repository in Documents: its HEAD is never read.
        try write("ref: refs/heads/private\n", to: "\(home)/Documents/repo/.git/worktrees/wt/HEAD")
        try write("gitdir: \(home)/Documents/repo/.git/worktrees/wt\n", to: "\(home)/dev/outside/.git")
        #expect(ProjectCandidates.gitInfo(at: "\(home)/dev/outside", home: home).branch == nil)
        try write("gitdir: ../../documents/repo/.git/worktrees/wt\n", to: "\(home)/dev/relative/.git")
        #expect(ProjectCandidates.gitInfo(at: "\(home)/dev/relative", home: home).branch == nil, "relative, in any case")
    }

    // MARK: - Ranking

    @Test
    func frecency_is_ncodes() {
        let now = Date()
        func candidate(_ source: ProjectCandidate.Source, days: Double?, uses: Int = 0, branch: String? = nil) -> ProjectCandidate {
            ProjectCandidate(
                path: "/p",
                source: source,
                lastUsed: days.map { now.addingTimeInterval(-$0 * 86400) },
                uses: uses,
                branch: branch,
                gitModified: nil,
                parent: "/"
            )
        }
        #expect(abs(candidate(.claude, days: 0).frecency(now: now) - 24) < 0.001)
        #expect(abs(candidate(.claude, days: 7).frecency(now: now) - 14) < 0.001, "recency halves each week")
        #expect(abs(candidate(.claude, days: nil, uses: 3).frecency(now: now) - 10) < 0.001, "4 + 3·log₂(4)")
        #expect(abs(candidate(.scan, days: nil, branch: "main").frecency(now: now) - 2) < 0.001)
        #expect(candidate(.scan, days: nil).frecency(now: now) == 0)
    }

    // MARK: - Cache

    @Test
    func the_cache_keeps_a_load_until_it_ages_or_a_history_file_changes() throws {
        let home = try makeHome()
        let now = Date()
        let first = "\(home)/dev/first"
        try makeFolder(first)
        let history = "\(home)/.claude/history.jsonl"
        try write(historyLine(first, at: 1), to: history)

        #expect(ProjectCandidates.latest(home: home) == nil, "nothing loaded yet")
        #expect(ProjectCandidates.cached(home: home, now: now).map(\.path) == [first])
        #expect(ProjectCandidates.latest(home: home)?.map(\.path) == [first])

        // A new repository on disk: the young cache hides it until it ages.
        try makeRepository("\(home)/dev/new")
        #expect(ProjectCandidates.cached(home: home, now: now.addingTimeInterval(1)).map(\.path) == [first])
        #expect(
            ProjectCandidates.cached(home: home, now: now.addingTimeInterval(ProjectCandidates.timeToLive + 1)).contains {
                $0.path == "\(home)/dev/new"
            }
        )

        // Claude ran somewhere new: the changed history loads again at once.
        let second = "\(home)/dev/second"
        try makeFolder(second)
        let later = now.addingTimeInterval(ProjectCandidates.timeToLive + 2)
        try write([historyLine(first, at: 1), historyLine(second, at: 2)].joined(separator: "\n"), to: history)
        try FileManager.default.setAttributes([.modificationDate: later.addingTimeInterval(-3600)], ofItemAtPath: history)
        #expect(ProjectCandidates.cached(home: home, now: later).contains { $0.path == second })
    }
}
