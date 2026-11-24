// Agent Revive: herdr-core gives a terminal lost to a reboot a plain shell. This mod saves, once a minute,
// structured resume data for local agents and configured Linux cores. After a reboot it checks for a kept
// root shell immediately before asking hc to send a rebuilt command; see README for the residual race.
// The work is in ./hc-revive; this view runs it and shows how many agents are saved.

import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { exec, appHome, home, readTextFile, theme, checking } from "herdr";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const core = /^[0-9a-f]{32}$/;
const terminal = /^t[0-9]+$/;
const controls = /[\u0000-\u001f\u007f-\u009f]/;

function validMachineMap(value) {
  return value && typeof value === "object" && !Array.isArray(value)
    && Object.entries(value).every(([id, boot]) => core.test(id)
      && typeof boot === "string" && uuid.test(boot));
}

function terminalSummary(terminals, eligible = () => true) {
  const candidates = terminals.filter((entry) => entry && typeof entry === "object"
    && Object.prototype.hasOwnProperty.call(entry, "machine")
    && entry.legacy !== true && entry.delivery == null
    && (entry.machine == null || (typeof entry.machine === "string" && core.test(entry.machine)))
    && typeof entry.terminal === "string" && terminal.test(entry.terminal)
    && typeof entry.cwd === "string" && !controls.test(entry.cwd)
    && ["codex", "claude", "agy"].includes(entry.agent)
    && typeof entry.session === "string" && uuid.test(entry.session)
    && (entry.tries == null || (Number.isInteger(entry.tries) && entry.tries >= 0))
    && eligible(entry));
  const identityCounts = new Map();
  for (const entry of candidates) {
    const identity = `${entry.machine ?? "local"}/${entry.terminal}`;
    identityCounts.set(identity, (identityCounts.get(identity) ?? 0) + 1);
  }
  const actionable = candidates.filter((entry) =>
    identityCounts.get(`${entry.machine ?? "local"}/${entry.terminal}`) === 1).length;
  return {
    total: terminals.length,
    actionable,
    review: terminals.length - actionable,
    machines: terminals.map((entry) => entry?.machine)
      .filter((id) => typeof id === "string" && core.test(id)),
  };
}

function savedSummary(document) {
  const validBoot = (value) => value != null
    && (typeof value === "string" || typeof value === "number");
  if (!document || typeof document !== "object" || Array.isArray(document)
      || document.version !== 2 || !validBoot(document.boot)
      || !validMachineMap(document.machines) || !Array.isArray(document.terminals)) {
    return { total: 0, actionable: 0, review: 0, invalid: true, missing: false, machines: [] };
  }
  const summary = terminalSummary(document.terminals,
    (entry) => entry.machine == null
      || Object.prototype.hasOwnProperty.call(document.machines, entry.machine));
  return {
    ...summary,
    invalid: false,
    missing: false,
    machines: [...new Set([...Object.keys(document.machines), ...summary.machines])],
  };
}

function savedStatus(saved) {
  const reviewText = saved.review === 1
    ? "1 saved entry needs review" : `${saved.review} saved entries need review`;
  if (saved.missing) return "no agents saved";
  if (saved.invalid) return "saved state needs review";
  if (saved.actionable > 0) {
    return `${saved.actionable} agent${saved.actionable === 1 ? "" : "s"} saved${saved.review ? `; ${reviewText}` : ""}`;
  }
  return saved.review ? reviewText : "0 agents saved";
}

function pendingSummary(document) {
  const validBoot = (value) => value == null || typeof value === "string" || typeof value === "number";
  const validBaseline = document?.baseline == null
    || (typeof document.baseline === "object" && !Array.isArray(document.baseline)
      && validBoot(document.baseline.boot)
      && validMachineMap(document.baseline.machines ?? {}));
  if (!document || document.version !== 2 || !Array.isArray(document.terminals)
      || !validBoot(document.boot)
      || (document.machines != null && !validMachineMap(document.machines))
      || (document.tries != null && !(Number.isInteger(document.tries) && document.tries >= 0))
      || !validBaseline) {
    return { total: 0, actionable: 0, review: 0, invalid: true };
  }
  const summary = terminalSummary(document.terminals);
  return {
    ...summary,
    invalid: false,
    machines: [...new Set([
      ...Object.keys(document.machines ?? {}),
      ...Object.keys(document.baseline?.machines ?? {}),
      ...summary.machines,
    ])],
  };
}

function commandTimeout(saved, pending) {
  const machines = new Set([...(saved.machines ?? []), ...(pending.machines ?? [])]);
  // Budget both batches plus boot/scan work and several alias fallbacks per recorded core.
  return 120000 + (saved.total + pending.total) * 12000 + machines.size * 60000;
}

export default class AgentRevive extends View {
  init(_props, cx) {
    this.saved = { total: 0, actionable: 0, review: 0, invalid: false, missing: true, machines: [] };
    this.pending = { total: 0, actionable: 0, review: 0, invalid: false };
    if (checking()) return;
    this.tick("tick", cx);
    cx.timer.every(60000, (cx) => this.tick("tick", cx));
  }

  tick(command, cx) {
    cx.spawn(async (cx) => {
      const state = `${home()}/.local/state/hc-revive`;
      const readSaved = async () => {
        let text;
        try { text = await readTextFile(`${state}/snapshot.json`); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: false, missing: true, machines: [] };
        }
        try { return savedSummary(JSON.parse(text)); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: true, missing: false, machines: [] };
        }
      };
      const readPending = async () => {
        let text;
        try { text = await readTextFile(`${state}/pending.json`); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: false, machines: [] };
        }
        try { return pendingSummary(JSON.parse(text)); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: true, machines: [] };
        }
      };
      const savedBefore = await readSaved();
      const pendingBefore = await readPending();
      try {
        await exec("zsh", [`${appHome()}/mods/agent-revive/hc-revive`, command],
          { timeout: commandTimeout(savedBefore, pendingBefore) });
      } catch {}
      this.saved = await readSaved();
      this.pending = await readPending();
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const { actionable, review, invalid } = this.pending;
    const hasPending = actionable > 0 || review > 0 || invalid;
    const savedNeedsReview = this.saved.invalid || this.saved.review > 0;
    const reviewText = review === 1 ? "1 entry needs review" : `${review} entries need review`;
    const text = actionable > 0
      ? `resuming ${actionable} agent${actionable === 1 ? "" : "s"}${review ? `; ${reviewText}` : "…"}`
      : invalid ? "pending state needs review"
        : review ? reviewText
          : savedStatus(this.saved);
    return h_flex().size_full().px(14).items_center().justify_end().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8)
      .child(div().id("revive-save").text_color(hasPending || savedNeedsReview ? t.working : t.dim).hover((s) => s.text_color(t.foreground))
        .tooltip("Agents that resume after a reboot. Manual-review records are not retried. Click to save now.")
        .on_click((_e, cx) => this.tick("save", cx)).child(`↻ ${text}`));
  }
}
