// One fresh process per arm and seed, to isolate timing and peak RSS.
import { buildScaledScenario, runArmA, runArmB, runArmC, runArmD1NoRinging, runArmD2NoResonance } from "./benchmark.js";
const [topicsRaw, seedRaw, armName] = process.argv.slice(2);
const topics = Number(topicsRaw), seed = Number(seedRaw);
const s = buildScaledScenario(topics);
const budget = Math.floor(s.factsBundle.facts.length * 0.56);
const t0 = performance.now();
const arm = ({ A: () => runArmA(s.factsBundle), B: () => runArmB(s.factsBundle),
  C: () => runArmC(s.factsBundle, { seed, budget: "all" }),
  CP: () => runArmC(s.factsBundle, { seed, budget }),
  D1: () => runArmD1NoRinging(s.factsBundle, { budget }),
  D2: () => runArmD2NoResonance(s.factsBundle, { seed, budget: "all" }) })[armName]();
const ms = performance.now() - t0;
const result = { arm: armName, seed, facts_count: s.factsBundle.facts.length, elapsed_ms: ms,
  max_rss_kib: process.resourceUsage().maxRSS, facts: s.factsBundle.facts,
  active_ids: [...arm.active_ids], provenance: Object.fromEntries(arm.provenance_by_id),
  conflicts: arm.flagged_conflict_pairs,
  truth: { decisions: Object.fromEntries(s.groundTruth.active_decisions),
    superseded: [...s.groundTruth.superseded_decisions], echoes: [...s.groundTruth.obsolete_echo_ids],
    conflicts: s.groundTruth.unresolved_conflict_pairs } };
process.stdout.write(JSON.stringify(result) + "\n");
