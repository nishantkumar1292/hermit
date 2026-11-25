# The ghostty config pipeline

This file loads when you work in `Macterm/Config/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Ghostty config pipeline

In automatic mode, Macterm delegates the user layer to `ghostty_config_load_default_files`. Settings can append custom files. `GhosttyApp.loadConfig` loads `macterm-defaults.conf`, then the user files, then `macterm-overrides.conf` (the last one wins). It regenerates both private files (`MactermConfig.regenerate()`) before every load, because the overrides depend on the content of the user. `GhosttyConfigSource` is the seam for raw text, for keys that the C API cannot expose.

**`~/.config/macterm/config.ghostty` is a custom config file of the user that Macterm seeds and lists for them** (`MactermConfigFile`). Ghostty.app never reads it, so a key in it applies to Macterm alone.

- Macterm seeds it at the first launch that finds it missing (`MactermConfig.init`), as a template: every line of `MactermConfig.defaults` commented out, each under its note. A commented line sets nothing. `MactermConfigFileTests` pins that no line of the template is bare. An uncommented default would override the Ghostty config in silence.
- At the same time, one time per install (`Preferences.addMactermConfigFileOnce`, flag `macterm.ghostty.addedMactermConfigFile`), Macterm appends it to the custom config files of Settings → General → Ghostty Config, so it loads last. **It is a row like any other from then on.** The user can move it or remove it. Macterm never puts it back on its own. There is no special layer, no special row and no special path in the loader.
- The defaults layer stays the home of each default. The file lists the defaults. It never holds them. A user who deletes the file, or who installed before a default was added, loses nothing.
- Macterm never writes the file again. An absent file means "no input". A present file belongs to the user. Open Macterm Config (`AppCommand.openMactermConfig`, the command palette and the View menu) seeds it again before it opens the file in the terminal editor, the way a text file from Finder opens. If the file is not in the list, a toast says where to add it.
- The listed path is `MactermConfigFile.listedPath`: `~`-abbreviated under the home directory, absolute elsewhere, because `~` expands through the user record and not through `$HOME`.
- Hermetic runs (`MactermConfig.isHermetic`: tests, `MACTERM_BENCHMARK=1`) neither seed nor list it, as they load no user config.

**Ghostty keys that Macterm applies to its own behavior** have no Settings UI.

- `macos-shortcuts` (App Intents).
- `tab-inherit-working-directory` and `split-inherit-working-directory`. `false` means the project directory. In a project-based terminal, this is the "default working directory" of ghostty. `AppState.newTabInheritsWorkingDirectory` is the read that you can inject.
- `macos-hidden`.
- `macos-icon`.
- `window-theme`, and the `set_window_theme` action, which overrides it until `set_window_theme:config` (`WindowTheme`, the rule of Ghostty.app). They give one light or dark scheme (`GhosttyApp.windowScheme`): the chrome (`MactermTheme.colorScheme`) and the scheme of each surface, which picks the side of a `theme = light:X,dark:Y` split. `auto` follows the terminal background, as before. `system` and `ghostty` follow macOS. The override is in memory only and survives a config reload. The window title (the project name and the path) is drawn over the terminal, so it takes the scheme of the window's terminal background, not this one (`WindowAppearance.titleAppearanceName`). Ghostty.app's transparent titlebar does the same for the whole terminal window. Where AppKit paints its own titlebar background (fullscreen), the title keeps the window's scheme.
- `focus-follows-mouse`. Macterm reads it live on each pointer move. It moves focus only away from another pane.
- `font-family`. It sets the family of every monospaced text in the UI of Macterm (`TerminalFontFamily`, from raw text, because a `RepeatableString` has no C shape). `GhosttyApp.loadConfig` puts the first installed family into `TerminalFont.shared` at each load and reload. **Views use `Font.terminal(size:)` or `Font.terminal(_:)`, and AppKit uses `TerminalFont.shared.nsFont`.** Never write `.monospaced()`, `design: .monospaced` or `NSFont.monospacedSystemFont` for UI text. Each place keeps its size and weight. With no installed family, the helpers give the system monospaced font. `.monospacedDigit()` sets only the digits of the system font. Keep it.

**When the default of Macterm departs from the default of ghostty, the departure is a line in `macterm-defaults.conf`**. The place is the `MactermConfig.defaults` table: the line, and the note that the template of `config.ghostty` prints above its commented copy. `defaultsBody` is derived from it. `MactermConfigTests` pins it: `tab-inherit-working-directory = false`, `macos-secure-input-indication = false` and `background-opacity-cells = true`. It is never a fallback in `Preferences`. The user can then override it in the same way as any other key.

**Wheel scrolling belongs to libghostty on every path**. `GhosttyTerminalNSView.scrollWheel` forwards events exactly as Ghostty.app does (2× precise deltas, momentum phase). `SurfaceScrollView` only draws the scroller. It turns scroller drags into `scroll_to_row` and, under smooth scrolling, into the sub-row remainder (see `Macterm/Views/Terminal/AGENTS.md`). We removed the row accumulator in the style of iTerm2 from #102, with its Scroll speed slider. `mouse-scroll-multiplier` therefore means the same thing here as in Ghostty. Do not bring back a wheel path on the side of Macterm.

Overrides that Macterm must lock. The `smooth-scroll`, `smooth-cursor`, `cursor-morph` and `cursor-trail` lines from `MactermConfig.Animations` come in addition (see `Macterm/Views/Terminal/AGENTS.md`).

- `background-default-transparent = true`. This is a fork patch. The renderer skips the default background, so that `WindowAppearance` composites the translucency itself.
- `background-opacity = <Preferences.windowOpacity>`. This is the real value, so that the `background-opacity-cells` of the user works.
- `background-blur = 0`. Macterm calls the CGS blur SPI.
- `env = GHOSTTY_BIN_DIR=<bundle>/Contents/Resources/ssh-bridge`. This folder holds our `ghostty` shim that relays `+ssh` to `macterm ssh`. Keep it out of any folder in the PATH of the pane.
- `shell-integration-features`, emitted again with the flags of the user plus `no-path` (`ShellIntegrationFeatures.overrideValue`, #75). You cannot write the key bare.

The state of the UI of Macterm lives in `Preferences`. It never touches this pipeline.

**Custom app icon**. Macterm honors `macos-icon = custom` and `macos-custom-icon` with the semantics of Ghostty.

- `GhosttyApp.applyAppIcon` runs after every load and reload. It reads both keys from the *loaded* config, so a `config-file` include counts. It reads each key through `GhosttyConfigKey`, which pairs a key with the C shape that `ghostty_config_get` writes for it.
- It passes the keys to the pure function `GhosttyAppIcon.resolve` (`.bundled` or `.custom(URL)`). With no path, it uses `~/.config/ghostty/Ghostty.icns` of Ghostty. A path that is still relative after the expansion of `~` is invalid, because the cwd of a GUI app is not predictable.
- The one AppKit write is `AppIconPresenter.apply`. It sets `NSApp.applicationIconImage`. For a file that is missing, that it cannot read or that it cannot decode, it assigns nil. This restores the icon of the bundle.
- Every other `macos-icon` value is artwork of the Ghostty brand that we do not ship. We deliberately do not mirror the Dock-tile plugin of Ghostty.
- Hermetic caveat: `loadConfig` disables the user layer under `MACTERM_BENCHMARK=1`. To verify, use a throwaway `HOME`, `XDG_CONFIG_HOME` and `ZMX_DIR` plus `MACTERM_BENCHMARK_DATA_DIR`, and **no** `MACTERM_BENCHMARK`.

**`macos-hidden`**. `never` and `always` of ghostty map to `.regular` and `.accessory` through `MacosHidden`. This is a pure function with tests. The raw values are the own tag names of ghostty, so a rename of a case breaks the wire.

- `AppDelegate.applyActivationPolicy` applies it after `GhosttyApp.shared` at launch, and again on `.mactermConfigDidChange`. It skips AppKit when the policy already agrees. This is what makes the observer safe, although the observer fires too often.
- Read it as an **enum** through `GhosttyConfigKey`. libghostty writes an enum as a bare C string, not as a `ghostty_string_s`. An enum that you read as a `ghostty_string_s` comes back empty. This is the reason why `GhosttyColorSpace` went to raw text.
- Accessory mode is deliberately narrower than that of Ghostty.app, which builds no window. Macterm still builds one, because `MainWindow.onAppear` installs the responders and attaches the control handler.
- Every explicit request for a window (`window new`, `window focus`, `revealProject`) calls `MacosHidden.activateForWindowRequest`. It forces the activation with `ignoringOtherApps: true`. We measured that cooperative activation **refuses**, in silence, a plain `activate()` and an activate from another process.
- An accessory app has no menu bar. Settings, Quit, About and Check for Updates therefore lose their only route. Keybinds are not affected (`KeyRouter` handles them, not the menu bar).

**Process locale (#370)**. `ghostty_init` calls `setlocale(LC_ALL, "")`. Under any locale with a comma as the decimal separator, the rendering of toolbar glyphs in SwiftUI asserts inside CoreUI on macOS 27. The result is SIGTRAP, with nothing on stderr. `ProcessLocale.pinNumericToC()` runs right after `ghostty_init`. It touches only `LC_NUMERIC`. To reproduce, unset `LANG` (a launch from the Dock). `OS_ACTIVITY_DT_MODE=enable ACTIVITY_LOG_STDERR=1` shows the text of the assertion.

- `Macterm/Config/`: `MactermConfig` (with `Animations`), `MactermConfigFile` (`~/.config/macterm/config.ghostty`), `GhosttyConfigSource`, `GhosttyConfigText`, `TerminalFontFamily`, `ShellIntegrationFeatures`, `GhosttyColorSpace`, `MouseScrollMultiplier` and `MacosHidden`.
