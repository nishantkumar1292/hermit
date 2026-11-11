import Foundation
import os

/// A folder that the palette's Open Project screen offers: a folder where
/// Claude Code ran (in any of its config directories), or a project folder
/// that a short scan of the usual code folders found.
struct ProjectCandidate: Equatable {
    enum Source: Equatable {
        /// Claude Code ran in it: a `projects` key of a config file, or a
        /// line of a `history.jsonl`.
        case claude
        /// Only the scan found it.
        case scan
    }

    /// Absolute, with no trailing slash.
    let path: String
    let source: Source
    /// The last time that Claude Code ran in it, in any config directory.
    /// Nil when no record has a time.
    let lastUsed: Date?
    /// The prompts sent from it, the sum over every config directory.
    let uses: Int
    /// The checked-out branch (`.git/HEAD`), or a short commit when HEAD is
    /// detached. Nil for a folder that is not a repository, and for a folder
    /// that the load does not touch (`ProjectCandidates.isOffLimits`).
    let branch: String?
    /// When `.git` changed last: the order of the scan's rows. Nil with no
    /// `.git`.
    let gitModified: Date?
    /// The folder that holds it, with `~` for the home directory: the row's
    /// subtitle and the second search field.
    let parent: String

    var name: String { (path as NSString).lastPathComponent }

    /// ncode's frecency: 4 for a folder where Claude ran, up to 20 for
    /// recency (halved for each week since the last use), 3·log₂(1 + uses),
    /// and 2 for a repository. Higher is better.
    func frecency(now: Date) -> Double {
        var score: Double = source == .claude ? 4 : 0
        if let lastUsed {
            let days = max(0, now.timeIntervalSince(lastUsed)) / 86400
            score += 20 * pow(0.5, days / 7)
        }
        if uses > 0 { score += 3 * log2(1 + Double(uses)) }
        if branch != nil { score += 2 }
        return score
    }
}

/// The folders of the Open Project screen, ported from ncode's project
/// finder. Pure over the file system and nonisolated: the load runs off the
/// main actor, and a fake home directory is the whole test.
///
/// - Recents come from every Claude config directory (`configDirs`), merged
///   by path: the latest time wins and the use counts add up. Only the
///   `projects` keys with `lastStartTime`, and the `project` and `timestamp`
///   of each history line, are read. Prompt text is never kept.
/// - A bounded scan (`scan`) adds the project folders under the usual code
///   folders and next to the recents.
/// - The load never touches a protected folder (`isProtected`), `~/Library`
///   or `/Volumes` (`isOffLimits`): no stat, no listing, no `.git` read. So
///   opening the screen can never cause a macOS privacy prompt.
enum ProjectCandidates {
    /// One Claude Code config directory: what `CLAUDE_CONFIG_DIR` names.
    struct ConfigDir: Equatable {
        let root: String
        /// `~/.claude.json` for the default `~/.claude`, `<root>/.claude.json`
        /// for every other directory.
        let configFile: String
        var historyFile: String { (root as NSString).appendingPathComponent("history.jsonl") }
    }

    /// The folders under home that macOS guards with a privacy prompt. The
    /// load never touches them, and path mode lists none of them.
    static let protectedFolders = [
        "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
    ]
    /// The folders under home that the scan starts from, after the parents
    /// of the recents.
    static let scanFolders = ["dev", "code", "projects", "src", "Developer", "repos", "workspace", "git", "work"]
    /// A folder with one of these entries is a project, and the scan does
    /// not go into it.
    static let markers: Set<String> = [
        ".git", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "go.mod", "setup.py", "Gemfile",
        "pom.xml", "build.gradle", "CLAUDE.md",
    ]
    /// Folders that the scan never goes into. Hidden folders are skipped too.
    static let skippedFolders: Set<String> = [
        "node_modules", "Library", "build", "dist", "target", "DerivedData", "Pods", "venv", "__pycache__",
    ]
    static let scanDepth = 3
    static let scanVisitLimit = 4000

    // MARK: - Config directories

    /// `~/.claude`, then every `~/.claude-*` directory that holds a
    /// `history.jsonl` or a `.claude.json`, by name. A directory with
    /// neither (`~/.claude-cache`) is not a config directory.
    static func configDirs(home: String) -> [ConfigDir] {
        let fm = FileManager.default
        var dirs: [ConfigDir] = []
        let standard = ConfigDir(
            root: (home as NSString).appendingPathComponent(".claude"),
            configFile: (home as NSString).appendingPathComponent(".claude.json")
        )
        if fm.fileExists(atPath: standard.configFile) || fm.fileExists(atPath: standard.historyFile) {
            dirs.append(standard)
        }
        let names = ((try? fm.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".claude-") }
            .sorted()
        for name in names {
            let root = (home as NSString).appendingPathComponent(name)
            let dir = ConfigDir(root: root, configFile: (root as NSString).appendingPathComponent(".claude.json"))
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
                  fm.fileExists(atPath: dir.historyFile) || fm.fileExists(atPath: dir.configFile)
            else { continue }
            dirs.append(dir)
        }
        return dirs
    }

    /// The last start time of each `projects` key of a config file, in
    /// milliseconds since 1970 (0 when the key has none).
    static func configStartTimes(at file: String) -> [String: Double] {
        guard let data = FileManager.default.contents(atPath: file),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data)
        else { return [:] }
        return (config.projects ?? [:]).mapValues { $0.lastStartTime ?? 0 }
    }

    /// The last prompt time (milliseconds since 1970) and the prompt count
    /// of each folder in a `history.jsonl`. Each line is decoded into its
    /// `project` and `timestamp` only, so the prompt text is never kept.
    static func historyUsage(at file: String) -> [String: (last: Double, count: Int)] {
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        let decoder = JSONDecoder()
        var usage: [String: (last: Double, count: Int)] = [:]
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = try? decoder.decode(HistoryLine.self, from: line), let project = entry.project else { continue }
            let previous = usage[project] ?? (0, 0)
            usage[project] = (max(previous.last, entry.timestamp ?? 0), previous.count + 1)
        }
        return usage
    }

    /// The part of a config file that the load reads.
    private struct ConfigFile: Decodable {
        let projects: [String: ConfigProject]?
    }

    /// One `projects` entry: its start time only. Lenient, so that one odd
    /// entry does not lose the file.
    private struct ConfigProject: Decodable {
        let lastStartTime: Double?

        private enum CodingKeys: String, CodingKey {
            case lastStartTime
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            lastStartTime = try? container?.decodeIfPresent(Double.self, forKey: .lastStartTime)
        }
    }

    /// The part of a history line that the load reads. The prompt (`display`)
    /// is not a field, so the decoder skips it.
    private struct HistoryLine: Decodable {
        let project: String?
        let timestamp: Double?
    }

    // MARK: - Path rules

    /// Whether `path` is in a folder that macOS guards with a privacy
    /// prompt (`protectedFolders`), or is one. Case does not count: the
    /// default volume ignores it, so `~/documents` is `~/Documents`.
    static func isProtected(_ path: String, home: String) -> Bool {
        protectedFolders.contains { isWithin(path, (home as NSString).appendingPathComponent($0)) }
    }

    /// Whether the load must not touch `path`: a protected folder, anything
    /// in `~/Library` (other apps' data) or in `/Volumes` (a removable or
    /// network volume). Such a recent is kept as Claude recorded it, unchecked.
    static func isOffLimits(_ path: String, home: String) -> Bool {
        isProtected(path, home: home)
            || isWithin(path, (home as NSString).appendingPathComponent("Library"))
            || isWithin(path, "/Volumes")
    }

    /// Whether `path` is `root` or in it, ignoring case.
    private static func isWithin(_ path: String, _ root: String) -> Bool {
        let path = path.lowercased()
        let root = root.lowercased()
        return path == root || path.hasPrefix(root + "/")
    }

    /// Folders that are never a project: home, the root, Claude's own
    /// worktrees and temporary folders. The temporary prefixes apply only
    /// outside home, so a home in a temporary folder (a test) keeps its own.
    static func isNoise(_ path: String, home: String) -> Bool {
        if path == home || path == "/" || path.contains("/.claude/worktrees/") { return true }
        if path.hasPrefix(home + "/") { return false }
        return ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `path` with `~` for the home directory.
    static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// `path` with a leading `~` expanded against `home` (`$HOME`, not the
    /// user record, as `ProjectPath.currentHome` resolves it).
    static func expanded(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// An absolute path with no trailing slash and no empty, `.` or `..`
    /// component; nil for a relative path. Lexical only: it reads nothing on
    /// disk (Foundation's own standardizing can), so a protected path stays
    /// untouched, and symbolic links are not resolved.
    static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    // MARK: - Git

    /// The branch checked out in `path` and when its `.git` changed, read
    /// from `.git/HEAD` without running git. A worktree's `.git` file names
    /// its git directory (`gitdir:`), which holds its HEAD — unless that
    /// directory is off limits (a worktree of a repository in `~/Documents`),
    /// which gives no branch.
    static func gitInfo(at path: String, home: String) -> (branch: String?, modified: Date?) {
        let fm = FileManager.default
        let git = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: git, isDirectory: &isDirectory) else { return (nil, nil) }
        let modified = (try? fm.attributesOfItem(atPath: git))?[.modificationDate] as? Date
        let gitDirectory: String
        if isDirectory.boolValue {
            gitDirectory = git
        } else {
            guard let text = try? String(contentsOfFile: git, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return (nil, modified) }
            let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let absolute = named.hasPrefix("/") ? named : (path as NSString).appendingPathComponent(named)
            gitDirectory = normalized(absolute) ?? absolute
            guard !isOffLimits(gitDirectory, home: home) else { return (nil, modified) }
        }
        let head = (gitDirectory as NSString).appendingPathComponent("HEAD")
        guard let text = try? String(contentsOfFile: head, encoding: .utf8) else { return (nil, modified) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) { return (String(trimmed.dropFirst(prefix.count)), modified) }
        return (trimmed.isEmpty ? nil : String(trimmed.prefix(7)), modified)
    }

    // MARK: - Scan

    /// The project folders under `roots`: a folder below a root with a
    /// marker entry (`markers`) is a project, and the scan does not go into
    /// it. At most `depth` levels below a root and `visitLimit` folders in
    /// all. It skips hidden and `skippedFolders` folders, never follows a
    /// symbolic link, and never enters an off-limits folder.
    static func scan(
        roots: [String],
        home: String,
        depth: Int = scanDepth,
        visitLimit: Int = scanVisitLimit
    ) -> [String] {
        var found: [String] = []
        var visited = Set<String>()
        func walk(_ directory: String, level: Int) {
            guard level <= depth, visited.count < visitLimit, visited.insert(directory).inserted else { return }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return }
            if level > 0, children.contains(where: { markers.contains($0.lastPathComponent) }) {
                found.append(directory)
                return
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                guard !name.hasPrefix("."), !skippedFolders.contains(name) else { continue }
                let values = try? child.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let path = (directory as NSString).appendingPathComponent(name)
                guard !isOffLimits(path, home: home) else { continue }
                walk(path, level: level + 1)
            }
        }
        for root in roots where !isOffLimits(root, home: home) && !linksOffLimits(root, home: home) {
            walk(root, level: 0)
        }
        return found
    }

    /// Whether `path` is a symbolic link to an off-limits folder (`~/code`
    /// linked into `~/Documents`): a listing would follow it. Reads the link
    /// only, never its target.
    static func linksOffLimits(_ path: String, home: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        let absolute = target.hasPrefix("/") ? target : ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(target)
        return isOffLimits(normalized(expanded(absolute, home: home)) ?? absolute, home: home)
    }

    /// The folders the scan starts from: `scanFolders` under home, then the
    /// folder of each recent that is below home and not off limits.
    static func scanRoots(home: String, recents: [String]) -> [String] {
        var roots = scanFolders.map { (home as NSString).appendingPathComponent($0) }
        let parents = Set(recents.map { ($0 as NSString).deletingLastPathComponent })
            .filter { $0 != home && $0.hasPrefix(home + "/") && !isOffLimits($0, home: home) }
        roots += parents.sorted()
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    // MARK: - Load

    /// Every candidate for `home`, best frecency first. Reads every config
    /// directory, drops noise and recents that are gone (an off-limits
    /// recent is kept unchecked), then adds the scan's folders.
    static func load(home: String, now: Date = Date()) -> [ProjectCandidate] {
        var last: [String: Double] = [:]
        var uses: [String: Int] = [:]
        var fromClaude = Set<String>()
        for dir in configDirs(home: home) {
            for (raw, time) in configStartTimes(at: dir.configFile) {
                guard let path = normalized(raw) else { continue }
                fromClaude.insert(path)
                last[path] = max(last[path] ?? 0, time)
            }
            for (raw, usage) in historyUsage(at: dir.historyFile) {
                guard let path = normalized(raw) else { continue }
                fromClaude.insert(path)
                last[path] = max(last[path] ?? 0, usage.last)
                uses[path, default: 0] += usage.count
            }
        }

        let fm = FileManager.default
        var candidates: [String: ProjectCandidate] = [:]
        for path in fromClaude where !isNoise(path, home: home) {
            let offLimits = isOffLimits(path, home: home)
            if !offLimits {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            }
            let git = offLimits ? (branch: nil, modified: nil) : gitInfo(at: path, home: home)
            let time = last[path] ?? 0
            candidates[path] = ProjectCandidate(
                path: path,
                source: .claude,
                lastUsed: time > 0 ? Date(timeIntervalSince1970: time / 1000) : nil,
                uses: uses[path] ?? 0,
                branch: git.branch,
                gitModified: git.modified,
                parent: abbreviated((path as NSString).deletingLastPathComponent, home: home)
            )
        }

        for path in scan(roots: scanRoots(home: home, recents: Array(candidates.keys)), home: home)
            where candidates[path] == nil && !isNoise(path, home: home)
        {
            let git = gitInfo(at: path, home: home)
            candidates[path] = ProjectCandidate(
                path: path,
                source: .scan,
                lastUsed: nil,
                uses: 0,
                branch: git.branch,
                gitModified: git.modified,
                parent: abbreviated((path as NSString).deletingLastPathComponent, home: home)
            )
        }
        return ranked(Array(candidates.values), now: now)
    }

    /// Best frecency first; a tie to the newer `.git`, then the path.
    static func ranked(_ candidates: [ProjectCandidate], now: Date) -> [ProjectCandidate] {
        candidates
            .map { (candidate: $0, score: $0.frecency(now: now)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lhsGit = lhs.candidate.gitModified ?? .distantPast
                let rhsGit = rhs.candidate.gitModified ?? .distantPast
                if lhsGit != rhsGit { return lhsGit > rhsGit }
                return lhs.candidate.path < rhs.candidate.path
            }
            .map(\.candidate)
    }

    /// The search index over `candidates`: the folder's name is the title
    /// field and its parent the second. Not the full path: with it, `maple`
    /// would match `mine/applet-hub`.
    static func searchIndex(for candidates: [ProjectCandidate]) -> SearchIndex {
        SearchIndex(candidates.map { [$0.name, $0.parent] })
    }

    // MARK: - Cache

    /// A load is used again for this long, unless a config or history file
    /// changed.
    static let timeToLive: TimeInterval = 60

    private struct CacheEntry {
        let loadedAt: Date
        let signature: [String: Date]
        let candidates: [ProjectCandidate]
    }

    /// The last load for each home directory.
    private static let cache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])

    /// The modification time of every config and history file. A change
    /// (Claude ran somewhere new) makes the next read load again.
    private static func signature(home: String) -> [String: Date] {
        var signature: [String: Date] = [:]
        for dir in configDirs(home: home) {
            for file in [dir.configFile, dir.historyFile] {
                signature[file] = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
                    ?? .distantPast
            }
        }
        return signature
    }

    /// The candidates for `home`: the last load while it is younger than
    /// `timeToLive` and no config or history file changed, else a new load.
    /// Blocking: call it off the main actor.
    static func cached(home: String, now: Date = Date()) -> [ProjectCandidate] {
        let current = signature(home: home)
        if let entry = cache.withLock({ $0[home] }),
           now.timeIntervalSince(entry.loadedAt) < timeToLive,
           entry.signature == current
        {
            return entry.candidates
        }
        let candidates = load(home: home, now: now)
        cache.withLock { $0[home] = CacheEntry(loadedAt: now, signature: current, candidates: candidates) }
        return candidates
    }

    /// The last load for `home`, however old, for a screen to show at once
    /// while it loads again. Nil before the first load.
    static func latest(home: String) -> [ProjectCandidate]? {
        cache.withLock { $0[home]?.candidates }
    }

    /// Load once in the background, so that the first open of the screen
    /// shows its rows at once.
    static func prewarm(home: String = ProjectPath.currentHome) {
        Task.detached(priority: .utility) {
            _ = cached(home: home)
        }
    }
}
