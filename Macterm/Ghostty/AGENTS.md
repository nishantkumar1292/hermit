# The libghostty bridge

This file loads when you work in `Macterm/Ghostty/`. The root `AGENTS.md` has the build, the architecture and the conventions.

- **The header is under `#pragma clang assume_nonnull` since `build-2026-11-06`.** A pointer that the header does not mark `GHOSTTY_NULLABLE` imports into Swift non-optional, and a NULL there is undefined behavior, not nil. A fork field that can be NULL must carry the macro in its patch (`command` of `command_finished`, macterm/ghostty#41). `ghostty_runtime_config_s` has no zero initializer any more: every callback is given in its memberwise init, in `GhosttyApp.makeRuntimeConfig`, which is `nonisolated` on purpose. A closure literal made inside the `@MainActor` init is inferred main-actor-isolated, and libghostty calls the wakeup and the clipboard callbacks from its own threads: the test host died with SIGTRAP in `dispatch_assert_queue` at the first wakeup. The closures name `GhosttyApp.sharedCallbacks`, a nonisolated static, for the same reason. `GhosttyCallbacks.reportedCommand` reads the one field that a build imported non-null through its offset, as a nullable pointer, so that a NULL is nil under either header.
- A pinned tag is **not immutable**. The fork has uploaded assets again under the same tag. If a build behaves differently from an identical commit, compare the sizes of `GhosttyKit.xcframework/*/Headers/ghostty.h` before you suspect your own change. For the same reason, the DerivedData caches of CI have a key that includes the hash of that header. Do not merge the restore step and the save step in `test.yml`. Do not add a `restore-keys` fallback that does not depend on the framework.
- Setup needs the `GHOSTTY_ACTION_OUTPUT_ACTIVITY` ABI (the heartbeat for tab activity). To bisect to a commit from before that requirement, install a GhosttyKit of the same time by hand. Do not run setup.

## Bundled ghostty resources

The bundle mirrors Ghostty.app. `Contents/Resources/ghostty/{themes,shell-integration}` is there, with the compiled terminfo at the **sibling** `Contents/Resources/terminfo/`.

- `GhosttyApp.resolveResources()` sets `GHOSTTY_RESOURCES_DIR` from our own candidates. It ignores any value that it inherits.
- **Never set `TERMINFO` ourselves**. libghostty overwrites it with `dirname(GHOSTTY_RESOURCES_DIR)/terminfo`. The terminfo must therefore be a sibling of `ghostty/` (#39 and #40).
- The tree uses the hashed layout of macOS (`terminfo/78/xterm-ghostty`).
- `BundledResourcesTests` asserts all of this. It skips before setup has run.

## Adaptive terminal background

`AdaptiveTerminalBackground` infers the background of a TUI from the BGRA8 IOSurface of libghostty. It fails closed if the format changes. It can also take OSC 11 directly.

- **Macterm presents a report over the inference. It never writes the report into the inference** (`AdaptiveTerminalChrome.reportedCandidate`). libghostty reports an OSC 111 reset as a change *to the configured color*. A report that reset the stabilizer left the stale sampled color as the fallback. The `:theme` of Helix then left a hole of tint over the bare shell after you quit, until the config reload of a new surface.
- The report carries the alpha at which the renderer paints cells (`reportedPaintAlpha`: the window opacity under `background-opacity-cells`, if not opaque). It is never a bare 1.
- The alpha floor derives from the window opacity (`minimumPaintedAlpha`). Painted cells arrive premultiplied at `background-opacity`.
- A color that is translucent gets no fill for the pane. The window tint is **cut out from under its whole pane**. Its margin is **filled again in its own color**. `TintCutout` does this, with a `TerminalPaintRegion` for each pane.
  - The paint, which Macterm walks along the edges by alpha through `paintedUnitBounds`, stays bare.
  - The `window-padding` around it, which nothing painted, gets the color of the pane at the window opacity, on a sibling layer. In a split, the window keeps the configured theme. When Macterm cut out only the paint, it framed every TUI in that theme.
- The tint therefore lives in a view that you can mask. It never lives in `NSWindow.backgroundColor` or `NSGlassEffectView.tintColor`. The tint does not depend on the key status. Colors are read in the color space of the renderer (`GhosttyColorSpace`).
- `AdaptiveTerminalInferenceGate` freezes the inference while `ghostty_surface_has_selection` is true. It protects a confirmed color from repaints that have no output heartbeat within 1.5 s. This is for adoption only, never for clearing.
- The winning color must also span 0.80 of the sampled grid **on each axis** (`minimumBackgroundExtent`). This keeps a slide or an image from tinting the window again.
- **A region follows the visibility of the pane, not its frame** (`AdaptiveTerminalChrome.paintRegion`). A pane that zoom hides keeps its frame, its color and its sampled paint at opacity 0. Its hole showed the bare material inside the zoomed pane. `hiddenInLayout` drops the region at once. It restores the region only after the split animation faded the pane back in (`layoutVisibilityDidChange`).
- The quick terminal is outside the tint of the whole window.
