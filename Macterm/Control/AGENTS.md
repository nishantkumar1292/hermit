# The control CLI

This file loads when you work in `Macterm/Control/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Control CLI (`macterm`)

A bundled CLI controls the app over `<App Support>/control.sock` (target `MactermCLI`, and `PRODUCT_MODULE_NAME` must stay `MactermCLI`). Xcode copies it to `Contents/Resources/bin/macterm`. Every pane gets it in `PATH`, together with `MACTERM_SOCKET` and `MACTERM_SESSION`. The full grammar is in `docs/80-cli.md`.

The verbs:

- `status`
- `project list/create/select/rename/remove`
- `tab list/new/select/move/rename/close/merge`
- `pane list/inspect/dump/split/focus/close/run/key/zoom/resize-split/mirror`
- `grid RxC`
- `session list/info/kill`
- `window list/new/focus/close`
- `widget list/new/set/edit/done/remove`
- `layout apply/save`
- `palette list` (the palette files of the extensions, read again each time, with the error of each one). The hidden `palette exec` is the runner of a `run:` action (`CustomPaletteLaunch`).
- `tutor`
- `ssh` (offline, the `+ssh` of ghostty natively through `SSHWrapper`)
- `skills` (offline, the agent skills below)

Rules:

- **Wire protocol** (`ControlProtocol.swift`, compiled into both targets). One request is one JSON line that ends with a newline, for each connection: `{v, id, command, args}`, with `noun.verb` commands. The responses are `{ok, data}` or `{ok:false, error:{code, message, action?}}`. The codes are in snake_case (`not_found`, `busy`, `no_surface`, `starting`, `ambiguous`).
  - The `v` of a request is the minimum version of the server that it needs. Ordinary requests stay at v1. `focus` needs v2. The handler rejects newer versions before dispatch.
  - Apps of v1 that shipped earlier ignore `v`. The CLI must therefore check newer requests against the version in the response of the server before it sends any mutation. A new version number alone cannot stop an older app from ignoring `--no-focus` in silence.
- **Server** (`ControlSocketServer`). A dedicated thread polls a non-blocking listen fd. The dispatch of each connection hops to `@MainActor`. The server starts in `applicationDidFinishLaunching`. The handler attaches in `installResponders` (early requests get `starting`). The socket has mode 0600 in a directory with mode 0700, for the same user only.
- **Handler** (`ControlHandler`). It translates and delegates only. It resolves selectors (name, UUID, index from 1). It calls the same `AppState`, `ProjectStore` and `ZmxClient` methods that the UI uses. Close verbs return a typed `busy` error, and they do not stage dialogs. A session selector with no `--project` resolves in the project that holds the session (`MACTERM_SESSION` arrives in the same way). A pane in the background can therefore still reach itself while the user looks at another project.
- **Client.**
  - Discovery order: `--socket`, then `MACTERM_SOCKET` (a hint, and the client falls through when it is stale), then the paths in App Support for each flavor.
  - stdout has output only on success. The exit code is 0 for ok, 1 for an error of the app, 2 for not reachable.
  - **Targeting trap:** a `--socket` that is not pinned, from a debug harness, can hit the live app of the developer. An untargeted `pane run` then types into their focused pane.
  - `pane run` therefore types as given only what follows `--`. Before `--`, its own flags parse at any place, and plain words are typed. Any other word with a leading dash fails validation, and Macterm sends nothing.
  - Its text is one `.allUnrecognized` array that Macterm splits at the `--` by hand. A second array with `.postTerminator` fails the validation of ArgumentParser in debug builds.
  - `ssh` keeps `.captureForPassthrough`. It mirrors the own argv of ssh. It answers a leading `-h` or `--help` itself (`startsWithHelpFlag`).
- **Agent skills** (`macterm skills`). There are four Agent Skills (panes, workspace, sub-agents, palettes). They are `SKILL.md` files in the format of agentskills.io. They teach coding agents this CLI.
  - They are compiled into the binary from `Macterm/Control/AgentSkills/` (shared with the CLI target, like `ControlProtocol`). The CLI prints them offline: every skill after a header about the install, or one skill as it is. Agents install them themselves.
  - Agents load one skill at a time, so each skill embeds `AgentSkills.groundRules`.
  - We ran every example against a hermetic instance before it shipped. Keep it that way.
  - `AgentSkillsTests` runs every `macterm …` line in them against the tree of `--experimental-dump-help` of the bundled CLI. If you rename a verb or a flag, a test fails until the skills follow.
- **`tab new --no-focus` and `pane split --no-focus`** send the optional `ControlArgs.focus = false` (absent means true).
  - Creation skips the selection at the mutation of the model. It never selects and then restores. The history of tabs and panes and the selections of windows stay untouched. A split with no focus keeps the zoom. An empty workspace adopts its first tab with no history, because there is no selection to keep.
  - `AppState.createTab` and `splitPane` incubate only children that no window renders (this includes panes that zoom hides). Visible splits then start at their real size.
  - Every warm goes through `warmPane`: project selection, the restore of pinned tabs and the creation by the CLI. The `incubatePane` that you can inject supplies the surface. One exit closure reads `pane.projectID` at the time of the exit, so that moving a tab cannot strand it.
  - A background split starts only the new pane. The other panes of a project that no window showed yet start when the project is selected.
  - The view slot is not observed, so the warm stays synchronous with the structural redraw. A window that is ordered out still mounts new children (E2E pins this). Children that zoom hides do need incubation.
  - Remote tabs get `project.zmxPath` before the warm. A split stamps the whole target tab, so the new sibling inherits the path of the source.
  - The start is asynchronous. It is not a promise that the shell prompt is ready when the CLI returns.
- `pane run` types through the paste path (`sendText`). `--no-submit` withholds the newline and keeps the evidence of a submission armed. `pane key <chord>` uses the key-encoding path (`sendKey`) and **bypasses `keyDown`**, so the interceptions of `keyDown` do not apply. A bare printable key must carry `.text`, or it encodes to nothing. `pane resize` exists only under `#if DEBUG`.

- `Macterm/Control/`: `ControlProtocol` (shared with the CLI), `ControlSocketServer`, `ControlHandler`, and `AgentSkills/` (the text of `macterm skills`, shared with the CLI).
- `CLI/`: the `macterm` binary. `MactermCommand` (the ArgumentParser tree), `ControlClient`, `Output`, `SSHCommand`, `TutorCommand`, `SkillsCommand`, `WidgetCommand`, `PaletteCommand` (`palette list`, and the hidden runner `palette exec`), `AskpassCommand` (the hidden `askpass`, and the debug-only `host`), and `RemotePaneCommand` (the hidden `remote-pane`, the client on a remote pane's tty).
