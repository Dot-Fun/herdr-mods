// ctrl-b m: send the pane that had focus to another space on its machine, as a new tab.
// Up/down or j/k move, Enter sends, Esc cancels. The target comes from shared "send-to-space".
import { View } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { run, spaces, panes, hc, theme, shared, props, closeOverlay } from "herdr";

export default class SendToSpace extends View {
  init(_props, cx) {
    this.from = shared("send-to-space") ?? {};
    this.at = 0;
    this.handle = cx.focus_handle();
    this.handle.focus();
    cx.timer.after(300, () => this.handle.focus());
  }

  targets() {
    return spaces().filter((p) => p.machine === this.from.machine && p.id !== this.from.space);
  }

  send(cx) {
    const to = this.targets()[this.at];
    if (!to) return;
    const { terminal } = this.from;
    // Parked first: relabeling a terminal that still has a pane does nothing.
    run("terminal.park", { terminal });
    cx.spawn(async (cx) => {
      for (let i = 0; i < 60 && panes().some((p) => p.terminal === terminal); i++) await cx.sleep(50);
      await hc(["label", terminal, `herdr.space=${to.id.split("/").pop()}`, `herdr.tab=tbsent${Date.now().toString(36)}`]);
      closeOverlay(props().overlay);
    });
  }

  key(e, cx) {
    cx.stop_propagation();
    const n = this.targets().length;
    if (e.key === "escape") closeOverlay(props().overlay);
    else if (e.key === "enter") this.send(cx);
    else if (n && (e.key === "down" || e.key === "j")) this.at = (this.at + 1) % n;
    else if (n && (e.key === "up" || e.key === "k")) this.at = (this.at + n - 1) % n;
    cx.notify();
  }

  render() {
    const t = theme();
    const list = this.targets();
    this.at = Math.min(this.at, Math.max(0, list.length - 1));
    return v_flex().id("send-to-space").track_focus(this.handle).on_key_down((e, cx) => this.key(e, cx))
      .p(12).gap(4).bg(t.popover).text_size(13).text_color(t.foreground)
      .child(h_flex().pb(4).text_size(11).text_color(t.dim).child("Send pane to…"))
      .children(list.length
        ? list.map((p, i) => h_flex().id(`sts-${p.id}`).px(10).h(30).items_center().rounded(7).when(i === this.at, (el) => el.bg(t.hover)).child(p.name))
        : [h_flex().px(10).h(30).items_center().text_color(t.dim).child("no other space on this machine")]);
  }
}
