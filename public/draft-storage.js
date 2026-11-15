export function clearResetDraftStorage({ storage, previousKey, currentKey }) {
  const keys = new Set(
    [previousKey, "agent-panel-draft:new", currentKey].filter(Boolean),
  );
  for (const key of keys) {
    storage.removeItem(key);
  }
  return [...keys];
}
