// Agent Revive: herdr-core gives a terminal lost to a reboot a plain shell. This mod saves, once a minute,
// the command that resumes each local agent, and after a reboot types it into the recovered shells.
// The work is in ./hc-revive; this view runs it and shows how many agents are saved.

import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { exec, appHome, home, readTextFile, theme, checking } from "herdr";

export default class AgentRevive extends View {
  init(_props, cx) {
    this.saved = null; // agents in the snapshot, null: no snapshot yet
    this.pending = 0; // agents still to resume after a reboot
    if (checking()) return;
    this.tick("tick", cx);
    cx.timer.every(60000, (cx) => this.tick("tick", cx));
  }

  tick(command, cx) {
    cx.spawn(async (cx) => {
      const state = `${home()}/.local/state/hc-revive`;
      const count = async (file) => JSON.parse(await readTextFile(`${state}/${file}`)).terminals.length;
      try { await exec("zsh", [`${appHome()}/mods/agent-revive/hc-revive`, command], { timeout: 120000 }); } catch {}
      this.saved = await count("snapshot.json").catch(() => null);
      this.pending = await count("pending.json").catch(() => 0);
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const text = this.pending ? `resuming ${this.pending} agents…` : this.saved == null ? "no agents saved" : `${this.saved} agents saved`;
    return h_flex().size_full().px(14).items_center().justify_end().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8)
      .child(div().id("revive-save").text_color(this.pending ? t.working : t.dim).hover((s) => s.text_color(t.foreground))
        .tooltip("Agents that resume by themselves after a reboot. Click to save now.")
        .on_click((_e, cx) => this.tick("save", cx)).child(`↻ ${text}`));
  }
}
