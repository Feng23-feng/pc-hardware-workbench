const PERSISTENT_TELEMETRY_BLOCK_TYPES = new Set([
  "metrics",
  "chart",
  "table",
  "callout",
  "artifact-download",
]);

export function mergePersistentPanelState(previous, current) {
  if (!previous || !current) {
    return current;
  }
  const artifacts = [];
  const artifactIds = new Set();
  for (const artifact of [
    ...(previous.artifact_refs ?? []),
    ...(current.artifact_refs ?? []),
  ]) {
    if (!artifactIds.has(artifact.id)) {
      artifactIds.add(artifact.id);
      artifacts.push(artifact);
    }
  }
  const blockIds = new Set((current.blocks ?? []).map((block) => block.id));
  const persistentBlocks = (previous.blocks ?? []).filter(
    (block) =>
      String(block.id ?? "").startsWith("telemetry-") &&
      PERSISTENT_TELEMETRY_BLOCK_TYPES.has(block.type) &&
      (block.type !== "chart" && block.type !== "artifact-download"
        ? true
        : artifactIds.has(block.artifact_ref)) &&
      !blockIds.has(block.id),
  );
  return {
    ...current,
    artifact_refs: artifacts.slice(0, 6),
    blocks: [...(current.blocks ?? []), ...persistentBlocks].slice(0, 12),
  };
}
