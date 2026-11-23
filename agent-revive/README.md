# Agent Revive

Agents that start again after a reboot, for the [Herdr](https://herdr.dev) desktop app. The herdr terminal app (the TUI) resumes its agents after a restart. The desktop app does not: after a reboot, each terminal comes back as an empty shell. This mod saves the command that resumes each agent, and types it into the shell that comes back.

![Agent Revive: the count of saved agents in the status bar](preview.png)

The mod shows one line of text, for example `↻ 23 agents saved`. After a reboot the line reads `resuming 23 agents…` until each agent is back.

It resumes Claude Code (`claude --resume <id>`), Codex (`codex resume <id>`) and Antigravity (`agy --conversation <id>`). It works on macOS, for the terminals on this computer.

The entry has one mod, `mods/agent-revive`: a small view, `main.js`, and a zsh script, `hc-revive`, that does the work.

**Before you add it:** the mod runs `zsh`, and the script runs `hc` (herdr-core), `ps`, `lsof`, `jq` and `sysctl`. The script reads `~/.claude/sessions/` and the first line of open Codex session files to find session IDs. It writes two files in `~/.local/state/hc-revive/`. It types into terminals with `hc send`. It does not use the network.

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

There is nothing to do. Once a minute the mod saves the agents that run now. After a reboot, open Herdr. Within about a minute, each saved terminal that is back at its shell gets its resume command.

Click the text to save at once, for example right before a reboot.

To run it by hand:

```sh
~/.config/herdr-app/mods/agent-revive/hc-revive save      # save now and print the list
~/.config/herdr-app/mods/agent-revive/hc-revive restore   # resume each saved agent that is back at its shell
```

## What it does and does not resume

- An agent resumes at its last saved message. An agent that was in the middle of a turn does not continue the turn by itself.
- An agent in a folder that Claude Code does not trust for good, such as the home folder, stops at the trust question. Answer it once.
- A terminal that runs something else when the restore comes is left alone. The mod never types into a program.
- An agent you quit before the reboot is not resumed. It leaves the saved list within a minute.
- A power cut can lose the agents started in the last minute.
- Programs that are not agents, such as a `tail` or a dev server, are not restarted.
- Terminals on other machines are not saved. Those machines do not reboot with this one.

## Known limits

- macOS only. The script uses `sysctl kern.boottime`, `lsof` and BSD `stat`.
- The agent's own shell command must work in a login shell. The mod types `claude`, `codex` or `agy`, so a shell function or alias with your usual flags applies.
- Prime Agent and other agents are not resumed.

## License

Apache License 2.0. See [LICENSE](../LICENSE).
