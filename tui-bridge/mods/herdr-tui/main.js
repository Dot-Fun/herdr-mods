// The agents in the herdr TUI, on this computer and on every enabled machine in
// `herdr machine list`. Pick one to read its screen; Enter in the field sends it
// a prompt. The prompt is the only write: nothing in the TUI is closed or moved.
// Agents are addressed by pane id, because most have no herdr agent name.
import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { exec, theme, settings, checking } from "herdr";

const LIST_MS = 15000;
const SCREEN_MS = 3000;
const QUERY_MS = 8000;
const SEND_MS = 20000;

const lastLine = (s) => String(s ?? "").trim().split("\n").pop().slice(0, 200);

// The TUI's CLI; `machine` is a saved machine label, null for this computer.
const herdr = (machine, args, timeout = QUERY_MS) =>
  exec("herdr", machine ? ["--machine", machine, ...args] : args, { timeout });

// One machine's agents with their workspace and tab labels, or { error }.
async function snapshot(machine) {
  try {
    const r = await herdr(machine, ["api", "snapshot"]);
    if (r.code !== 0) return { error: lastLine(r.stderr || r.stdout) };
    const s = JSON.parse(r.stdout).result.snapshot;
    const spaces = new Map(s.workspaces.map((w) => [w.workspace_id, w.label]));
    const tabs = new Map(s.tabs.map((t) => [t.tab_id, t.label]));
    return {
      agents: s.agents.map((a) => ({
        pane: a.pane_id,
        kind: a.agent ?? "agent",
        status: a.agent_status ?? "unknown",
        title: a.name || a.terminal_title_stripped || "",
        space: spaces.get(a.workspace_id) ?? a.workspace_id,
        tab: tabs.get(a.tab_id) ?? a.tab_id,
      })),
    };
  } catch (e) {
    return { error: lastLine(e?.message ?? e) };
  }
}

export default class HerdrTui extends View {
  init(_props, cx) {
    this.machines = []; // [{ label, agents?, error?, loading? }]
    this.sel = null; // { machine, pane, title }
    this.screen = "";
    this.note = "";
    this.input = InputState.new({ placeholder: "Prompt for the selected agent. Enter sends." });
    this.input.on("submit", (_e, cx) => this.send(cx));
    if (checking()) return;
    this.loadList(cx);
    cx.timer.every(LIST_MS, (cx) => this.loadList(cx));
    cx.timer.every(SCREEN_MS, (cx) => this.loadScreen(cx));
  }

  loadList(cx) {
    if (this.listing) return;
    this.listing = true;
    cx.spawn(async (cx) => {
      let labels = [];
      try {
        const r = await exec("herdr", ["machine", "list", "--json"], { timeout: QUERY_MS });
        labels = JSON.parse(r.stdout).filter((m) => m.enabled).map((m) => m.label);
      } catch (e) {
        this.note = `machine list failed: ${lastLine(e?.message ?? e)}`;
      }
      const all = [null, ...labels];
      this.machines = all.map((label) => this.machines.find((m) => m.label === label) ?? { label, loading: true });
      cx.notify();
      // Each machine shows as soon as it answers; a slow or offline one waits only for itself.
      await Promise.all(all.map(async (label) => {
        const got = await snapshot(label);
        this.machines = this.machines.map((m) => (m.label === label ? { label, ...got } : m));
        cx.notify();
      }));
      this.listing = false;
    });
  }

  loadScreen(cx, now = false) {
    const sel = this.sel;
    if (!sel || (this.reading && !now)) return;
    this.reading = true;
    cx.spawn(async (cx) => {
      let text;
      try {
        const r = await herdr(sel.machine, ["agent", "read", sel.pane, "--source", "visible"]);
        text = r.code === 0 ? r.stdout.replace(/\s+$/, "") : `read failed: ${lastLine(r.stderr || r.stdout)}`;
      } catch (e) {
        text = `read failed: ${lastLine(e?.message ?? e)}`;
      }
      this.reading = false;
      if (this.sel !== sel) return;
      this.screen = text;
      cx.notify();
    });
  }

  select(machine, a, cx) {
    this.sel = { machine, pane: a.pane, title: a.title || a.kind };
    this.screen = "";
    this.note = "";
    this.loadScreen(cx, true);
    this.input.focus();
    cx.notify();
  }

  send(cx) {
    const sel = this.sel;
    const text = this.input.value().trim();
    if (!sel || !text || this.sending) return;
    this.sending = true;
    this.note = "sending…";
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        // Sends the text and Enter as one submission; refuses an agent waiting at a question.
        const r = await herdr(sel.machine, ["agent", "prompt", sel.pane, text], SEND_MS);
        this.note = r.code === 0 ? "sent" : `send failed: ${lastLine(r.stderr || r.stdout)}`;
        if (r.code === 0) this.input.set_value("");
      } catch (e) {
        // A timeout does not prove the prompt was not delivered: read the screen before sending again.
        this.note = `send unconfirmed: ${lastLine(e?.message ?? e)}`;
      }
      this.sending = false;
      cx.notify();
      this.loadScreen(cx, true);
    });
  }

  agentRow(t, machine, a) {
    const on = this.sel?.machine === machine && this.sel?.pane === a.pane;
    return v_flex()
      .id(`a-${machine ?? ""}-${a.pane}`)
      .px(10)
      .py(4)
      .rounded(6)
      .cursor_pointer()
      .when(on, (el) => el.bg(t.selected))
      .hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => this.select(machine, a, cx))
      .child(h_flex().gap(6).items_center()
        .child(div().flex_none().text_color(t[a.status] ?? t.unknown).child("●"))
        .child(div().flex_none().text_color(t.muted).child(a.kind))
        .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(a.title))
        .child(div().flex_none().text_size(11).text_color(t[a.status] ?? t.unknown).child(a.status)))
      .child(div().pl(16).truncate().text_size(11).text_color(t.dim).child(`${a.space} › ${a.tab} · ${a.pane}`));
  }

  machineBlock(t, m) {
    const state = m.loading ? "…" : m.error ? "unreachable" : `${m.agents.length}`;
    return v_flex()
      .gap(2)
      .child(h_flex().px(10).pt(10).pb(2).gap(8).items_center()
        .child(div().flex_1().truncate().font_semibold().text_color(m.error ? t.dim : t.foreground).child(m.label ?? "this computer"))
        .child(div().flex_none().text_size(11).text_color(m.error ? t.blocked : t.dim).child(state)))
      .when(Boolean(m.error), (el) => el.child(div().px(10).text_size(11).text_color(t.dim).truncate().child(m.error)))
      .children((m.agents ?? []).map((a) => this.agentRow(t, m.label, a)));
  }

  render() {
    const t = theme();
    const sel = this.sel;
    const lines = (sel ? this.screen || "reading…" : "Pick an agent on the left.").split("\n");
    const left = v_flex()
      .id("machines")
      .w(340)
      .flex_none()
      .h_full()
      .pb(10)
      .border_r(1)
      .border_color(t.border)
      .bg(t.chrome)
      .overflow_y_scrollbar()
      .children(this.machines.map((m) => this.machineBlock(t, m)));
    const header = h_flex().px(14).h(36).flex_none().gap(8).items_center().border_b(1).border_color(t.border)
      .child(div().flex_1().truncate().font_semibold().child(sel ? `${sel.machine ?? "this computer"} · ${sel.title}` : "Herdr TUI"))
      .child(div().flex_none().text_size(11).text_color(t.dim).child(sel ? sel.pane : "Esc closes"));
    const screen = v_flex()
      .id("screen")
      .flex_1()
      .min_h(0)
      .p(12)
      .bg(t.background)
      .overflow_scroll()
      .font_family(settings().font_family ?? "JetBrains Mono")
      .text_size(12)
      .text_color(t.foreground)
      .children(lines.map((l) => div().whitespace_nowrap().child(l || " ")));
    const input = h_flex().p(10).gap(10).flex_none().items_center().border_t(1).border_color(t.border)
      .child(Input.new(this.input).flex_1().h(34).px(10).rounded(8).border_1().border_color(t.input).bg(t.background).text_size(13).text_color(t.foreground))
      .child(div().flex_none().max_w(320).truncate().text_size(11).text_color(/failed|unconfirmed/.test(this.note) ? t.blocked : t.dim).child(this.note));
    return h_flex()
      .size_full()
      .bg(t.popover)
      .text_color(t.foreground)
      .text_size(13)
      .child(left)
      .child(v_flex().flex_1().min_w(0).h_full().child(header).child(screen).when(Boolean(sel), (el) => el.child(input)));
  }
}
