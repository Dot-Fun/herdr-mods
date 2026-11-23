# Agent Revive

One line of text in the status bar that counts the agents saved for a restart. Behind it, a script saves how to resume each local agent, and after a reboot types that command into each terminal that came back as a shell.

![Agent Revive](preview.png)

## What you see

A block 28px high and 190px wide at the right end of the status bar: `chrome` background, 1px `border` line on top, 14px side padding, text right-aligned at 11.8px.

- `↻ 23 agents saved` in `dim`: the number of agents in the snapshot.
- `↻ no agents saved` in `dim`: there is no snapshot yet.
- `↻ resuming 5 agents…` in `working`: a restore after a reboot still has that many terminals to do.
- Hover turns the text `foreground` and shows the tooltip `Agents that resume by themselves after a reboot. Click to save now.`

## How it behaves

- **At start and every 60 seconds** the view runs `hc-revive tick`, then reads the two state files to refresh its text.
- **A click on the text** runs `hc-revive save`.
- **`save`** lists the live, kept terminals of this computer (`hc ls --json`, `hc get`). One `ps -axo pid=,tty=,comm=` call gives the tty of each terminal's root process and the processes on it. One `lsof` call for all `codex` and `agy` processes gives their open files. For each terminal, it looks for an agent on the tty:
  - Claude Code: a file `~/.claude/sessions/<pid>.json` whose process is on the tty. The command is `claude --resume <sessionId>` and the folder is the file's `cwd`.
  - Codex: a `codex` process on the tty that holds a `rollout-*.jsonl` file open. The first line of the file gives `payload.session_id` and `payload.cwd`. The command is `codex resume <session_id>`.
  - Antigravity: an `agy` process on the tty that holds `antigravity-cli/brain/<id>` open. The command is `agy --conversation <id>`, in the process's working folder.
  It writes `~/.local/state/hc-revive/snapshot.json`: `{boot, terminals: [{address, cwd, cmd, seen}]}`. `boot` is the boot time in seconds and `seen` is the time of the last save that found the agent. A terminal that was in the last snapshot and has no agent now stays in the snapshot until its `seen` is 5 minutes old.
- **`restore [file]`** goes through the saved terminals. For a terminal that is live and whose foreground process is its own root shell, it runs `hc send <address> "cd <cwd> && <cmd>"` and waits 100 ms. It leaves every other terminal alone and reports it.
- **`tick`**:
  1. Stops when the core does not answer `hc server status`.
  2. Takes a lock folder, so that several windows do not run it at the same time.
  3. Stops when the snapshot is from this boot and less than 45 seconds old.
  4. When the snapshot's `boot` is not this boot, copies it to `pending.json` with `tries: 0`.
  5. When `pending.json` exists, restores from it and keeps only the terminals not yet resumed. It deletes the file when none are left or after 10 tries. While the file exists, it does not save.
  6. Saves.

## Built from

- **`mods/agent-revive/main.js`**: a `View` with `init`, `tick(command, cx)` and `render`. `mod.json` is `{"place": "none"}`.
- **`mods/agent-revive/hc-revive`**: a zsh script with `save`, `restore` and `tick`. `HC_REVIVE_STATE` overrides the state folder, for tests.
- **Layout**: the `status` block sits in a row with an `agent-revive` block of 190px.
- **herdr functions**: `exec`, `appHome`, `home`, `readTextFile`, `theme`, `checking`.
- **Programs**: `zsh`, `hc`, `jq`, `ps`, `lsof`, `sysctl`, `stat`, `find`.

## Watch out

- herdr-core never runs a lost terminal's command again. It gives the terminal a shell at the same address, so the address is the key between save and restore.
- Read session IDs from the running processes, not from agent hooks. Agents that started before the mod was added must be saved too.
- The open Codex rollout files are often sub-agent threads. `payload.session_id` names the root session. `payload.id` does not.
- A Claude session resumes only from its own folder. Type `cd <cwd> &&` before the command.
- Compare the foreground process ID with the terminal's root process ID before any `hc send`. A send into a running agent would become a prompt.
- A shutdown stops the agents one by one while the mod can still run. Without the 5 minute rule, a save in that moment drops the agents that are already gone, and they never resume.
- On macOS each `ps` call costs about a third of a second, however few processes it names. Call `ps` once for a save, not once for each terminal. The same goes for `lsof` and `jq`.
- Right after a reboot the terminals are shells, so a save would find no agents. Do the boot check before the save, and never replace a snapshot with an empty one.
- The core can bring a terminal back a little late. Keep the terminals that were not ready in `pending.json` and try again on the next ticks.
- `sysctl -n kern.boottime` prints `{ sec = …, usec = … }`. Match `sec` at the start of the line, or the pattern takes `usec`.
- Every Herdr window runs its own copy of the mod. Without the lock and the 45 second rule, two windows could type the same command twice.
- Do not start the script from `init` during `herdr-app check`. Test `checking()` first.
- A view only runs while a layout shows its block. `"place": "none"` alone never starts it.

## Done when

- `herdr-app check mods/agent-revive` passes and `herdr-app status` shows `errors: []`.
- `hc-revive save` prints one line for each local agent terminal, and a Codex ID is a root session.
- A kept terminal that runs Claude, killed with `kill -9` on its root process, comes back as a shell. `hc-revive restore` then resumes the same session, and a second restore reports the terminal as busy.
- With two entries added to the snapshot by hand, one with `seen` 100 seconds old and one 400 seconds old, the next `save` keeps the first and drops the second.
- `time hc-revive save` shows less than one second of processor time for 25 agents.
- With `boot` in the snapshot changed to an old value, `tick` writes `pending.json`, types nothing into running agents, and saves again after the pending file is gone.
- The status bar shows the count of saved agents.
