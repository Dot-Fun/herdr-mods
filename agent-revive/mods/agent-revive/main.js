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
  for (const entry of terminals) {
    if (entry && (entry.delivery != null || entry.collision === true)) {
      identityCounts.set(`${entry.machine ?? "local"}/${entry.terminal}`, 2);
    }
  }
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
  };
}

function savedSummary(document) {
  const validBoot = (value) => value != null
    && (typeof value === "string" || typeof value === "number");
  if (!document || typeof document !== "object" || Array.isArray(document)
      || document.version !== 2 || !validBoot(document.boot)
      || !validMachineMap(document.machines) || !Array.isArray(document.terminals)) {
    return { total: 0, actionable: 0, review: 0, invalid: true, missing: false };
  }
  const summary = terminalSummary(document.terminals,
    (entry) => entry.machine == null
      || Object.prototype.hasOwnProperty.call(document.machines, entry.machine));
  return {
    ...summary,
    invalid: false,
    missing: false,
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
  return { ...summary, invalid: false };
}

function workerStatus(record, now = Date.now() / 1000) {
  if (record?.status === "timed_out") return "recovery worker timed out";
  if (record?.status === "running" && typeof record.run === "string" && core.test(record.run)) {
    return record.priorFailure ? "retrying failed recovery" : "recovery in progress";
  }
  if (record?.status === "failed") return "recovery worker failed";
  if (record?.status === "succeeded" && Number.isInteger(record.finished)) {
    return now - record.finished > 150 ? "recovery status is stale" : null;
  }
  return "recovery status unavailable";
}

export default class AgentRevive extends View {
  init(_props, cx) {
    this.saved = { total: 0, actionable: 0, review: 0, invalid: false, missing: true };
    this.pending = { total: 0, actionable: 0, review: 0, invalid: false };
    this.health = "checking recovery";
    this.refreshId = 0;
    if (checking()) return;
    this.tick("tick", cx);
    cx.timer.every(60000, (cx) => this.tick("tick", cx));
    cx.timer.every(5000, (cx) => this.tick(null, cx));
  }

  tick(command, cx) {
    cx.spawn(async (cx) => {
      const state = `${home()}/.local/state/hc-revive`;
      const readSaved = async () => {
        let text;
        try { text = await readTextFile(`${state}/snapshot.json`); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: false, missing: true };
        }
        try { return savedSummary(JSON.parse(text)); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: true, missing: false };
        }
      };
      const readPending = async () => {
        let text;
        try { text = await readTextFile(`${state}/pending.json`); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: false };
        }
        try { return pendingSummary(JSON.parse(text)); } catch {
          return { total: 0, actionable: 0, review: 0, invalid: true };
        }
      };
      if (command) {
        try {
          const result = await exec("zsh", [`${appHome()}/mods/agent-revive/hc-revive`, "schedule", command]);
          this.launchFailed = result.code !== 0 || !["started", "busy"].includes(result.stdout.trim());
        } catch { this.launchFailed = true; }
      }
      const refreshId = ++this.refreshId;
      let record;
      try { record = JSON.parse(await readTextFile(`${state}/worker.json`)); } catch {}
      const [saved, pending] = await Promise.all([readSaved(), readPending()]);
      if (refreshId !== this.refreshId) return;
      this.saved = saved;
      this.pending = pending;
      this.health = workerStatus(record);
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const { actionable, review, invalid } = this.pending;
    const hasPending = actionable > 0 || review > 0 || invalid;
    const savedNeedsReview = this.saved.invalid || this.saved.review > 0;
    const reviewText = review === 1 ? "1 entry needs review" : `${review} entries need review`;
    const health = this.launchFailed ? "recovery worker failed to start" : this.health;
    const showHealth = health && (health !== "recovery in progress" || !hasPending);
    const text = showHealth ? health : actionable > 0
      ? `resuming ${actionable} agent${actionable === 1 ? "" : "s"}${review ? `; ${reviewText}` : "…"}`
      : invalid ? "pending state needs review"
        : review ? reviewText
          : savedStatus(this.saved);
    return h_flex().size_full().px(14).items_center().justify_end().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8)
      .child(div().id("revive-save").text_color(health || hasPending || savedNeedsReview ? t.working : t.dim).hover((s) => s.text_color(t.foreground))
        .tooltip("Agents that resume after a reboot. Manual-review records are not retried. Click to save now.")
        .on_click((_e, cx) => this.tick("save", cx)).child(`↻ ${text}`));
  }
}
