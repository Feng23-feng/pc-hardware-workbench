function normalizeBinding(value) {
  if (!value || typeof value !== "object") return null;
  return {
    launch_id: String(value.launch_id ?? ""),
    pid: Number(value.pid),
    port: Number(value.port),
    origin: String(value.origin ?? ""),
  };
}

function sameBinding(left, right) {
  if (!left || !right) return false;
  return (
    left.launch_id === right.launch_id &&
    left.pid === right.pid &&
    left.port === right.port &&
    left.origin === right.origin
  );
}

export function parseRuntimeBindingHint(value) {
  if (!value) return null;
  try {
    return normalizeBinding(JSON.parse(value));
  } catch {
    return null;
  }
}

export function parseRuntimeBindingQuery(search = "", locationValue) {
  const params = new URLSearchParams(search);
  if (
    !params.has("runtime_launch_id") ||
    !params.has("runtime_pid") ||
    !params.has("runtime_port")
  ) {
    return null;
  }
  return normalizeBinding({
    launch_id: params.get("runtime_launch_id"),
    pid: params.get("runtime_pid"),
    port: params.get("runtime_port"),
    origin: `${locationValue?.protocol ?? ""}//${locationValue?.host ?? ""}`,
  });
}

export function evaluateRuntimeBinding({
  health,
  locationValue,
  hint = null,
  stateBinding = null,
  queryBinding = null,
}) {
  const binding = normalizeBinding(health?.runtime_binding);
  const checks = {
    health_ok: health?.ok === true,
    binding_present: Boolean(binding),
    binding_valid: Boolean(
      binding &&
        /^[A-Za-z0-9._:-]{16,100}$/u.test(binding.launch_id) &&
        Number.isInteger(binding.pid) &&
        binding.pid > 0 &&
        Number.isInteger(binding.port) &&
        binding.port > 0 &&
        binding.origin
    ),
    location_origin_matches: false,
    location_port_matches: false,
    health_surface_matches: false,
    hint_matches: hint === null,
    query_matches: queryBinding === null,
    state_matches: stateBinding === null,
  };
  if (binding) {
    checks.location_origin_matches =
      binding.origin === String(locationValue?.origin ?? "");
    checks.location_port_matches =
      String(binding.port) === String(locationValue?.port ?? "");
    checks.health_surface_matches =
      Number(health?.surface?.port) === binding.port &&
      String(health?.surface?.host ?? "") === "127.0.0.1";
    checks.hint_matches = hint === null || sameBinding(binding, hint);
    checks.query_matches =
      queryBinding === null || sameBinding(binding, queryBinding);
    checks.state_matches =
      stateBinding === null ||
      sameBinding(binding, normalizeBinding(stateBinding));
  }
  const failureCodes = [];
  if (!checks.health_ok) failureCodes.push("runtime_health_unavailable");
  if (!checks.binding_present) failureCodes.push("runtime_binding_missing");
  if (!checks.binding_valid) failureCodes.push("runtime_binding_invalid");
  if (!checks.location_origin_matches) {
    failureCodes.push("runtime_origin_mismatch");
  }
  if (!checks.location_port_matches) failureCodes.push("runtime_port_mismatch");
  if (!checks.health_surface_matches) {
    failureCodes.push("runtime_health_surface_mismatch");
  }
  if (!checks.hint_matches) failureCodes.push("runtime_hint_mismatch");
  if (!checks.query_matches) failureCodes.push("runtime_query_mismatch");
  if (!checks.state_matches) failureCodes.push("runtime_state_mismatch");
  return {
    ok: failureCodes.length === 0,
    binding,
    checks,
    failureCodes,
  };
}
