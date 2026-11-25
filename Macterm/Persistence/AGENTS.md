# Persistence

This file loads when you work in `Macterm/Persistence/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Persistence

- Workspaces are in `~/Library/Application Support/<display name>/workspaces_v3.json` (schema v6, written as v7 only while desktop widgets exist). Projects are in `projects.json`. The wrapper configs are next to them. Debug builds use `Macterm Debug/`, and the Debug bundle is `Macterm Debug.app` (`PRODUCT_MODULE_NAME` stays `Macterm`). Write the space wherever you name the bundle by path.
- `Pane` IDs are new at every restore. The session identity (`sessionID` and `sessionName`, stored exactly as given) is what connects a pane to its session again.
  - Only an explicit Apply Layout applies a declared layout (palette, menu, Settings row, `layout apply`). When you select a project or start Macterm again, Macterm never reads it. The snapshot restores, and a project without a snapshot gets the default workspace.
- **A directory is not an identity**. `ProjectStore.create` always appends a new project. `findOrCreate` exists only for callers that must be idempotent (the `open-project` hook of `BenchmarkControl`, and the folder rows of the palette).
- Project declarations are YAML in `~/.config/macterm/projects/`. All build flavors share them. They look at the `$HOME` env first, through `ProjectPath.currentHome`.
  - `name:` is for display only. `path:` is the identity (scp-style, with `~` when Macterm writes it). `tabs:` is optional.
  - The schema is `assets/project.schema.json`. Keep them in sync.
  - Only an explicit Save Layout and the editor of the user write a file. Only Settings → Projects → Layouts → Remove deletes it.
  - Matching is by the canonical `path:`. The slug of the name of the project breaks a tie when one directory backs several projects (`ProjectSlug.owns`). Macterm surfaces duplicates. It never deletes them.
- `save` records `run:` as the live foreground command (`ProcessInspector.runningCommand`, for a remote project through the probe cache). It records `shell:` only for a shell that is not the default. `apply` (`LayoutReconciler`) matches by the same `(run, cwd)`. Files that do not parse surface `LayoutFileError`. An empty `tabs:` is a bare declaration.
- v1.22.0 removed the .macterm/layout.yaml in the repo. `LayoutFile` has no form on disk. Do not add helpers to load or serialize it.
- **The tab of the quick terminal persists too** (`WorkspacesFile.quickTerminal`, an optional section with deliberately no change of the schema version, see its doc comment).
  - `AppState` adopts `QuickTerminalService.shared.splitState` one time (`adoptQuickTerminal`, which you can inject at init for tests). It takes a snapshot of it in every `saveWorkspaces`. It hands the tab back in `restoreSelection`. It counts the sessions of the tab as claims. The panes connect only when the panel is shown for the first time, so until then they have zero clients.
  - `QuickTerminalSplitState` reports its own splits and closes through `onStructureChange`, because it owns no `AppState`. Macterm refuses a restore after the panel was shown in this run.
  - Results: a quit kills nothing and confirms nothing while zmx is bundled. The confirmation returns, with the quick terminal included, only when zmx is not available. A close of a pane in the panel is still the one permanent kill.
- Settings → Projects duplicates the alerts for layout and remove. Keep them gated on `AppState.DialogHost`, so that a confirmation that the palette raises does not also open Settings.

- `Macterm/Persistence/`: `WorkspacePersistence` (snapshots, `WorkspaceStore`), `ProjectStore`, `FileStorage`, `ProjectFile` and `ProjectFileStore` (`~/.config/macterm/projects/`), `LayoutBuilder`, `LayoutSerializer` and `LayoutReconciler`, `LayoutFile` (only in memory), `PinnedLayoutStore`, `WidgetLayoutStore`, and `PasswordStore` (Keychain and `PasswordVault`).
