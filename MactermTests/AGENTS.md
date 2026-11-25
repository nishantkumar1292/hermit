# Unit tests

This file loads when you work in `MactermTests/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Unit (`MactermTests/`)

There is one `XxxTests.swift` for each production type. It mirrors the source path. The tests use `@testable import Macterm` and `@MainActor`.

- Swift Testing suites run in parallel. Anything that touches shared state (preferences, stores) is injected. Tests that need `AppState` or `WorkspaceStore` inject a file in a temp directory.
- Helpers are in `Support/`: the DSL `TreeBuilder` (`H(pane("a"), V(pane("b"), pane("c")))`), `TreeRenderer` and `LayoutFixture`.
- The coverage targets the model, persistence, palette and hotkey logic, and pure helpers. Nothing unit-tests SwiftUI views and the bindings of libghostty.
- A wait that polls for a condition must sleep. Do not use `Task.yield()` in a loop with a fixed count.
