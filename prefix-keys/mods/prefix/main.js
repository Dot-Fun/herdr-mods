// ctrl-b prefix: press ctrl-b, then one key from KEYS. Any other key, or Escape, cancels.
// Each entry is [command, args]; a function gets the pane/tab/space focused before the popup opened.
import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { run, focused, props, closeOverlay, theme, hc, panes, spaces, setShared, exec, home } from "herdr";

const KEYS = {
  c: ["tab.new"],
  v: ["pane.split", { direction: "right" }],
  "-": ["pane.split", { direction: "down" }],
  h: ["pane.go", { direction: "left" }],
  j: ["pane.go", { direction: "down" }],
  k: ["pane.go", { direction: "up" }],
  l: ["pane.go", { direction: "right" }],
  H: ["pane.swap", { direction: "left" }],
  J: ["pane.swap", { direction: "down" }],
  K: ["pane.swap", { direction: "up" }],
  L: ["pane.swap", { direction: "right" }],
  z: ["pane.zoom"],
  x: ["pane.close"],
  n: ["tab.next"],
  p: ["tab.prev"],
  T: ["tab.rename", (f) => ({ id: f.tab })],
  X: ["tab.close", (f) => ({ id: f.tab })],
  N: ["space.new"],
  W: ["space.rename", (f) => ({ id: f.space })],
  D: ["space.close", (f) => ({ id: f.space })],
  g: ["mod.open", { name: "picker" }],
  t: ["mod.open", { name: "herdr-tui" }],
  b: ["layout.toggle", { id: "sidebar" }],
  "?": ["app.help"],
};
for (let i = 1; i <= 9; i++) KEYS[i] = ["tab.select", { index: i }];

const PANE_COMMANDS = new Set(["pane.swap", "pane.zoom", "pane.close", "pane.split"]);

// Park first: relabeling a terminal that still has a pane does nothing. Once its pane is gone,
// new labels adopt it (an unknown tab id is a new tab). Labels use the machine's own ids.
async function relabel(cx, terminal, space, tab) {
  run("terminal.park", { terminal });
  for (let i = 0; i < 60 && panes().some((p) => p.terminal === terminal); i++) await cx.sleep(50);
  await hc(["label", terminal, `herdr.space=${space.split("/").pop()}`, `herdr.tab=${tab}`]);
}

export default class Prefix extends View {
  init(_props, cx) {
    // Taken before the popup grabs the keyboard, so commands act on what was focused.
    this.was = focused() ?? {};
    this.handle = cx.focus_handle();
    this.handle.focus();
    cx.timer.after(300, () => this.handle.focus());
  }

  key(e, cx) {
    cx.stop_propagation();
    const k = e.key;
    if (["shift", "control", "alt", "meta", "cmd", "platform"].includes(k)) return;
    const f = this.was;
    // "!" stays open until the move is done: a closed popup may stop its own task.
    const breakOut = k === "!" && f.terminal && panes().filter((p) => p.tab === f.tab).length > 1;
    if (!breakOut) closeOverlay(props().overlay);
    if (e.modifiers.control && k === "b") {
      if (f.terminal) hc(["keys", f.terminal, "ctrl+b"]);
      return;
    }
    if (e.modifiers.control || e.modifiers.alt || e.modifiers.platform) return;
    if (breakOut) {
      cx.spawn(async (cx) => {
        await relabel(cx, f.terminal, f.space, `tbout${Date.now().toString(36)}`);
        closeOverlay(props().overlay);
      });
      return;
    }
    if (k === "m") {
      // Hands the pane to the picker through shared state: mod.open takes no props.
      if (!f.terminal) return;
      setShared("send-to-space", { terminal: f.terminal, space: f.space, machine: spaces().find((p) => p.id === f.space)?.machine ?? null });
      run("mod.open", { name: "send-to-space" });
      return;
    }
    if (k === "<" || k === ">") {
      // Moves the space one place inside its machine group. space.move wants the neighbor's one-based position in the whole list.
      const all = spaces();
      const group = all.filter((s) => s.machine === all.find((p) => p.id === f.space)?.machine);
      const next = group[group.findIndex((s) => s.id === f.space) + (k === "<" ? -1 : 1)];
      if (next && f.space) run("space.move", { id: f.space, index: all.indexOf(next) + 1 });
      return;
    }
    if (k === "w") {
      exec(`${home()}/.local/bin/herdr-window`);
      return;
    }
    const hit = KEYS[k];
    if (!hit) return;
    const [name, extra] = hit;
    const args = typeof extra === "function" ? extra(f) : { ...extra };
    if (PANE_COMMANDS.has(name) && f.pane) args.pane = f.pane;
    run(name, args);
  }

  render() {
    const t = theme();
    return h_flex().id("prefix").track_focus(this.handle).on_key_down((e, cx) => this.key(e, cx))
      .px(12).py(6).rounded(8).border_1().border_color(t.border).bg(t.popover)
      .text_size(12).text_color(t.dim).child("prefix…");
  }
}
