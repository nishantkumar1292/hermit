# The app: windows, keys, tabs, passwords, pinned tabs, widgets, Finder and Dock

This file loads when you work in `Macterm/App/`. The root `AGENTS.md` has the build, the architecture and the conventions.

The rules for the adaptive icon code in this folder (`AdaptiveIcon…`, `AppIconPresenter`) are in `IconRenderer/AGENTS.md`.

## Windows (#345, #353)

These rules make many windows work over one model:

- **The registry is keyed by `NSWindow`** (`AppState.windows`, a weak-keyed `NSMapTable`). SwiftUI makes a view and its `@State` more than one time for each real window, so the view cannot own the identity. The first `WindowState` that someone proposes for an `NSWindow` wins (`canonicalWindowState`). Register when the window attaches to the `NSWindow`. Never register in `onAppear`. Never stamp the SwiftUI window identifier.
- **A window registers when AppKit attaches its `WindowStyler` view** (`WindowAttachmentView.viewDidMoveToWindow`). Never poll `view.window` with a limit on main-queue turns. SwiftUI can make the view before its window exists, and an idle main queue runs 30 turns in a few milliseconds. A window that `window new` opened during launch then never registered: it showed its sidebar and no terminal, and `window list` did not show it.
- **There is one teardown entry**. `AppState.windowDidClose` clears every table that is for one window. A new table for one window must hang off it. Key it weakly by the window. Never key it by `ObjectIdentifier`, because Swift uses an address again.
- **App-wide values mirror the key window**. `noteKeyWindow` pushes `AppState.activeProjectID`, `Workspace.activeTabID`, `sidebarVisible`, `isCommandPaletteVisible` and similar values from the `WindowState` of the key window, and into it. Anything that you *render* for one window must read `WindowState`. It must never read the mirror. Something that happens *to* a project (a click on a notification, CLI `pane focus`) goes through `revealProject`. That function brings forward a window that already shows the project.
- **The real panes of a tab render in one window. Other windows on that tab render a mirror**. `tabOwners` is sticky (`reconcileWindowViews` settles it). A window that is not the owner gets a *shadow* tab of `Pane(mirroring:)` panes. They are connected to the same zmx sessions. Macterm builds the shadow tab again when the `shapeSignature` of the real tab changes. `WorkspaceView` maps the focus, zoom, split and click of a mirror onto the real tab by the position in the tree (`counterpartPaneID`). The pinned workspace has **no tab selection for each window**. Every path that reads `activeTabIDs` skips the sentinel.
- **Only `reconcileWindowViews` builds a shadow. `viewTab(for:in:)` is a pure read**. It returns the real tab for the owner, the shadow in `WindowState.shadowTabs` for any other window, and nil when there is none. It never allocates. The reconcile builds or refreshes the shadow of every window in `AppState.renderingWindows` that selects a tab it does not own, and it drops the rest. It runs inside every mutation that changes what a window shows: register, unregister, key window change, a project or tab selection in a window, `restoreWindows`, and `saveWorkspaces`, which follows every structural mutation (a split, a closed pane, a merge, a layout, `pane mirror`). It is cheap and idempotent, so add a call where a new mutation changes a tab's shape or a window's selection. Zoom changes no shape. Before this rule, `viewTab` built the shadow as a side effect of rendering. Every window that asked got a fresh tab of mirror panes, each one a zmx client, and no reconcile dropped it. Each stray client that we found (#353, #359, #366, #557, #657) was one more caller that nobody had guarded.
- **`renderingWindows` is the one set of windows that can own a tab and that can get a shadow**. It is the registered windows, plus the scene's own window from the moment `restoreWindows` adopts it, before it registers (`windowAdoptedBeforeRegistration`). A window outside the set renders nothing: a closed window whose SwiftUI view lives on, or a window that has not registered yet. It gets no shadow, however often its view renders. `registerWindow` lists a window before it applies the saved frame, and the reconcile at the end of registration gives it its tab.
- **Session leadership**. Only one zmx client is the leader. Its size sets the size of the pty. The other clients render dimmed. `AppState.sessionLeaders` tracks the leader. An APC claim tells zmx (`ZmxLeadership.claimSequence`, a wire contract with the zmx fork). Leadership follows the tab of the key window as a whole (`claimLeadershipForKeyWindow`). Macterm asserts the records again. It never trusts them. It sends the claim only when leadership moves, synchronously. It records the claim only if zmx received it. It never sends the claim on focus for remote panes. **A local pane in the key window's tab claims when its surface has a size and the pane has printed its first output (`LeadershipClaimReadiness`: before it, the pty echoes the claim as text), also when the model counts one client** (`surfaceDidGetSize`, `assertSessionLeadership`). `isMirrored` counts only the clients that Macterm knows of. A client from outside the model attaches first and leads, and zmx then drops the control keys of the visible pane. The claim is a no-op in zmx for a client that already leads. A window that is not the key window and whose tab has only panes that are not leaders renders `MirroredTabNotice` and not panes. The key window always renders its panes. After that, the first responder is restored through `FocusRestoration.restoreFocusWhenAttached`. It finds the window from the own view of the pane.
- **Closing and quitting**. Only the **last visible** terminal window hides when you close it (`AppDelegate.hidesInsteadOfClosing`). Every other window really closes. A quit freezes the window list (`unregisterWindow` does nothing under `AppTerminationState.isTerminating`). Without this, each window that closes would save a snapshot again with one window fewer. `restoreWindows` gives the first saved entry to the own window of the scene. It opens the others with `applicationOpenUntitledFile`. It fronts the saved key window last.
- **`AppDelegate.isTerminalWindowCandidate` answers "Is this the terminal window?"** Do not use `!(window is NSPanel)`. The function excludes marker subclasses (`QuickTerminalPanel`, `SurfaceIncubatorWindow`). Send any new auxiliary window through it. It is a heuristic. Use it only before `didBecomeMain` has cached the real pointer.
- **Macterm activates the app for a window that opens from the quick terminal while the app is inactive** (`QuickTerminalService.panelDidResignKey` → `AppDelegate.activateForKeyHandoff`). The panel does not activate the app, and it takes keys while another app is frontmost. If you type ⌘, or ⌘N into it, Settings or a new window becomes key in an inactive app. That window is dimmed and you cannot type in it. Macterm watches the handoff for one run-loop turn (the new window becomes key synchronously when the panel resigns). It forces the activation with `ignoringOtherApps: true`. That one activation skips `reopenIfNeeded`. Without this, a terminal window that is hidden comes to the front over the window that the keystroke asked for.
- **A launch that does not front the app builds no window (#241)**. This is how macOS opens apps again at login. `AppDelegate.repairMissingWindow` polls for about 3 seconds. Only if no candidate window exists, it calls `applicationOpenUntitledFile` (activation alone does nothing). The condition is "no window at all". `requestInitialWindow` debounces the call. Without these, one launch opens two windows.
- `AppDelegate.reopenIfNeeded` (the Dock click that brings the app to the front again) uses an `NSWorkspace.didActivateApplicationNotification` observer. `applicationShouldHandleReopen` is not reliable through `@NSApplicationDelegateAdaptor`. Observers that you install in `applicationDidFinishLaunching` miss window notifications at launch. On launches from the Dock or Finder, `didBecomeMain` can fire before `applicationDidFinishLaunching`.
- **Full screen is native, and fn+F belongs to AppKit**. The `toggle_fullscreen` action of ghostty (⌃⌘F and ⌘↩ by default) toggles the own window of the pane through `toggleFullScreen(_:)` (`GhosttyCallbacks`). This is the same path as the automatic Enter Full Screen menu item of AppKit. That item carries fn+F of macOS. Leave that item alone. Do not set `NSFullScreenMenuItemEverywhere` to false. Do not change its shortcut. Ghostty.app lost fn+F when it rewrote the shortcut of its full-screen item (ghostty-org/ghostty#1389). Macterm does not honor `macos-non-native-fullscreen`. The panel of the quick terminal cannot go full screen.

## Hotkeys

`HotkeyAction` and `HotkeyRegistry` hold the bindings. The defaults are in `Hotkeys.swift`. Overrides are at `macterm.hotkey.<action_id>`. `KeyRouter` installs one `NSEvent.addLocalMonitorForEvents`. It dispatches through the ordered `KeyResponder` chain in `Responders.swift`. `isAppShortcut` in `GhosttyTerminalNSView` lets registered shortcuts pass the terminal.

**Passthrough (#209)**. An action can opt in with the suffix `.passthrough`. Then Macterm gives the chord to the program in the focused pane when the name of that program is in `Preferences.passthroughPrograms`. `KeybindPassthrough` owns the policy. Both key paths (the responders *and* `isAppShortcut`) read it. Remote panes never yield. We tried two times to infer the condition (tty raw mode, "not a shell"), and both failed. Read the doc comment of the type before you try again.

**Global keybinds**. An action can opt in with the suffix `.global`. It is an item in the menu of its row in Settings → Keymaps, next to passthrough. Macterm then registers the chord as a Carbon `RegisterEventHotKey`, so it fires while another app is frontmost. This is the `global:` prefix of Ghostty. `GlobalHotkeys` owns every registration in the process, including the registration of the quick terminal (`HotkeyAction.isAlwaysGlobal`). `sync` reconciles the registrations after each rebind and each change of a flag. It leaves a chord that did not change alone. We use Carbon and not a CGEvent tap, because Carbon needs no Accessibility grant. The system also reports a chord that it will not give us (`eventHotKeyExistsErr`). The row then says so. Otherwise, a chord would do nothing anywhere, in silence.
**One owner:** Carbon consumes a registered hot key, so the local monitor never sees that keyDown. `KeyRouter` yields exactly the chords that Carbon *holds* (`yieldsToCarbon`). This states the rule that nothing fires two times. It also lets a chord that Carbon *refused* work as a plain local keybind. Two results are deliberate. A global chord always runs its app-level `AppCommand`, so it no longer reaches the own splits of the responder of the quick terminal. And Macterm refuses global together with passthrough on one action, so that it does not defeat passthrough in silence. A chord that fires brings a window to the front first (`AppDelegate.showWindow`). The exception is the toggle of the quick terminal, because its panel does not activate the app.

**Non-Latin layouts**. Some keys type no ASCII (Cyrillic, Greek, Hebrew, Arabic and others). A ⌘ chord on such a key gets its name from the Command key map of the layout: `HotkeyRegistry.commandKeyCharacter`. This is the QWERTY Latin letter that those layouts type under ⌘. That one name serves all three matchers:

1. The bindings of Macterm (`eventToken`).
2. The carve-out of `isAppShortcut` for system keys (⌘Q, ⌘H, ⌘M and ⌘,).
3. libghostty. `performKeyEquivalent` gives it the name as the text of the key.

libghostty resolves a unicode binding such as `super+c` from the text before it uses the unshifted codepoint. Under a Cyrillic layout that codepoint is `с`. Without the text, ⌘C and ⌘V matched nothing. The three matchers must agree. If they do not, the raw default bindings of ghostty (`super+q=quit`, `super+w=close_surface`) take chords that Macterm or the menu bar owns. A key that types ASCII keeps its own character. Dvorak, AZERTY and every other Latin layout are unchanged.

## Tab naming and activity

- The automatic title of a tab is the name of the foreground process (`ProcessInspector.runningProcessName`, the kernel `comm`). If there is none, it is the login shell (from `getpwuid`). `customTitle` overrides it. There is no switch for this (`macterm.tabs.autoName` is a retired key). The polling also serves busy-close and execution tracking.
- `AppState` polls in an adaptive way (`PollCadence` and `refreshAllForegroundProcesses`). It polls every 250 ms in a burst after any `.terminalPollEvent`. It polls every 1 s when the app is active and idle. It polls every 2 s when the app is inactive. It stops when nothing is on the screen.
- **Execution tracking runs whatever the "Show tab status indicator" setting is** (#705). `pane list` reports the state, and agents wait on it. The setting only chooses what the tab row draws (`TabStatusColumn`).
- **The status of a tab is in a column at the trailing end of its row** (`TabStatusColumn`, `TabStatusAccessory`, `TabStatus`). The leading icon shows identity only (`TabGlyph`: the tab icon, or the agent logo). Status never changes it. The setting is on by default. `macterm.sidebar.showSpinnerOverAgentIcons` is a retired key: the spinner never covers the logo now.
  - The slot is on the axis of the hover "+" of a project header. While the setting is on, the trailing inset of the title is a constant (`projectActionRevealedInset`). A state change only changes opacities, so it never wraps a title again or moves a row. While the setting is off, the slot takes no width.
  - The glyphs, highest first: Needs You (`questionmark.bubble.fill`, `MactermTheme.warning`, one bounce when it arrives, none under Reduce Motion), Running (`StatusSpinner`, an AppKit `NSProgressIndicator`), Failed (`xmark.circle.fill`, `MactermTheme.failure`), Done (a dot, `MactermTheme.success`), Idle (empty). A split shows its highest pane (`TerminalTab.status`). Tooltips and VoiceOver say "Needs You", "Running", "Failed" and "Done".
  - Every glyph stays mounted, and the status drives opacities. On a selected row with the accent background, the glyphs draw white (`backgroundProminence == .increased`). An `NSProgressIndicator` has no tint: a tag color does not reach the spinner, and on the accent row it takes the dark appearance. Do not draw a spinner by hand.
  - The slot takes no hits. SwiftUI's `allowsHitTesting(false)` does not reach an AppKit view, so `StatusSpinnerView.hitTest` returns nil. The click, the drag, the right-click menu and the drop insertion line of the row stay as they were. The outline view reuses a row with no SwiftUI update, so the spinner starts again in `viewDidMoveToWindow`. The tooltip of the status is on the row under the slot (`TabStatusTooltip`), because a view that takes no hits can get no tooltip. Nobody has checked this with a real pointer yet: that the row tooltip shows over the slot, and that a nearer tooltip (a truncated title, "Not running") still wins.
  - A collapsed project shows the highest status of its tabs in the slot of its "+", with a count when two or more tabs share it (`TabStatus.rollUp`, `SidebarProjectHeader`). On hover, the roll-up fades into the "+". An expanded project shows nothing there. The header reads the status in its own body, never in the `List` builder.
  - The cards of the tab switcher show the same glyph at the end of their title row.
- **Needs You is a pane flag, not a fourth state** (`Pane.awaitingInput`). It means that Claude Code waits for an answer: a permission prompt or a question.
  - What sets it: a desktop notification (OSC 777) whose body starts with `Claude needs your permission` (`ClaudeCodeNotice`, measured on Claude Code 2.1.326). Claude Code sends that body for a permission prompt and for AskUserQuestion, about 6 s after its OSC 9;4 progress stops. For those 6 s the tab shows Done, or nothing while the user looks at it. The idle notice after 60 s (`Claude is waiting for your input`) does not set it. The foreground must be Claude (`agentIcon == .claude`), and the pane must not be a mirror, because a mirror parses the same OSC stream. `Pane+ViewCallbacks` sets it before the early return for a focused pane, so a pane that the user looks at shows it too.
  - What clears it: a new run (`executionState` becomes `.running`, in its `didSet`; Claude Code sends progress again when the user answers), input that reaches the pty (`GhosttyTerminalNSView.onInputSent`: a typed key, a paste, a drop, `pane run`, `pane key`), Claude leaving the foreground (the `didSet` of `agentIcon`), and `destroySurface`.
  - What does not clear it: a selection of the tab, a look at the tab, and a click in the pane. `onInteraction` and `recordUserInteraction` also fire for a click and a scroll, so they never clear it. A click is not an answer, and the question is still on the screen. `onUserInput` moves session leadership, so the new hook is a separate callback.
  - It is live only and never persisted. The `state` of the CLI does not change. The Dock badge does not count it.
  - Input typed into a mirror clears only the mirror. The real pane clears at the next run.
  - libghostty drops desktop notifications that come close together. Measured: in one pane with one body, a second notification up to about 5.3 s after the first never arrived, and one 5.5 s or more later did. From two panes 0.5 s apart, the second never arrived, with the same body and with different bodies. Two panes 1 to 5 s apart were not measured. When two sessions ask at almost the same time, the second tab can show Done and not Needs You.
- **The `GHOSTTY_ACTION_OUTPUT_ACTIVITY` heartbeat is the only source of activity**. It fires also while the pane is occluded. The scrollbar action in the render path does not. Completion edges (OSC 133;D and foreground transitions) rebase the row baseline. Then the late heartbeat of a fast command never starts it again as activity. `TerminalExecutionTracker` has the rules for when output that does not grow counts as work (foregrounds of AI agents after a real Return).
- **An OSC 9;4 progress ERROR ends the run as a failure**. The status column of the tab shows a red cross in place of the green dot (`xmark.circle.fill`, `MactermTheme.failure`, palette 1, tooltip "Failed"). The outcome is `Pane.completionFailed`. This flag has a meaning only while the state is `.done`.
  - `executionState`'s `didSet` clears the flag each time that the state leaves `.done`. Every path that acknowledges a run therefore clears red in the same way as it clears green.
  - The code sets the flag *before* `.done` publishes. The poll that the publish wakes can save or acknowledge at once, in the same call.
  - Never add a fourth `TerminalExecutionState`. The guards of the tracker compare against `.done`.
  - REMOVE and PAUSE end a run as a success. Macterm drops a report that finds the pane not `.running`. For this reason SET → ERROR → REMOVE stays red.
  - Within a tab, Needs You wins over running, running wins over failed, and failed wins over done (`TabStatus`).
  - It persists as `PaneSnapshot.completionFailed` next to `needsAttention`. It never replaces `needsAttention`.
  - The `state` of the CLI stays `done`. The percentage is never shown.
- OSC 0 and OSC 2 titles are **gated by provenance** (`Pane.receiveReportedTitle`). Macterm adopts one as `programTitle` only while the foreground is a real program. It pins the title to that pid. The title expires when the program loses the foreground. Macterm discards titles that a prompt sets (nushell, Starship). It never persists titles.
- **Macterm throttles a title report before it costs anything** (`TitleReportThrottle`, one for each pane, pure and tested).
  - The lookup of provenance and the refresh of the foreground that a title triggers cost about 100 µs of syscalls. These are `KERN_PROCARGS2` three times, and `open` and `tcgetattr` on the tty.
  - A zmx session that replays scrollback with many prompts at launch reports one title for each prompt. 150k of them froze the main thread for 14 seconds. The control socket did not answer.
  - Macterm evaluates the first title after a quiet window (`PollCadence.fastInterval`, 250 ms) at once. It holds the other titles of the window. The newest title wins. It flushes once at the end of the window. Nothing is dropped. A title is at most 250 ms late. Macterm judges it against the foreground that holds the pane at that time, which the next tick of the poll would have seen anyway.
  - `receiveReportedTitle(_:programPID:)` is the core with no throttle. The tests drive it. `destroySurface` cancels a flush that waits, and it resets the window.
- **Remote panes** have no local pid. Their name comes from OSC titles (`Pane.receiveRemoteReportedTitle`) and from the host's foreground reports. Nothing else names them: Macterm makes no background ssh for a remote project (0058).
  - **The host's session pushes the foreground (#695).** The pane command exports `ZMX_FOREGROUND_EVENTS` before `connect` (`RemoteSpawn.remoteForegroundEventsPreamble`). The session reads the pty's foreground process group before it forwards each chunk of output, and every 500 ms, and sends a report to the client. The client writes it into the output as an APC, in front of the output that follows it. libghostty raises an APC that it does not know as `GHOSTTY_ACTION_UNKNOWN_APC` (ghostty patch 0020), and `ZmxForegroundEvents.parse` turns it into a `RemoteForeground`. The report is `zmx;foreground;<idle>;<shell>;<comm>;<args>`. Both the variable and the prefix are a wire contract with the server.
  - The report carries the host's verdicts about idle and about the shell (`/etc/shells`), and the foreground command line. The command line is the fallback of argv for the agent logo, as `KERN_PROCARGS2` is on the local Mac. It also gives the name of a `comm` that a version names. The sample's origin is `.remoteEvent`.
  - **The order is the point.** A report that the shell is back lands before the shell's prompt, and a report that a program started lands before its first output. A title outside a run is therefore judged against the latest report at once: shown when a program holds the pty, dropped when the shell does or when no report came. A title that arrives while the pane is running (OSC 133, activity, progress) is shown at once. A title that arrives at a prompt that OSC 133;D announced is discarded. A run that ends keeps its title only while the latest report says a program holds the pty. This is how an agent that is idle between turns keeps its title.
  - **A title in the replay of an attach never names the tab.** The session replays its last title with its screen, maybe a prompt's from before the program in front started. The same client writes `zmx;snapshot;start` and `zmx;snapshot;end` APCs around each snapshot (`server/src/attach.zig`), and `Pane.receiveReportedTitle` drops every title between them, before the throttle. The pushed foreground names the tab.
  - The session reports only on macOS and Linux (`proc_pidpath`, `/proc`). A pane with no server on its host (a plain shell) gets no report: it keeps the host name and the titles of its runs, and closing it always asks (the surface's reading of the ssh client: never silently kill an unknown foreground).
  - Both pipelines publish one value, `Pane.foregroundSample`. Policies such as `ForegroundPolicy.needsConfirmClose` are pure functions over it. Every busy-close guard reads `Pane.needsConfirmClose`. It never reads `needsConfirmQuit` of libghostty directly, because for a remote pane that only sees the `ssh` client.
- **`bell-features = attention` has two halves.**
  - `GHOSTTY_ACTION_RING_BELL` handles the app-level parts in `GhosttyCallbacks.ringBell`: the beep, `bell-audio-path` and `NSApp.requestUserAttention`. It also flags the pane that rings (`Pane.ringBell`). `title` and `border` are UI for each tab that Macterm does not implement.
  - The Dock badge is the second half. `BellBadge.label` is the pure rule from the count to the label (nil without `attention` or with nothing that rings, capped at `99+`). `BellBadge.apply` is the one AppKit write. `AppState.syncDockBadge` joins the two.
  - The badge counts **tabs**, not the windows of ghostty, because the user goes to a tab and looks at it.
  - The badge is DERIVED. Code never writes it from the ring. For this reason, a config reload that drops `attention` clears a badge that is already up, and no code path needs to know about clearing.
  - Acknowledgment follows the existing verdict of Macterm, "looking at the active tab". It does not follow the rule of ghostty about the next keypress. The badge therefore cannot disagree with the sidebar. A bell in the active tab of the active app is seen the moment that it rings. Everything else clears in the same way as the completion dot: tab selection, pane focus or interaction, the app that comes forward, and surface teardown.
  - Each change of the flag posts `.terminalBellStateDidChange`, so clearing is derived again with no extra work.

## Password prompts (Settings → Password Manager)

A pane that asks for a password gets a native `NSPopover` at the cursor (`PasswordBubble`). The bubble shows **Autofill** when Macterm saved a password for that prompt. It shows **Save Password?** after a password that the user typed worked. `PasswordPromptMonitor` (`Macterm/App/`) does all of this. The pure rules are in `Macterm/Model/PasswordPrompt.swift`.

- **Detection uses the tty, not the screen**. The rule is canonical mode with echo off (`ProcessInspector.terminalIsReadingPassword`). Ghostty and iTerm2 use the same rule.
  - Macterm reads the tty of the **session** (`ZmxForegroundResolver.daemonTTYPath`, the `pty` of `session.list`). The check of libghostty sees the pty of the `zmx connect` client, and `cfmakeraw` keeps that pty raw for ever. Under zmx, `GHOSTTY_ACTION_SECURE_INPUT` never fires.
  - The same reading also drives `macos-auto-secure-input` (`GhosttyTerminalNSView.detectedPasswordInput`, combined with OR with `passwordInput` of libghostty). The lock badge for each pane is off by default (`macos-secure-input-indication = false` in the defaults layer), because the bubble marks the prompt.
  - Macterm reads the tty in three cases:
    1. On the output heartbeat of the pane (`viewDidOutput`), because a prompt is output.
    2. On every key that the user types into the pane (`viewDidType`). `keyDown` reports it **at the send point, as the text that the tty receives**. This is the committed text of the IME. Nothing is reported during a composition. Nothing legible is reported for an option-as-alt chord. A chord that `isAppShortcut` or the ⌃\ swallow ate is never reported. A program on the own pty of the surface has therefore already ended its read when Macterm reports the Return. An example is the ssh of a remote project. A line end belongs to the prompt that was up when the line went out.
    3. On a timer: every 1 s, with tolerance, for the focused pane while it is idle. Every 150 ms only while some pane is in a *timed* phase (`sighted`, `verifying`), or for `outputWatchWindow` (750 ms) after a heartbeat. A pane that is parked at a prompt or at an offer that nobody answered costs only the slow cadence.
  - **The heartbeat alone cannot sight a prompt**. It is leading-edge with drops: the first output after 500 ms of quiet fires at once, and every chunk in the 500 ms after it is dropped. The echo of the command fires it before the tty changes. The prompt that the program prints after that is in a dropped chunk. Without the watch, the sighting waited for the idle timer. The bubble then came up about 2 s after the prompt. With the watch, the sighting lands within one fast tick of the tty change. A sighting also schedules one look at the end of its hold (`scheduleConfirm`), so the confirmation does not wait for the tick after it. What remains is the hold of 200 ms and the animation of the popover. Measured in a hermetic instance with `pane password`: the prompt was confirmed about 0.93 s after the command went in before, and about 0.37 s after.
  - `pane run` and `pane key` feed the same capture (`viewDidSendText` and `viewDidSendKey`). This is how the e2e suite answers prompts. The monitor fences off its own autofill typing (`isInjecting`).
  - Everything that the monitor reads or drives goes through `PasswordPromptMonitor.Probes`. `PasswordPromptMonitorStateTests` therefore runs the whole machine without a surface.
  - A sighting must hold for 200 ms, unless the user types at it. A script that drops echo to read a reply of the terminal is not a prompt.
  - Prompts on a remote host *inside* ssh are invisible, because the local ssh client is raw. The own ssh login of a remote project asks in a sheet (`SSHLoginPrompts`), not in the pane.
- **The identity is the command and the prompt line** (`PasswordEntryID`). The command is the foreground command, named by the **real path of its executable** (`ProcessInspector.passwordAsker`: `proc_pidpath` and argv without argv[0]). The prompt line is the last viewport line that is not empty.
  - Never use argv[0]. A process sets it for itself. `exec -a ssh ./fake prod` would collect the password that Macterm saved for the real ssh.
  - `runningCommand` (the capture of `run:` for a layout) still uses argv. Do not change it.
  - The prompt line separates the two passwords of `ssh -J bastion prod`.
  - There are three exceptions. `sudo …` is filed under `sudo` (one login password). Key passphrases are filed under the prompt alone. The login of a remote project is filed under `ssh user@host` (the login sheet offers it).
  - **Those two shared entries answer only a program that the user cannot have replaced** (`PasswordAsker.isProtected` and `ProcessInspector.isProtectedExecutable`). The executable and every directory above it must belong to root, and we must not be able to write them. This is true of `/usr/bin`. It is false of Homebrew and `~`.
  - Anything else with the name `sudo` is filed under its own full command. A passphrase that a program asks for, and that someone can replace, is filed under the path of that program. Without this rule, a `~/bin/sudo` earlier in PATH that prints `Password:` would get the autofill of the login password.
  - A shell that *runs a script* is a program for `passwordAsker` (`isIdleShellInvocation`). A prompt inside `./deploy.sh` is therefore filed under `/bin/sh ./deploy.sh`.
  - The idle shell itself (`read -s`) is `.shell`. It is filed by the prompt alone.
  - A foreground that Macterm cannot read is `.unknown`. It is never `.shell`. The prompt stays `sighted` and Macterm tries again. A key that the user types in the meantime taints the capture (`confirmTyping`).
  - When Macterm shows an entry, it shortens a resolved program path to its name. It drops the options that the ssh wrapper of Macterm injected (`SSHWrapper.userArguments`). The exception is a program that is named `sudo`. It keeps its path, so that it cannot pass for the real one. Matching never shortens.
  - The Details editor files through `declaredEntryID`. It trusts what the user typed.
  - **`Preferences.passwordManagerEnabled` is the master switch**. Macterm stores it under the old key "Offer to save", so an old "off" stays off. When it is off, `step` drops the pane to idle with its offers at every observation. Nothing is captured, offered or autofilled. `detectedPasswordInput` still follows the tty.
- **Macterm offers to save only on evidence** (`PasswordSubmissionJudge`).
  - These events mean failure: a failure line within `failureWindow` (3) lines of the prompt.
  - These events mean success. One is a prompt that is up again after the settle window. Another is an OSC 133 exit with **any** code. Another is output that is not a failure. The last is a tty that leaves line mode (`ICANON` off). A remote project login shows only the last event. zmx then draws the screen again from the top, and nothing is drawn below the prompt.
  - Silence for more than 12 s saves nothing.
  - Two things are deliberately not rejections. One is the exit code, because it judges the command (`sudo grep -q` exits with 1 when it accepted the password). The other is the identical prompt again with no failure line (git over HTTPS asks one time for each connection).
  - Typed keys go through `PasswordLineCapture` (DEL and ⌃H, ⌃U and ⌃W edit the line, and arrows and escape taint it). It gets them from `keyDown` before libghostty, and from `surfaceDidPasteText`.
  - Offers queue (`ssh -J` gives two). Macterm shows one at a time when no prompt is up. An offer expires after `offerLifetime` (15 minutes). Only a command that *the own shell of the pane* runs drops an offer (`foregroundProcessIsShell`). A bare Return keeps the offers. Anything that the user types into the remote shell of ssh keeps them too.
  - If a keychain write fails, the offer stays up with the error (`Offer.problem`). Macterm does not lose the secret.
  - A keystroke at a prompt while a submission is still `verifying` settles the verdict at once (`settle`). A fast retype after a rejection is therefore not captured without its first characters.
  - Failure lines count only within `failureWindow` (3) lines of the prompt. A MOTD that says "denied" is a successful login.
  - Macterm never offers prompts for one-time codes (`isOneTimeCode`).
- **Storage is the login keychain** (`KeychainPasswordStore`, service `<bundle id>.passwords`, metadata as JSON in `kSecAttrGeneric`).
  - The data-protection keychain needs an entitlement for a provisioning profile. A self-signed app cannot have it. Touch ID is therefore the gate of the app (`PasswordAuthenticator`, `.deviceOwnerAuthentication`). The default is once for each app launch. A screen lock, sleep or a switch of user also ends it. Macterm never persists it, because a lock while Macterm is quit leaves no reliable trace. The other option is every time.
  - A debug build with an ad-hoc signature gets a keychain dialog on a read. A debug build with a stable identity (`Configs/Local.xcconfig`, see Build & Run in the root `AGENTS.md`) gets it one time, until you click Always Allow.
  - Tests, `MACTERM_BENCHMARK=1` and any launch with `MACTERM_BENCHMARK_DATA_DIR` use `InMemoryPasswordStore` (`PasswordVault.isHermetic`). A **debug** build under that condition skips Touch ID. The only passwords that such a run holds are passwords that it captured itself. The e2e suite autofills with nobody at the keyboard.
- **Autofill types and never pastes** (`GhosttyTerminalNSView.sendSecret`: the text path without the evidence of a command submission, then Return). It checks the tty again after authentication. It clears a line that the user half typed with ⌃U first.
  - A refused autofill turns the next sighting into "Saved Password Did Not Work". A typed password that then works is offered as an update.
- **The bubble never keeps the key**. It has the behavior `.applicationDefined`. Every button gives the key back to the window of the terminal (`PasswordBubble.returnKey`). It does this only when the popover or nothing holds the key. It never takes the key from another window of ours.
  - The anchor is `cursorCellRect()` (the IME point of libghostty).
  - **Return is the primary button, and Escape dismisses**. Both go through the key path of the terminal (`viewWillSendKey` consumes them). They work only while the user typed nothing since the bubble appeared (`Tracker.typedSinceBubble`). `PasswordBubble.show` resets it when it reports new *content*. A new anchor after the cursor scrolled away and back does not reset it. The first character gives both keys back. A password or a command that the user types under the bubble therefore submits as usual.
  - The bubble draws no key hints.
  - A parked AeroSpace window (off screen) makes AppKit push the popover onto the visible screen. This is not an error of the anchor.
- **On demand** (`PasswordPaletteScope`, the Password Manager of the palette) types any saved entry that the user selects. It types into the focused pane of the active tab (`PasswordPromptMonitor.fillOnDemand`). It needs no prompt match and **no confirmation**. The selection is the authorization. Touch ID still gates the read.
  - The tty decides only Return (`OnDemandPasswordFill` over `TerminalLineMode`).
  - At a verified read (canonical, echo off), Macterm presses ⌃U first, then types the password, then presses Return. It judges the result as an autofill. Its `Submission.id` is the entry that the user *selected*. A rejection therefore marks that entry, and Macterm offers nothing that was typed for saving.
  - At any other place, Macterm types the password with no Return. Examples: ssh or tmux that relays a remote prompt, the line editor of a shell, and a line that echoes. Remote `sudo` is the reason that this feature exists. A wrong selection then never runs, and it never reaches a history. The user submits it or clears it.
  - If a verified read is gone after authentication, Macterm types nothing.
  - **An entry with an empty prompt is only for on-demand use** (`PasswordEntryID.isOnDemandOnly`). Detection never reads an empty prompt line, so nothing ever autofills it. Its keychain account is `<command> — on demand`.
  - The screen is also an action that you can bind (`HotkeyAction.passwordManager`). It has no keybind by default, because ⌥⌘F belongs to Autofill. It is in the View menu. It toggles the palette on that screen (`AppState.toggleCommandPalette(scope:)`). While the palette is up, the app responder stands aside, so `PaletteResponder` answers that chord itself.
  - You add entries from the `+` of Settings, or from the Add rows of the palette. Both use `PasswordEditorSheet`, which Details… shares. `MainWindow` presents the copy of the palette from `WindowState.passwordEditor`. The sheet **requires a command**. Only detection creates entries with only a prompt (key passphrases, `read -s`). You can edit them as they are. You never create them, and you never make them by hand.
- **`pane password` (DEBUG only)** reads the phase, prompt, command and bubble of a pane. It never reads a secret. `--answer accept|dismiss|autofill` presses the buttons of the bubble. `scripts/e2e/test_passwords.py` drives the whole flow with it against a `stty -echo; read` script.
- **Never** add a CLI verb, an App Intent or a log line that carries a secret. Any process in a pane can call `macterm`.
  - Autofill Password is an `AppCommand` (default ⌥⌘F). Its action is nil unless the focused pane is at a saved prompt. As for every chord with a nil action, `isAppShortcut` then swallows it in `keyDown`. It does nothing, and it does not reach libghostty (which has no default on `super+alt+f`).

## Pinned Tabs

Pinned tabs belong to no project. The sidebar shows them above the projects. They are a **sentinel workspace** (`workspaces[PinnedTabs.projectID]`). Its ID is a fixed UUID that is not a `ProjectStore` row, so the iteration over projects never sees it. Each pinned tab is a `PinnedTabRecord`: a durable declaration (`LayoutTab`) and, while it is loaded, a live `TerminalTab`. All the logic is in `AppState+PinnedTabs.swift`.

- Pin and Unpin are `moveTab`s. They never kill anything. `syncPinnedRecordsWithWorkspace` pins a tab that was born in the pinned workspace.
- **Closing a pinned tab is an unload. It is never a removal**. The sessions end. The record stays as a dimmed row. When Macterm starts again, it starts the tab again at once. Unpin is the path for removal.
  - The same unload happens when the own sessions of a tab die (`paneProcessExited`).
  - The code calls this state "unloaded" (`unloadPinnedTab`). The GUI never does: the dimmed row's tooltip says "Not running".
- The persistence has two layers.
  - The live state is in the `pinned` section of `workspaces_v3.json`.
  - The declaration is in `~/.config/macterm/pinned.yaml`. It is next to `widgets.yaml`. The location comes from `ProjectFileStore.configDirectoryURL`, and the custom store of a test keeps it inside its own directory.
  - The file is a `ProjectFile` whose reserved `path: <pinned>` is the marker. It has no IDs for entries. Macterm matches entries back by name, then by the exact layout, then by position (`PinnedLayoutMatcher`).
  - `AppState` tracks its own last write. It absorbs external edits before each write. A file that does not parse suspends the auto-writes with an alert.
  - A file that is absent or empty means "no input". It never means "remove everything".
- **`pinned.yaml` lived in `projects/` before 1.31. That location is retired (#446)**. Macterm reads and writes only the new place. The 1.31 releases moved an existing file up at launch. A file that is still in `projects/` is ignored. The listing of projects still skips the reserved name there. A leftover file is therefore never offered as a project, and no project can take the name.
- At launch, every record materializes. `materializeRestoredPinnedTabs` asks the server which sessions survived. A session that is dead starts again from the declaration. The declaration refreshes at pin time, when the pinned foreground changes (debounced), and at quit. It never refreshes at unload.
- Sidebar drag: the pinned rows and the tab lists share one `.dropDestination` at the level of the ForEach. It drives the native insertion line. Rows have no destinations of their own. A target on a row kills the line and swallows clicks. `PinTabDropZone` above the List makes the first pin possible by drag. `--project pinned` addresses the workspace over the CLI.
- **No project may have the name `Pinned`** (any case, padding ignored). `ControlHandler.resolveProject` reads it as this workspace before any project, so such a project cannot be reached by name.
  - `PinnedTabs.reservesName` is the one test that every naming path applies. A typed name is refused where the user typed it. These paths are CLI `project create --name` and `project rename`, the notice of the sidebar rename, the New Project intent, and the remote sheet.
  - A name that nobody chose (the own name of a folder) becomes `Pinned 2` in `ProjectStore.create`. `ProjectStore.rename` refuses it outright.
  - Projects that got their names before the rule keep their names.

## Desktop widgets

Desktop widgets are terminals on the desktop (`DesktopWidget`, `AppState+DesktopWidgets.swift`, `DesktopWidgetWindows`, Settings → Widgets). Each one is one pane. Its zmx session persists in the same way as the session of a pinned tab. A panel of our own draws it, in the shape of a system widget. The grammar for users is in `docs/44-desktop-widgets.md`.

- **A widget is not WidgetKit, and it cannot be.**
  - A WidgetKit widget is an archived SwiftUI snapshot that another process renders. It has no NSView and no text input. Its budget of refreshes is minutes.
  - chronod also purges the descriptors of any widget extension that has no Apple team in its signature. It logs `Requested to add extension, but purging instead because we shouldn't cache it`. We measured this with ad-hoc builds and self-signed builds, against a control with a Team ID.
  - Widgets therefore never appear in the Edit Widgets gallery of the desktop. You create them from Macterm (File menu, palette, `+` of Settings, `widget new`).
- **The metrics are measured, not guessed** (`DesktopWidgetMetrics`, `DesktopWidgetGrid`).
  - chronod logs the `CHSWidgetMetricsSpecification` of the host (`log show --predicate 'process == "chronod"'`, the entries with `cornerRadius`). The edges are 164, 344 and 704 pt. The continuous corner is 27.88 pt.
  - These edges are all spans of one module (164 pt cells, 16 pt gaps, a pitch of 180 pt). The size of a widget is therefore a `DesktopWidgetSpan`. There are no presets.
  - A new widget is `DesktopWidgetSpan.initial` (3×3). Macterm puts it at the exact middle of the screen (`DesktopWidgetGrid.centered`). It is off the lattice until its first move or resize. The lattice cell that is nearest to the middle can be half a pitch away. When the middle is taken, Macterm uses the nearest free cell of the default lattice.
  - **There is no grid for the whole screen**. Notification Center stores its widgets as groups, each with its own origin. It logs `Writing desktop widget placement storage to disk: … groups: [{origin: (18.0, 25.0), items: [<col, row, size>…]}]`.
  - Every move and resize therefore ends in `DesktopWidgetGrid.snap`. It snaps onto the lattice of the nearest widget within one pitch. This includes the system widgets. Macterm reads them from the window list (`NativeDesktopWidgets`). The window of a widget is the widget plus 8 pt of shadow. The placement file itself is in a protected container.
  - Read EVERY window, not only the windows on the screen. Notification Center reports its widgets as off screen when windows cover the desktop.
  - Accept only real widget windows. They are windows of the host, at the level of the desktop icons plus 2. They have a visible alpha and whole cells in each direction.
  - Notification Center also keeps a window with no title and alpha 0, one level below. We saw it at 464×824 after we dragged widgets around. When we read it as a widget, it blocked empty cells and pulled the widgets of Macterm onto its lattice.
  - If no widget is near, Macterm uses the default lattice of the screen at the corner inset that macOS uses (26, 33).
  - The result is the nearest cell and span, kept on the screen. If it overlaps, Macterm moves it to the nearest free cell. System widgets count as occupied.
  - `column` and `row` in `widgets.yaml` are on the default lattice. The snap after Macterm applies them pulls a widget back onto the lattice of its neighbor.
  - Measure again when a macOS release looks different.
- **Locked by default. One widget is edited at a time**. `AppState.editingDesktopWidgetID` is the single edit slot. It is only in memory, so every launch comes up locked.
  - A locked widget behaves like a system widget. `canBecomeKey` is false. `DesktopWidgetShieldView` takes every mouse event and turns a press into a widget drag. The wheel is included. Over mouse reporting or alternate scroll, the wheel is input.
  - The terminal gets no focused pane (`focusedPaneID: nil`). The one pane of a widget is always the focused pane of its tab. When we passed that through, every locked widget showed a solid cursor.
  - Editing has four parts. The first is the own edge resize of the widget. The second is the outline in the accent color. The third is a Done button. The fourth is a drag from the margin only. `DesktopWidgetResize` does the resize. It uses the outer 7 pt band of the margin and 20 pt corners. The cursors come from a tracking area with `.activeAlways`. Inside the terminal, a drag selects.
  - We do not use `.resizable` of AppKit. Its resize area for a borderless window is a sliver, and its hover cursor never showed.
  - Every drag waits for a threshold of 4 pt before `performDrag`. A jitter of a click must not move a widget. Then the code polls for the release and snaps the widget.
  - The CLI can still type into a locked widget.
- **An edited widget has no shadow**. The shadow and the rim of a KEY window come from the rectangle of the window, not from its alpha. That put a dark square behind the rounded corners. In an A/B test, the square was gone with `hasShadow = false`. The style mask and `invalidateShadow` did not change it.
- **The panel lives where system widgets live.**
  - Its level is `desktopIconWindow + 1`. It has `.canJoinAllSpaces`, `.stationary` and `.ignoresCycle`. It is borderless and `.nonactivatingPanel`. When you type into a widget, the frontmost app stays in front.
  - The quick terminal shares the key handoff through `panelDidResignKey`.
  - It is an `NSPanel`, so `isTerminalWindowCandidate` already excludes it. AeroSpace does not manage it.
  - A modal that a widget raises (`DesktopWidgetRemoval`) must activate the app first (`AppDelegate.activateWithoutReopen`). In an app that is inactive, the modal never comes forward and blocks, and nobody sees it.
- **The appearance is `WindowAppearance.syncDesktopWidget`**. The window is never opaque, because the rounded backdrop is the shape. Glass and tint are at the corner of the widget.
  - **The shape of the window is the `_cornerMask` of `DesktopWidgetPanel`**. It is the continuous corner of the widget as an image of nine parts. When we left the window server to derive the shape from the alpha, it made a coarse, jagged region with wider corners. With glass off, the CGS blur filled that region. The result was a blurred desktop around every corner, and the radius was visibly lost. Glass hid this, because it draws its material inside the curve. In an A/B test against a flat backdrop, the halo and the rim were gone with the mask.
- **There are two layers of persistence, as for pinned tabs.**
  - The snapshot (`WorkspacesFile.desktopWidgets`, schema v7) carries the session identity.
  - `~/.config/macterm/widgets.yaml` is the declaration (`WidgetLayoutStore`, schema `assets/widgets.schema.json`: keep them in sync). It has `name`, `size`, the grid `column` and `row`, and `display`. `display` is the name of the screen. Macterm always writes it, because the primary display changes with what the user plugs in. In an entry that someone wrote by hand, no `display` means the primary one. It also has the recipe for a new start, `cwd` and `run`. Macterm captures it from the live pane with the pinned rule that an idle capture never clears `run:`.
  - The file follows the rules of `pinned.yaml`:
    - Macterm writes it again after every change and at quit.
    - It absorbs external edits first (baseline of the exact text).
    - It has no IDs (`WidgetLayoutMatcher`: name, then content, then position).
    - It is authoritative for membership at launch.
    - An absent file is no input.
    - A file that does not parse suspends the writes behind an alert.
    - Macterm honors the removal of a running widget at launch only. The entry of that widget stays out of every write from then on (`unlistedDesktopWidgetIDs`). Macterm judges it against the widgets that our last write listed, so that a widget created since then is not taken for a removal. If it did not do this, the next write put the entry straight back.
  - The reconcile at launch adopts the size and the cell of an entry only where they DIFFER from the own declaration of the widget. The cell in the file is on the default lattice, and it cannot express a widget that joined the lattice of a neighbor. When Macterm derived an unchanged entry again, it moved the widget off its neighbor at every launch.
  - The reconcile also saves no snapshot. It runs before any window registers, and `windows` would be written as absent.
  - The capture of the recipe (`refreshDesktopWidgetRecipes`) drops a foreground that it saw while `Pane.isShellAtPrompt`. That is a prompt hook, and Macterm was typing it into the next new shell.
  - Macterm draws restored widgets only after `materializeRestoredDesktopWidgets` asks zmx which sessions survived. A widget that is dead starts again from its recipe. If a surface attached first, it would get the empty shell that zmx upserts.
- **Widgets follow the displays in the way of Notification Center** (`DesktopWidgetPlacement`). We measured this from its logs when we went from a 3008×1692 display to a 1920×1243 display.
  - Notification Center keeps the layout of the system widgets for each display *and* for each resolution. On a display for which it has no layout, it PROJECTS the latest layout, with the same offsets from the visible top-left. It saves nothing.
  - The `placements` of a widget therefore record where the user put it (creation, a settle, a declaration). The key is the display name plus the resolution of the whole frame, so that the Dock does not make a new key. `topLeft` is where the widget is now. Macterm never records a projection.
  - `desktopScreensDidChange` and the restore at launch both go through `placeForCurrentScreens`. `DesktopWidgetWindows` calls `desktopScreensDidChange` 1 second after the notification for the screen parameters stops firing. A connect posts it several times, and Notification Center moves its own widgets in the meantime.
  - `placeForCurrentScreens` uses the display that the widget was last put on, or else the primary display. It uses exact placements first. Then it uses projections, clamped onto the screen. A projection that would land on another widget moves to a free cell.
  - Macterm never shrinks the span to fit. That would lose its size for the large display.
  - `widgets.yaml` declares the latest *placement*, not `topLeft`. If it declared `topLeft`, a quit on the laptop would write the cell of the laptop. The next launch on the external display would adopt it.
  - Not verified live: what Notification Center does with widgets that do not fit, and if it anchors any of them to the right edge. Ours clamp.
- **Widget panes live outside every workspace**, like the panes of the quick terminal.
  - Their sessions are claims (`desktopWidgetSessionNames`). They are bound in `session list`. They are rows in the quit prompt for the case with no persistence. The pane verbs address them through a bare `--session` (`ControlHandler.widgetTarget`).
  - When the shell of a widget exits, the widget starts again in a new session (`desktopWidgetShellExited`). It does not close.

## First-run seed

`FirstRunSeed` (pure) and `AppState.seedFirstRunIfNeeded` seed a fresh install with one project (the home directory) and one pinned "Welcome" tab. Each one runs `macterm tutor <topic>` as its `run:`.

- It runs after `restoreSelection`.
- `Preferences.hasSeededFirstRun` is written on the first launch that can answer, seeded or not. The exception is `.postpone` on `WorkspaceStore.loadFailed`.
- It is off (postponed, not skipped) under `MACTERM_BENCHMARK=1`. The harnesses look like fresh installs, and they do not isolate the defaults domain.
- The seeded `run:` is bare words, so that it tokenizes in the same way in every login shell.

## Project color tags

`Project.colorName` tints glyphs that the row already draws (the project icon, the icons of the tab rows, including agent logos and status glyphs).

- **No stripes. No glyph means no tag. No indicator in the titlebar**. We tried each alternative and rejected it.
- The colors are fixed system colors (`MactermTheme.color(for:)`). They are deliberately not derived from the ghostty palette.
- The picker is `.pickerStyle(.palette)` (`ProjectColorMenu`). It is the only menu form that renders.
- Macterm stores the color as a String, so that an unknown value becomes untagged.
- `iconStyle` wraps both arms in `AnyShapeStyle`. Without it, `tagColor ?? .secondary` coerces to `Color.secondary` in silence and restyles every untagged row.
- `Preferences.autoAssignProjectColors` (default off) is read only at creation, through a closure that you can inject on `ProjectStore`.

## Finder Services

**Services → New Macterm Project Here** is an `NSServices` entry in the plist plus `FinderServiceProvider` (`Macterm/App/FinderServices.swift`). The `NSMessage` in the plist and the `@objc` selector are a contract at run time that nothing checks. `FinderServicesTests` reads the plist back. A request can arrive before the app restores its state. The provider therefore queues requests until `attach`, and then defers through `AppState.performWhenRestored`. Use that hook for any external request at launch.

**Opening a folder or a file WITH Macterm** arrives at `AppDelegate.application(_:open:)`. The ways are Open With in Finder, a drop on the Dock icon, and `open -a Macterm <path>`. `DocumentOpenRequest` (`Macterm/App/OpenFolder.swift`) splits the request.

- Folders go to `FinderServiceProvider.open(paths:)`. This always makes a **new** project, never a tab.
- Files go to `FinderServiceProvider.openTextFiles` (see Text files below).
- A cold launch therefore uses the queue and defer from above for both.

`CFBundleDocumentTypes` has three entries. **All have `LSHandlerRank: Alternate`**, so Macterm is never a default opener until the user selects it with Get Info → Change All.

1. `public.directory` (the entry of Ghostty).
2. `public.text`.
3. A list of extensions for text that macOS does not type as text (`go`, `rs`, `ts`, which it takes for video). The Info.plist of Zed makes the same split.

Unlike Ghostty, Macterm does not declare scripts and executables. A script that you open with Macterm is edited and not run. `OpenFolderTests` reads the plist back for this contract.

**The two file entries name `Document.icns` (`CFBundleTypeIconFile`)**. Finder shows it for a file that Macterm opens by default, as Zed does. Without it, macOS draws its generic white page with the app icon in the middle. The icon is the app icon's screen in the shape of a page: one glass pane over the app icon's characters. It is plainer than the app icon on purpose: it has no cross and no gap. `scripts/document-icon.sh` draws it from `AppIcon.icon` (`scripts/document-icon/render.swift`). After a change to the app icon, run the script and commit the new `Macterm/Document.icns`. The Folders entry names no icon: a folder that opens with Macterm still looks like a folder.
- **The page is real Liquid Glass from `macterm-icon-renderer`**. The script builds Debug and runs the helper, so it needs macOS 26 or later on Apple silicon. The app never draws this icon at run time.
- **The script compiles its own copy of `AppIcon.icon`** (`actool`, into a temporary catalog). In it, the pane and the characters are drawn again for the page, in a region of the canvas with the page's shape, inside the frames, so no ring shows. The copy leaves out the cross, its shade and the screen's gradient (`leftOut`), and each group takes the fill of the first layer it keeps. The pane covers the whole page and more, so its edges are outside the page and it bends nothing in it. The helper renders the copy on the page's own background, and the script lays that region over the page.
- **The page has the app icon's characters**: the same ramp, density gradient, dither, spacing and seed as `scripts/app-icon/characters.swift`, in 96 pt cells, turned 8° as the app icon's are. The page is the app icon's lid, the color of the top of its screen. Never hide a group of the copy: a hidden group drops out of the compiled icon, and the helper refuses a request whose count of groups differs. Hiding a group's only layer, or setting its opacity to 0, also drops the group.

**Text files (Settings → General → Opening Text Files)** open in the terminal editor of the user (`AppState+TextFiles.swift`).

**Set Macterm as Default App… sets Macterm as the default app of every text file type in one click** (`TextFileDefaults`, Settings → General → Opening Text Files). It is Get Info → Change All, for each type.

- Launch Services keeps a default for each content type. A default for `public.text` does not reach `public.python-script`, so the button sets each concrete type.
- A type is in the list because an extension has it: `TextFileDefaults.commonExtensions` and the extensions of the third plist entry. It keeps a type that conforms to `public.text` or that is dynamic (an extension that macOS does not know). It drops HTML, RTF and images (`excludedTypes`). The filter is why `.ts` stays out: macOS types it as MPEG-2 video.
- `NSWorkspace.setDefaultApplication(at:toOpen:)` runs one type at a time, because Launch Services can ask the user to agree to a change.
- The section compares the default app of each type by bundle identifier and reads it again on activation. When every type opens with Macterm, the button is gone and the caption says so.
- The docs list every extension that the button changes (`docs/20-configuration.md`, "Text file types"). `TextFileDefaultsTests` compares that table with `TextFileDefaults.extensions()`. A new extension in the plist or in `commonExtensions` therefore fails a test until the docs list it. Ghostty has no equivalent. Upstream declined the detection of `file:line` and a link that you can configure (discussions #11378 and #9546). This feature is therefore our own.

- **A ⌘-click goes to the pane first** (`GhosttyTerminalNSView.onOpenLink`). This is only for the `.unknown` kind of the link regex. It is never for OSC 8 or for opens by a keybind.
  - `FileLink` splits `:line[:col]` off. The regex of libghostty keeps it, and `foo.swift:42` even parses as a URL scheme. `FileLink` resolves the path against the cwd of the real pane.
  - Anything that is not an existing local file goes to the system opener, unchanged. So does every remote pane.
  - An existing file goes to its **default app, and Macterm drops the line**, because you cannot tell another app a line. The exception is that the default app is Macterm (`TextFileOpening.isDefaultApp`, by bundle id). Then the editor opens directly and keeps the line.
  - A click in a mirror acts on the real pane (`editorAnchor`). A click in the quick terminal splits the panel. A click in a desktop widget goes the Finder way.
- **The editor is `$VISUAL`, if not `$EDITOR`, if not `vi`**. This is the order of git. Macterm has no setting of its own, deliberately. The variable is where a user already names their editor.
  - **Macterm types the command. It does not start the editor with a spawn** (`TextFileEditor`). The variable and the PATH of the editor are in the shell rc of the user, and no process outside the shell can read them.
  - The typed line is a fixed ` exec sh -c '…'`. It parses in the same way in nu, fish, zsh and bash (no `'` or `\` inside). The file and the line go in the environment of the new pane (`MACTERM_EDITOR_FILE` and `MACTERM_EDITOR_LINE`). No path is ever escaped into shell grammar.
  - `exec` makes the pane close when the user quits the editor. If the editor is missing, the line waits for Return instead.
  - Macterm passes the line as `+N`. This is the one syntax that every terminal editor shares.
- **The placement** is `Preferences.textFilePlacement`. It is a split (automatic axis, `SplitDirection.auto`) next to the pane that was clicked or the focused pane of the project. It can also be a new tab.
  - The exception is the pinned workspace. It always splits. A tab that is born there would be pinned, and when you quit the editor, it would leave a dimmed row.
  - A file from Finder goes to `TextFileProject.project`. This is the deepest local project that contains it. If there is none, it is the active local project. If there is none, it is the first local project. If there is none, it is a new project for its folder. It never goes to a remote project.

**A folder that you drop on the sidebar** opens in the same way (`SidebarFolderDropTarget`, `Macterm/Views/SidebarFolderDrop.swift`, through `AppState.openProjects`, which the Finder service shares). Macterm selects it in the window where you dropped it.

- It is an AppKit view over the whole sidebar. It is registered only for `.fileURL`, and it is transparent to `hitTest`.
- AppKit picks a drag destination by the registered type. It does not ask `hitTest`. Clicks and scrolls therefore still reach the outline below it. So do the drags of tabs, projects and panes in the app, because none of them carries a file URL. No SwiftUI destination could have caught a drag from Finder there.
- The feedback is the `+` of the cursor alone.
- A drop on a pane is still the paste of a path by `GhosttyTerminalNSView`.

**SwiftUI answers that same event by opening a second window. The `handlesExternalEvents(matching:)` of the scene stops it.**

- If you leave it alone, an event for open documents gets a new `WindowGroup` window on top of the project that the delegate just selected. Then there are two windows on one tab, a dimmed mirror in front and `MirroredTabNotice` behind. It also happens when we remove our delegate method, so this is the handling of SwiftUI and not ours.
- Macterm emits no external events of its own (no URL scheme, no Handoff). The group therefore declares a condition that nothing ever matches.
- The set must be **non-empty**. `[]` means "handles no external events at all". It also silences `applicationOpenUntitledFile`. That is the only call that reliably builds a `WindowGroup` window. We measured New Window, `window new` and the repair of #241 as dead under `[]` and alive under a condition that never matches.

## Dock menu

When you right-click the Dock tile, you see **New Window**, **New Tab**, **New Project…** and **Toggle Quick Terminal**. This is the set of Ghostty. `AppDelegate.applicationDockMenu` builds it (`Macterm/App/DockMenu.swift`). `@NSApplicationDelegateAdaptor` does forward this one, and we verified it live.

- The items are `AppCommand`s. They run through `AppCommand.action(in:)`. The Dock is therefore a fourth renderer of that list, and not a second set of handlers.
- Macterm builds the menu again at each right-click with `autoenablesItems` off (enabled means that the action is not nil). The menu is nil until `MainWindow` gives the delegate its state objects.
- `DockMenu.Preparation` is what the Dock adds. A selection arrives from outside the app, and it does not activate the app.
  - New Tab and New Project… call `showWindow()` first (the last window, which is hidden, or the state with no window of #241).
  - New Window activates the app and lets the command make its own window.
  - Toggle Quick Terminal prepares **nothing**. The panel does not activate the app, by design.
- Macterm resolves the action *after* the preparation, because fronting a window is what makes `activeProjectID` the right project.
- `DockMenu.Preparation` is now the shared table for **"invoked from outside the app"**. App Intents run through the same `AppDelegate.performExternalCommand`, and they do not decide again. For this reason the table has `.toggleCommandPalette`, which you cannot reach from the Dock menu itself.

- `Macterm/App/`
  - `PaletteHotkeys`: the chords of extensions, by palette id under `macterm.hotkey.palette.<id>`. The `.passthrough` and `.global` flags are beside them. A Carbon id for each process starts at `carbonIDBase`. It gives one answer to `MainAppResponder`, `PaletteResponder` and `isAppShortcut`. A row under Extensions in Keymaps has the key `palette:<id>`.
  - `HotkeyBinding`: an action or a palette. `GlobalHotkeys` registers it, and `KeybindPassthrough` gates it. The chord of a palette therefore gets Global and Pass to TUI in the same way as the chord of an action.
  - `AppState` (with `AppState+PinnedTabs`, `AppState+FirstRun`, `AppState+QuickTerminal` and `AppState+DesktopWidgets`).
  - `WindowState`.
  - `Preferences`.
  - `Hotkeys`, `KeyRouter`, `Responders` and `KeybindPassthrough`.
  - `AppCommand`, `AppCommandActions` and `AppCommandMenu`: the single source of truth for the actions that a user can invoke. The palette, the menus and Settings render from `AppCommand.allCases`.
  - `FocusRestoration`.
  - `Updater` (Sparkle).
  - `AppInfo`.
  - `FirstRunSeed`.
  - `Tutorial`.
  - `FinderServices` and `OpenFolder`.
  - `AppState+TextFiles` and `TextFileDefaults`.
  - `DockMenu`.
  - `BellBadge` (with `AppState+BellBadge`).
  - `AdaptiveIcon`, `AdaptiveIconController`, `AdaptiveIconRenderer` and `AdaptiveIconRequest` (shared with the helper), with `AppIconPresenter`.
  - `PasswordPromptMonitor`.
  - `BenchmarkControl`.
  - `ExceptionReporting`.
  - `EnvironmentSetup`.
  - `Notifications` and `NotificationHandler`.
  - `PollCadence`.
  - `RecencyStack`.
  - `TabIndexChord`.
