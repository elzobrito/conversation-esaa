import assert from "node:assert/strict";
import {
   chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { sha256Hex } from "../../src/memory/core/canonical.js";
import {
  createWorkspaceSnapshot,
  ensurePrivateMemoryDirs,
  verifySnapshotFreshness,
} from "../../src/memory/adapter/snapshot.js";

function makeTempWorkspace() {
  const ws = mkdtempSync(path.join(tmpdir(), "conv-mtcg-snap-"));
  const conv = path.join(ws, ".conversation-esaa");
  mkdirSync(conv, { recursive: true });
  return { ws, conv, activityPath: path.join(conv, "activity.jsonl") };
}

test("snapshot creates deterministic digest, watermark, and isolates workspace without touching ledger", () => {
  const { ws, activityPath } = makeTempWorkspace();
  const otherWs = "/tmp/other-workspace-never-include";
  try {
    const events = [
      {
        event_id: "evt-001",
        ts: "2026-11-07T10:00:00-03:00",
        event: "conversation_turn",
        actor: "user",
        agent_id: null,
        source: "codex",
        source_session_id: "s1",
        source_index: 0,
        workspace_root: ws,
        summary: "Precisamos escolher o banco de dados",
        text: "Precisamos escolher o banco de dados. Chave TEST-SECRET-DO-NOT-EXPOSE",
      },
      {
        event_id: "evt-002",
        ts: "2026-11-07T10:01:00-03:00",
        event: "decision.recorded",
        actor: "assistant",
        agent_id: "codex",
        workspace_root: ws,
        decision: "Adotar PostgreSQL",
        rationale: "Integridade transacional",
        related_turns: ["evt-001"],
        summary: "Adotar PostgreSQL",
        text: "Adotar PostgreSQL",
      },
      {
        event_id: "evt-other-ws",
        ts: "2026-11-07T10:02:00-03:00",
        event: "conversation_turn",
        actor: "user",
        agent_id: null,
        source: "codex",
        source_session_id: "s2",
        source_index: 0,
        workspace_root: otherWs,
        summary: "Segredo de outro workspace",
        text: "Segredo de outro workspace",
      },
      {
        event_id: "evt-mem-ignore",
        ts: "2026-11-07T10:03:00-03:00",
        event: "memory.consolidation.accepted",
        actor: "assistant",
        agent_id: "codex",
        workspace_root: ws,
        summary: "Evento de governança de memória",
        text: "Evento de governança de memória",
      },
    ];
    writeFileSync(
      activityPath,
      events.map((e) => JSON.stringify(e)).join("\n") + "\n",
      "utf8",
    );

    const beforeHash = sha256Hex(readFileSync(activityPath, "utf8"));
    const snap1 = createWorkspaceSnapshot(ws);
    const snap2 = createWorkspaceSnapshot(ws);
    const afterHash = sha256Hex(readFileSync(activityPath, "utf8"));

    assert.equal(beforeHash, afterHash, "Ledger must remain byte-for-byte unchanged");
    assert.equal(
      snap1.factsBundle.source_snapshot_id,
      snap2.factsBundle.source_snapshot_id,
    );
    assert.equal(snap1.factsBundle.watermark_event_id, "evt-002");
    assert.equal(snap1.meta.excluded_external_workspace_count, 1);
    assert.equal(snap1.meta.excluded_memory_events_count, 1);

    const factIds = snap1.factsBundle.facts.map((f) => f.id);
    assert.ok(factIds.includes("evt-001"));
    assert.ok(factIds.includes("decision:evt-002"));
    assert.ok(!factIds.includes("evt-other-ws"));
    assert.ok(!factIds.includes("evt-mem-ignore"));

    const serialized = JSON.stringify(snap1.factsBundle);
    assert.ok(
      !serialized.includes("TEST-SECRET-DO-NOT-EXPOSE"),
      "Synthetic secret must be redacted in facts bundle",
    );
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
});

test("snapshot detects concurrent head mutation (STALE_PROPOSAL) and rejects symlinks", () => {
  const { ws, conv, activityPath } = makeTempWorkspace();
  try {
    const initialEvent = {
      event_id: "evt-100",
      ts: "2026-11-07T10:00:00-03:00",
      event: "conversation_turn",
      actor: "user",
      agent_id: null,
      workspace_root: ws,
      summary: "Turno 1\r\nCom quebra CRLF e acentuação café",
      text: "Turno 1\r\nCom quebra CRLF e acentuação café",
    };
    writeFileSync(activityPath, JSON.stringify(initialEvent) + "\n", "utf8");

    const snap = createWorkspaceSnapshot(ws);
    const fresh = verifySnapshotFreshness(
      ws,
      snap.factsBundle.source_snapshot_id,
      snap.factsBundle.watermark_event_id,
    );
    assert.equal(
      fresh.factsBundle.source_snapshot_id,
      snap.factsBundle.source_snapshot_id,
    );

    const concurrentEvent = {
      event_id: "evt-101",
      ts: "2026-11-07T10:05:00-03:00",
      event: "conversation_turn",
      actor: "assistant",
      agent_id: "codex",
      workspace_root: ws,
      summary: "Novo evento concorrente",
      text: "Novo evento concorrente",
    };
    writeFileSync(
      activityPath,
      [initialEvent, concurrentEvent].map((e) => JSON.stringify(e)).join("\n") +
        "\n",
      "utf8",
    );

    assert.throws(
      () =>
        verifySnapshotFreshness(
          ws,
          snap.factsBundle.source_snapshot_id,
          snap.factsBundle.watermark_event_id,
        ),
      (err) => err.code === "STALE_PROPOSAL",
    );

    const dirs = ensurePrivateMemoryDirs(ws);
    if (process.platform !== "win32") {
      const mode = lstatSync(dirs.memoryDir).mode & 0o777;
      assert.equal(mode, 0o700);
    }

    rmSync(dirs.memoryDir, { recursive: true, force: true });
    symlinkSync("/tmp", path.join(conv, "memory"));
    assert.throws(
      () => ensurePrivateMemoryDirs(ws),
      (err) => err.code === "UNSAFE_PATH",
    );
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
});
