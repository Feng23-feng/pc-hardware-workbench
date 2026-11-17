import assert from "node:assert/strict";
import {
  evaluateRuntimeBinding,
  parseRuntimeBindingHint,
  parseRuntimeBindingQuery,
} from "../public/runtime-binding.js";

const binding = {
  launch_id: "12345678-1234-1234-1234-123456789abc",
  pid: 4242,
  port: 55123,
  origin: "http://127.0.0.1:55123",
};
const health = {
  ok: true,
  surface: {
    host: "127.0.0.1",
    port: 55123,
  },
  runtime_binding: binding,
};
const locationValue = {
  protocol: "http:",
  host: "127.0.0.1:55123",
  origin: "http://127.0.0.1:55123",
  port: "55123",
  search: "",
};

let result = evaluateRuntimeBinding({
  health,
  locationValue,
  hint: binding,
  queryBinding: binding,
  stateBinding: binding,
});
assert.equal(result.ok, true);
assert.deepEqual(result.failureCodes, []);

result = evaluateRuntimeBinding({
  health,
  locationValue: {
    ...locationValue,
    host: "127.0.0.1:55124",
    origin: "http://127.0.0.1:55124",
    port: "55124",
  },
});
assert.equal(result.ok, false);
assert.ok(result.failureCodes.includes("runtime_origin_mismatch"));
assert.ok(result.failureCodes.includes("runtime_port_mismatch"));

result = evaluateRuntimeBinding({
  health,
  locationValue,
  hint: { ...binding, launch_id: "different-launch-id" },
});
assert.equal(result.ok, false);
assert.ok(result.failureCodes.includes("runtime_hint_mismatch"));

result = evaluateRuntimeBinding({
  health,
  locationValue,
  stateBinding: { ...binding, pid: 9999 },
});
assert.equal(result.ok, false);
assert.ok(result.failureCodes.includes("runtime_state_mismatch"));

assert.deepEqual(
  parseRuntimeBindingHint(JSON.stringify(binding)),
  binding,
);
assert.deepEqual(
  parseRuntimeBindingQuery(
    "?runtime_launch_id=12345678-1234-1234-1234-123456789abc&runtime_pid=4242&runtime_port=55123",
    locationValue,
  ),
  binding,
);

console.log("Runtime exact origin/PID/port binding: PASS");
