import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { sha256Prefixed } from "../../src/memory/core/canonical.js";
import { buildActiveViewFromProposal, cmdContext } from "../../src/memory/adapter/cli.js";

test("active view carries all explicit graph topic links for a retained episode", () => {
  const node = { id: "e1", kind: "episode", topic_id: "TOP-001", summary: "shared", evidence_event_ids: ["e1"] };
  const graph = { nodes: [node], derived_edges: [
    { source: "TOP-001", target: "e1", relation: "topic_contains_event" },
    { source: "TOP-002", target: "e1", relation: "topic_contains_event" },
  ] };
  const proposal = { actions: [{ action: "retain", memory_id: "e1", evidence_event_ids: ["e1"] }] };
  const view = buildActiveViewFromProposal(proposal, graph);
  assert.deepEqual(view.retained[0].topic_ids, ["TOP-001", "TOP-002"]);
});

test("topic context exposes its topic without unrelated or global decisions", () => {
  const root = mkdtempSync(path.join(tmpdir(), "conv-topic-filter-"));
  try {
    const dir = path.join(root, ".conversation-esaa", "memory");
    mkdirSync(dir, { recursive: true });
    const body = {
      schema_version: "conversation-esaa.memory.active.v1",
      graph_generation_id: "generation", proposal_id: "proposal", watermark_event_id: "watermark",
      retained: [
        { memory_id: "TOP-029", kind: "topic", topic_id: "TOP-029", summary: "Lisandra", evidence_event_ids: [] },
        { memory_id: "global", kind: "decision", topic_id: null, summary: "global", evidence_event_ids: [] },
        { memory_id: "linked", kind: "episode", topic_id: "TOP-001", topic_ids: ["TOP-001", "TOP-029"], summary: "related", reason_codes: ["CONSOLIDATED_SUBJECT_MATTER"], evidence_event_ids: [] },
        { memory_id: "noise", kind: "episode", topic_id: "TOP-029", summary: "</image>", reason_codes: ["CONSOLIDATED_SUBJECT_MATTER"], evidence_event_ids: [] },
      ],
      grouped_duplicates: [{ memory_id: "noisy-group", kind: "episode", topic_id: "TOP-029", summary: "I will wait for `pnpm tauri build` to complete." }], historical_decisions: [], deprioritized: [],
      flagged_conflicts: [{ memory_id: "flagged", kind: "episode", topic_id: "TOP-029", summary: "conflict", evidence_event_ids: [] }],
      unresolved: [{ conflict_id: "other", memory_ids: ["global"], evidence_event_ids: [] }, { conflict_id: "here", memory_ids: ["flagged"], evidence_event_ids: [] }],
    };
    writeFileSync(path.join(dir, "active.json"), JSON.stringify({ ...body, active_digest: sha256Prefixed(body) }));
    const result = cmdContext(root, { topicId: "TOP-029", budgetChars: 20000 });
    assert.equal(result.status, "OK");
    assert.deepEqual(result.retained_topics_and_tasks.map(x => x.memory_id), ["TOP-029"]);
    assert.deepEqual(result.consolidated_subjects.map(x => x.memory_id), ["linked"]);
    assert.deepEqual(result.retained_decisions, []);
    assert.deepEqual(result.grouped_duplicates, []);
    assert.deepEqual(result.unresolved_conflicts.map(x => x.conflict_id), ["here"]);
    assert.match(result.markdown, /Lisandra/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
