import assert from "node:assert/strict";
import test from "node:test";
import { sha256Prefixed } from "../../src/memory/core/canonical.js";
import { buildMemoryGraph } from "../../src/memory/core/graph.js";
import { runRinging } from "../../src/memory/core/ringing.js";

function makeMultiTopicFactsBundle() {
  const facts = [];
  const topics = ["TOP-001", "TOP-002", "TOP-003"];
  const dates = ["2026-10-01", "2026-10-15", "2026-11-07"];
  let counter = 1;
  for (const topic of topics) {
    for (const date of dates) {
      for (let k = 0; k < 4; k++) {
        const id = `evt-${String(counter++).padStart(3, "0")}`;
        facts.push({
          id,
          kind: "episode",
          timestamp: `${date}T10:00:00Z`,
          topic_id: topic,
          time_bucket: date,
          summary: `Evento ${id} em ${topic} (${date})`,
          content_digest: sha256Prefixed(`${id}-${topic}-${date}`),
          authority: "conversation_turn",
          epistemic_status: "verified_explicit",
          validity_status: "active",
          evidence_event_ids: [id],
        });
      }
    }
  }
  return {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: sha256Prefixed("workspace:ringing-test"),
    source_snapshot_id: sha256Prefixed(facts),
    watermark_event_id: facts[facts.length - 1].id,
    normalizer_version: "1.0.0",
    facts,
    relations: [],
  };
}

test("ringing samples across topics and time buckets reproducibly for the same seed", () => {
  const bundle = makeMultiTopicFactsBundle();
  const baseGraph = buildMemoryGraph(bundle, { seed: 42 });

  const r1 = runRinging(baseGraph, { seed: 42, budget: 9 });
  const r2 = runRinging(baseGraph, { seed: 42, budget: 9 });
  const rDifferentSeed = runRinging(baseGraph, { seed: 99, budget: 9 });

  assert.deepEqual(r1.sampling, r2.sampling);
  assert.equal(r1.graph.generation_id, r2.graph.generation_id);
  assert.equal(r1.sampling.sampled_ids.length, 9);
  assert.equal(r1.sampling.omitted_ids.length, 27);
  assert.notDeepEqual(r1.sampling.sampled_ids, rDifferentSeed.sampling.sampled_ids);

  const sampledNodes = baseGraph.nodes.filter((n) =>
    r1.sampling.sampled_ids.includes(n.id),
  );
  const coveredTopics = new Set(sampledNodes.map((n) => n.topic_id));
  const coveredBuckets = new Set(sampledNodes.map((n) => n.time_bucket));
  assert.equal(coveredTopics.size, 3, "Must stratify across all 3 topics");
  assert.equal(coveredBuckets.size, 3, "Must stratify across all 3 time buckets");
});

test("ringing enforces explicit analysis limits without silent truncation", () => {
  const bundle = makeMultiTopicFactsBundle();
  const baseGraph = buildMemoryGraph(bundle, { seed: 42 });

  assert.throws(
    () => runRinging(baseGraph, { seed: 42, maxAnalysisNodes: 10 }),
    (err) => err.code === "LIMIT_EXCEEDED",
  );

  assert.throws(
    () => runRinging(baseGraph, { seed: 42, budget: 0 }),
    (err) => err.code === "LIMIT_EXCEEDED",
  );

  assert.throws(
    () =>
      runRinging(baseGraph, {
        seed: 42,
        budget: 5,
        strictAnalysisBudget: true,
      }),
    (err) => err.code === "LIMIT_EXCEEDED",
  );
});
