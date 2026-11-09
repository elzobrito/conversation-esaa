// Frozen synthetic cases, evaluated end-to-end through the real snapshot adapter.
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import { createWorkspaceSnapshot } from "../../src/memory/adapter/snapshot.js";
import { runRrrCycle } from "../../src/memory/core/renormalize.js";

const cases = [
  { topic: "TOP-001", expected: true, texts: ["O banco principal é PostgreSQL", "O banco principal é MySQL"] },
  { topic: "TOP-002", expected: false, texts: ["O banco principal é PostgreSQL", "O banco principal é postgres"] },
  { topic: "TOP-003", expected: true, texts: ["Os registros são conservados por 30 dias", "O prazo de retenção é de 60 dias"] },
  { topic: "TOP-004", expected: false, texts: ["O banco principal é MySQL", "O banco principal é MySQL"] },
  { topic: "TOP-005", expected: true, texts: ["A conexão usa TLS 1.2", "Exigir TLS 1.3 para todas as conexões"] },
  { topic: "TOP-006", expected: false, texts: ["O banco isolado está em manutenção", "O banco é um serviço interno"] },
];
const root = mkdtempSync(path.join(os.tmpdir(), "conv-adversarial-"));
try {
  const dir = path.join(root, ".conversation-esaa"); mkdirSync(dir);
  const events = [];
  for (const c of cases) {
    events.push({ event_id: `create-${c.topic}`, event: "topic.created", topic_id: c.topic, title: c.topic, actor: "assistant", agent_id: "synthetic", workspace_root: root, ts: "2026-11-01T00:00:00Z" });
    c.texts.forEach((text, i) => events.push({ event_id: `${c.topic}-${i}`, event: "conversation_turn", topic_id: c.topic, actor: "user", agent_id: null, workspace_root: root, ts: `2026-11-01T00:0${i}:00Z`, text, summary: text }));
  }
  writeFileSync(path.join(dir, "activity.jsonl"), events.map(JSON.stringify).join("\n") + "\n");
  const { factsBundle } = createWorkspaceSnapshot(root);
  const runs = [];
  for (const seed of [11, 29, 42, 73, 101]) {
    const { graph } = runRrrCycle(factsBundle, { seed, budget: "all" });
    const pairs = new Set((graph.boundaries || []).filter(x => x.kind === "unresolved_conflict").map(x => [...x.node_ids].sort().join("|")));
    const evaluated = cases.map(c => ({ topic: c.topic, expected: c.expected, detected: pairs.has([`${c.topic}-0`, `${c.topic}-1`].sort().join("|")) }));
    const tp = evaluated.filter(x => x.expected && x.detected).length;
    const fn = evaluated.filter(x => x.expected && !x.detected).length;
    const fp = evaluated.filter(x => !x.expected && x.detected).length;
    const tn = evaluated.filter(x => !x.expected && !x.detected).length;
    runs.push({ seed, tp, fp, fn, tn, evaluated });
  }
  if (!process.argv[2]) throw new Error("Pass report path");
  writeFileSync(process.argv[2], JSON.stringify({ schema: "conv-rrr.adversarial.v1", cases, runs }, null, 2) + "\n");
} finally { rmSync(root, { recursive: true, force: true }); }
