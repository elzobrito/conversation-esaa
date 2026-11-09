import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import { buildScaledScenario, runArmA, runArmB, runArmC, runArmD1NoRinging, runArmD2NoResonance } from "./benchmark.js";
import { runAuthorityBaseline } from "./authority-baseline.js";
import { runRrrCycle, runRenormalization } from "../../src/memory/core/renormalize.js";
import { buildMemoryGraph } from "../../src/memory/core/graph.js";
import { runResonance } from "../../src/memory/core/resonance.js";
import { buildActiveViewFromProposal, cmdContext } from "../../src/memory/adapter/cli.js";

const [topicsRaw, seedRaw, name] = process.argv.slice(2);
const topics = Number(topicsRaw), seed = Number(seedRaw), s = buildScaledScenario(topics);
const budget = Math.floor(s.factsBundle.facts.length * 0.56);
const before = performance.now();
let nativeOrder = [];
let arm;
if (["C", "CP", "CN"].includes(name)) {
  const { graph, proposal } = runRrrCycle(s.factsBundle, { seed, budget: name === "CP" ? budget : "all", mode: "shadow" });
  const activeIds = new Set(), provenance = new Map();
  for (const act of proposal.actions) if (act.action === "retain") { activeIds.add(act.memory_id); provenance.set(act.memory_id, act.evidence_event_ids); }
  const pairs = proposal.unresolved.map(b => [...b.memory_ids].sort());
  arm = { active_ids: activeIds, provenance_by_id: provenance, flagged_conflict_pairs: pairs };
  if (name === "CN") {
  const temp = mkdtempSync(path.join(os.tmpdir(), "rrr-native-"));
  try {
    const dir = path.join(temp, ".conversation-esaa", "memory"); mkdirSync(dir, { recursive: true });
    const view = buildActiveViewFromProposal(proposal, graph);
    writeFileSync(path.join(dir, "active.json"), JSON.stringify(view));
    const ctx = cmdContext(temp, { budgetChars: 100000000 });
    if (ctx.status !== "OK" || ctx.omitted_memory_ids.length) throw new Error("native ordering could not be fully recovered");
    const conflictsById = new Map((ctx.unresolved_conflicts || []).map(c => [c.conflict_id, c.memory_ids]));
    nativeOrder = ctx.included_memory_ids.map(id => conflictsById.has(id) ? { type: "conflict", ids: conflictsById.get(id) } : { type: "id", id });
  } finally { rmSync(temp, { recursive: true, force: true }); }
  }
} else if (name === "BP") {
  arm = runAuthorityBaseline(s.factsBundle);
} else if (name === "D1") {
  const facts = [...s.factsBundle.facts].sort((a,b) => String(a.timestamp || "").localeCompare(String(b.timestamp || ""))).slice(0, budget);
  const ids = new Set(facts.map(f => f.id));
  const bundle = { ...s.factsBundle, facts, relations: s.factsBundle.relations.filter(r => ids.has(r.source) && ids.has(r.target)) };
  const graph = runResonance(buildMemoryGraph(bundle, { seed: 42 }), bundle);
  const proposal = runRenormalization(graph, { workspace_id: bundle.workspace_id, watermark_event_id: bundle.watermark_event_id });
  const activeIds = new Set(), provenance = new Map();
  for (const act of proposal.actions) if (act.action === "retain") { activeIds.add(act.memory_id); provenance.set(act.memory_id, act.evidence_event_ids); }
  arm = { active_ids: activeIds, provenance_by_id: provenance, flagged_conflict_pairs: proposal.unresolved.map(b => [...b.memory_ids].sort()) };
} else {
  arm = ({ A: () => runArmA(s.factsBundle), B: () => runArmB(s.factsBundle),
    C: () => runArmC(s.factsBundle, { seed, budget: "all" }),
    CP: () => runArmC(s.factsBundle, { seed, budget }),
    D1: () => runArmD1NoRinging(s.factsBundle, { budget }),
    D2: () => runArmD2NoResonance(s.factsBundle, { seed, budget: "all" }) })[name]();
}
process.stdout.write(JSON.stringify({ arm: name, seed, facts: s.factsBundle.facts,
  analysis_ms: performance.now() - before, max_rss_kib: process.resourceUsage().maxRSS,
  active_ids: [...arm.active_ids], provenance: Object.fromEntries(arm.provenance_by_id),
  conflicts: arm.flagged_conflict_pairs, native_order: nativeOrder,
  truth: { decisions: Object.fromEntries(s.groundTruth.active_decisions),
    superseded: [...s.groundTruth.superseded_decisions], echoes: [...s.groundTruth.obsolete_echo_ids],
    conflicts: s.groundTruth.unresolved_conflict_pairs } }) + "\n");
