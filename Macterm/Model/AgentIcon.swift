import Foundation

/// A bundled AI coding-agent logo, matched from a pane's live foreground
/// process so the sidebar shows *which* agent runs in a tab instead of the
/// generic tab icon. The raw value is the asset-catalog image name (a
/// monochrome template image, tinted like an SF Symbol).
enum AgentIcon: String, CaseIterable {
    case claude = "AgentClaude"
    case codex = "AgentCodex"
    case opencode = "AgentOpenCode"
    case cursor = "AgentCursor"
    case gemini = "AgentGemini"
    case copilot = "AgentCopilot"
    case grok = "AgentGrok"
    case pi = "AgentPi"
    case antigravity = "AgentAntigravity"
    case omp = "AgentOmp"

    /// Agent CLI names, matched against a process's kernel `comm` (the
    /// executable's basename, truncated to 15 chars) and its invoked name
    /// (argv-derived). Both are needed: an agent's *binary* often isn't named
    /// after the CLI — brew's codex is `codex-aarch64-apple-darwin` (comm
    /// `codex-aarch64-a`), and Claude Code's native install execs a versioned
    /// binary whose comm is the bare version (`2.1.207`) while argv[0] stays
    /// `claude`. Internal (not private) so a guard test can assert every case
    /// keeps a mapping here.
    static let processNames: [String: AgentIcon] = [
        "claude": .claude,
        "codex": .codex,
        "opencode": .opencode,
        "cursor-agent": .cursor,
        "gemini": .gemini,
        "copilot": .copilot,
        "grok": .grok,
        "pi": .pi,
        "agy": .antigravity,
        "omp": .omp,
    ]

    /// The agent running as `processName`, or nil for anything else
    /// (shells, ordinary programs, nil before the surface exists). An exact
    /// match wins; otherwise a known name followed by a non-alphanumeric
    /// separator matches (`codex-aarch64-a` → codex), so arch/version suffixes
    /// don't defeat detection while `claudette` still doesn't match `claude`.
    static func match(processName: String?) -> AgentIcon? {
        guard let name = processName?.lowercased() else { return nil }
        if let exact = processNames[name] { return exact }
        // Longest key first, so a future short alias that prefixes a longer
        // name can't win by nondeterministic dictionary order.
        for (key, icon) in processNames.sorted(by: { $0.key.count > $1.key.count }) where name.hasPrefix(key) {
            if let next = name.dropFirst(key.count).first, !next.isLetter, !next.isNumber {
                return icon
            }
        }
        return nil
    }

    /// Match against the kernel `comm` first (already in hand from the poll),
    /// falling back to the process's argv: the invoked name, then the
    /// Cursor `agent` alias. The argv is read lazily, one time, and ONLY
    /// when `comm` cannot name the CLI itself: an opaque versioned binary
    /// (Claude Code's native install) or an interpreter (npm-installed CLIs
    /// run as `node script`). A real process name that simply isn't an
    /// agent (bash, hx, btop…) must not cost a `KERN_PROCARGS2` read on the
    /// default poll.
    static func match(comm: String?, argv: () -> [String]?) -> AgentIcon? {
        matchComm(comm) {
            guard let args = argv() else { return nil }
            if let icon = match(processName: ProcessInspector.invokedName(argv: args)) { return icon }
            return isCursorAgentAlias(comm: comm, argv: args) ? .cursor : nil
        }
    }

    /// The remote stand-in for `match(comm:argv:)`. The host's report
    /// carries the command line (`ps -o args=`) in place of the local argv.
    /// `remoteInvokedNames` reads the invoked name from it, and the Cursor
    /// alias reads its words. `args` loses argv's quoting, so an argv[0]
    /// with a space in it does not match the alias here.
    static func match(comm: String?, commandLine: String?) -> AgentIcon? {
        matchComm(comm) {
            guard let commandLine else { return nil }
            for name in ProcessInspector.remoteInvokedNames(commandLine: commandLine) {
                if let icon = match(processName: name) { return icon }
            }
            let words = commandLine.split(separator: " ").map(String.init)
            return isCursorAgentAlias(comm: comm, argv: words) ? .cursor : nil
        }
    }

    /// Whether `argv` is the Cursor CLI run by its short alias `agent`.
    ///
    /// The Cursor CLI installs two symlinks, `~/.local/bin/cursor-agent` and
    /// `~/.local/bin/agent`, to a bash wrapper that ends in
    /// `exec -a "$0" node … ~/.local/share/cursor-agent/versions/<v>/index.js`.
    /// So comm is `node`, and argv[0] is the name the user typed. For
    /// `cursor-agent` the invoked name matches. For `agent` it does not.
    ///
    /// `agent` is not in `processNames`, because `match(processName:)` also
    /// runs on a bare comm: the Datadog `agent` binary and any `agent-*`
    /// binary would match. An interpreter comm alone is not sufficient
    /// either: `invokedName` strips script extensions, so `python agent.py`
    /// and `node agent.js` also give `agent`. So all three must hold:
    /// - comm is an interpreter;
    /// - the basename of argv[0] itself (not the script) is `agent`;
    /// - a later argument is a path with a component that is exactly
    ///   `cursor-agent` (the wrapper's `…/cursor-agent/versions/<v>/index.js`).
    ///
    /// Both names ignore case, as the rest of the matcher does: on a
    /// case-insensitive disk, `Agent` runs the same wrapper with `$0` set to
    /// `…/bin/Agent`. The rule needs the installer's layout
    /// (`…/cursor-agent/versions/<v>/`), so an install that puts the bundle
    /// under another folder name shows the logo for `cursor-agent` but not
    /// for `agent`.
    static func isCursorAgentAlias(comm: String?, argv: [String]) -> Bool {
        guard let comm, ProcessInspector.isInterpreterName(comm),
              let first = argv.first, (first as NSString).lastPathComponent.lowercased() == "agent"
        else { return false }
        return argv.dropFirst().contains { argument in
            argument.contains("/") && argument.lowercased().split(separator: "/").contains("cursor-agent")
        }
    }

    /// The shared core of both `match(comm:…)` forms: `comm` first, then
    /// `fallback` only when `comm` cannot name the CLI (a bare version, an
    /// interpreter, or no comm at all).
    private static func matchComm(_ comm: String?, orElse fallback: () -> AgentIcon?) -> AgentIcon? {
        if let icon = match(processName: comm) { return icon }
        if let comm {
            guard ProcessInspector.looksLikeVersionString(comm)
                || ProcessInspector.isInterpreterName(comm)
            else { return nil }
        }
        return fallback()
    }
}
