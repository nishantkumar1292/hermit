# Search

This file loads when you work in `Macterm/Search/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Search (`Macterm/Search/`)

**Every search in the app goes through one engine**. This covers the palette and its screens. It covers the lists in Settings (Keymaps, saved passwords). It also covers the path mode of the palette. The path mode completes and does not search, but it uses the engine in the same way. Do not add a matcher of your own. The palette of a plugin must use the engine too.

- **The ranking is the ranking of fzf** (`SearchScoring`, its `FuzzyMatchV2` and its constants).
  - The letters of a query must be a subsequence. The score has bonuses for word starts, path components and camelCase humps (Macterm reads them from the unfolded text). Consecutive runs carry the bonus of their first character. Gaps have penalties.
  - Whitespace splits the query into terms. All terms must match, in any field of a record (`split right` is the same as `right split`). A later field costs `SearchIndex.fieldPenalty` for each position. A match in a title therefore beats the same match in a subtitle.
  - Ties go to the shorter title, then to the order of the list. `SearchIndex.rank`, `Search.rank` and every palette list through `rankedByScore()` sort in the same way.
  - There is one deliberate difference from fzf: no clamp at zero. A score stays a true maximum across a long gap.
- **Lists in Settings rank too** (`Search.rank`). They never only filter. Fuzzy matching admits letters that are spread across words. In a list that stays in its own order, such a row looks the same as a strong match.
- **Macterm prepares text one time** (`SearchText`).
  - It folds case and diacritics for scalars. For ASCII it does not use Foundation. A combining mark, as in a decomposed `é`, folds away. It neither breaks a run nor starts a word.
  - It stores a bonus for each scalar and a 64-bit character mask. It also stores offsets back to the original string for highlighting (`PaletteItem.highlights`, which the row draws in semibold).
- **The engine is built for long lists** (`SearchIndex`).
  - The mask rejects with one AND. A forward scan rejects the rest before any scoring.
  - The DP runs only over the window that a match can occupy. It uses two rows at a time in buffers that Macterm uses again (`SearchScratch`).
  - Preparation and matching split across cores above `parallelThreshold`.
  - `search(limit:)` keeps only the best K, in order.
  - `SearchSession` searches only the last matches when a keystroke only narrows the query (`SearchQuery.narrows`). Files and the listing of an extension search through it. Each one prepares the text one time, when its rows arrive.
  - We measured 100k paths in an optimized build: about 45 ms to prepare and 2 to 5 ms for each search.
  - `Search` is the shortcut for a short list that you build at the moment of use.
- `SearchEngineTests` pins the ranking on the own command titles of the app. It also makes sure that top-K, the parallel path and session narrowing give the same answers as the plain path. Change the scoring only when you mean to change those tests.

- `Macterm/Search/`: `SearchText` (prepared, folded text), `SearchScoring` (the scoring of fzf and the positions of highlights), and `SearchIndex` with `SearchSession` and `Search` (the engine, see Search).
