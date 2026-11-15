# Agent Bridge

Status: accepted architecture direction; a `0.1-draft` schema and local HTTP
driver exist. The protocol is not frozen.

## Decision

SkillDock will use a small local Agent Bridge contract as the long-term
compatibility layer for Agent backends. Built-in adapters may translate Codex or
DSH into this contract, while other Agent products can provide a bridge process
without changing the SkillDock UI, Task, Artifact, permission, or SkillRuntime
layers.

The first implementation will be a draft. Its protocol version will not be
declared stable until two independent Agent implementations and the built-in
Codex adapter pass the same contract suite.

Draft implementation:

- [contract and response schema](contracts/agent-bridge/0.1-draft/README.md);
- `AgentBridgeDriver` in `lib/agents/agent-bridge-driver.mjs`;
- deterministic bridge fixture in `fixtures/agent-bridge-fixture.mjs`;
- contract test in `tests/agent-bridge.test.mjs`.

## Boundary

The bridge runs on the user's machine and listens only on a loopback address. It
owns Agent-specific authentication, model selection, Session persistence, and
transport details. SkillDock owns Tasks, Skill Surface state, artifacts,
permissions, and user interaction.

Bridge processes may not:

- receive or persist SkillDock capability or handoff secrets;
- expose a wildcard or public network listener;
- inject HTML, JavaScript, or arbitrary UI into the browser;
- silently broaden a Skill's read-only capability profile;
- claim structured output or Session resume without declaring the capability.

## Minimum semantic surface

The draft must describe these operations before implementation:

1. health and capability negotiation;
2. create or recover a Session;
3. submit one turn with text and Skill context;
4. receive text or structured output and neutral lifecycle events;
5. cancel a running turn;
6. classify errors as unavailable, blocked, auth, permission, or protocol.

Streaming, resume, structured output, cancellation, and multi-turn tool events
are optional capabilities. A lack of support must produce a visible limitation
and a safe fallback; it must not be simulated as success.

## Compatibility layers

The long-term support order is:

1. Agent Bridge;
2. generic CLI JSON/NDJSON profile;
3. OpenAI-compatible HTTP where the Agent semantics fit;
4. a built-in protocol-specific adapter;
5. manual handoff for Agents without a safe machine interface.

An adapter is written per protocol family, not per product brand. The router
will select by declared capabilities rather than vendor name.

## Deferred question: Skill selection

Skill discovery is intentionally not part of this decision.

The following remain open:

- whether the user selects a Skill before or after selecting an Agent;
- whether ordinary `SKILL.md`-only packages appear in the picker;
- how chat-only Skills are labelled without implying rich graphical support;
- whether Skill selection belongs in the launcher, the web UI, or both;
- how installed copies with the same Skill ID and version are deduplicated.

Until those questions are decided, discovery remains manifest-first and the
current SkillDock launcher may use an explicit preferred Skill ID for a
controlled test package. No automatic `SKILL.md`-to-UI generation is approved.
