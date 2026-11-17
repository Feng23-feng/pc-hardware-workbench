import assert from "node:assert/strict";
import {
  SOURCE_HOSTED_STUCK_PHASES,
  SOURCE_HOSTED_SUBMITTABLE_PHASES,
  evaluateSourceHostedPhaseContract,
} from "../lib/source-hosted-phase.mjs";
import {
  SOURCE_HOSTED_SUBMITTABLE_PHASES as UI_SUBMITTABLE_PHASES,
  evaluateSourceHostedPhase as evaluateUiPhase,
} from "../public/source-hosted-phase.js";

assert.deepEqual(
  [...UI_SUBMITTABLE_PHASES],
  [...SOURCE_HOSTED_SUBMITTABLE_PHASES],
);
assert.deepEqual([...SOURCE_HOSTED_STUCK_PHASES], ["source_agent_pulled"]);

for (const phase of SOURCE_HOSTED_SUBMITTABLE_PHASES) {
  const contract = evaluateSourceHostedPhaseContract({
    mode: "source_hosted",
    phase,
  });
  const ui = evaluateUiPhase({
    mode: "source_hosted",
    phase,
  });
  assert.equal(contract.submittable, true);
  assert.equal(ui.submittable, true);
  assert.equal(ui.can_upload, true);
  assert.equal(ui.can_submit, true);
  assert.equal(ui.can_analyze, true);
  assert.equal(ui.can_decide_permission, true);
}

const stuckContract = evaluateSourceHostedPhaseContract({
  mode: "source_hosted",
  phase: "source_agent_pulled",
});
const stuckUi = evaluateUiPhase({
  mode: "source_hosted",
  phase: "source_agent_pulled",
});
assert.equal(stuckContract.submittable, false);
assert.equal(stuckContract.recovery_available, true);
assert.equal(stuckUi.submittable, false);
assert.equal(stuckUi.recovery_available, true);
assert.equal(stuckUi.can_upload, false);
assert.equal(stuckUi.can_submit, false);
assert.equal(stuckUi.can_analyze, false);
assert.equal(stuckUi.can_decide_permission, false);

const unsupportedUi = evaluateUiPhase({
  mode: "source_hosted",
  phase: "unknown_phase",
});
assert.equal(unsupportedUi.submittable, false);
assert.equal(unsupportedUi.recovery_available, false);

const generic = evaluateSourceHostedPhaseContract({
  mode: "independent",
  phase: "ready",
});
assert.equal(generic.submittable, true);

console.log("Source-hosted phase policy: PASS");
