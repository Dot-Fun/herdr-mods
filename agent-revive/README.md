# Agent Revive

Agents that start again after a reboot, for the [Herdr](https://herdr.dev) desktop app. The herdr terminal app (the TUI) resumes its agents after a restart. The desktop app does not: after a reboot, each terminal comes back as an empty shell. This mod saves each agent's structured resume identity, rebuilds an allowlisted command, and types it into the shell that comes back.

![Agent Revive: the count of saved agents in the status bar](preview.png)

The mod shows one line of text, for example `↻ 23 agents saved`. After a reboot it reports the entries that can still resume automatically separately from inert records that need manual review.

It resumes Claude Code (`claude --resume <id>`), Codex (`codex resume <id>`) and Antigravity (`agy --conversation <id>`). The mod runs on a macOS controller and saves both its local terminals and terminals on configured Linux Herdr cores.

The mod directory contains the status view, the `hc-revive` controller, and `supervise.pl`, which enforces the scheduled worker deadline.

**Before you add it:** the controller needs zsh 5.9 with the `zsh/system`, `zsh/files`, and `zsh/datetime` modules, the system `/usr/bin/perl`, `hc` (herdr-core), `ps`, `lsof`, `jq`, `sync`, `sysctl` and BSD `stat`. Each remote Linux core needs `zsh`, `hc`, `ps`, `lsof`, `jq`, and `/proc/sys/kernel/random/boot_id`. The script reads `~/.claude/sessions/` and the first line of open Codex session files to find session IDs. It writes mode-0600 state in `~/.local/state/hc-revive/` on the controller only. It uses existing Herdr machine connections through `hc exec`; recovery happens inside one remote helper that verifies the reached core's permanent ID before using that core's local `hc get` and `hc send`. It does not create a new listener or connection.

## Add it

Ask your Herdr agent:

```text
Read ~/.config/herdr-app/AGENTS.md, then add this mod: herdr.dev/mods/Dot-Fun/herdr-mods/agent-revive
```

To add it by hand:

1. Install `jq` if you do not have it: `brew install jq`.
2. Clone the repository: `git clone https://github.com/Dot-Fun/herdr-mods.git`.
3. Copy the mod: `cp -R herdr-mods/agent-revive/mods/agent-revive ~/.config/herdr-app/mods/`.
4. Herdr's own layouts are read-only. If you use one, clone it first: `herdr-app do layout.clone '{"name":"main","as":"my-main"}'`.
5. In your layout file, put the mod in a block. The mod only runs while a layout shows it. This example puts it at the right end of the status bar. Replace the `status` block with this row:

   ```json
   { "id": "status-row", "type": "row", "size": { "px": 28 }, "resizable": false,
     "children": [
       { "id": "status", "type": "block", "content": { "mod": "workspace-status" }, "size": { "weight": 1 } },
       { "id": "agent-revive", "type": "block", "content": { "mod": "agent-revive" }, "size": { "px": 190 } } ] }
   ```

6. Check the mod: `herdr-app check ~/.config/herdr-app/mods/agent-revive`.

## Use it

There is nothing to do. Once a minute the mod saves the agents that run now. After the controller or a configured Linux core reboots, open Herdr on the controller, or add Herdr to your login items so that it opens by itself. The next tick normally starts within about a minute; completion time scales with the saved batch and unavailable or ambiguous records may instead require manual review. Agent Revive does not power on a computer or launch Herdr by itself.

Clicking the text requests an asynchronous save. The worker acquires the controller lock and publishes its run ID before acknowledging startup. Every five seconds the view reads the worker outcome. It reports a failed or timed-out run and flags a completion older than 150 seconds as stale. An incomplete scan can preserve earlier entries for unavailable machines.

The controller supervisor gives each scheduled run one hour. It cleans up the local helper process group on every worker exit and kills the worker at its monotonic deadline. It publishes the observed outcome only while the same run ID is current. The next tick can acquire the released lock and continue from the journal. A synced attempt that was in flight needs manual reconciliation. The controller cannot cancel work already accepted by a remote core.

Before a planned reboot, run `hc-revive save` directly, wait for completion, and verify the intended machines and sessions in the snapshot. A contended manual save exits unsuccessfully.

To run it by hand:

```sh
~/.config/herdr-app/mods/agent-revive/hc-revive save      # save now and print the list
~/.config/herdr-app/mods/agent-revive/hc-revive restore   # resume local saved agents; tick handles remote recovery
```

## What it does and does not resume

- An agent resumes at its last saved message. An agent that was in the middle of a turn does not continue the turn by itself.
- An agent in a folder that Claude Code does not trust for good, such as the home folder, stops at the trust question. Answer it once.
- A terminal observed running something else is left alone. The helper checks for the kept root shell immediately before `hc send`, but inspection and send are separate operations; a process that starts in that narrow interval could receive the command.
- An agent missing from a successful scan normally leaves the saved list after 5 minutes. The wait is there because a shutdown stops agents one by one, and those must stay saved. For local reboot safety, a completely empty local scan retains prior local entries until another local agent is observed; successful empty remote scans still age their core normally.
- A remote core that is unavailable, returns malformed discovery data, or has no current route keeps its saved and pending entries unchanged. Unavailability never causes a send or consumes a retry.
- Remote state is keyed by the core's permanent 32-character machine ID. Aliases may change and duplicate aliases for one ID are scanned once. If a core is wiped or recreated and receives a new ID, its old entries are deliberately orphaned for manual reconciliation instead of being guessed onto the new machine.
- Legacy v1 remote `alias/tN` rows are never mapped onto a current core ID because an alias is not permanent identity. They remain inert manual-review evidence; local v1 `tN` rows can still migrate when their command is safe.
- Each local or remote send has a synced attempt record before dispatch. A confirmed send removes its own pending row immediately. An interrupted send or an ambiguous acknowledgement leaves evidence for manual review. Only an explicitly busy live terminal consumes a retry.
- A power cut can lose the agents started in the last minute.
- Programs that are not agents, such as a `tail` or a dev server, are not restarted.

## Known limits

- The controller is macOS. Remote recovery supports configured Linux cores whose default Herdr session is reachable through the aliases reported by `hc machine ls --json` and whose terminals appear in `hc ls --json`.
- The remote `hc` launched by the helper must resolve the same default Herdr session as the outer `hc exec`. Custom `HC_SESSION`/`HC_SOCKET` routing has not been validated.
- Remote discovery pipes the installed `hc-revive` script to remote `zsh`; the mod does not install its files or dependencies on those cores.
- The helper verifies the permanent core ID immediately before its local terminal check and send. Herdr 0.1.21 cannot target `hc exec` by permanent ID, so destruction or replacement of the remote core during that same helper process is not transactionally protected. Run a canary before relying on remote recovery.
- Terminal inspection and `hc send` are not one atomic Herdr operation. There is a residual inspect/send race locally and remotely, so a canary is mandatory before relying on unattended recovery.
- A manual restore imports eligible local snapshot entries into the same pending journal. A pending attempt blocks another automatic or manual dispatch for that terminal until the operator reconciles it. A separate explicit restore after a confirmed completion requests a fresh attempt.
- The agent's own shell command must work in a login shell. The mod types `claude`, `codex` or `agy`, so a shell function or alias with your usual flags applies.
- Working directories containing ASCII control characters are skipped. Saved commands and arbitrary legacy command text are never evaluated; v2 resume commands are rebuilt only from a supported agent name and UUID. Untrusted legacy pending records remain inert for manual inspection.
- Atomic rename plus `sync` orders pending state before a changed boot baseline and orders the new snapshot before clearing that deferred baseline. This is not a formal macOS power-loss guarantee equivalent to `F_FULLFSYNC`.
- Prime Agent and other agents are not resumed.

## License

Apache License 2.0. See [LICENSE](../LICENSE).
