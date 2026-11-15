import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";

function initialState() {
  const now = new Date().toISOString();
  return {
    schema_version: "1.0",
    owner: "app-owned",
    active_skill: null,
    skill_discovery: null,
    session_ref: null,
    session_name: null,
    session_recovered: null,
    // Compatibility aliases. New state is written with session_* first.
    thread_id: null,
    thread_name: null,
    thread_recovered: null,
    task: null,
    phase: "ready",
    panel: null,
    draft: {
      events: [],
      attachments: [],
    },
    error: null,
    last_turn: null,
    activity: null,
    created_at: now,
    updated_at: now,
    event_count: 0,
  };
}

function synchronizeSessionAliases(state) {
  const sessionRef = state.session_ref ?? state.thread_id ?? null;
  const sessionName = state.session_name ?? state.thread_name ?? null;
  const sessionRecovered =
    state.session_recovered ?? state.thread_recovered ?? null;
  if (sessionRecovered && typeof sessionRecovered.message === "string") {
    sessionRecovered.message =
      "原 Agent Session 不可用，已创建新 Session；任务与共享证据仍已复用。";
  }
  state.session_ref = sessionRef;
  state.session_name = sessionName;
  state.session_recovered = sessionRecovered;
  // Kept for old task snapshots and adapters until the compatibility window ends.
  state.thread_id = sessionRef;
  state.thread_name = sessionName;
  state.thread_recovered = sessionRecovered;
}

function readEventLog(eventLogPath) {
  if (!existsSync(eventLogPath)) {
    return [];
  }
  return readFileSync(eventLogPath, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

function inferLegacyActivity(state, eventLogPath) {
  if (!state.thread_id || state.activity) {
    return state.activity ?? null;
  }
  const records = readEventLog(eventLogPath);
  const sessionStart = records.findLastIndex(
    (record) =>
      record.type === "session.started" &&
      record.thread_id === state.thread_id,
  );
  if (sessionStart < 0) {
    return null;
  }
  const scoped = records.slice(sessionStart + 1);
  const submission = [...scoped]
    .reverse()
    .find(
      (record) =>
        record.type === "ui.user_message" ||
        record.type === "ui.panel_submission",
    );
  const update = [...scoped]
    .reverse()
    .find((record) => record.type === "agent.panel_updated");
  if (!submission && !update) {
    return null;
  }
  let userSummary = "";
  if (submission?.type === "ui.user_message") {
    userSummary = submission.event?.text ?? "";
  } else if (submission?.type === "ui.panel_submission") {
    const selected = submission.packet?.events?.find(
      (event) => event.type === "option_selected",
    );
    const evidence = submission.packet?.events
      ?.filter((event) => event.type === "evidence_added")
      .map((event) => event.label);
    userSummary = [
      selected ? `选择：${selected.option_id}` : "",
      submission.packet?.free_text
        ? `补充：${submission.packet.free_text}`
        : "",
      evidence?.length ? `证据：${evidence.join("、")}` : "",
    ]
      .filter(Boolean)
      .join("；");
  }
  return {
    status: update ? "completed" : state.phase === "running" ? "running" : "error",
    user_summary: userSummary,
    submitted_at: submission?.occurred_at ?? null,
    started_at: submission?.occurred_at ?? null,
    completed_at: update?.occurred_at ?? null,
    agent_summary: update?.summary ?? state.panel?.turn_summary ?? "",
    next_action: state.panel?.next_action ?? "",
    error: null,
    turn_id: update?.turn_id ?? null,
  };
}

export class StateStore {
  constructor(runtimeDir) {
    this.runtimeDir = runtimeDir;
    this.statePath = resolve(runtimeDir, "state.json");
    this.eventLogPath = resolve(runtimeDir, "events.jsonl");
    mkdirSync(runtimeDir, { recursive: true });
  }

  load() {
    if (!existsSync(this.statePath)) {
      this.state = initialState();
      this.save();
      return this.state;
    }
    this.state = JSON.parse(readFileSync(this.statePath, "utf8"));
    synchronizeSessionAliases(this.state);
    this.state.draft ??= { events: [], attachments: [] };
    this.state.draft.attachments ??= [];
    this.state.draft.events ??= [];
    const inferredActivity = inferLegacyActivity(
      this.state,
      this.eventLogPath,
    );
    if (inferredActivity && !this.state.activity) {
      this.state.activity = inferredActivity;
      this.state.updated_at = new Date().toISOString();
      this.save();
    }
    if (this.state.phase === "running") {
      this.state.phase = "interrupted";
      this.state.error =
        "服务在上一次 agent 回合完成前退出。草稿已保留，可以重试或新建任务。";
      if (this.state.activity?.status === "running") {
        this.state.activity.status = "error";
        this.state.activity.error = this.state.error;
      }
      this.state.updated_at = new Date().toISOString();
      this.save();
    }
    return this.state;
  }

  save() {
    synchronizeSessionAliases(this.state);
    this.state.updated_at = new Date().toISOString();
    const tempPath = `${this.statePath}.tmp`;
    writeFileSync(tempPath, `${JSON.stringify(this.state, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    renameSync(tempPath, this.statePath);
  }

  replaceStateInPlace(nextState) {
    for (const key of Object.keys(this.state)) {
      delete this.state[key];
    }
    Object.assign(this.state, nextState);
  }

  appendEvent(event) {
    const sessionRef = event.session_ref ?? event.thread_id;
    const record = {
      schema_version: "1.0",
      occurred_at: new Date().toISOString(),
      ...event,
      ...(sessionRef ? { session_ref: sessionRef } : {}),
    };
    appendFileSync(this.eventLogPath, `${JSON.stringify(record)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    this.state.event_count = (this.state.event_count ?? 0) + 1;
    return record;
  }

  reset() {
    if (!this.state) {
      this.load();
    }
    const created = this.state.created_at;
    const next = initialState();
    if (created) {
      next.created_at = created;
    }
    this.replaceStateInPlace(next);
    this.appendEvent({ type: "session.reset" });
    this.save();
    return this.state;
  }

  startTask(task, { threadReference, threadName }) {
    if (!this.state) {
      this.load();
    }
    const next = initialState();
    next.created_at = this.state.created_at;
    next.active_skill = this.state.active_skill ?? null;
    next.skill_discovery = this.state.skill_discovery ?? null;
    next.session_ref = threadReference;
    next.session_name = threadName;
    next.task = task;
    synchronizeSessionAliases(next);
    this.replaceStateInPlace(next);
    this.appendEvent({
      type: "task.created",
      task_id: task.task_id,
      session_ref: threadReference,
      thread_id: threadReference,
      objective: task.objective,
    });
    this.save();
    return this.state;
  }

  startTaskDraft({ threadReference, threadName }) {
    if (!this.state) {
      this.load();
    }
    const next = initialState();
    next.created_at = this.state.created_at;
    next.active_skill = this.state.active_skill ?? null;
    next.skill_discovery = this.state.skill_discovery ?? null;
    next.session_ref = threadReference;
    next.session_name = threadName;
    next.task = null;
    synchronizeSessionAliases(next);
    this.replaceStateInPlace(next);
    this.appendEvent({
      type: "task.draft_started",
      session_ref: threadReference,
      thread_id: threadReference,
    });
    this.save();
    return this.state;
  }
}
