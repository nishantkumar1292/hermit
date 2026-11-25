import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentIconTests {
    @Test
    func matches_known_agent_process_names() {
        #expect(AgentIcon.match(processName: "claude") == .claude)
        #expect(AgentIcon.match(processName: "codex") == .codex)
        #expect(AgentIcon.match(processName: "opencode") == .opencode)
        #expect(AgentIcon.match(processName: "cursor-agent") == .cursor)
        #expect(AgentIcon.match(processName: "gemini") == .gemini)
        #expect(AgentIcon.match(processName: "copilot") == .copilot)
        #expect(AgentIcon.match(processName: "grok") == .grok)
        #expect(AgentIcon.match(processName: "pi") == .pi)
        #expect(AgentIcon.match(processName: "agy") == .antigravity)
        #expect(AgentIcon.match(processName: "omp") == .omp)
    }

    @Test
    func match_is_case_insensitive() {
        #expect(AgentIcon.match(processName: "Claude") == .claude)
    }

    @Test
    func matches_suffixed_binary_names() {
        // brew's codex binary is `codex-aarch64-apple-darwin`; the kernel comm
        // truncates it to 15 chars.
        #expect(AgentIcon.match(processName: "codex-aarch64-a") == .codex)
        #expect(AgentIcon.match(processName: "claude.bak") == .claude)
    }

    @Test
    func prefix_match_requires_a_separator() {
        // A known name followed by more letters is a different program.
        #expect(AgentIcon.match(processName: "claudette") == nil)
        #expect(AgentIcon.match(processName: "grokify") == nil)
    }

    @Test
    func shells_and_ordinary_programs_do_not_match() {
        #expect(AgentIcon.match(processName: "zsh") == nil)
        #expect(AgentIcon.match(processName: "btop") == nil)
        #expect(AgentIcon.match(processName: nil) == nil)
    }

    @Test
    func comm_match_wins_without_reading_argv() {
        var argvRead = false
        let icon = AgentIcon.match(comm: "codex") { argvRead = true
            return nil
        }
        #expect(icon == .codex)
        #expect(!argvRead)
    }

    @Test
    func falls_back_to_argv0_when_comm_is_opaque() {
        // Claude Code's native install execs a versioned binary: comm is the
        // bare version, argv[0] stays `claude`.
        #expect(AgentIcon.match(comm: "2.1.207") { ["claude"] } == .claude)
        #expect(AgentIcon.match(comm: "2.1.207") { nil } == nil)
    }

    @Test
    func falls_back_to_script_name_for_interpreter_comms() {
        // npm-installed CLIs run as `node <bin script>`: comm is the
        // interpreter, the invoked-name fallback yields the script name.
        #expect(AgentIcon.match(comm: "node") { ["node", "/usr/local/lib/node_modules/.bin/pi"] } == .pi)
        #expect(AgentIcon.match(comm: "node") { ["node", "/x/node_modules/.bin/webpack"] } == nil)
    }

    @Test
    func real_nonagent_comms_never_pay_for_an_argv_read() {
        // The fallback exists only for comms that can't name the CLI (versions,
        // interpreters). An ordinary process name must not cost a syscall on
        // the default poll.
        var argvRead = false
        for comm in ["bash", "hx", "btop", "claudette"] {
            #expect(AgentIcon.match(comm: comm) { argvRead = true
                return ["claude"]
            } == nil)
        }
        #expect(!argvRead)
        // No comm at all still consults argv (nothing else to go on).
        #expect(AgentIcon.match(comm: nil) { ["claude"] } == .claude)
    }

    // MARK: - Cursor `agent` alias

    /// The Cursor CLI's `agent` symlink, as `ps` shows it: the bash wrapper
    /// runs `exec -a "$0" node $NODE_FLAGS …/index.js "$@"`, so comm is
    /// `node` and argv[0] is the typed path.
    private static let cursorScript = "/Users/me/.local/share/cursor-agent/versions/2026.11.19-f005e9d/index.js"
    private static let agentPath = "/Users/me/.local/bin/agent"

    @Test
    func cursor_alias_matches_with_each_node_flags_variant() {
        let variants: [[String]] = [
            [],
            ["--disable-sigusr1"],
            ["--use-system-ca"],
            ["--disable-sigusr1", "--use-system-ca"],
        ]
        for flags in variants {
            let argv = [Self.agentPath] + flags + [Self.cursorScript]
            #expect(AgentIcon.match(comm: "node") { argv } == .cursor)
            // The user's own arguments follow the script.
            #expect(AgentIcon.match(comm: "node") { argv + ["--resume", "fix the build"] } == .cursor)
        }
    }

    @Test
    func cursor_alias_reads_argv_one_time() {
        var argvReads = 0
        let icon = AgentIcon.match(comm: "node") {
            argvReads += 1
            return [Self.agentPath, "--use-system-ca", Self.cursorScript]
        }
        #expect(icon == .cursor)
        #expect(argvReads == 1)
    }

    @Test
    func cursor_agent_name_still_matches_under_node() {
        let argv = ["/Users/me/.local/bin/cursor-agent", "--use-system-ca", Self.cursorScript]
        #expect(AgentIcon.match(comm: "node") { argv } == .cursor)
    }

    @Test
    func cursor_alias_ignores_case() {
        // On a case-insensitive disk, `Agent` runs the same wrapper with
        // `$0` set to `…/bin/Agent`.
        #expect(AgentIcon.match(comm: "node") { ["/Users/me/.local/bin/Agent", Self.cursorScript] } == .cursor)
        #expect(AgentIcon.match(comm: "node") {
            [Self.agentPath, "/Users/me/.local/share/Cursor-Agent/versions/1/index.js"]
        } == .cursor)
    }

    @Test
    func agent_without_the_cursor_shape_does_not_match() {
        // A script named `agent` gives the invoked name `agent` too.
        #expect(AgentIcon.match(comm: "python3") { ["python3", "agent.py"] } == nil)
        #expect(AgentIcon.match(comm: "python") { ["python", "/srv/bot/agent.py"] } == nil)
        #expect(AgentIcon.match(comm: "node") { ["node", "agent.js"] } == nil)
        // The invoked name is `agent` through the script, not through argv[0],
        // so a `cursor-agent` component does not make it the alias.
        #expect(AgentIcon.match(comm: "node") { ["node", "/x/cursor-agent/versions/1/agent.js"] } == nil)
        // argv[0] is `agent`, but the script is not under `cursor-agent`.
        #expect(AgentIcon.match(comm: "node") { [Self.agentPath, "/opt/other/index.js"] } == nil)
        // A component that only contains the text is not `cursor-agent`.
        #expect(AgentIcon.match(comm: "node") {
            [Self.agentPath, "/x/my-cursor-agent-fork/index.js"]
        } == nil)
        // A bare word is not a path.
        #expect(AgentIcon.match(comm: "node") { [Self.agentPath, "cursor-agent"] } == nil)
    }

    @Test
    func agent_comm_never_reads_argv() {
        // A binary named `agent` (Datadog's, for one) is not an interpreter,
        // so argv is never read, even when it has the Cursor shape.
        var argvRead = false
        let icon = AgentIcon.match(comm: "agent") {
            argvRead = true
            return [Self.agentPath, Self.cursorScript]
        }
        #expect(icon == nil)
        #expect(!argvRead)
    }

    @Test
    func cursor_alias_needs_an_interpreter_comm() {
        // The fallback also runs for a bare-version comm and for no comm.
        // The alias must still require an interpreter.
        let argv = [Self.agentPath, Self.cursorScript]
        #expect(AgentIcon.match(comm: "2.1.207") { argv } == nil)
        #expect(AgentIcon.match(comm: nil) { argv } == nil)
        #expect(!AgentIcon.isCursorAgentAlias(comm: nil, argv: argv))
        #expect(AgentIcon.isCursorAgentAlias(comm: "node", argv: argv))
    }

    // MARK: - Remote command line

    @Test
    func remote_command_line_matches_the_cursor_alias() {
        let command = "\(Self.agentPath) --disable-sigusr1 --use-system-ca \(Self.cursorScript) --resume"
        #expect(AgentIcon.match(comm: "node", commandLine: command) == .cursor)
        #expect(AgentIcon.match(comm: "node", commandLine: "\(Self.agentPath) \(Self.cursorScript)") == .cursor)
    }

    @Test
    func remote_command_line_keeps_the_other_rules() {
        #expect(AgentIcon.match(
            comm: "node",
            commandLine: "node /usr/local/lib/node_modules/@google/gemini-cli/bin/gemini"
        ) == .gemini)
        // A script path with a space: `remoteInvokedNames` offers `My`, then
        // `gemini`, and the first one that names an agent wins.
        #expect(AgentIcon.match(
            comm: "node",
            commandLine: "node /home/me/My Tools/gemini-cli/bin/gemini --yolo"
        ) == .gemini)
        #expect(AgentIcon.match(comm: "2.1.207", commandLine: "claude --resume") == .claude)
        #expect(AgentIcon.match(comm: "node", commandLine: nil) == nil)
        #expect(AgentIcon.match(comm: "node", commandLine: "node agent.js") == nil)
        #expect(AgentIcon.match(comm: "node", commandLine: "\(Self.agentPath) /opt/other/index.js") == nil)
        // A comm that names a program stops the match before the command line.
        #expect(AgentIcon.match(comm: "agent", commandLine: "\(Self.agentPath) \(Self.cursorScript)") == nil)
    }

    @Test
    func every_case_has_a_process_name_mapping() {
        // `processNames` is hand-maintained; a new case + asset without a dict
        // entry would be a silent no-op. Keep them in lockstep.
        #expect(Set(AgentIcon.processNames.values) == Set(AgentIcon.allCases))
    }
}
