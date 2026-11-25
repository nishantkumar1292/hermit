# Scripts and test harnesses

This file loads when you work in `scripts/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## End-to-end (`scripts/e2e/`)

The suite starts the real Debug app in a hermetic way through `MactermHarness`. It uses a throwaway `$HOME`, `MACTERM_BENCHMARK_DATA_DIR`, `MACTERM_RUNTIME_DIR` and `ZMX_DIR`. The runtime directory of the session server is per user. Without the override, a hermetic instance would use the developer's real server and share its sessions. The suite asserts through the CLI (`pane dump` and others read the live state of libghostty). Darwin notifications open the project and front the window (`BenchmarkControl`, which listens only under `MACTERM_BENCHMARK=1`; that flag also skips the notification prompt, Sparkle and the first-run seed).

Conventions:

- There is one app instance for each session. Keep it the **active app** before every test (`_active_app` in `conftest.py`: `lsappinfo front`, taken again through the `activate` hook of `BenchmarkControl`). That hook forces activation, because the cooperative request is refused once another app holds the front.
  - The password monitor watches only the focused pane of the key window. It runs no timer while the app is inactive.
  - A test that starts an instance of its own (`open -n` fronts it) leaves the shared instance behind Finder when it kills its own. This is what timed out both tests of `test_passwords.py` on CI.
- Use the `fresh_tab` fixture. Never change the initial pane.
- Every wait is a poll with a deadline.
- Type commands as `/bin/sh -c "…"` with no single quotes (the login shell of CI is bash 3.2).
- Target panes explicitly.
- Prove that something ran with markers that you assemble at run time (`printf started-%s <nonce>`). No signal for idle or running is independent of the environment.
- CI runs it as `Test / End-to-end`. A failure uploads `e2e-diagnostics`.

## Release build and older macOS (`scripts/older-macos-smoke.sh`)

`Test / Release Build` builds the universal Release app and its DMG with `.github/actions/build-release`. This is the same recipe that `release.yml` and `release-tip.yml` use. The test build has no secrets: it is ad-hoc signed, has the Sparkle placeholder key, and is never published. A release never reuses it. A release always builds again from its tagged commit, with the certificate and the key.

`Test / Smoke` starts the Release build on `macos-26` and `macos-15`, isolated, and requires these things:

- The control socket answers `status`. A newer SDK or Swift runtime can break the launch on an older system without a compile error.
- The app is a terminal. A new tab and a split each get a shell through the bundled zmx, and a command that the script types there shows its output in `pane dump`.
- On macOS 26, the app paints its adaptive icon by itself, so the private renderer still works there, and the icon's body spans 824 of 1024 px on its middle row, so the body is on the icon grid. This is the only test of either on macOS 26. If the icon is not there, the script runs the helper by hand so that the helper's own error is in the log.
- Before macOS 26, the app does not try.
- No crash report from the app, zmx or the icon helper appears during the run.

The script stops only the process that it started, and it kills its own zmx sessions. On a developer Mac it still reads and writes the real defaults domain of the build, because cfprefsd ignores `HOME`. The CLI takes `--socket` after the subcommand (`macterm status --socket <path>`).

## Session layer benchmark

`scripts/session_bench.py` measures what the session layer adds to typing, to a reattach, to memory and to idle wakeups, for v1's and v2's panes side by side, local and over ssh. It runs no app: a pty driver plays the terminal. CI runs it on a pull request that changes `server/`, `protocol/`, the script, its limits or the server build, and by hand (`.github/workflows/session-bench.yml`). The workflow starts on every pull request, and a `changes` job skips the measuring jobs when no such file changed, so its checks report also where they are required. It writes the report to the job summary. Run it locally with a zmx build (`run`, then `report`); `--ssh-host` adds the remote arms. The report gives p50, p95 and p99, and a table of each v1/v2 pair with the ratio:

- **Local panes**: one binary has both. `v1` is `zmx attach <s> <command>` (a v1 daemon for each pane), `v2` is `zmx connect <s> -- <command>` (a v2 session made through the server). The run sets `MACTERM_RUNTIME_DIR` to its throwaway folder, so v2 never uses the user's server.
- **Each pair runs in one run, alternated**: the echo keys go in rounds to v1 and v2 in turn, the reattaches alternate, and the idle panes of both are measured in the same window. A pair is never compared across runs or runners.
- **Echo**: write one key and time its echo, 500 keys. `bare` is `/bin/cat` on a pty in line mode, so only the kernel echoes (the floor). `v1` and `v2` are `/bin/cat` in a local pane. On Linux, `ssh` is `ssh -tt localhost /bin/cat` (the floor for a remote pane), `remote-v1` is a remote pane of v1 (`ssh … zmx attach`, a login of its own), `remote-v2` is a remote pane of v2 (`ssh -S <master> … zmx connect`, a channel over the run's one connection, as `SSHConnections` does), and `relay` is a channel of `zmx proxy` over that connection (the one stream for each host that the app will use for its panes).
- **New remote pane** (Linux): from the start of the pane's ssh to the first echo after the session prints its ready marker, 5 panes in each layer, alternated. v1 logs in for each pane. v2 opens a channel, and its first pane starts the host's server. The report gives the login of the connection on its own line, and adds it to v2's time to the 5th pane.
- **Relay flood** (Linux): one relay channel prints as fast as it can, 3 times. The run times the keys of a second channel, channel 0's pings, and the interrupt of the flood until its prompt shows, and counts the skips ahead (`relay.skip_ms`). The Linux job limits loopback to 100 Mbit/s. The report gives the rate that the client got: a flood with no skip was not faster than the link.
- **Reattach**: fill a session with 10,000 lines of 199 characters on a 200-column terminal, detach, then time a new client until the echo of a marker line. The marker goes in after the client takes the terminal, and its echo comes after the replay. The report gives the size of the replay.
- **Idle** (macOS): 1 and then 9 panes of `/bin/cat` in each layer. It reads `phys_footprint` and the interrupt wakeups (`proc_pid_rusage`, with no sudo; the kernel counts each package idle wakeup also as an interrupt wakeup) of the session side (v1's daemons; v2's server and sessions) and of the clients, over 60 s. The programs in the panes are not counted. The run ends the sessions of the other arms first, so v2's server holds only the idle sessions. v2's server carries the argv of the client that started it, so the run finds it by the peer pid of its socket.
- A key goes in only after the client turns echo off on its pty and the session prints a ready marker. Before that, the kernel or the remote pty echoes the key, and the time is not the session layer's. An ssh client turns echo off before the remote side runs zmx.
- The JSON records `ssh -V`: OpenSSH 9.5 and later delays keystrokes (`ObscureKeystrokeTiming`).
- The report gives p95 and p99 only for 20 samples or more.
- Not measured here: the GUI part of typing latency (`keyDown`, the render, the compositor), and the app's own memory.
- Every session that a run makes is ended after the run, in a throwaway `ZMX_DIR` and runtime folder. A session with no client drops terminal replies.
- **The gate** (`check`, the step Compare v2 with v1) fails the job when v2 is worse than v1 in the same run. It compares echo p50 and p95 (local and remote), the new remote pane, the reattach and the memory as v2 / v1, and the idle wakeups for each pane as v2 − v1. A limit is no change plus the noise: the largest distance of one run from the median of 20 runs (`limits`, written to `scripts/session_bench_limits.json`, one entry for each system). A v2 that is worse passes also when the difference is under `FLOOR_MS` (1 ms, typing and reopen) or `FLOOR_MB` (2 MB, memory): a user cannot feel it (Ethan, 2026-11-10). Wakeups have no floor. A measurement that the limits name and the run does not have fails. A job whose Server job fails fails too, because a skipped job counts as passing where a check is required. To make the limits again, run the workflow by hand 20 times on one commit (a temporary 20-run matrix works), download the `session-results-*` artifacts, and give `limits` all the JSONs. The gate has no unit test: check it by running `check` on a results JSON against a limits file with a limit of -5.
- No comparison with an earlier run: v2 is compared with v1 only.

- `scripts/`: `setup.sh`, `build-server.sh` (the server builds and their key), `build.sh`, `_lib.sh` (version mapping, update channel), `publish-appcast.sh`, `_harness.py` (`MactermHarness`, for e2e) and `session_bench.py` (the session layer benchmark). It also has `e2e.sh` with `e2e/` (the pytest suite), `ghosttykit-api-diff.sh`, `ghostty-shim.sh` and `record-demos/` (the demo clips of the website).
