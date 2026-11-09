import test from "node:test";
import assert from "node:assert/strict";
import { runAuthorityBaseline } from "./authority-baseline.js";

test("authority baseline chooses the latest explicit decision and ignores later echoes", () => {
  const fact = (id, kind, timestamp, extra = {}) => ({ id, kind, timestamp, topic_id: "T", conflict_key: "k", authority: kind === "decision" ? "explicit_decision" : "conversation_turn", evidence_event_ids: [id], ...extra });
  const result = runAuthorityBaseline({ facts: [fact("old", "decision", "2026-01-01"), fact("new", "decision", "2026-01-02"), fact("echo", "episode", "2026-01-03")] });
  assert.deepEqual([...result.active_ids], ["new"]);
  assert.deepEqual(result.provenance_by_id.get("new"), ["new"]);
  assert.deepEqual(result.flagged_conflict_pairs, []);
});
