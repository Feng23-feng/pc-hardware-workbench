import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  evaluatePchwSurfaceCompatibility,
  PCHW_SURFACE_COMPATIBILITY_PROFILE,
} from "../lib/pchw-surface-contract.mjs";

const CAPABILITY = "telemetry.csv.analyze";

function manifest({
  version = "2.9.0",
  id = "pc-hardware-workbench",
  status = "active",
  contractVersion,
  minSkillVersion = "2.8.0",
  requiredCapabilities = [CAPABILITY],
  capabilities = [{ id: CAPABILITY }],
  uiStateSchemaVersion = "1.2",
  eventSchemaVersion = "1.0",
  includeContract = true,
} = {}) {
  const value = {
    skill: { id, version },
    status,
    ui: {
      state_schema_version: uiStateSchemaVersion,
      event_schema_version: eventSchemaVersion,
    },
    domain: { capabilities },
  };
  if (includeContract) {
    value.surface_contracts = {
      "pchw-source-hosted": {
        contract_version: contractVersion ?? "1.0.0",
        min_skill_version: minSkillVersion,
        required_capabilities: requiredCapabilities,
      },
    };
  }
  return value;
}

function assertCompatible(expectedMode) {
  return (result) => {
    assert.equal(result.compatible, true);
    assert.equal(result.mode, expectedMode);
  };
}

function assertIncompatible(expectedCode) {
  return (result) => {
    assert.equal(result.compatible, false);
    assert.equal(result.code, expectedCode);
  };
}

assertCompatible("legacy_exact")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      version: "2.8.0",
      includeContract: false,
    }),
  ),
);

assert.deepEqual(PCHW_SURFACE_COMPATIBILITY_PROFILE.ui_state_schema_versions, [
  "1.2",
]);
assert.deepEqual(PCHW_SURFACE_COMPATIBILITY_PROFILE.event_schema_versions, [
  "1.0",
]);
assert.equal(Object.isFrozen(PCHW_SURFACE_COMPATIBILITY_PROFILE), true);
assert.equal(
  Object.isFrozen(PCHW_SURFACE_COMPATIBILITY_PROFILE.ui_state_schema_versions),
  true,
);
assert.equal(
  Object.isFrozen(PCHW_SURFACE_COMPATIBILITY_PROFILE.event_schema_versions),
  true,
);

for (const version of ["2.9.0", "2.10.0", "3.0.0"]) {
  assertCompatible("contract")(
    evaluatePchwSurfaceCompatibility(manifest({ version })),
  );
}

for (const uiStateSchemaVersion of ["1.1", "1.3", "2.0", ""]) {
  const result = evaluatePchwSurfaceCompatibility(
    manifest({
      version: "3.0.0",
      uiStateSchemaVersion,
    }),
  );
  assert.equal(result.compatible, false, uiStateSchemaVersion);
  assert.equal(result.code, "ui_state_schema_unsupported");
}

for (const eventSchemaVersion of ["0.9", "1.1", "2.0", ""]) {
  const result = evaluatePchwSurfaceCompatibility(
    manifest({
      version: "3.0.0",
      eventSchemaVersion,
    }),
  );
  assert.equal(result.compatible, false, eventSchemaVersion);
  assert.equal(result.code, "event_schema_unsupported");
}

const missingUi = manifest({ version: "3.0.0" });
delete missingUi.ui;
assertIncompatible("ui_state_schema_unsupported")(
  evaluatePchwSurfaceCompatibility(missingUi),
);

const missingEventSchema = manifest({ version: "3.0.0" });
delete missingEventSchema.ui.event_schema_version;
assertIncompatible("event_schema_unsupported")(
  evaluatePchwSurfaceCompatibility(missingEventSchema),
);

const shippedManifest = JSON.parse(
  readFileSync(
    resolve("skills", "pc-hardware-workbench", "workbench.manifest.json"),
    "utf8",
  ),
);
assertCompatible("contract")(
  evaluatePchwSurfaceCompatibility({
    ...shippedManifest,
    status: "active",
  }),
);

assertCompatible("contract")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      version: "2.9.0",
      contractVersion: "1.1.0",
    }),
  ),
);

assertIncompatible("surface_contract_missing")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      version: "2.9.0",
      includeContract: false,
    }),
  ),
);

for (const contractVersion of ["2.0.0", "0.9.9", "1.0", "01.0.0"]) {
  const result = evaluatePchwSurfaceCompatibility(
    manifest({
      version: "2.9.0",
      contractVersion,
    }),
  );
  assert.equal(result.compatible, false, contractVersion);
  assert.ok(
    [
      "surface_contract_unsupported",
      "surface_contract_version_invalid",
    ].includes(result.code),
    `${contractVersion}: ${result.code}`,
  );
}

assertIncompatible("skill_version_below_contract_minimum")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      version: "2.9.0",
      minSkillVersion: "2.10.0",
    }),
  ),
);

assertIncompatible("surface_contract_capability_missing")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      capabilities: [],
    }),
  ),
);

assertIncompatible("surface_contract_capability_missing")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      requiredCapabilities: [],
    }),
  ),
);

assertIncompatible("skill_id_mismatch")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      id: "different-skill",
    }),
  ),
);

assertIncompatible("skill_not_active")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      status: "fallback",
    }),
  ),
);

assertIncompatible("skill_version_too_old")(
  evaluatePchwSurfaceCompatibility(
    manifest({
      version: "2.7.9",
      includeContract: false,
    }),
  ),
);

for (const launcherPath of [
  resolve("launcher", "SkillDockLauncher.cs"),
  resolve("launcher", "release", "SkillDockLauncher.cs"),
]) {
  const source = readFileSync(launcherPath, "utf8");
  assert.doesNotMatch(source, /ExpectedSkillVersion/u);
  assert.match(source, /ExpectedSurfaceContract/u);
  assert.match(source, /surfaceCompatibility/u);
  assert.match(source, /surfaceSkillVersion/u);
}

console.log("PCHW surface contract compatibility: PASS");
