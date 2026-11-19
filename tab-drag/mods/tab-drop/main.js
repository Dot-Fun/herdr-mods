import { View, div } from "gpui-kit";
import { props, layout, theme, run, closeOverlay, setShared, settings } from "herdr";

// The drop zones for a tab dragged off the tab bar (tabs-dnd opens this over the
// whole window until the release). It lays out the shown layout's own tree, so the
// pane area and the tab bar sit where the window has them. Over the pane area it
// shows the half the terminal would take; over the tab bar it hands the drag back.
// props: { bar: the tab bar's mod, terminal: the one to move, target: the shown
// tab's focused pane } (no terminal: nothing to drop, release only ends the drag).
// With out: true (pane-dnd, a pane dragged by its header): the only drop is the tab bar,
// and it makes the terminal its own tab.
export default class TabDrop extends View {
  init(_p, cx) {
    this.side = null;
    // The overlay is only as tall as its content: give it the window's height, in mod px (zoomed).
    cx.spawn(async (cx) => { this.height = globalThis.window.viewport_size().height / settings().zoom; cx.notify(); });
    this.done = false;
  }

  end(drop) {
    if (this.done) return;
    this.done = true;
    const { overlay, terminal, target } = props() ?? {};
    if (drop && this.side && terminal) {
      // tabs-dnd finishes it once the park lands: keep beside target, swap for left/up.
      run("terminal.park", { terminal });
      const after = this.side === "left" || this.side === "top";
      setShared("tab-drop.move", { terminal, place: this.side === "tab" ? "tab" : this.side === "left" || this.side === "right" ? "right" : "down", swap: after ? target : null, until: Date.now() + 5000 });
    }
    closeOverlay(overlay);
  }

  node(n, row, t) {
    if (!n || n.hidden) return null;
    const { bar, terminal, out } = props() ?? {};
    const pad = Array.isArray(n.padding) ? n.padding : [n.padding ?? 0, n.padding ?? 0];
    // Plain flex: h_flex centers its items, the layout's nodes stretch.
    let el = div().flex().when(n.type === "row", e => e.flex_row()).when(n.type !== "row", e => e.flex_col()).id(`n-${n.id}`).relative().min_w(0).min_h(0)
      .py(pad[0]).px(pad[1]).gap((n.gap ?? 0) + (n.divider?.width ?? 0));
    el = n.size?.px != null ? (row ? el.w(n.size.px) : el.h(n.size.px)).flex_none() : el.flex_grow(n.size?.weight ?? 1).flex_basis(0);
    if (n.type === "row" || n.type === "column") return el.children((n.children ?? []).map(c => this.node(c, n.type === "row", t)).filter(Boolean));
    if (n.content?.mod === bar && out) return el
      .on_mouse_move((_e, cx) => { if (this.side !== "tab") { this.side = "tab"; cx.notify(); } })
      .on_hover((hovered, cx) => { if (!hovered && this.side) { this.side = null; cx.notify(); } })
      .when(this.side === "tab", e => e.child(div().absolute().top(0).bottom(0).left(0).right(0).rounded(6).border(2).border_color(t.accent).bg(`${t.accent.slice(0, 7)}33`)));
    if (n.content?.mod === bar) return el.on_mouse_move((e) => {
      // A few px in, so the bar has the pointer too before it gets the drag back.
      if (e.local_position.y < e.bounds.height - 4 && !this.done) { run(`${bar}.resume`); this.end(false); }
    });
    if (n.content?.tab !== "active" || !terminal || out) return el;
    return el
      .on_mouse_move((e, cx) => {
        const x = e.local_position.x / e.bounds.width, y = e.local_position.y / e.bounds.height;
        const side = [["left", x], ["right", 1 - x], ["top", y], ["bottom", 1 - y]].reduce((a, b) => b[1] < a[1] ? b : a)[0];
        if (side !== this.side) { this.side = side; cx.notify(); }
      })
      .on_hover((hovered, cx) => { if (!hovered && this.side) { this.side = null; cx.notify(); } })
      .when(Boolean(this.side), el => el.child(div().absolute().rounded(10).border(2).border_color(t.accent).bg(`${t.accent.slice(0, 7)}33`)
        .when(this.side === "left" || this.side === "right", z => z.top(0).bottom(0).w_1_2())
        .when(this.side === "top" || this.side === "bottom", z => z.left(0).right(0).h_1_2())
        .when(this.side !== "right", z => z.left(0)).when(this.side === "right", z => z.right(0))
        .when(this.side !== "bottom", z => z.top(0)).when(this.side === "bottom", z => z.bottom(0))));
  }

  render() {
    return (this.node(layout(), true, theme()) ?? div().id("tab-drop")).w_full().when(this.height, el => el.h(this.height))
      .on_mouse_up("left", () => this.end(true))
      .on_mouse_down("left", () => this.end(false));
  }
}
