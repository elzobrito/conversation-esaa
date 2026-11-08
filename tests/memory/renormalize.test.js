import assert from "node:assert/strict";
import test from "node:test";
import { sha256Prefixed } from "../../src/memory/core/canonical.js";
import {
  ALLOWED_PROPOSAL_ACTIONS,
  runRrrCycle,
} from "../../src/memory/core/renormalize.js";

test("renormalization restricts actions, preserves all source evidence IDs, and retains explicit decision over newer conflicting turns", () => {
  const dupDigest = sha256Prefixed("SQLite foi cogitado como alternativa");
  const facts = [
    {
      id: "e001",
      kind: "episode",
      timestamp: "2026-11-07T10:01:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Definimos adotar PostgreSQL como banco oficial",
      content_digest: sha256Prefixed("dec-pg"),
      authority: "explicit_decision",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e001"],
    },
    {
      id: "decision:e001",
      kind: "decision",
      timestamp: "2026-11-07T10:01:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Adotar PostgreSQL",
      content_digest: sha256Prefixed("dec-pg"),
      authority: "explicit_decision",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e001"],
    },
    {
      id: "e002",
      kind: "episode",
      timestamp: "2026-11-07T10:02:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "SQLite foi cogitado como alternativa",
      content_digest: dupDigest,
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e002"],
    },
    {
      id: "e003",
      kind: "episode",
      timestamp: "2026-11-07T10:03:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "SQLite foi cogitado como alternativa",
      content_digest: dupDigest,
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e003"],
    },
    {
      id: "e004",
      kind: "episode",
      timestamp: "2026-11-07T10:09:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Comentário recente sugerindo escolher SQLite sem decisão formal",
      content_digest: sha256Prefixed("recent-comment-sqlite"),
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e004"],
    },
  ];
  const relations = [
    {
      source: "decision:e001",
      relation: "decision_supported_by_event",
      target: "e001",
      rule_id: "explicit_decision_event",
      rule_version: "1.0.0",
      evidence_event_ids: ["e001"],
    },
  ];

  const bundle = {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: sha256Prefixed("workspace:renorm-test"),
    source_snapshot_id: sha256Prefixed({ facts, relations }),
    watermark_event_id: "e004",
    normalizer_version: "1.0.0",
    facts,
    relations,
  };

  const { proposal } = runRrrCycle(bundle, { seed: 42, budget: "all" });

  for (const act of proposal.actions) {
    assert.ok(ALLOWED_PROPOSAL_ACTIONS.has(act.action));
    assert.ok(act.reason_codes.length >= 1);
    assert.ok(act.evidence_event_ids.length >= 1);
  }

  const decAction = proposal.actions.find((a) => a.memory_id === "decision:e001");
  assert.equal(decAction.action, "retain");
  assert.ok(decAction.reason_codes.includes("EXPLICIT_DECISION"));

  const dupGroup = proposal.actions.find(
    (a) => a.action === "group_exact_duplicates",
  );
  assert.ok(dupGroup);
  assert.deepEqual(dupGroup.evidence_event_ids, ["e002", "e003"]);
});

test("renormalization marks explicitly superseded decisions as mark_historical_explicit", () => {
  const facts = [
    {
      id: "decision:e001",
      kind: "decision",
      timestamp: "2026-11-07T10:01:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Adotar PostgreSQL 15",
      content_digest: sha256Prefixed("dec-pg15"),
      authority: "explicit_decision",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e001"],
    },
    {
      id: "decision:e008",
      kind: "decision",
      timestamp: "2026-11-07T11:00:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Migrar para PostgreSQL 17",
      content_digest: sha256Prefixed("dec-pg17"),
      authority: "explicit_decision",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      supersedes_id: "decision:e001",
      evidence_event_ids: ["e008"],
    },
  ];
  const bundle = {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: sha256Prefixed("workspace:renorm-sup"),
    source_snapshot_id: sha256Prefixed(facts),
    watermark_event_id: "e008",
    normalizer_version: "1.0.0",
    facts,
    relations: [],
  };

  const { proposal } = runRrrCycle(bundle, { seed: 42 });
  const oldDec = proposal.actions.find((a) => a.memory_id === "decision:e001");
  const newDec = proposal.actions.find((a) => a.memory_id === "decision:e008");

  assert.equal(oldDec.action, "mark_historical_explicit");
  assert.equal(oldDec.superseded_by_id, "decision:e008");
  assert.equal(newDec.action, "retain");
});
