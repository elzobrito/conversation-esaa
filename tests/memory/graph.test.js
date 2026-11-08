import assert from "node:assert/strict";
import test from "node:test";
import {
  sha256Prefixed,
  validateFactsBundle,
} from "../../src/memory/core/canonical.js";
import {
  assertGraphInvariants,
  buildMemoryGraph,
} from "../../src/memory/core/graph.js";

function makeSampleFactsBundle() {
  const wsId = sha256Prefixed("workspace:sample");
  const d1 = sha256Prefixed("Adotar PostgreSQL");
  const d2 = sha256Prefixed("Repetição literal do mesmo turno");
  const facts = [
    {
      id: "evt-001",
      kind: "episode",
      timestamp: "2026-11-07T10:00:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Repetição literal do mesmo turno",
      content_digest: d2,
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["evt-001"],
    },
    {
      id: "evt-002",
      kind: "episode",
      timestamp: "2026-11-07T10:01:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Repetição literal do mesmo turno",
      content_digest: d2,
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["evt-002"],
    },
    {
      id: "decision:evt-003",
      kind: "decision",
      timestamp: "2026-11-07T10:02:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Adotar PostgreSQL",
      content_digest: d1,
      authority: "explicit_decision",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["evt-001", "evt-003"],
    },
  ];
  const relations = [
    {
      source: "decision:evt-003",
      relation: "decision_supported_by_event",
      target: "evt-001",
      rule_id: "explicit_decision_related_turn",
      rule_version: "1.0.0",
      evidence_event_ids: ["evt-001", "evt-003"],
    },
  ];
  return {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: wsId,
    source_snapshot_id: sha256Prefixed({ facts, relations }),
    watermark_event_id: "evt-003",
    normalizer_version: "1.0.0",
    facts,
    relations,
  };
}

test("core graph accepts only normalized facts without ESAA paths and produces deterministic output", () => {
  const bundle = makeSampleFactsBundle();
  assert.equal(validateFactsBundle(bundle), true);

  const g1 = buildMemoryGraph(bundle, { seed: 42 });
  const g2 = buildMemoryGraph(
    {
      ...bundle,
      facts: [...bundle.facts].reverse(),
    },
    { seed: 42 },
  );

  assert.equal(g1.generation_id, g2.generation_id);
  assert.deepEqual(g1, g2);
  assert.equal(assertGraphInvariants(g1), true);

  const dupEdges = g1.derived_edges.filter(
    (e) => e.relation === "duplicate_exact_content",
  );
  assert.equal(dupEdges.length, 1);
  assert.equal(dupEdges[0].rule_id, "exact_content_digest_match");

  assert.throws(
    () =>
      validateFactsBundle({
        ...bundle,
        workspace_id: "/home/user/.conversation-esaa",
      }),
    (err) => err.code === "UNSUPPORTED_FACT",
  );
});

test("core graph enforces derived_edges vs possible_edges separation and explicit boundaries", () => {
  const bundle = makeSampleFactsBundle();
  bundle.relations.push({
    source: "decision:evt-003",
    relation: "decision_supported_by_event",
    target: "evt-missing-999",
    rule_id: "explicit_decision_related_turn",
    rule_version: "1.0.0",
    evidence_event_ids: ["evt-003"],
  });

  const graph = buildMemoryGraph(bundle, { seed: 7 });
  assert.equal(graph.boundaries.length, 1);
  assert.equal(graph.boundaries[0].kind, "missing_referenced_event");

  assert.throws(
    () => buildMemoryGraph(bundle, { max_nodes: 1 }),
    (err) => err.code === "LIMIT_EXCEEDED",
  );
});
