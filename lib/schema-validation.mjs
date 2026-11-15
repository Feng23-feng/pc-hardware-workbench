const PANEL_STATUSES = new Set(["needs_input", "ready", "blocked"]);
const EVIDENCE_SOURCES = new Set([
  "user_reported",
  "agent_inference",
  "observed_current",
  "historical",
]);
const EVIDENCE_RELATIONS = new Set(["supports", "conflicts", "context"]);
const BLOCK_TYPES = new Set([
  "markdown",
  "metrics",
  "chart",
  "table",
  "callout",
  "artifact-download",
]);
const CALLOUT_TONES = new Set(["info", "warning", "neutral"]);

function assertString(value, name, { min = 0, max = Infinity } = {}) {
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new Error(`${name} must be a string between ${min} and ${max} characters`);
  }
}

function assertId(value, name, max = 64) {
  assertString(value, name, { min: 1, max });
  if (!/^[a-z0-9-]+$/.test(value)) {
    throw new Error(`${name} must contain only lowercase letters, digits, and hyphens`);
  }
}

function validateQuestion(panel) {
  if (panel.question === null) {
    return;
  }
  const question = panel.question;
  if (!question || typeof question !== "object" || Array.isArray(question)) {
    throw new Error("question must be an object or null");
  }
  assertId(question.id, "question.id");
  assertString(question.prompt, "question.prompt", { min: 1, max: 240 });
  if (typeof question.allow_free_text !== "boolean") {
    throw new Error("question.allow_free_text must be boolean");
  }
  if (
    !Array.isArray(question.options) ||
    question.options.length < 2 ||
    question.options.length > 4
  ) {
    throw new Error("question.options must contain two to four options");
  }
  const optionIds = new Set();
  for (const [index, option] of question.options.entries()) {
    assertId(option?.id, `question.options[${index}].id`, 48);
    if (optionIds.has(option.id)) {
      throw new Error("question option IDs must be unique");
    }
    optionIds.add(option.id);
    assertString(option.label, `question.options[${index}].label`, {
      min: 1,
      max: 48,
    });
    assertString(option.description, `question.options[${index}].description`, {
      max: 160,
    });
  }
}

function validateRecommendation(panel) {
  const recommendation = panel.recommendation;
  if (!recommendation || typeof recommendation !== "object") {
    throw new Error("recommendation must be an object");
  }
  assertString(recommendation.summary, "recommendation.summary", { max: 240 });
  if (
    recommendation.option_id !== null &&
    typeof recommendation.option_id !== "string"
  ) {
    throw new Error("recommendation.option_id must be a string or null");
  }
  if (recommendation.option_id) {
    const validIds = new Set(
      panel.question?.options?.map((option) => option.id) ?? [],
    );
    if (!validIds.has(recommendation.option_id)) {
      throw new Error("recommendation.option_id does not match a question option");
    }
  }
}

function validateResultPanel(panel) {
  assertString(panel.turn_summary, "turn_summary", { min: 1, max: 240 });
  assertString(panel.current_goal, "current_goal", { min: 1, max: 120 });
  if (!PANEL_STATUSES.has(panel.status)) {
    throw new Error("Agent response has an invalid status");
  }
  assertString(panel.judgement, "judgement", { min: 1, max: 800 });
  validateQuestion(panel);
  validateRecommendation(panel);

  if (!Array.isArray(panel.evidence) || panel.evidence.length > 8) {
    throw new Error("evidence must be an array with at most eight items");
  }
  for (const [index, evidence] of panel.evidence.entries()) {
    assertId(evidence?.id, `evidence[${index}].id`);
    assertString(evidence.label, `evidence[${index}].label`, {
      min: 1,
      max: 80,
    });
    assertString(evidence.detail, `evidence[${index}].detail`, { max: 280 });
    if (!EVIDENCE_SOURCES.has(evidence.source)) {
      throw new Error(`evidence[${index}].source is invalid`);
    }
    if (!EVIDENCE_RELATIONS.has(evidence.relation)) {
      throw new Error(`evidence[${index}].relation is invalid`);
    }
  }

  if (
    !Array.isArray(panel.uncertainty) ||
    panel.uncertainty.length < 1 ||
    panel.uncertainty.length > 6
  ) {
    throw new Error("uncertainty must contain one to six items");
  }
  for (const [index, item] of panel.uncertainty.entries()) {
    assertString(item, `uncertainty[${index}]`, { min: 1, max: 280 });
  }

  if (
    !Array.isArray(panel.recommendations) ||
    panel.recommendations.length < 2 ||
    panel.recommendations.length > 3
  ) {
    throw new Error("recommendations must contain two or three items");
  }
  for (const [index, item] of panel.recommendations.entries()) {
    assertId(item?.id, `recommendations[${index}].id`);
    assertString(item.title, `recommendations[${index}].title`, {
      min: 1,
      max: 100,
    });
    assertString(item.detail, `recommendations[${index}].detail`, {
      min: 1,
      max: 520,
    });
    if (item.risk !== "low") {
      throw new Error(`recommendations[${index}].risk must be low`);
    }
    assertString(item.evidence_goal, `recommendations[${index}].evidence_goal`, {
      min: 1,
      max: 240,
    });
  }

  const priority = panel.priorityAction;
  if (!priority || typeof priority !== "object" || Array.isArray(priority)) {
    throw new Error("priorityAction must be an object");
  }
  assertString(priority.title, "priorityAction.title", { min: 1, max: 100 });
  assertString(priority.detail, "priorityAction.detail", { min: 1, max: 520 });

  if (
    !Array.isArray(panel.actions) ||
    panel.actions.length < 1 ||
    panel.actions.length > 3
  ) {
    throw new Error("actions must contain one to three items");
  }
  for (const [index, action] of panel.actions.entries()) {
    assertId(action?.id, `actions[${index}].id`);
    assertString(action.label, `actions[${index}].label`, { min: 1, max: 48 });
    if (action.kind !== "copy") {
      throw new Error(`actions[${index}].kind must be copy`);
    }
    assertString(action.content, `actions[${index}].content`, {
      min: 1,
      max: 2000,
    });
  }
  return panel;
}

function validateArtifactRefs(panel) {
  if (
    !Array.isArray(panel.artifact_refs) ||
    panel.artifact_refs.length > 6
  ) {
    throw new Error("artifact_refs must be an array with at most six items");
  }
  const ids = new Set();
  for (const [index, artifact] of panel.artifact_refs.entries()) {
    assertId(artifact?.id, `artifact_refs[${index}].id`, 80);
    if (ids.has(artifact.id)) {
      throw new Error("artifact_refs IDs must be unique");
    }
    ids.add(artifact.id);
    if (artifact.kind !== "chart" || artifact.mime !== "image/svg+xml") {
      throw new Error(`artifact_refs[${index}] has an unsupported type`);
    }
    assertString(artifact.title, `artifact_refs[${index}].title`, {
      min: 1,
      max: 120,
    });
    assertString(
      artifact.relative_path,
      `artifact_refs[${index}].relative_path`,
      { min: 1, max: 240 },
    );
    if (
      isAbsolutePath(artifact.relative_path) ||
      artifact.relative_path.includes("..") ||
      artifact.relative_path.includes("\\")
    ) {
      throw new Error(`artifact_refs[${index}].relative_path must be a safe relative path`);
    }
    if (!/^[a-f0-9]{64}$/u.test(artifact.sha256 ?? "")) {
      throw new Error(`artifact_refs[${index}].sha256 must be lowercase SHA-256`);
    }
    if (
      !Array.isArray(artifact.source_evidence_ids) ||
      artifact.source_evidence_ids.length < 1 ||
      artifact.source_evidence_ids.length > 8
    ) {
      throw new Error(
        `artifact_refs[${index}].source_evidence_ids must contain one to eight items`,
      );
    }
    for (const [sourceIndex, sourceId] of artifact.source_evidence_ids.entries()) {
      assertId(
        sourceId,
        `artifact_refs[${index}].source_evidence_ids[${sourceIndex}]`,
        80,
      );
    }
    if (
      typeof artifact.created_at !== "string" ||
      !Number.isFinite(Date.parse(artifact.created_at))
    ) {
      throw new Error(`artifact_refs[${index}].created_at must be a date-time`);
    }
    if (artifact.safeToEmbed !== true) {
      throw new Error(`artifact_refs[${index}].safeToEmbed must be true`);
    }
    if (
      !Number.isInteger(artifact.size) ||
      artifact.size < 1 ||
      artifact.size > 5 * 1024 * 1024
    ) {
      throw new Error(`artifact_refs[${index}].size is outside the allowed range`);
    }
  }
  return ids;
}

function isAbsolutePath(value) {
  return /^[A-Za-z]:[\\/]/u.test(value) || value.startsWith("/");
}

function validateBlocks(panel, artifactIds) {
  if (!Array.isArray(panel.blocks) || panel.blocks.length > 12) {
    throw new Error("blocks must be an array with at most twelve items");
  }
  const blockIds = new Set();
  for (const [index, block] of panel.blocks.entries()) {
    assertId(block?.id, `blocks[${index}].id`, 80);
    if (blockIds.has(block.id)) {
      throw new Error("block IDs must be unique");
    }
    blockIds.add(block.id);
    if (!BLOCK_TYPES.has(block.type)) {
      throw new Error(`blocks[${index}].type is not whitelisted`);
    }
    assertString(block.title, `blocks[${index}].title`, {
      min: 1,
      max: 120,
    });

    if (block.type === "markdown" || block.type === "callout") {
      assertString(block.text, `blocks[${index}].text`, {
        min: 1,
        max: 2000,
      });
    }
    if (block.type === "callout") {
      if (!CALLOUT_TONES.has(block.tone)) {
        throw new Error(`blocks[${index}].tone is invalid`);
      }
      if (typeof block.collapsed !== "boolean") {
        throw new Error(`blocks[${index}].collapsed must be boolean`);
      }
    }
    if (block.type === "metrics") {
      if (
        !Array.isArray(block.items) ||
        block.items.length < 1 ||
        block.items.length > 6
      ) {
        throw new Error(`blocks[${index}].items must contain one to six metrics`);
      }
      for (const [itemIndex, item] of block.items.entries()) {
        assertString(item?.label, `blocks[${index}].items[${itemIndex}].label`, {
          min: 1,
          max: 100,
        });
        assertString(item.value, `blocks[${index}].items[${itemIndex}].value`, {
          min: 1,
          max: 40,
        });
        assertString(item.unit, `blocks[${index}].items[${itemIndex}].unit`, {
          max: 16,
        });
        assertString(
          item.source_column,
          `blocks[${index}].items[${itemIndex}].source_column`,
          { min: 1, max: 120 },
        );
      }
    }
    if (block.type === "chart" || block.type === "artifact-download") {
      assertId(block.artifact_ref, `blocks[${index}].artifact_ref`, 80);
      if (!artifactIds.has(block.artifact_ref)) {
        throw new Error(`blocks[${index}].artifact_ref does not match an artifact`);
      }
    }
    if (block.type === "chart") {
      assertString(block.alt, `blocks[${index}].alt`, {
        min: 1,
        max: 240,
      });
    }
    if (block.type === "artifact-download") {
      assertString(block.label, `blocks[${index}].label`, {
        min: 1,
        max: 48,
      });
    }
    if (block.type === "table") {
      if (
        !Array.isArray(block.columns) ||
        block.columns.length < 1 ||
        block.columns.length > 6
      ) {
        throw new Error(`blocks[${index}].columns must contain one to six items`);
      }
      for (const [columnIndex, column] of block.columns.entries()) {
        assertString(
          column,
          `blocks[${index}].columns[${columnIndex}]`,
          { min: 1, max: 80 },
        );
      }
      if (!Array.isArray(block.rows) || block.rows.length > 20) {
        throw new Error(`blocks[${index}].rows must contain at most twenty rows`);
      }
      for (const [rowIndex, row] of block.rows.entries()) {
        if (!Array.isArray(row) || row.length !== block.columns.length) {
          throw new Error(
            `blocks[${index}].rows[${rowIndex}] must match the column count`,
          );
        }
        for (const [cellIndex, cell] of row.entries()) {
          assertString(
            cell,
            `blocks[${index}].rows[${rowIndex}][${cellIndex}]`,
            { max: 120 },
          );
        }
      }
    }
  }
}

function validateArtifactPanel(panel) {
  validateResultPanel(panel);
  const artifactIds = validateArtifactRefs(panel);
  validateBlocks(panel, artifactIds);
  return panel;
}

export function validatePanelState(panel) {
  if (!panel || typeof panel !== "object" || Array.isArray(panel)) {
    throw new Error("Agent response must be a JSON object");
  }
  if (panel.schema_version === "1.2") {
    return validateArtifactPanel(panel);
  }
  if (panel.schema_version === "1.1") {
    return validateResultPanel(panel);
  }
  if (panel.schema_version !== "1.0") {
    throw new Error("Agent response has an unsupported schema_version");
  }
  assertString(panel.turn_summary, "turn_summary", { min: 1, max: 240 });
  assertString(panel.current_goal, "current_goal", { min: 1, max: 120 });
  if (!PANEL_STATUSES.has(panel.status)) {
    throw new Error("Agent response has an invalid status");
  }
  validateQuestion(panel);
  validateRecommendation(panel);

  if (!Array.isArray(panel.evidence) || panel.evidence.length > 8) {
    throw new Error("evidence must be an array with at most eight items");
  }
  for (const [index, evidence] of panel.evidence.entries()) {
    assertId(evidence?.id, `evidence[${index}].id`);
    assertString(evidence.label, `evidence[${index}].label`, {
      min: 1,
      max: 80,
    });
    assertString(evidence.detail, `evidence[${index}].detail`, { max: 240 });
    if (!EVIDENCE_SOURCES.has(evidence.source)) {
      throw new Error(`evidence[${index}].source is invalid`);
    }
  }

  if (!Array.isArray(panel.limitations) || panel.limitations.length > 6) {
    throw new Error("limitations must be an array with at most six items");
  }
  for (const [index, limitation] of panel.limitations.entries()) {
    assertString(limitation, `limitations[${index}]`, { min: 1, max: 240 });
  }
  assertString(panel.next_action, "next_action", { min: 1, max: 240 });
  return panel;
}

export function buildDraftEvent(input, panel) {
  const createdAt = new Date().toISOString();
  if (input.type === "option_selected") {
    const option = panel?.question?.options?.find(
      (candidate) => candidate.id === input.option_id,
    );
    if (!option || input.question_id !== panel.question.id) {
      throw new Error("Selected option does not belong to the current question");
    }
    return {
      schema_version: "1.0",
      type: "option_selected",
      event_id: crypto.randomUUID(),
      created_at: createdAt,
      question_id: panel.question.id,
      option_id: option.id,
    };
  }
  if (input.type === "evidence_added") {
    assertString(input.label, "label", { min: 1, max: 80 });
    assertString(input.detail ?? "", "detail", { max: 240 });
    const source =
      input.source === "observed_current" ? "observed_current" : "user_reported";
    return {
      schema_version: "1.0",
      type: "evidence_added",
      event_id: crypto.randomUUID(),
      created_at: createdAt,
      label: input.label.trim(),
      detail: (input.detail ?? "").trim(),
      source,
    };
  }
  throw new Error("Unsupported local event type");
}
