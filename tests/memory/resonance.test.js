import assert from "node:assert/strict";
import test from "node:test";
import { sha256Prefixed } from "../../src/memory/core/canonical.js";
import { buildMemoryGraph } from "../../src/memory/core/graph.js";
import { runResonance } from "../../src/memory/core/resonance.js";

test("resonance never promotes candidate edges to derived_edges, flags unresolved conflicts, and deduplicates agent echoes", () => {
  const echoDigest = sha256Prefixed("SQLite adotado como banco principal");
  const facts = [
    {
      id: "e003",
      kind: "episode",
      timestamp: "2026-11-07T10:03:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Resumo incorreto: usar SQLite no módulo",
      content_digest: echoDigest,
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e003"],
    },
    {
      id: "e006",
      kind: "episode",
      timestamp: "2026-11-07T10:06:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Resumo incorreto: usar SQLite no módulo",
      content_digest: echoDigest,
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e006"],
    },
    {
      id: "e009",
      kind: "episode",
      timestamp: "2026-11-07T10:09:00Z",
      topic_id: "TOP-002",
      time_bucket: "2026-11-07",
      summary: "O cache oficial é Redis",
      content_digest: sha256Prefixed("cache-redis"),
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      conflict_key: "cache_backend",
      conflict_value: "redis",
      evidence_event_ids: ["e009"],
    },
    {
      id: "e010",
      kind: "episode",
      timestamp: "2026-11-07T10:10:00Z",
      topic_id: "TOP-002",
      time_bucket: "2026-11-07",
      summary: "O cache oficial é Memcached",
      content_digest: sha256Prefixed("cache-memcached"),
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      conflict_key: "cache_backend",
      conflict_value: "memcached",
      evidence_event_ids: ["e010"],
    },
    {
      id: "e011",
      kind: "episode",
      timestamp: "2026-11-07T10:11:00Z",
      topic_id: "TOP-001",
      time_bucket: "2026-11-07",
      summary: "Resumo incorreto: usar SQLite no módulo central",
      content_digest: sha256Prefixed("near-dup-sqlite"),
      authority: "conversation_turn",
      epistemic_status: "verified_explicit",
      validity_status: "active",
      evidence_event_ids: ["e011"],
    },
  ];

  const bundle = {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: sha256Prefixed("workspace:res-test"),
    source_snapshot_id: sha256Prefixed(facts),
    watermark_event_id: "e011",
    normalizer_version: "1.0.0",
    facts,
    relations: [],
  };

  const baseGraph = buildMemoryGraph(bundle, { seed: 42 });
  const initialDerivedCount = baseGraph.derived_edges.length;
  const resonated = runResonance(baseGraph, bundle);

  assert.equal(
    resonated.derived_edges.length,
    initialDerivedCount,
    "Resonance must never promote possible edges into derived_edges",
  );

  const contradictions = resonated.possible_edges.filter(
    (e) => e.relation === "possibly_contradicts",
  );
  assert.equal(contradictions.length, 1);
  assert.deepEqual(contradictions[0].source, "e009");
  assert.deepEqual(contradictions[0].target, "e010");

  const node9 = resonated.nodes.find((n) => n.id === "e009");
  const node10 = resonated.nodes.find((n) => n.id === "e010");
  assert.equal(node9.epistemic_status, "unresolved");
  assert.equal(node10.epistemic_status, "unresolved");

  const unresolvedBoundaries = resonated.boundaries.filter(
    (b) => b.kind === "unresolved_conflict",
  );
  assert.equal(unresolvedBoundaries.length, 1);

  const nearDups = resonated.possible_edges.filter(
    (e) => e.relation === "possibly_duplicate",
  );
  assert.ok(nearDups.length >= 1, "Near duplicate lexical overlap stays in possible_edges");

  const node3 = resonated.nodes.find((n) => n.id === "e003");
  const node6 = resonated.nodes.find((n) => n.id === "e006");
  assert.equal(node3.independent_support_count, 1);
  assert.equal(node6.independent_support_count, 1);
});
