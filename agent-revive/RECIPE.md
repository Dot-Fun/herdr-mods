# Agent Revive

One line of text in the status bar that counts the agents saved for a restart. Behind it, a controller script saves how to resume local agents and agents on configured Linux Herdr cores, then checks for a kept root shell immediately before each recovery send. Inspection and send are not atomic.

![Agent Revive](preview.png)

## What you see

A block 28px high and 190px wide at the right end of the status bar: `chrome` background, 1px `border` line on top, 14px side padding, text right-aligned at 11.8px.

- `↻ 23 agents saved` in `dim`: the unique actionable agents in a valid v2 snapshot.
- `↻ no agents saved` in `dim`: there is no snapshot yet.
- `↻ 2 saved entries need review` in `working`: inert, malformed, orphaned, or colliding snapshot rows are excluded from the saved-agent count.
- `↻ resuming 5 agents…` in `working`: a restore after a reboot still has that many terminals to do.
- `↻ 2 entries need review` in `working`: inert, colliding, attempting, or delivery-ambiguous evidence will not be retried automatically.
- Hover turns the text `foreground` and shows the tooltip `Agents that resume after a reboot. Manual-review records are not retried. Click to save now.`

## How it behaves

- At startup and every 60 seconds the view requests a worker. After acquiring the shared lock, the worker atomically writes its random run ID and PID to `worker.json` and acknowledges startup. A second window receives a busy response. The system Perl supervisor starts the worker in a private process group and enforces a one-hour monotonic deadline independently of the UI exec limit. At expiry it kills the worker. It cleans up the helper group on every worker exit, then publishes the exit or timeout under the controller lock if the running record still matches. Synced send markers survive for manual review.
- Every five seconds the view reads the published worker outcome. Failed discovery, publication, or checkpointing takes precedence over the saved count. The supervisor records a crash as failed and an enforced deadline as timed out. A success record older than 150 seconds indicates stale status. A retry keeps the previous failure visible until completion.
- **A click on the text** runs `hc-revive save`.
- **`save`** lists live, kept local terminals (`hc ls --json`, `hc get`). One `ps -axo pid=,tty=,comm=` call gives the tty of each terminal's root process and the processes on it. One `lsof` call for all `codex` and `agy` processes gives their open files. For each terminal, it looks for an agent on the tty:
  - Claude Code: a file `~/.claude/sessions/<pid>.json` whose process is on the tty. The command is `claude --resume <sessionId>` and the folder is the file's `cwd`.
  - Codex: a `codex` process on the tty that holds a `rollout-*.jsonl` file open. The first line of the file gives `payload.session_id` and `payload.cwd`. The command is `codex resume <session_id>`.
  - Antigravity: an `agy` process on the tty that holds `antigravity-cli/brain/<id>` open. The command is `agy --conversation <id>`, in the process's working folder.
  For remote discovery it validates `hc machine ls --json`, deduplicates configured aliases by permanent core ID, and pipes this same script to one usable alias with `hc exec -i --on <alias> zsh -s -- remote-scan`. The reached core verifies `hc server status --json .id` and returns that ID with its Linux boot identity from `/proc/sys/kernel/random/boot_id`. A mismatched, failed, or malformed scan fails only that core.
  It writes `~/.local/state/hc-revive/snapshot.json` as `{version: 2, boot, machines, terminals}`. `machines` maps permanent core IDs to last observed Linux boot IDs. Each terminal stores `{machine, terminal, cwd, agent, session, seen}`; `machine` is null for the controller. Aliases and shell commands are not persisted in v2. A terminal missing from a successful scan ages out after 5 minutes, but an unavailable core's entries never age. An empty local scan preserves old local entries even when a remote scan succeeds.
- **`restore [file]`** selects eligible local rows from the supplied snapshot and uses the same pending journal as automatic recovery. An explicit pending file resumes queued work. Before every dispatch the controller renames and syncs an attempt marker. Local and remote recovery both require a live kept terminal at its root shell and rebuild the allowlisted command. The remote helper also verifies the permanent core ID. Each confirmed send removes that row immediately, and an uncertain result retains its marker for manual review.
- **`tick`**:
  1. Acquires the same persistent kernel lock as save and restore. Contention skips the scheduled run. Process exit releases the lock.
  2. Checks whether the controller's Herdr core answers `hc server status`.
  3. Skips a recent snapshot from this boot if there is no pending work. A scheduled retry after failure or interruption bypasses the 45-second window.
  4. Probes each available core boot ID. First observation records a baseline only. A changed boot selects only that core's saved entries.
  5. Merges selected entries into `pending.json` with an atomic mode-0600 rename, calls `sync`, advances and syncs the snapshot baseline, and only then clears the deferred baseline. Applying an uncleared baseline again is idempotent.
  6. Checkpoints each local or remote result independently. Explicit success removes the row, busy retries up to ten available checks, and unavailable terminals retain their retry budget. An ambiguous attempt remains inert for manual reconciliation.
  7. Saves.

## Built from

- **`mods/agent-revive/main.js`**: a `View` with `init`, `tick(command, cx)` and `render`. `mod.json` is `{"place": "none"}`.
- **`mods/agent-revive/hc-revive`**: a zsh script with `save`, `restore` and `tick`. `HC_REVIVE_STATE` overrides the state folder, for tests.
- **Layout**: the `status` block sits in a row with an `agent-revive` block of 190px.
- **herdr functions**: `exec`, `appHome`, `home`, `readTextFile`, `theme`, `checking`.
- **Controller programs**: zsh 5.9 with the `zsh/system`, `zsh/files`, and `zsh/datetime` modules, `/usr/bin/perl` with core POSIX and Time::HiRes modules, `hc`, `jq`, `ps`, `lsof`, `sync`, `sysctl`, and BSD `stat`.
- **Remote programs/data**: `zsh`, `hc`, `jq`, `ps`, `lsof`, and `/proc/sys/kernel/random/boot_id`, in the default remote Herdr session.

## Watch out

- herdr-core never runs a lost terminal's command again. It gives the terminal a shell at the same suffix. Local entries use that suffix directly; remote entries pair it with the permanent core ID and resolve a current alias only at restore time.
- Read session IDs from the running processes, not from agent hooks. Agents that started before the mod was added must be saved too.
- The open Codex rollout files are often sub-agent threads. `payload.session_id` names the root session. `payload.id` does not.
- A Claude session resumes only from its own folder. Type `cd <cwd> &&` before the command.
- Compare the foreground process ID with the terminal's root process ID before any local or remote `hc send`. A send into a running agent would become a prompt.
- A shutdown stops the agents one by one while the mod can still run. The 5 minute rule protects partially emptied scans; preserving a completely empty local scan also protects the last local agent during reboot.
- On macOS each `ps` call costs about a third of a second, however few processes it names. Call `ps` once for a save, not once for each terminal. The same goes for `lsof` and `jq`.
- Right after a reboot the terminals are shells, so a save would find no agents. Do the boot check before the save, and never replace a snapshot with an empty one.
- The core can bring a terminal back a little late. Keep the terminals that were not ready in `pending.json` and try again on the next ticks.
- Treat the whole permanent machine inventory as a trust boundary. Invalid IDs, malformed names, or one alias mapped to different IDs disable all remote baseline, aging, and send activity for that tick. Unknown fields and states are tolerated; `connected` aliases are preferred.
- Do not equate an alias with identity. Multiple aliases may name one core and must be scanned once. A recreated core receives a different permanent ID, so old state is left orphaned for an operator rather than attached to the replacement.
- Herdr 0.1.21 cannot address `hc exec` by permanent ID. Run identity verification, terminal inspection, and local send in one remote helper; never split them across controller calls. Even then, replacement of the core during that same helper process is not transactionally protected.
- The remote helper assumes its inherited/default `hc` session resolves the same server reached by the outer exec. Custom `HC_SESSION` or `HC_SOCKET` routing requires separate validation.
- Validate exact JSON documents from remote scans and terminal inspection. Log prefixes, partial arrays, or malformed fields make the core unavailable; they must never look like an empty successful scan.
- Reject all ASCII control characters in working directories. `@sh` quotes shell syntax, but it does not neutralize terminal-editing bytes such as Ctrl-U.
- Existing local v1 `{address,cwd,cmd,seen}` rows migrate only when `address` is a bare `tN` and the command is an exact supported resume form with a UUID. Legacy remote `alias/tN` rows never inherit the core currently using that mutable alias; they and all other unresolved or unsafe records remain inert evidence.
- Every dispatch has a synced attempt marker. Inspect and reconcile interrupted attempts before clearing them. This applies to manual restore as well as automatic reboot recovery.
- `sysctl -n kern.boottime` prints `{ sec = …, usec = … }`. Match `sec` at the start of the line, or the pattern takes `usec`.
- Every Herdr window runs its own copy of the mod. Top-level `save`, `restore`, and `tick` cooperate on one persistent fcntl lock; its descriptor is not inherited by executed children and process exit releases it. Without that lock and the 45 second rule, two windows could type the same command twice.
- A snapshot or pending file can have at most one actionable row per stable `(machine, terminal)`. Every colliding row remains as inert evidence while independent entries can proceed.
- Atomic rename plus `sync` provides the required pending-before-snapshot and snapshot-before-clear ordering for a controlled reboot. It is not a formal macOS sudden-power-loss guarantee equivalent to `F_FULLFSYNC`.
- Do not start the script from `init` during `herdr-app check`. Test `checking()` first.
- A view only runs while a layout shows its block. `"place": "none"` alone never starts it.

## Done when

- `zsh test-hc-revive.zsh` passes the hermetic mock suite for v1 migration, local regression, stable IDs, alias rebinding, duplicate aliases, changed boots, collision replacement, precommit ordering and failure, ambiguous delivery, worker deadlines and post-start failures, strict restore checks, control-byte rejection, and mode-0600 state.
- `herdr-app check mods/agent-revive` passes and `herdr-app status` shows `errors: []` in an authorized deployment validation.
- `hc-revive save` prints one line for each local or reachable remote agent terminal, and a Codex ID is a root session.
- A kept terminal that runs Claude, killed with `kill -9` on its root process, comes back as a shell. `hc-revive restore` then resumes the same session, and a second restore reports the terminal as busy.
- With another agent still observable on the same origin, two saved entries with `seen` 100 seconds and 400 seconds old cause the next successful `save` to keep the first and drop the second.
- `time hc-revive save` shows less than one second of processor time for 25 agents.
- With one core boot ID changed, `tick` writes only that core's entries to `pending.json` before advancing its baseline, types nothing into running agents, and leaves unavailable siblings untouched.
- The status bar shows the count of saved agents.
- Before production reliance, a disposable remote-core canary passes end to end: observe and verify the saved snapshot, reboot the canary, confirm exactly one intended resume, confirm no busy terminal receives input, and confirm pending/status state settles correctly.
