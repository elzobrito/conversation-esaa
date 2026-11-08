import {
  MemoryTcgError,
  normalizeTextForDigest,
  sha256Prefixed,
} from "./canonical.js";
import { assertGraphInvariants } from "./graph.js";

export const RESONANCE_HEURISTIC_VERSION = "1.0.0";

function tokenizeToSet(text) {
  const norm = normalizeTextForDigest(text || "").toLowerCase();
  if (!norm) return new Set();
  const tokens = norm
    .split(/[^a-z0-9à-ú_]+/i)
    .filter((tok) => tok.length >= 3);
  return new Set(tokens);
}

function jaccardSimilaritySets(setA, setB) {
  if (!setA.size || !setB.size) return 0;
  const [smaller, larger] = setA.size <= setB.size ? [setA, setB] : [setB, setA];
  let inter = 0;
  for (const t of smaller) {
    if (larger.has(t)) inter++;
  }
  if (inter === 0) return 0;
  const union = setA.size + setB.size - inter;
  return union === 0 ? 0 : Number((inter / union).toFixed(4));
}

function inferChoiceSubjectAndValue(summaryOrText) {
  const text = normalizeTextForDigest(summaryOrText || "");
  const dbChoice = text.match(
    /\b(?:(?:adotar|escolher|adopted|choose)\s+(?:o\s+|a\s+)?(?:banco\s+)?|banco(?:\s+de\s+dados)?\s+(?:oficial|adotado|escolhido|definitivo|principal)(?:\s+(?:é|is)|(?:\s*(?:=|:)))\s*)(postgresql|postgres|sqlite|mysql|mongodb|mariadb|redis|memcached)\b/i,
  );
  if (dbChoice) {
    const raw = dbChoice[1].toLowerCase();
    const val = raw === "postgres" ? "postgresql" : raw;
    return { key: "database_engine", value: val };
  }
  return null;
}

export function runResonance(graph, factsBundle = null, options = {}) {
  if (!graph || graph.schema_version !== "memory-tcg.graph.v1") {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "runResonance requires a memory-tcg.graph.v1 object",
    );
  }

  const sampledSet = new Set(
    Array.isArray(graph.coverage?.sampled_node_ids) &&
      graph.coverage.sampled_node_ids.length > 0
      ? graph.coverage.sampled_node_ids
      : graph.nodes.map((n) => n.id),
  );

  const factLookup = new Map();
  if (factsBundle && Array.isArray(factsBundle.facts)) {
    for (const f of factsBundle.facts) {
      factLookup.set(f.id, f);
    }
  }

  const nodeMap = new Map();
  const updatedNodes = graph.nodes.map((n) => ({ ...n }));
  for (const n of updatedNodes) {
    nodeMap.set(n.id, n);
  }

  const derivedTripleSet = new Set(
    graph.derived_edges.map((e) => `${e.source}|${e.relation}|${e.target}`),
  );

  const supportByDecision = new Map();
  for (const edge of graph.derived_edges) {
    if (edge.relation === "decision_supported_by_event") {
      if (!supportByDecision.has(edge.source)) {
        supportByDecision.set(edge.source, []);
      }
      supportByDecision.get(edge.source).push(edge.target);
    }
  }

  for (const node of updatedNodes) {
    const supportingTargets = supportByDecision.get(node.id) || [];
    const distinctDigests = new Set();
    if (node.content_digest) distinctDigests.add(node.content_digest);
    for (const targetId of supportingTargets) {
      const targetNode = nodeMap.get(targetId);
      if (targetNode && targetNode.content_digest) {
        distinctDigests.add(targetNode.content_digest);
      }
    }
    node.independent_support_count = Math.max(1, distinctDigests.size);
  }

  const possibleEdgesMap = new Map();
  for (const p of graph.possible_edges || []) {
    possibleEdgesMap.set(`${p.source}|${p.relation}|${p.target}`, p);
  }

  const boundariesMap = new Map();
  for (const b of graph.boundaries || []) {
    boundariesMap.set(b.id, b);
  }

  function addPossibleEdge({
    source,
    relation,
    target,
    heuristic_id,
    score,
    reason_codes,
    evidence_event_ids,
  }) {
    const [s, t] =
      relation === "possibly_supersedes"
        ? [source, target]
        : [source, target].sort();
    const triple = `${s}|${relation}|${t}`;
    if (derivedTripleSet.has(triple)) {
      return;
    }
    if (possibleEdgesMap.has(triple)) {
      return;
    }
    possibleEdgesMap.set(triple, {
      id: `pedge:${sha256Prefixed(triple).slice(7, 23)}`,
      source: s,
      relation,
      target: t,
      heuristic_id,
      heuristic_version: RESONANCE_HEURISTIC_VERSION,
      score,
      reason_codes: [...new Set(reason_codes)].sort(),
      evidence_event_ids: [...new Set(evidence_event_ids)].sort(),
    });
  }

  function addBoundary({ kind, reason_code, node_ids, evidence_event_ids }) {
    const sortedIds = [...new Set(node_ids)].sort();
    const key = `${kind}|${reason_code}|${sortedIds.join(",")}`;
    const id = `bnd:${sha256Prefixed(key).slice(7, 23)}`;
    if (!boundariesMap.has(id)) {
      boundariesMap.set(id, {
        id,
        kind,
        reason_code,
        node_ids: sortedIds,
        evidence_event_ids: [...new Set(evidence_event_ids)].sort(),
      });
    }
  }

  const sampledEpisodesAndAssertions = updatedNodes.filter(
    (n) =>
      sampledSet.has(n.id) &&
      (n.kind === "episode" || n.kind === "assertion" || n.kind === "decision"),
  );

  const activeDecisionsByTopicAndKey = new Map();
  for (const node of updatedNodes) {
    if (node.kind === "decision" && node.validity_status === "active") {
      const f = factLookup.get(node.id);
      const choice =
        f?.conflict_key && f?.conflict_value
          ? { key: f.conflict_key, value: f.conflict_value }
          : inferChoiceSubjectAndValue(node.summary);
      if (choice) {
        const topicKey = `${node.topic_id || "_global_"}|${choice.key}`;
        if (!activeDecisionsByTopicAndKey.has(topicKey)) {
          activeDecisionsByTopicAndKey.set(topicKey, []);
        }
        activeDecisionsByTopicAndKey.get(topicKey).push({
          node,
          value: choice.value,
        });
      }
    }
  }

  // 1. Precompute choice and tokenSet once per sampled node O(N), deduplicating exact-duplicate episodes per (key, value, content_digest)
  const nodesByChoiceKey = new Map();
  const seenEpisodeDigestByChoiceKey = new Map();
  const tokenSetByNodeId = new Map();
  for (const node of sampledEpisodesAndAssertions) {
    const fact = factLookup.get(node.id);
    const choice =
      fact?.conflict_key && fact?.conflict_value
        ? { key: fact.conflict_key, value: fact.conflict_value }
        : inferChoiceSubjectAndValue(node.summary);
    if (choice) {
      if (!nodesByChoiceKey.has(choice.key)) {
        nodesByChoiceKey.set(choice.key, []);
        seenEpisodeDigestByChoiceKey.set(choice.key, new Set());
      }
      const dupDigestKey =
        node.kind === "episode" && node.content_digest
          ? `${choice.value}|${node.content_digest}`
          : null;
      const seenSet = seenEpisodeDigestByChoiceKey.get(choice.key);
      if (!dupDigestKey || !seenSet.has(dupDigestKey)) {
        if (dupDigestKey) seenSet.add(dupDigestKey);
        nodesByChoiceKey.get(choice.key).push({ node, choice });
      }
    }
    if (node.kind === "episode") {
      tokenSetByNodeId.set(node.id, tokenizeToSet(node.summary));
    }
  }

  // 2. Evaluate structured conflicts per choice.key group (exact match to pairwise semantics)
  for (const [choiceKey, entries] of nodesByChoiceKey.entries()) {
    for (let i = 0; i < entries.length; i++) {
      const { node: a, choice: choiceA } = entries[i];
      for (let j = i + 1; j < entries.length; j++) {
        const { node: b, choice: choiceB } = entries[j];
        if (choiceA.value === choiceB.value) continue;

        let sameTopicOrGlobal = false;
        if (a.topic_id && b.topic_id) {
          sameTopicOrGlobal = a.topic_id === b.topic_id;
        } else if (!a.topic_id && !b.topic_id) {
          if (
            a.kind === "decision" ||
            b.kind === "decision" ||
            (a.time_bucket &&
              a.time_bucket !== "unknown" &&
              a.time_bucket === b.time_bucket) ||
            (a.session_id && a.session_id === b.session_id)
          ) {
            sameTopicOrGlobal = true;
          } else {
            const setA = tokenSetByNodeId.get(a.id) || tokenizeToSet(a.summary);
            const setB = tokenSetByNodeId.get(b.id) || tokenizeToSet(b.summary);
            sameTopicOrGlobal = jaccardSimilaritySets(setA, setB) >= 0.15;
          }
        } else {
          sameTopicOrGlobal =
            a.kind === "decision" ||
            b.kind === "decision" ||
            (a.time_bucket &&
              a.time_bucket !== "unknown" &&
              a.time_bucket === b.time_bucket);
        }
        if (!sameTopicOrGlobal) continue;

        const evidence = [...a.evidence_event_ids, ...b.evidence_event_ids];
        const hasExplicitSupersession =
          derivedTripleSet.has(`${a.id}|explicit_supersedes|${b.id}`) ||
          derivedTripleSet.has(`${b.id}|explicit_supersedes|${a.id}`);

        if (!hasExplicitSupersession) {
          addPossibleEdge({
            source: a.id,
            relation: "possibly_contradicts",
            target: b.id,
            heuristic_id: "conflict_key_value_mismatch",
            score: 0.9,
            reason_codes: ["CONFLICTING_CLAIM_VALUES", "NO_EXPLICIT_SUPERSESSION"],
            evidence_event_ids: evidence,
          });

          const topicKey = `${a.topic_id || b.topic_id || "_global_"}|${choiceKey}`;
          const authoritative = activeDecisionsByTopicAndKey.get(topicKey) || [];

          if (
            a.kind === "decision" &&
            b.kind === "decision" &&
            a.validity_status === "active" &&
            b.validity_status === "active"
          ) {
            addPossibleEdge({
              source: b.id,
              relation: "possibly_supersedes",
              target: a.id,
              heuristic_id: "unverified_decision_succession",
              score: 0.5,
              reason_codes: ["RECENCY_IS_NOT_PROOF", "MISSING_EXPLICIT_SUPERSEDES"],
              evidence_event_ids: evidence,
            });
            addBoundary({
              kind: "unverified_supersession",
              reason_code: "COMPETING_ACTIVE_DECISIONS_WITHOUT_EXPLICIT_LINK",
              node_ids: [a.id, b.id],
              evidence_event_ids: evidence,
            });
          } else if (authoritative.length === 0) {
            a.epistemic_status = "unresolved";
            b.epistemic_status = "unresolved";
            a.validity_status = "unknown";
            b.validity_status = "unknown";
            addBoundary({
              kind: "unresolved_conflict",
              reason_code: "CONTRADICTORY_CLAIMS_WITHOUT_AUTHORITATIVE_DECISION",
              node_ids: [a.id, b.id],
              evidence_event_ids: evidence,
            });
          }
        }
      }
    }
  }

  // 3. Evaluate lexical resonance (possibly_duplicate / possibly_related) on episodes
  const sampledEpisodes = sampledEpisodesAndAssertions.filter(
    (n) => n.kind === "episode",
  );
  const dupThreshold = options.duplicateSimilarityThreshold ?? 0.75;
  const relThreshold = options.relatedSimilarityThreshold ?? 0.35;
  const maxLexicalWindow = options.maxLexicalWindow ?? 250;

  if (sampledEpisodes.length <= maxLexicalWindow) {
    for (let i = 0; i < sampledEpisodes.length; i++) {
      const a = sampledEpisodes[i];
      const setA = tokenSetByNodeId.get(a.id);
      if (!setA || !setA.size) continue;
      for (let j = i + 1; j < sampledEpisodes.length; j++) {
        const b = sampledEpisodes[j];
        if (a.content_digest === b.content_digest) continue;
        const setB = tokenSetByNodeId.get(b.id);
        if (!setB || !setB.size) continue;
        const sim = jaccardSimilaritySets(setA, setB);
        if (sim >= dupThreshold) {
          addPossibleEdge({
            source: a.id,
            relation: "possibly_duplicate",
            target: b.id,
            heuristic_id: "token_jaccard_similarity",
            score: sim,
            reason_codes: ["HIGH_LEXICAL_OVERLAP_NOT_EXACT"],
            evidence_event_ids: [...a.evidence_event_ids, ...b.evidence_event_ids],
          });
        } else if (a.topic_id && a.topic_id === b.topic_id && sim >= relThreshold) {
          addPossibleEdge({
            source: a.id,
            relation: "possibly_related",
            target: b.id,
            heuristic_id: "co_topic_lexical_resonance",
            score: sim,
            reason_codes: ["CO_TOPIC_SHARED_TERMS"],
            evidence_event_ids: [...a.evidence_event_ids, ...b.evidence_event_ids],
          });
        }
      }
    }
  } else {
    // Partition by (topic_id, time_bucket) and compare within sliding window for large stores (17k+ events)
    const buckets = new Map();
    for (const ep of sampledEpisodes) {
      const key = `${ep.topic_id || "_unscoped_"}::${ep.time_bucket || "unknown"}`;
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(ep);
    }
    const windowStride = 40;
    for (const group of buckets.values()) {
      for (let i = 0; i < group.length; i++) {
        const a = group[i];
        const setA = tokenSetByNodeId.get(a.id);
        if (!setA || !setA.size) continue;
        const limit = Math.min(group.length, i + 1 + windowStride);
        for (let j = i + 1; j < limit; j++) {
          const b = group[j];
          if (a.content_digest === b.content_digest) continue;
          const setB = tokenSetByNodeId.get(b.id);
          if (!setB || !setB.size) continue;
          const sim = jaccardSimilaritySets(setA, setB);
          if (sim >= dupThreshold) {
            addPossibleEdge({
              source: a.id,
              relation: "possibly_duplicate",
              target: b.id,
              heuristic_id: "token_jaccard_similarity",
              score: sim,
              reason_codes: ["HIGH_LEXICAL_OVERLAP_NOT_EXACT"],
              evidence_event_ids: [
                ...a.evidence_event_ids,
                ...b.evidence_event_ids,
              ],
            });
          } else if (
            a.topic_id &&
            a.topic_id === b.topic_id &&
            sim >= relThreshold
          ) {
            addPossibleEdge({
              source: a.id,
              relation: "possibly_related",
              target: b.id,
              heuristic_id: "co_topic_lexical_resonance",
              score: sim,
              reason_codes: ["CO_TOPIC_SHARED_TERMS"],
              evidence_event_ids: [
                ...a.evidence_event_ids,
                ...b.evidence_event_ids,
              ],
            });
          }
        }
      }
    }
  }

  const possibleEdges = [...possibleEdgesMap.values()].sort((a, b) =>
    `${a.source}|${a.relation}|${a.target}`.localeCompare(
      `${b.source}|${b.relation}|${b.target}`,
    ),
  );
  const boundaries = [...boundariesMap.values()].sort((a, b) =>
    a.id.localeCompare(b.id),
  );

  const unresolvedNodeIds = new Set();
  for (const n of updatedNodes) {
    if (n.epistemic_status === "unresolved") unresolvedNodeIds.add(n.id);
  }
  for (const bnd of boundaries) {
    if (
      bnd.kind === "unresolved_conflict" ||
      bnd.kind === "unverified_supersession"
    ) {
      for (const nid of bnd.node_ids) unresolvedNodeIds.add(nid);
    }
  }

  const coverage = {
    ...graph.coverage,
    unresolved_nodes: unresolvedNodeIds.size,
  };

  const nextPayload = {
    schema_version: "memory-tcg.graph.v1",
    source_snapshot_id: graph.source_snapshot_id,
    policy_digest: graph.policy_digest,
    seed: graph.seed,
    nodes: updatedNodes,
    derived_edges: graph.derived_edges,
    possible_edges: possibleEdges,
    boundaries,
    coverage,
  };

  const nextGraph = {
    schema_version: "memory-tcg.graph.v1",
    generation_id: sha256Prefixed(nextPayload),
    ...nextPayload,
  };

  assertGraphInvariants(nextGraph);
  return nextGraph;
}
