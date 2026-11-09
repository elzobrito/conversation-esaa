import assert from "node:assert/strict";
import test from "node:test";
import {
  NORMALIZER_VERSION,
  normalizeTextForDigest,
  sha256Prefixed,
} from "../../src/memory/core/canonical.js";
import { buildMemoryGraph } from "../../src/memory/core/graph.js";
import { runRinging } from "../../src/memory/core/ringing.js";
import { runResonance } from "../../src/memory/core/resonance.js";
import {
  runRenormalization,
  runRrrCycle,
} from "../../src/memory/core/renormalize.js";

export const BENCHMARK_SEEDS = [11, 29, 42, 73, 101];

function makeFact({
  id,
  kind,
  topic_id,
  time_bucket,
  timestamp,
  summary,
  text,
  authority = "conversation_turn",
  epistemic_status = "verified_explicit",
  validity_status = "active",
  supersedes_id = null,
  conflict_key = null,
  conflict_value = null,
  evidence_event_ids = null,
}) {
  const bodyText = text || summary;
  return {
    id,
    kind,
    topic_id,
    time_bucket,
    timestamp,
    summary,
    text: bodyText,
    content_digest: sha256Prefixed(normalizeTextForDigest(bodyText)),
    authority,
    epistemic_status,
    validity_status,
    supersedes_id,
    conflict_key,
    conflict_value,
    evidence_event_ids: evidence_event_ids || [id],
  };
}

export function buildCanonicalScenario() {
  const workspaceId = sha256Prefixed("workspace:benchmark-canonical-v1");
  const facts = [
    makeFact({
      id: "TOP-001",
      kind: "topic",
      topic_id: "TOP-001",
      time_bucket: "2026-11-01",
      timestamp: "2026-11-01T10:00:00Z",
      summary: "TOP-001: Arquitetura de Persistência",
      authority: "curated_topic",
      evidence_event_ids: ["E001"],
    }),
    makeFact({
      id: "decision:E002",
      kind: "decision",
      topic_id: "TOP-001",
      time_bucket: "2026-11-01",
      timestamp: "2026-11-01T10:05:00Z",
      summary: "Adotar SQLite no MVP inicial",
      authority: "explicit_decision",
      conflict_key: "primary_database",
      conflict_value: "sqlite",
      evidence_event_ids: ["E002"],
    }),
    makeFact({
      id: "E003",
      kind: "episode",
      topic_id: "TOP-001",
      time_bucket: "2026-11-01",
      timestamp: "2026-11-01T10:10:00Z",
      summary: "Configurar pool de conexões igual a 10",
      evidence_event_ids: ["E003"],
    }),
    makeFact({
      id: "E004",
      kind: "episode",
      topic_id: "TOP-001",
      time_bucket: "2026-11-01",
      timestamp: "2026-11-01T10:11:00Z",
      summary: "Configurar pool de conexões igual a 10",
      evidence_event_ids: ["E004"],
    }),
    makeFact({
      id: "E005",
      kind: "episode",
      topic_id: "TOP-001",
      time_bucket: "2026-11-02",
      timestamp: "2026-11-02T09:00:00Z",
      summary: "Benchmark de escrita concorrente apontou contenção em arquivo único",
      evidence_event_ids: ["E005"],
    }),
    makeFact({
      id: "decision:E006",
      kind: "decision",
      topic_id: "TOP-001",
      time_bucket: "2026-11-02",
      timestamp: "2026-11-02T09:30:00Z",
      summary: "Adotar PostgreSQL 16 como banco oficial de produção",
      authority: "explicit_decision",
      supersedes_id: "decision:E002",
      conflict_key: "primary_database",
      conflict_value: "postgresql",
      evidence_event_ids: ["E006", "E005"],
    }),
    makeFact({
      id: "E007",
      kind: "episode",
      topic_id: "TOP-001",
      time_bucket: "2026-11-03",
      timestamp: "2026-11-03T11:00:00Z",
      summary: "Eco de agente: conforme resumo anterior, o banco é SQLite no MVP",
      conflict_key: "primary_database",
      conflict_value: "sqlite",
      evidence_event_ids: ["E007"],
    }),
    makeFact({
      id: "E008",
      kind: "episode",
      topic_id: "TOP-002",
      time_bucket: "2026-11-03",
      timestamp: "2026-11-03T14:00:00Z",
      summary: "O cache distribuído oficial é Redis 7",
      conflict_key: "cache_engine",
      conflict_value: "redis",
      evidence_event_ids: ["E008"],
    }),
    makeFact({
      id: "E009",
      kind: "episode",
      topic_id: "TOP-002",
      time_bucket: "2026-11-03",
      timestamp: "2026-11-03T14:05:00Z",
      summary: "O cache distribuído oficial é Memcached",
      conflict_key: "cache_engine",
      conflict_value: "memcached",
      evidence_event_ids: ["E009"],
    }),
    makeFact({
      id: "TOP-003",
      kind: "topic",
      topic_id: "TOP-003",
      time_bucket: "2026-11-04",
      timestamp: "2026-11-04T08:00:00Z",
      summary: "TOP-003: Segurança de Transporte",
      authority: "curated_topic",
      evidence_event_ids: ["E010"],
    }),
    makeFact({
      id: "decision:E011",
      kind: "decision",
      topic_id: "TOP-003",
      time_bucket: "2026-11-04",
      timestamp: "2026-11-04T08:15:00Z",
      summary: "Exigir TLS 1.3 estrito em todos os serviços internos",
      authority: "explicit_decision",
      conflict_key: "tls_version",
      conflict_value: "tls1.3",
      evidence_event_ids: ["E011"],
    }),
  ];

  const relations = [
    {
      source: "decision:E006",
      relation: "decision_supported_by_event",
      target: "E005",
      rule_id: "explicit_decision_related_turn",
      rule_version: "1.0.0",
      evidence_event_ids: ["E006", "E005"],
    },
  ];

  const factsBundle = {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: workspaceId,
    source_snapshot_id: sha256Prefixed({ workspaceId, facts, relations }),
    watermark_event_id: "E011",
    normalizer_version: NORMALIZER_VERSION,
    facts,
    relations,
  };

  const groundTruth = {
    topic_by_id: new Map(facts.map((f) => [f.id, f.topic_id])),
    key_by_id: new Map(facts.map((f) => [f.id, f.conflict_key])),
    active_decisions: new Map([
      ["decision:E006", ["E005", "E006"]],
      ["decision:E011", ["E011"]],
    ]),
    superseded_decisions: new Set(["decision:E002"]),
    obsolete_echo_ids: new Set(["E007"]),
    unresolved_conflict_pairs: [["E008", "E009"]],
    duplicate_groups: new Map([["E003", ["E003", "E004"]]]),
  };

  return { name: "canonical-e001-e011", factsBundle, groundTruth };
}

export function buildScaledScenario(topicCount = 5) {
  const workspaceId = sha256Prefixed(`workspace:benchmark-scaled-${topicCount}-v1`);
  const facts = [];
  const relations = [];
  const activeDecisions = new Map();
  const supersededDecisions = new Set();
  const obsoleteEchoIds = new Set();
  const unresolvedConflictPairs = [];

  for (let t = 1; t <= topicCount; t++) {
    const topicId = `TOP-${String(t).padStart(3, "0")}`;
    const dayOld = `2026-11-${String(((t - 1) % 25) + 1).padStart(2, "0")}`;
    const dayNew = `2026-11-${String(((t - 1) % 25) + 2).padStart(2, "0")}`;
    const oldDecId = `decision:T${t}-OLD`;
    const supEpId = `T${t}-SUP-EP`;
    const newDecId = `decision:T${t}-NEW`;
    const echoId = `T${t}-ECHO`;
    const dupA = `T${t}-DUP-A`;
    const dupB = `T${t}-DUP-B`;

    facts.push(
      makeFact({
        id: oldDecId,
        kind: "decision",
        topic_id: topicId,
        time_bucket: dayOld,
        timestamp: `${dayOld}T10:00:00Z`,
        summary: `Decisão inicial obsoleta do tópico ${topicId} (v1)`,
        authority: "explicit_decision",
        conflict_key: `key_topic_${t}`,
        conflict_value: `v1_topic_${t}`,
        evidence_event_ids: [`EV-${t}-OLD`],
      }),
      makeFact({
        id: supEpId,
        kind: "episode",
        topic_id: topicId,
        time_bucket: dayNew,
        timestamp: `${dayNew}T09:00:00Z`,
        summary: `Evidência empírica para revisão do tópico ${topicId}`,
        evidence_event_ids: [`EV-${t}-SUP`],
      }),
      makeFact({
        id: newDecId,
        kind: "decision",
        topic_id: topicId,
        time_bucket: dayNew,
        timestamp: `${dayNew}T10:00:00Z`,
        summary: `Decisão definitiva vigente do tópico ${topicId} (v2)`,
        authority: "explicit_decision",
        supersedes_id: oldDecId,
        conflict_key: `key_topic_${t}`,
        conflict_value: `v2_topic_${t}`,
        evidence_event_ids: [`EV-${t}-NEW`, `EV-${t}-SUP`],
      }),
      makeFact({
        id: echoId,
        kind: "episode",
        topic_id: topicId,
        time_bucket: dayNew,
        timestamp: `${dayNew}T15:00:00Z`,
        summary: `Eco tardio de agente repetindo decisão antiga v1 do tópico ${topicId}`,
        conflict_key: `key_topic_${t}`,
        conflict_value: `v1_topic_${t}`,
        evidence_event_ids: [`EV-${t}-ECHO`],
      }),
      makeFact({
        id: dupA,
        kind: "episode",
        topic_id: topicId,
        time_bucket: dayOld,
        timestamp: `${dayOld}T11:00:00Z`,
        summary: `Nota operacional repetida no tópico ${topicId}`,
        evidence_event_ids: [`EV-${t}-DUPA`],
      }),
      makeFact({
        id: dupB,
        kind: "episode",
        topic_id: topicId,
        time_bucket: dayOld,
        timestamp: `${dayOld}T11:05:00Z`,
        summary: `Nota operacional repetida no tópico ${topicId}`,
        evidence_event_ids: [`EV-${t}-DUPB`],
      }),
    );

    relations.push({
      source: newDecId,
      relation: "decision_supported_by_event",
      target: supEpId,
      rule_id: "explicit_decision_related_turn",
      rule_version: "1.0.0",
      evidence_event_ids: [`EV-${t}-NEW`, `EV-${t}-SUP`],
    });

    activeDecisions.set(newDecId, [`EV-${t}-NEW`, `EV-${t}-SUP`]);
    supersededDecisions.add(oldDecId);
    obsoleteEchoIds.add(echoId);

    if (t % 5 !== 0) {
      const conf1 = `T${t}-CONF-1`;
      const conf2 = `T${t}-CONF-2`;
      facts.push(
        makeFact({
          id: conf1,
          kind: "episode",
          topic_id: topicId,
          time_bucket: dayNew,
          timestamp: `${dayNew}T16:00:00Z`,
          summary: `Parâmetro aberto ${t} configurado como modo Alpha`,
          conflict_key: `open_param_${t}`,
          conflict_value: "alpha",
          evidence_event_ids: [`EV-${t}-C1`],
        }),
        makeFact({
          id: conf2,
          kind: "episode",
          topic_id: topicId,
          time_bucket: dayNew,
          timestamp: `${dayNew}T16:05:00Z`,
          summary: `Parâmetro aberto ${t} configurado como modo Beta`,
          conflict_key: `open_param_${t}`,
          conflict_value: "beta",
          evidence_event_ids: [`EV-${t}-C2`],
        }),
      );
      unresolvedConflictPairs.push([conf1, conf2]);
    }

    for (let n = 1; n <= 2; n++) {
      facts.push(
        makeFact({
          id: `T${t}-NOISE-${n}`,
          kind: "episode",
          topic_id: topicId,
          time_bucket: dayOld,
          timestamp: `${dayOld}T12:0${n}:00Z`,
          summary: `Log conversacional rotineiro #${n} do tópico ${topicId}`,
          evidence_event_ids: [`EV-${t}-N${n}`],
        }),
      );
    }
  }

  const factsBundle = {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: workspaceId,
    source_snapshot_id: sha256Prefixed({ workspaceId, facts, relations }),
    watermark_event_id: `EV-${topicCount}-N2`,
    normalizer_version: NORMALIZER_VERSION,
    facts,
    relations,
  };

  return {
    name: `scaled-multi-topic-${topicCount}`,
    factsBundle,
    groundTruth: {
      topic_by_id: new Map(facts.map((f) => [f.id, f.topic_id])),
      key_by_id: new Map(facts.map((f) => [f.id, f.conflict_key])),
      active_decisions: activeDecisions,
      superseded_decisions: supersededDecisions,
      obsolete_echo_ids: obsoleteEchoIds,
      unresolved_conflict_pairs: unresolvedConflictPairs,
    },
  };
}

// Arm A: Baseline v1.3.1 (chronological last-5 decisions + last-8 turns, no supersession filter)
export function runArmA(factsBundle) {
  const t0 = performance.now();
  const sortedByTime = [...factsBundle.facts].sort((a, b) =>
    String(a.timestamp || "").localeCompare(String(b.timestamp || "")),
  );
  const lastDecisions = sortedByTime
    .filter((f) => f.kind === "decision")
    .slice(-5);
  const lastEpisodes = sortedByTime
    .filter((f) => f.kind === "episode")
    .slice(-8);

  const activeSet = new Set(lastDecisions.map((d) => d.id));
  for (const ep of lastEpisodes) {
    if (ep.conflict_key) activeSet.add(ep.id);
  }
  const provenanceByDecision = new Map(
    lastDecisions.map((d) => [d.id, d.evidence_event_ids || []]),
  );

  return {
    arm: "A (Baseline v1.3.1)",
    active_ids: activeSet,
    provenance_by_id: provenanceByDecision,
    flagged_conflict_pairs: [],
    duration_ms: performance.now() - t0,
  };
}

// Arm B: Instructionist local (ADD/UPDATE/DELETE/NOOP by conflict_key recency)
export function runArmB(factsBundle) {
  const t0 = performance.now();
  const sortedByTime = [...factsBundle.facts].sort((a, b) =>
    String(a.timestamp || "").localeCompare(String(b.timestamp || "")),
  );
  const slotByKey = new Map();
  const unkeyedDecisions = new Map();

  for (const fact of sortedByTime) {
    if (fact.conflict_key) {
      // Instructionist UPDATE overwrites previous entry on same key, even if latest is an agent echo or unresolved turn!
      slotByKey.set(fact.conflict_key, fact);
    } else if (fact.kind === "decision") {
      if (fact.supersedes_id) unkeyedDecisions.delete(fact.supersedes_id);
      unkeyedDecisions.set(fact.id, fact);
    }
  }

  const activeSet = new Set();
  const provenanceById = new Map();
  for (const item of [...slotByKey.values(), ...unkeyedDecisions.values()]) {
    activeSet.add(item.id);
    // Instructionist overwrite keeps only latest event ID
    provenanceById.set(item.id, [item.evidence_event_ids[0]]);
  }

  return {
    arm: "B (Instructionist ADD/UPDATE/DELETE)",
    active_ids: activeSet,
    provenance_by_id: provenanceById,
    flagged_conflict_pairs: [],
    duration_ms: performance.now() - t0,
  };
}

// Arm C: Selectionist Memory-TCG + RRR
export function runArmC(factsBundle, { seed = 42, budget = "all" } = {}) {
  const t0 = performance.now();
  const { graph, proposal } = runRrrCycle(factsBundle, {
    seed,
    budget,
    mode: "shadow",
  });

  const activeSet = new Set();
  const provenanceById = new Map();
  for (const act of proposal.actions) {
    if (act.action === "retain") {
      activeSet.add(act.memory_id);
      provenanceById.set(act.memory_id, act.evidence_event_ids);
    }
  }
  const flaggedPairs = (graph.boundaries || [])
    .filter((b) => b.kind === "unresolved_conflict")
    .map((b) => [...b.node_ids].sort());

  return {
    arm: `C (Memory-TCG RRR budget=${budget})`,
    active_ids: activeSet,
    provenance_by_id: provenanceById,
    flagged_conflict_pairs: flaggedPairs,
    duration_ms: performance.now() - t0,
  };
}

// Arm D1: Ablation without stratified Ringing (naive FIFO truncation)
export function runArmD1NoRinging(factsBundle, { budget = 28 } = {}) {
  const t0 = performance.now();
  const sortedByTime = [...factsBundle.facts].sort((a, b) =>
    String(a.timestamp || "").localeCompare(String(b.timestamp || "")),
  );
  const fifoFacts = sortedByTime.slice(0, budget);
  const fifoIds = new Set(fifoFacts.map((f) => f.id));
  const subBundle = {
    ...factsBundle,
    facts: fifoFacts,
    relations: factsBundle.relations.filter(
      (r) => fifoIds.has(r.source) && fifoIds.has(r.target),
    ),
  };
  const g0 = buildMemoryGraph(subBundle, { seed: 42 });
  const gRes = runResonance(g0, subBundle);
  const prop = runRenormalization(gRes, {
    workspace_id: subBundle.workspace_id,
    watermark_event_id: subBundle.watermark_event_id,
  });

  const activeSet = new Set();
  const provenanceById = new Map();
  for (const act of prop.actions) {
    if (act.action === "retain") {
      activeSet.add(act.memory_id);
      provenanceById.set(act.memory_id, act.evidence_event_ids);
    }
  }
  const flaggedPairs = (gRes.boundaries || [])
    .filter((b) => b.kind === "unresolved_conflict")
    .map((b) => [...b.node_ids].sort());

  return {
    arm: "D1 (Ablation: FIFO without Ringing)",
    active_ids: activeSet,
    provenance_by_id: provenanceById,
    flagged_conflict_pairs: flaggedPairs,
    duration_ms: performance.now() - t0,
  };
}

// Arm D2: Ablation without Resonance (skips runResonance)
export function runArmD2NoResonance(factsBundle, { seed = 42, budget = "all" } = {}) {
  const t0 = performance.now();
  const g0 = buildMemoryGraph(factsBundle, { seed });
  const ring = runRinging(g0, { seed, budget });
  const prop = runRenormalization(ring.graph, {
    workspace_id: factsBundle.workspace_id,
    watermark_event_id: factsBundle.watermark_event_id,
    sampling: ring.sampling,
  });

  const activeSet = new Set();
  const provenanceById = new Map();
  for (const act of prop.actions) {
    if (act.action === "retain") {
      activeSet.add(act.memory_id);
      provenanceById.set(act.memory_id, act.evidence_event_ids);
    }
  }
  const flaggedPairs = (prop.unresolved || []).map((u) =>
    [...u.memory_ids].sort(),
  );

  return {
    arm: "D2 (Ablation: without Resonance)",
    active_ids: activeSet,
    provenance_by_id: provenanceById,
    flagged_conflict_pairs: flaggedPairs,
    duration_ms: performance.now() - t0,
  };
}

export function scoreArmResult(result, groundTruth) {
  const expectedActiveIds = [...groundTruth.active_decisions.keys()];
  let correctActive = 0;
  for (const id of expectedActiveIds) {
    const isPresent = result.active_ids.has(id);
    const topic = groundTruth.topic_by_id.get(id);
    if (!topic) throw new Error(`Missing ground-truth topic for ${id}`);
    const key = groundTruth.key_by_id.get(id);
    if (!key) throw new Error(`Missing ground-truth decision key for ${id}`);
    const sameDecision = (otherId) => groundTruth.topic_by_id.get(otherId) === topic &&
      key != null && groundTruth.key_by_id.get(otherId) === key;
    // If an obsolete superseded decision or echo for the same topic is also in active_ids, penalize CDA!
    let displacedOrAmbiguous = false;
    for (const supId of groundTruth.superseded_decisions) {
      if (result.active_ids.has(supId) && sameDecision(supId)) displacedOrAmbiguous = true;
    }
    for (const echoId of groundTruth.obsolete_echo_ids) {
      if (result.active_ids.has(echoId) && sameDecision(echoId)) displacedOrAmbiguous = true;
    }
    if (isPresent && !displacedOrAmbiguous) {
      correctActive++;
    }
  }
  const rawActiveRecall =
    expectedActiveIds.filter((id) => result.active_ids.has(id)).length /
    Math.max(1, expectedActiveIds.length);
  const cda = correctActive / Math.max(1, expectedActiveIds.length);

  // HCC: Historical Context Contamination
  const contaminants = [
    ...groundTruth.superseded_decisions,
    ...groundTruth.obsolete_echo_ids,
  ];
  let presentContaminants = 0;
  for (const cid of contaminants) {
    if (result.active_ids.has(cid)) presentContaminants++;
  }
  const hcc = presentContaminants / Math.max(1, contaminants.length);

  // Provenance Precision & Recall on active decisions
  let provPrecisionSum = 0;
  let provRecallSum = 0;
  for (const [decId, expectedEv] of groundTruth.active_decisions.entries()) {
    const actualEv = result.provenance_by_id.get(decId) || [];
    const expectedSet = new Set(expectedEv);
    const actualSet = new Set(actualEv);
    let hits = 0;
    for (const e of actualSet) {
      if (expectedSet.has(e)) hits++;
    }
    const prec = actualSet.size > 0 ? hits / actualSet.size : 0;
    const rec = expectedSet.size > 0 ? hits / expectedSet.size : 0;
    provPrecisionSum += prec;
    provRecallSum += rec;
  }
  const provenancePrecision =
    provPrecisionSum / Math.max(1, expectedActiveIds.length);
  const provenanceRecall =
    provRecallSum / Math.max(1, expectedActiveIds.length);

  // Conflict Calibration F1
  const expectedPairs = new Set(
    groundTruth.unresolved_conflict_pairs.map((p) => [...p].sort().join("|")),
  );
  const actualPairs = new Set(
    (result.flagged_conflict_pairs || []).map((p) => [...p].sort().join("|")),
  );
  let conflictHits = 0;
  for (const p of actualPairs) {
    if (expectedPairs.has(p)) conflictHits++;
  }
  const confPrec = actualPairs.size > 0 ? conflictHits / actualPairs.size : 0;
  const confRec =
    expectedPairs.size > 0 ? conflictHits / expectedPairs.size : 1;
  const conflictF1 =
    confPrec + confRec > 0 ? (2 * confPrec * confRec) / (confPrec + confRec) : 0;

  return {
    arm: result.arm,
    cda: Number(cda.toFixed(4)),
    raw_active_recall: Number(rawActiveRecall.toFixed(4)),
    hcc: Number(hcc.toFixed(4)),
    provenance_precision: Number(provenancePrecision.toFixed(4)),
    provenance_recall: Number(provenanceRecall.toFixed(4)),
    conflict_f1: Number(conflictF1.toFixed(4)),
    duration_ms: Number(result.duration_ms.toFixed(3)),
  };
}

export function runFullBenchmarkSuite() {
  const canonical = buildCanonicalScenario();
  const scaled = buildScaledScenario();

  const canonicalScores = [
    scoreArmResult(runArmA(canonical.factsBundle), canonical.groundTruth),
    scoreArmResult(runArmB(canonical.factsBundle), canonical.groundTruth),
    scoreArmResult(
      runArmC(canonical.factsBundle, { seed: 42, budget: "all" }),
      canonical.groundTruth,
    ),
    scoreArmResult(
      runArmD2NoResonance(canonical.factsBundle, { seed: 42, budget: "all" }),
      canonical.groundTruth,
    ),
  ];

  const scaledArms = [
    scoreArmResult(runArmA(scaled.factsBundle), scaled.groundTruth),
    scoreArmResult(runArmB(scaled.factsBundle), scaled.groundTruth),
    scoreArmResult(
      runArmC(scaled.factsBundle, { seed: 42, budget: "all" }),
      scaled.groundTruth,
    ),
    scoreArmResult(
      runArmD1NoRinging(scaled.factsBundle, { budget: 28 }),
      scaled.groundTruth,
    ),
    scoreArmResult(
      runArmD2NoResonance(scaled.factsBundle, { seed: 42, budget: 28 }),
      scaled.groundTruth,
    ),
  ];

  const multiSeedArmC = BENCHMARK_SEEDS.map((seed) => ({
    seed,
    ...scoreArmResult(
      runArmC(scaled.factsBundle, { seed, budget: 28 }),
      scaled.groundTruth,
    ),
  }));

  return {
    canonical: canonicalScores,
    scaled: scaledArms,
    multi_seed_arm_c_budget_28: multiSeedArmC,
  };
}

test("comparative benchmark evaluates Arms A, B, C, D across 5 seeds with reproducible metrics", () => {
  const report = runFullBenchmarkSuite();

  const armA = report.canonical.find((r) => r.arm.startsWith("A"));
  const armB = report.canonical.find((r) => r.arm.startsWith("B"));
  const armC = report.canonical.find((r) => r.arm.startsWith("C"));
  const armD2 = report.canonical.find((r) => r.arm.startsWith("D2"));

  // Arm C achieves 100% CDA, 0% HCC, 100% Provenance Precision/Recall, and 100% Conflict F1
  assert.equal(armC.cda, 1.0);
  assert.equal(armC.hcc, 0.0);
  assert.equal(armC.provenance_precision, 1.0);
  assert.equal(armC.provenance_recall, 1.0);
  assert.equal(armC.conflict_f1, 1.0);

  // Arm A suffers from Historical Context Contamination (includes superseded E002 and echo E007)
  assert.ok(armA.hcc > 0);
  assert.equal(armA.conflict_f1, 0);

  // Arm B suffers from agent echo overwriting authoritative decision (E007 overwrites E006) and loses multi-event provenance
  assert.ok(armB.hcc > 0);
  assert.ok(armB.provenance_recall < 1.0);
  assert.equal(armB.conflict_f1, 0);

  // Arm D2 (without Resonance) fails to detect unresolved conflict pairs E008/E009
  assert.equal(armD2.conflict_f1, 0);

  // Across all 5 seeds on the scaled 50-event dataset (budget=28), Arm C preserves 100% CDA and 0% HCC
  for (const run of report.multi_seed_arm_c_budget_28) {
    assert.equal(run.cda, 1.0, `seed=${run.seed} CDA`);
    assert.equal(run.hcc, 0.0, `seed=${run.seed} HCC`);
    assert.equal(run.provenance_recall, 1.0, `seed=${run.seed} provenance recall`);
  }
});

test("CDA penalizes a historical item only for the matching topic", () => {
  const truth = {
    active_decisions: new Map([["a", ["a"]], ["b", ["b"]]]),
    superseded_decisions: new Set(["old-a"]), obsolete_echo_ids: new Set(),
    unresolved_conflict_pairs: [],
    topic_by_id: new Map([["a", "A"], ["old-a", "A"], ["b", "B"]]),
    key_by_id: new Map([["a", "k"], ["old-a", "k"], ["b", "k"]]),
  };
  const result = { arm: "test", active_ids: new Set(["a", "b", "old-a"]),
    provenance_by_id: new Map([["a", ["a"]], ["b", ["b"]]]),
    flagged_conflict_pairs: [], duration_ms: 0 };
  assert.equal(scoreArmResult(result, truth).cda, 0.5);
});

if (process.argv.includes("--report")) {
  console.log(JSON.stringify(runFullBenchmarkSuite(), null, 2));
}
