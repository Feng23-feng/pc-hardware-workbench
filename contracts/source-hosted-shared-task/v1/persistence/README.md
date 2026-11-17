# SQLite Conformance Harness v1

Status: isolated SQLite schema v1 and conformance harness implemented
Requires: Node.js `>=24.22.1 <25.0.0` with `node:sqlite`
Production authority: not granted

## Scope

This harness implements the isolated persistence subset authorized by the R2
decision:

- SQLite schema migration v1;
- WAL + `synchronous=FULL`;
- temporary DB/WAL/SHM fixtures;
- synthetic Task and capability verifier rows;
- snapshot and publish transactional state;
- durable pull delivery watermark;
- durable sparse ack coverage;
- claim/release ownership transactions;
- idempotency receipt replay after reopen;
- pre-commit and post-commit fault injection;
- two-process same-key and revision races;
- abrupt worker crash/restart;
- generation reset and capability rotation;
- isolated loopback HTTP profile routed by path `task_id`;
- multi-Task HTTP workers with Task-scoped capability isolation;
- isolated same-origin SkillDock proxy and sanitized access log;
- frozen production SQLite/Node profile with checksum and fail-closed probes;
- foreign-key, migration-checksum, integrity, and cleanup checks.

Current executable coverage: 25 SQLite tests, 3 production-profile tests,
and 11 HTTP/proxy tests.

It does not implement:

- formal SkillDock HTTP transport integration;
- retention worker;
- default-traffic integration;
- SkillDock server/UI/launcher integration;
- persistent user Task directories;
- real Codex Thread access;
- retention worker or production packaging.

## Files

- `schema-v1.mjs`: schema/migration and connection profile;
- `sqlite-coordinator.mjs`: isolated SQLite coordinator;
- `fixture.mjs`: temporary multi-Task fixture;
- `worker.mjs`: child process used for multiprocess/crash tests.
- `http-server.mjs`: isolated loopback HTTP profile.
- `http-worker.mjs`: child process used for multiprocess HTTP tests.
- `same-origin-proxy.mjs`: isolated fixed-action SkillDock proxy.
- `production-profile.json`: frozen Node/SQLite/runtime profile.
- `production-profile.mjs`: runtime, database, and activation gate probes.
- `shadow-coordinator-worker.mjs`: dedicated shadow fixture process.

## Test

```powershell
pnpm test:source-hosted-sqlite
pnpm test:source-hosted-production-profile
pnpm test:source-hosted-http
```

The production profile is frozen to the built-in `node:sqlite`
`DatabaseSync` driver in one dedicated coordinator process. Node
`24.22.1`, SQLite `3.53.4`, WAL, `synchronous=FULL`, foreign keys,
`trusted_schema=OFF`, schema v1, and a 5-second busy timeout are checked
before shadow activation. The JSON profile has a fixed SHA-256 checksum;
any profile change requires an explicit conformance review.

## Safety

- all DB files are created under OS temp directories;
- fixture cleanup closes DB handles before recursive temp cleanup;
- raw capability tokens are returned only to the test harness;
- database stores SHA-256 verifier keys only;
- no cookie, provider credential, real Thread, or user runtime DB is used;
- test evidence contains no raw token or payload text.
