// Exploratory scale probe: different arm output policies make this non-comparative.
import { writeFileSync } from "node:fs";
import { buildScaledScenario, runArmA, runArmB, runArmC, runArmD1NoRinging, runArmD2NoResonance, scoreArmResult, BENCHMARK_SEEDS } from "./benchmark.js";
import { sha256Prefixed } from "../../src/memory/core/canonical.js";

const report = { schema: "conv-rrr.scale-exploratory.v1", limitation: "Fixed input templates; item count is only a coarse output-budget proxy, not token parity.", runs: [] };
for (const topicCount of [5, 50, 200]) {
  const scenario = buildScaledScenario(topicCount);
  const desired = topicCount * 10;
  while (scenario.factsBundle.facts.length < desired) {
    const id = `padding-${scenario.factsBundle.facts.length}`;
    scenario.factsBundle.facts.push({ id, kind: "episode", topic_id: null,
      timestamp: "2026-11-27T00:00:00Z", time_bucket: "2026-11-27",
      summary: `Mensagem sintética de teste ${id}`, text: `Mensagem sintética de teste ${id}`,
      content_digest: sha256Prefixed(id), authority: "conversation_turn",
      epistemic_status: "verified_explicit", validity_status: "active",
      supersedes_id: null, conflict_key: null, conflict_value: null, evidence_event_ids: [id] });
  }
  scenario.factsBundle.source_snapshot_id = sha256Prefixed({ facts: scenario.factsBundle.facts, relations: scenario.factsBundle.relations });
  for (const seed of BENCHMARK_SEEDS) {
    const partial = Math.floor(desired * 0.56);
    const arms = [
      runArmA(scenario.factsBundle), runArmB(scenario.factsBundle),
      runArmC(scenario.factsBundle, { seed, budget: "all" }),
      runArmC(scenario.factsBundle, { seed, budget: partial }),
      runArmD1NoRinging(scenario.factsBundle, { budget: partial }),
      runArmD2NoResonance(scenario.factsBundle, { seed, budget: "all" }),
    ];
    for (const arm of arms) {
      const factsById = new Map(scenario.factsBundle.facts.map((f) => [f.id, f]));
      const ordered = [...arm.active_ids].sort((a, b) => {
        const fa = factsById.get(a), fb = factsById.get(b);
        const rank = (f) => f?.kind === "decision" ? 0 : 1;
        return rank(fa) - rank(fb) || String(fb?.timestamp || "").localeCompare(String(fa?.timestamp || "")) || a.localeCompare(b);
      });
      const limitedIds = new Set(ordered.slice(0, 13));
      const limited = { ...arm, active_ids: limitedIds,
        flagged_conflict_pairs: arm.flagged_conflict_pairs.slice(0, Math.max(0, 13 - limitedIds.size)) };
      report.runs.push({ facts: desired, seed, ...scoreArmResult(arm, scenario.groundTruth),
        exposed_ids: arm.active_ids.size, flagged_pairs: arm.flagged_conflict_pairs.length,
        output_budget_items: 13, budgeted: scoreArmResult(limited, scenario.groundTruth),
        process_max_rss_kib: process.resourceUsage().maxRSS });
    }
  }
}
if (!process.argv[2]) throw new Error("Pass an output path for the synthetic JSON report");
writeFileSync(process.argv[2], JSON.stringify(report, null, 2) + "\n");
