# Machine Switch

Herdr's Spaces sidebar with an on/off switch on each remote machine's row. A machine that is off stays in the list, drawn dim, without its spaces.

![Machine Switch](preview.png)

## What you see

The sidebar looks the same as Herdr's `spaces` mod at app version 0.1.16, with these changes to a remote machine's header row (26px high, 8px side padding, 7px gap, 11px `dim` text):

- **On**: server icon 13px, the machine's name, its state text when not connected, the switch, the `+` button when connected, the fold chevron 11px. There is no status dot. "This computer" keeps its dot and has no switch.
- **The switch**: 22 x 12px, 6px corners. The track is `border` in both states. On: an 8px `ansi2` knob at left 12, top 2. Off: an 8px `dim` knob at left 2, top 2. Tooltip `Hide <name>` when on, `Show <name>` when off.
- **Off**: icon and name at 0.45 opacity, then the switch, then a 33px spacer so the switch stays in the same column as on rows. No `+`, no chevron, no state text, no hover fill. No rows under it: no spaces, no "Loading…", no "New space there", no login note.
- **Narrow rail** (sidebar under 160px): a machine that is off shows its icon at 0.45 opacity, with the tooltip `<name> · hidden. Right-click to show.`

## How it behaves

- **A click on the switch** adds the machine's name to shared `machines.hidden`, or removes it. The click stops propagation, so it does not fold the group.
- **A click on the header of a machine that is off** does nothing.
- **Narrow rail**: a right-click on a remote machine's icon flips the same value. There is no switch there.
- **Spaces**: rows of a machine in `machines.hidden` are filtered out before drawing. The machine's name stays in the list of remote machines, also when the core no longer lists it, so it can be switched back on.
- **Drag a machine's header onto another machine's header** to move its group there. While the pointer is over the other header, a 2px `accent` line shows on the edge where the group lands, and the dragged header draws at 0.5 opacity. The release writes the new order of names to shared `machines.order`. Groups draw in that order. A machine not in the list comes after the listed ones.
- **A drag ends on any release inside the mod, and when the pointer leaves the mod.** Both clear the drag state of machines and of spaces, so no drop line stays on screen.
- **All windows on one computer follow.** Shared state is per window, because each window has its own app home. So each synced key also lives in a file in `~/.config/herdr-shared/`: `machines-hidden.json` and `machines-order.json`, each a JSON array of names. A change writes the file. Each window watches the folder and copies a changed file into its own shared state. At start, a window reads the files, and writes a file that does not exist from its own shared state.
- Agent status, drag to reorder spaces, git tails, fold state and the reconnect flow are Herdr's and unchanged.

## Built from

- **`mods/spaces-machines`**: a clone of `spaces` (`herdr-app do mod.clone '{"name":"spaces","as":"spaces-machines"}'`). The changes are in `grouped()`, `draggable()`, `pull()`, `push()`, `cancelDrag()`, and the root element in `render()`.
- **Layout**: the sidebar block's `content.mod` is `spaces-machines`.
- **herdr functions added to the clone's use**: `shared` and `setShared` for `machines.hidden` and `machines.order`, `watchFolder`, `readTextFile`, `home`, `exec`.
- **Programs**: as in `spaces`: `hc machine ls --json`, `git`. Added: `sh`, to write a synced file.
- **Art**: the shipped `mods/workspace-chrome/server.svg`, `monitor.svg`, `chevron-*.svg`, `plus.svg`.

## Watch out

- Return early for a machine that is off, and add 1 to the running count of drawn children first. The list scrolls to the active space by child index.
- Put `machines.hidden` names into the remote list. A hidden machine that the core forgot would have no row and no way back.
- Other mods do not follow by themselves. A mod cannot change what `agents()` or `spaces()` return to other mods. An agents list must filter on `machines.hidden` itself: `a.address.split("/").slice(0, -1)[0]` is the agent's machine, `undefined` for this computer.
- A popup is a poor fit for this control. It takes its size from its first draw, and a list that loads after that stays one line tall.
- Write a synced file through a temporary file and `mv`. A window that reads a half-written file would get bad JSON.
- A watch on the folder can fail, for example before the folder exists. Fall back to a wait, and also read the files on the 15 second machine refresh.
- A release outside the mod never reaches the mod. Clear the drag state on a release on the root element and on hover exit of the root element, not only on the list.
- Shipped layouts are read-only. Point a cloned layout at the mod.

## Done when

- `herdr-app check mods/spaces-machines` passes and `herdr-app status` shows `errors: []`.
- With `machines.hidden` set to one machine's name, that machine's row is dim with a grey knob on the left of its switch, no rows show under it, and the other machines look as before.
- A click on the switch brings the machine's spaces back.
- "This computer" has no switch.
- A switch flipped in one window flips in a second window within a few seconds.
- A machine header dragged onto another moves its group. A drag released over a terminal leaves no line.
