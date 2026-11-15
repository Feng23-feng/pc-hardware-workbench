import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import {
  extname,
  isAbsolute,
  relative,
  resolve,
} from "node:path";

const MAX_TEXT_BYTES = 64 * 1024;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function inside(root, candidate) {
  const rel = relative(root, resolve(candidate));
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}

export async function createRuntime(context) {
  const { SkillRuntime, manifest, runtimeDir } = context;
  Object.setPrototypeOf(
    GenericDemoRuntime.prototype,
    SkillRuntime.prototype,
  );
  const runtime = new GenericDemoRuntime({
    ...context,
    SkillRuntime,
    manifest,
    runtimeDir,
  });
  runtime.SkillRuntimeError = context.SkillRuntimeError;
  runtime.SkillRuntimeBase = SkillRuntime;
  return runtime;
}

class GenericDemoRuntime {
  constructor(options) {
    this.SkillRuntimeBase = options.SkillRuntime;
    this.manifest = options.manifest;
    this.projectRoot = options.projectRoot;
    this.identity = Object.freeze({
      api_version: "1.0",
      skill_id: options.manifest.skill.id,
      skill_version: options.manifest.skill.version,
      manifest_hash: options.manifest.resolved?.manifest_hash ?? null,
      runtime_id: options.manifest.runtime.id,
    });
    this.active = false;
    this.runtimeDir = resolve(options.runtimeDir);
    this.artifactRoot = resolve(this.runtimeDir, "demo-artifacts");
    this.indexPath = resolve(this.artifactRoot, "index.json");
    mkdirSync(this.artifactRoot, { recursive: true });
  }

  createTaskState({ taskId }) {
    return {
      ...this.SkillRuntimeBase.prototype.createTaskState.call(this, { taskId }),
      domain_state: {
        mode: "decision-demo",
        label: "提示词与输出选择示例",
      },
      domain_refs: [`demo:${taskId}`],
    };
  }

  publicContext({ task }) {
    return {
      title: "Demo Runtime",
      summary: "A provider-free Skill with one text artifact action.",
      fields: [
        { label: "模式", value: task?.domain_state?.mode ?? "decision-demo" },
        { label: "输入", value: "任意文本；.txt 可生成摘要 artifact" },
      ],
    };
  }

  buildTaskContext({ task }) {
    return {
      ...this.SkillRuntimeBase.prototype.buildTaskContext.call(this, { task }),
      domain_context: {
        mode: "decision-demo",
        instruction:
          "Ask one concise question with two useful options. Keep the result small and non-hardware.",
      },
    };
  }

  promptInstructions() {
    return [
      "Ask exactly one concise question with two useful options unless the user has already selected a focus.",
      "Keep all output independent of any specific Agent provider or hardware domain.",
    ];
  }

  loadIndex() {
    if (!existsSync(this.indexPath)) return { artifacts: [] };
    try {
      const parsed = JSON.parse(readFileSync(this.indexPath, "utf8"));
      return { artifacts: Array.isArray(parsed.artifacts) ? parsed.artifacts : [] };
    } catch {
      return { artifacts: [] };
    }
  }

  saveIndex(index) {
    const temporary = `${this.indexPath}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(index, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    renameSync(temporary, this.indexPath);
  }

  getLocalAction(actionId) {
    if (actionId !== "demo.text.export") return null;
    this.requireCapability(actionId);
    return {
      id: actionId,
      capability: actionId,
      requiresPermission: false,
      requiresAgent: false,
      attachmentExtensions: [".txt"],
      label: "生成摘要文件",
      validateAttachment: (attachment) => {
        if (extname(attachment?.original_name ?? "").toLowerCase() !== ".txt") {
          const error = new this.SkillRuntimeError(
            "unsupported_attachment",
            "Only text files can produce a demo artifact.",
          );
          error.statusCode = 415;
          throw error;
        }
        const path = resolve(attachment.local_path);
        if (!inside(this.runtimeDir, path)) {
          const error = new this.SkillRuntimeError(
            "unsafe_attachment",
            "Attachment path is outside the managed runtime.",
          );
          error.statusCode = 404;
          throw error;
        }
        const stat = statSync(path);
        if (!stat.isFile() || stat.size > MAX_TEXT_BYTES) {
          const error = new this.SkillRuntimeError(
            "invalid_attachment",
            "Text input is too large.",
          );
          error.statusCode = 413;
          throw error;
        }
        return path;
      },
      execute: async ({ task, attachment }) => {
        const path = this.getLocalAction(actionId).validateAttachment(attachment);
        const source = readFileSync(path, "utf8").slice(0, MAX_TEXT_BYTES);
        const artifactId = `artifact-${randomUUID()}`;
        const filename = `${artifactId}.txt`;
        const target = resolve(this.artifactRoot, task.task_id, filename);
        mkdirSync(resolve(this.artifactRoot, task.task_id), { recursive: true });
        const body = [
          "# Generic Workbench Demo",
          "",
          `Task: ${task.objective}`,
          `Input: ${attachment.original_name}`,
          "",
          source.trim(),
          "",
        ].join("\n");
        writeFileSync(target, body, { encoding: "utf8", mode: 0o600 });
        const record = {
          id: artifactId,
          kind: "text",
          mime: "text/plain; charset=utf-8",
          title: "Generated text summary",
          relative_path: relative(this.artifactRoot, target).replaceAll("\\", "/"),
          absolute_path: target,
          sha256: sha256(Buffer.from(body)),
          source_evidence_ids: [attachment.id],
          created_at: new Date().toISOString(),
          safeToEmbed: true,
          size: Buffer.byteLength(body),
          task_id: task.task_id,
        };
        const index = this.loadIndex();
        index.artifacts = index.artifacts.filter((item) => item.id !== artifactId);
        index.artifacts.push(record);
        this.saveIndex(index);
        return {
          artifact: record,
          blocks: [
            {
              id: "demo-artifact-callout",
              type: "callout",
              title: "Text artifact ready",
              text: "The local runtime generated a text-only artifact from the submitted file.",
              tone: "info",
              collapsed: false,
            },
            {
              id: "demo-artifact-download",
              type: "artifact-download",
              title: "Generated summary",
              artifact_ref: artifactId,
              label: "Download text",
            },
          ],
          timeline: `Generated ${record.title} from ${attachment.original_name}.`,
        };
      },
    };
  }

  async runLocalAction({ actionId, task, attachment, host }) {
    const action = this.getLocalAction(actionId);
    if (!action) {
      throw new this.SkillRuntimeError(
        "local_action_unsupported",
        "Local action is not supported by this Skill.",
      );
    }
    const result = await action.execute({ task, attachment });
    const publicArtifact = {
      id: result.artifact.id,
      kind: result.artifact.kind,
      mime: result.artifact.mime,
      title: result.artifact.title,
      relative_path: result.artifact.relative_path,
      sha256: result.artifact.sha256,
      source_evidence_ids: result.artifact.source_evidence_ids,
      created_at: result.artifact.created_at,
      safeToEmbed: result.artifact.safeToEmbed,
      size: result.artifact.size,
    };
    const previous = host.getPanel();
    const fallbackPanel = {
      schema_version: "1.2",
      turn_summary: "A local text artifact was generated.",
      current_goal: task.objective,
      status: "ready",
      judgement:
        "The runtime completed a local text transform without asking the Agent to infer artifact contents.",
      question: null,
      recommendation: {
        summary: "Download the generated text artifact or continue the Task.",
        option_id: null,
      },
      evidence: [
        {
          id: "demo-artifact",
          label: "Local text artifact",
          detail: "Generated by the active Skill runtime.",
          source: "observed_current",
          relation: "supports",
        },
      ],
      uncertainty: ["This demo proves runtime/artifact plumbing, not domain analysis quality."],
      recommendations: [
        {
          id: "inspect-artifact",
          title: "Inspect the generated file",
          detail: "Open or download the text artifact and verify its source context.",
          risk: "low",
          evidence_goal: "Confirm that the artifact is tied to this Task.",
        },
        {
          id: "continue-task",
          title: "Continue the Task",
          detail: "Add another input if the summary needs correction.",
          risk: "low",
          evidence_goal: "Keep the conversation and artifact provenance connected.",
        },
      ],
      priorityAction: {
        title: "Download and inspect the text artifact",
        detail: "The local runtime created it from the submitted text file.",
      },
      actions: [],
      artifact_refs: [],
      blocks: [],
    };
    const base = previous ?? fallbackPanel;
    const panel = {
      ...base,
      turn_summary: "Generated a local text artifact.",
      status: "ready",
      question: null,
      artifact_refs: [
        ...(base.artifact_refs ?? []).filter(
          (artifact) => artifact.id !== publicArtifact.id,
        ),
        publicArtifact,
      ],
      blocks: [
        ...(base.blocks ?? []).filter(
          (block) => block.artifact_ref !== publicArtifact.id,
        ),
        ...result.blocks,
      ],
      actions: [
        ...(base.actions ?? []),
        {
          id: "demo-new-task",
          label: "New Task",
          kind: "new_task",
        },
      ],
    };
    host.setPanel(panel);
    host.setPhase("ready");
    host.updateTaskFromPanel(panel);
    task.artifacts ??= [];
    task.artifacts.push(publicArtifact);
    task.actions ??= [];
    task.actions.push({
      id: `action-${randomUUID()}`,
      action_id: actionId,
      attachment_id: attachment.id,
      artifact_id: publicArtifact.id,
      completed_at: new Date().toISOString(),
    });
    host.pushTimeline("tool", result.timeline);
    host.appendEvent({
      type: "action.completed",
      action_id: actionId,
      attachment_id: attachment.id,
      artifact_id: publicArtifact.id,
      task_id: task.task_id,
      session_ref: host.getSessionReference(),
    });
    host.archive();
    host.save();
    return { statusCode: 200 };
  }

  getArtifact(id) {
    const artifact = this.loadIndex().artifacts.find((item) => item.id === id) ?? null;
    if (!artifact) return null;
    if (!inside(this.artifactRoot, artifact.absolute_path)) return null;
    return artifact;
  }
}
