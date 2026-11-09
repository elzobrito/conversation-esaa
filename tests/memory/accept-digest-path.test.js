import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  buildActiveViewFromProposal,
  cmdPrepareAccept,
  cmdReconstructFromLedger,
  cmdSleep,
  cmdVerify,
  loadAcceptedConsolidation,
} from "../../src/memory/adapter/cli.js";

function seedWorkspace(turnCount = 4) {
  const ws = mkdtempSync(path.join(tmpdir(), "js04-digest-path-"));
  const conv = path.join(ws, ".conversation-esaa");
  mkdirSync(conv, { recursive: true });
  const events = [];
  for (let i = 0; i < turnCount; i++) {
    const assistant = i % 2 === 1;
    events.push({
      event_id: `turn-${String(i).padStart(4, "0")}`,
      ts: "2026-11-09T12:00:00Z",
      event: "conversation_turn",
      actor: assistant ? "assistant" : "user",
      agent_id: assistant ? "codex" : null,
      workspace_root: ws,
      summary: `turno sintetico ${i}`,
      text: `turno sintetico ${i}`,
    });
  }
  events.push({
    event_id: "dec-js04",
    ts: "2026-11-09T12:00:01Z",
    event: "decision.recorded",
    actor: "assistant",
    agent_id: "codex",
    workspace_root: ws,
    decision: "Usar digest+path no accept",
    rationale: "JS-04/D-03",
    summary: "Usar digest+path no accept",
    text: "Usar digest+path no accept",
  });
  const activityPath = path.join(conv, "activity.jsonl");
  writeFileSync(activityPath, events.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return { ws, activityPath, conv };
}

function appendAccepted(activityPath, payload, extras = {}) {
  const record = {
    schema_version: "conversation-esaa.v1",
    event_id: extras.event_id || "accept-1",
    ts: "2026-11-09T12:01:00Z",
    event: "memory.consolidation.accepted",
    actor: "assistant",
    agent_id: "grok",
    workspace_root: extras.workspace_root,
    ...payload,
    ...extras.override,
  };
  writeFileSync(activityPath, `${readFileSync(activityPath, "utf8").trimEnd()}\n${JSON.stringify(record)}\n`);
  return record;
}

test("prepare-accept emits digest+path without embedding graph/proposal/active_view", () => {
  const { ws } = seedWorkspace(6);
  try {
    const slept = cmdSleep(ws, { mode: "shadow", seed: 42, budget: "all" });
    const prep = cmdPrepareAccept(ws, slept.proposal_id);
    const payload = prep.event_payload;
    assert.equal(payload.artifact_encoding, "digest_path.v1");
    assert.equal(payload.proposal_id, slept.proposal_id);
    assert.ok(payload.proposal_path.startsWith(".conversation-esaa/memory/shadow/"));
    assert.ok(payload.graph_path.startsWith(".conversation-esaa/memory/generations/"));
    assert.equal(payload.graph, undefined);
    assert.equal(payload.proposal, undefined);
    assert.equal(payload.active_view, undefined);
    const encoded = Buffer.byteLength(JSON.stringify(payload), "utf8");
    assert.ok(encoded <= 256 * 1024, `payload ${encoded} bytes exceeds 256 KiB`);
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
});

test("reconstruct and verify reread digest+path files and fail closed when they vanish", () => {
  const { ws, activityPath } = seedWorkspace(6);
  try {
    const slept = cmdSleep(ws, { mode: "shadow", seed: 42, budget: "all" });
    const prep = cmdPrepareAccept(ws, slept.proposal_id);
    appendAccepted(activityPath, prep.event_payload, { workspace_root: ws });

    const reconstructed = cmdReconstructFromLedger(ws);
    assert.equal(reconstructed.status, "OK");
    assert.equal(reconstructed.active_generation_id, slept.graph_generation_id);
    const verified = cmdVerify(ws);
    assert.equal(verified.status, "OK");
    assert.equal(verified.active_generation_id, slept.graph_generation_id);

    rmSync(path.join(ws, ".conversation-esaa", "memory"), { recursive: true, force: true });
    assert.throws(
      () => cmdReconstructFromLedger(ws),
      (err) => err && err.code === "INTEGRITY_FAILURE",
    );
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
});

test("legacy embedded accept events still reconstruct after memory files are deleted", () => {
  const { ws, activityPath } = seedWorkspace(6);
  try {
    const slept = cmdSleep(ws, { mode: "shadow", seed: 42, budget: "all" });
    const prep = cmdPrepareAccept(ws, slept.proposal_id);
    const proposal = JSON.parse(
      readFileSync(path.join(ws, prep.event_payload.proposal_path), "utf8"),
    );
    const graph = JSON.parse(
      readFileSync(path.join(ws, prep.event_payload.graph_path), "utf8"),
    );
    const activeView = buildActiveViewFromProposal(proposal, graph, null);
    assert.equal(activeView.active_digest, prep.event_payload.active_digest);
    rmSync(path.join(ws, ".conversation-esaa", "memory"), { recursive: true, force: true });
    appendAccepted(
      activityPath,
      {
        proposal_id: prep.event_payload.proposal_id,
        snapshot_id: prep.event_payload.snapshot_id,
        watermark_event_id: prep.event_payload.watermark_event_id,
        graph_generation_id: prep.event_payload.graph_generation_id,
        previous_generation_id: null,
        policy_version: prep.event_payload.policy_version,
        workspace_id: prep.event_payload.workspace_id,
        active_digest: prep.event_payload.active_digest,
        proposal,
        graph,
        active_view: activeView,
      },
      { workspace_root: ws, event_id: "legacy-embed" },
    );

    const reconstructed = cmdReconstructFromLedger(ws);
    assert.equal(reconstructed.status, "OK");
    assert.equal(reconstructed.active_digest, prep.event_payload.active_digest);
    const verified = cmdVerify(ws);
    assert.equal(verified.status, "OK");
    const loaded = loadAcceptedConsolidation(
      JSON.parse(readFileSync(activityPath, "utf8").trim().split("\n").at(-1)),
      ws,
    );
    assert.equal(loaded.fromFiles.proposal, false);
    assert.equal(loaded.activeView.active_digest, prep.event_payload.active_digest);
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
});
