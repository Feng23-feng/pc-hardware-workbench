# source_hosted-shared-task-v1 Schema Bundle

Status: schema and reference-conformance baseline approved by main review R2
Implementation authority: production implementation not granted
Date: 2026-11-16

This directory contains the machine-readable schema surface for
`source_hosted-shared-task-v1`.

## Files

- `common.schema.json`: capabilities, events, Task state, snapshots, checkpoints,
  delivery/ack state, and execution state;
- `requests.schema.json`: snapshot, pull, publish, ack, claim, and release
  requests;
- `responses.schema.json`: successful operation responses and the error
  envelope;
- `errors.schema.json`: error-code and classification enums;
- `errors.json`: canonical code metadata used by the reference implementation;
- `idempotency-receipt.schema.json`: committed receipt persistence shape.

## Boundaries

- This bundle does not modify the formal SkillDock protocol.
- It does not connect to the production HTTP server or UI.
- It does not call Codex app-server or a real Codex Thread.
- The reference coordinator is in-memory and uses synthetic Task data only.
- Schema validity does not grant implementation or release authority.

## Validation

The conformance test uses JSON Schema Draft 2020-12 through `ajv` and
`ajv-formats`. It verifies:

- every schema compiles;
- valid operation samples pass;
- invalid profile/action and size-limit samples fail as expected;
- the JSON error enum and reference implementation enum are identical;
- canonical request hashes are stable across object-key order and exclude
  transport metadata;
- idempotency receipts can be replayed without a second mutation;
- the in-memory coordinator stores only SHA-256 capability verifiers and emits
  raw tokens once to the test harness through a callback.

Run:

```powershell
pnpm install --frozen-lockfile
pnpm test:source-hosted
```

## Canonical request hash

`reference/canonical-hash.mjs` uses this algorithm:

1. require a plain JSON object request;
2. exclude top-level `request_id` and `idempotency_key`;
3. preserve array order;
4. sort object keys lexicographically at every depth;
5. normalize negative zero to zero and reject non-finite numbers, cycles,
   non-plain objects, and non-JSON values;
6. include the operation name and normalized request payload;
7. hash UTF-8 canonical JSON with SHA-256 and emit lowercase hex.

The raw capability, transport headers, and wall-clock request time are not part
of the hash.

## Error and receipt schemas

- `errors.json` is the implementation catalog used by the reference coordinator.
- `errors.schema.json` is the normative enum used by response validation.
- `idempotency-receipt.schema.json` validates committed receipts and uses
  `operation` to select the corresponding publish, claim, or release response
  schema.

The conformance test asserts that the catalog and enum stay identical.

## Event and execution constraints

- `executionState` enforces the mode/owner/lease combination:
  - source-hosted -> source owner and non-null lease;
  - panel-hosted -> panel owner and non-null lease;
  - suspended -> no owner and null lease.
- Event drafts and committed events enforce the kind/authority/target matrix.
- The reference coordinator separately enforces author role and current-owner
  authority, so schema acceptance cannot turn a panel surface input into an
  Agent execution result.
