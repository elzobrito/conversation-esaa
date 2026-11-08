import {
  ALLOWED_DERIVED_RELATIONS,
  ALLOWED_POSSIBLE_RELATIONS,
  MemoryTcgError,
  redactSensitiveText,
  sha256Prefixed,
  validateFactsBundle,
} from "./canonical.js";

export const DEFAULT_GRAPH_POLICY = Object.freeze({
  policy_id: "memory-tcg.graph-policy.v1",
  policy_version: "1.0.0",
  max_nodes: 25000,
  max_edges: 100000,
  detect_exact_duplicates: true,
});

export function buildMemoryGraph(factsBundle, policyOverrides = {}) {
  validateFactsBundle(factsBundle);

  const policy = {
    ...DEFAULT_GRAPH_POLICY,
    ...policyOverrides,
  };
  const seed =
    Number.isInteger(policyOverrides.seed) && policyOverrides.seed >= 0
      ? policyOverrides.seed
      : 42;

  const policyDigest = sha256Prefixed({
    policy_id: policy.policy_id,
    policy_version: policy.policy_version,
    max_nodes: policy.max_nodes,
    max_edges: policy.max_edges,
    detect_exact_duplicates: Boolean(policy.detect_exact_duplicates),
  });

  if (factsBundle.facts.length > policy.max_nodes) {
    throw new MemoryTcgError(
      "LIMIT_EXCEEDED",
      `Facts count (${factsBundle.facts.length}) exceeds max_nodes (${policy.max_nodes})`,
      { count: factsBundle.facts.length, limit: policy.max_nodes },
    );
  }

  const factMap = new Map();
  const sortedFacts = [...factsBundle.facts].sort((a, b) =>
    a.id.localeCompare(b.id),
  );
  for (const fact of sortedFacts) {
    factMap.set(fact.id, fact);
  }

  const boundaries = [];
  const derivedEdgesMap = new Map();

  function addDerivedEdge({
    source,
    relation,
    target,
    rule_id,
    rule_version,
    evidence_event_ids,
  }) {
    if (!ALLOWED_DERIVED_RELATIONS.has(relation)) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Invalid derived relation: ${relation}`,
      );
    }
    if (!rule_id || !rule_version) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Derived edge ${source}->${target} missing rule_id or rule_version`,
      );
    }
    const cleanEvidence = [...new Set(evidence_event_ids)].sort();
    if (cleanEvidence.length === 0) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Derived edge ${source}->${target} missing evidence_event_ids`,
      );
    }
    const tripleKey = `${source}|${relation}|${target}`;
    const existing = derivedEdgesMap.get(tripleKey);
    if (existing) {
      const mergedEvidence = [
        ...new Set([...existing.evidence_event_ids, ...cleanEvidence]),
      ].sort();
      existing.evidence_event_ids = mergedEvidence;
      return;
    }
    const edgeId = `edge:${sha256Prefixed(tripleKey).slice(7, 23)}`;
    derivedEdgesMap.set(tripleKey, {
      id: edgeId,
      source,
      relation,
      target,
      rule_id,
      rule_version,
      evidence_event_ids: cleanEvidence,
    });
  }

  const supersededTargets = new Map();

  for (const rel of factsBundle.relations) {
    const hasSource = factMap.has(rel.source);
    const hasTarget = factMap.has(rel.target);
    if (!hasSource || !hasTarget) {
      const missingIds = [];
      if (!hasSource) missingIds.push(rel.source);
      if (!hasTarget) missingIds.push(rel.target);
      const boundaryKey = `missing_referenced_event|${rel.source}|${rel.relation}|${rel.target}`;
      boundaries.push({
        id: `bnd:${sha256Prefixed(boundaryKey).slice(7, 23)}`,
        kind: "missing_referenced_event",
        reason_code: "MISSING_REFERENCED_NODE",
        node_ids: [rel.source, rel.target].filter((id) => factMap.has(id)).length
          ? [rel.source, rel.target].filter((id) => factMap.has(id))
          : missingIds,
        evidence_event_ids: [...new Set(rel.evidence_event_ids)].sort(),
      });
      continue;
    }

    addDerivedEdge(rel);
    if (rel.relation === "explicit_supersedes") {
      supersededTargets.set(rel.target, rel.source);
    }
  }

  for (const fact of sortedFacts) {
    if (fact.supersedes_id) {
      if (factMap.has(fact.supersedes_id)) {
        addDerivedEdge({
          source: fact.id,
          relation: "explicit_supersedes",
          target: fact.supersedes_id,
          rule_id: "explicit_supersedes_field",
          rule_version: "1.0.0",
          evidence_event_ids: fact.evidence_event_ids,
        });
        supersededTargets.set(fact.supersedes_id, fact.id);
      } else {
        const boundaryKey = `unverified_supersession|${fact.id}|${fact.supersedes_id}`;
        boundaries.push({
          id: `bnd:${sha256Prefixed(boundaryKey).slice(7, 23)}`,
          kind: "unverified_supersession",
          reason_code: "SUPERSEDED_TARGET_NOT_FOUND",
          node_ids: [fact.id],
          evidence_event_ids: [...new Set(fact.evidence_event_ids)].sort(),
        });
      }
    }
  }

  if (policy.detect_exact_duplicates) {
    const byDigestAndKind = new Map();
    for (const fact of sortedFacts) {
      if (!fact.content_digest) continue;
      if (fact.kind !== "episode" && fact.kind !== "assertion") continue;
      const key = `${fact.kind}|${fact.content_digest}`;
      if (!byDigestAndKind.has(key)) byDigestAndKind.set(key, []);
      byDigestAndKind.get(key).push(fact);
    }

    for (const group of byDigestAndKind.values()) {
      if (group.length < 2) continue;
      const canonicalNode = group[0];
      for (let i = 1; i < group.length; i++) {
        const dupNode = group[i];
        addDerivedEdge({
          source: dupNode.id,
          relation: "duplicate_exact_content",
          target: canonicalNode.id,
          rule_id: "exact_content_digest_match",
          rule_version: "1.0.0",
          evidence_event_ids: [
            ...canonicalNode.evidence_event_ids,
            ...dupNode.evidence_event_ids,
          ],
        });
      }
    }
  }

  if (derivedEdgesMap.size > policy.max_edges) {
    throw new MemoryTcgError(
      "LIMIT_EXCEEDED",
      `Derived edges count (${derivedEdgesMap.size}) exceeds max_edges (${policy.max_edges})`,
      { count: derivedEdgesMap.size, limit: policy.max_edges },
    );
  }

  const nodes = sortedFacts.map((fact) => {
    const isSuperseded = supersededTargets.has(fact.id);
    const validity = isSuperseded ? "superseded" : fact.validity_status;
    const summary = fact.summary ? redactSensitiveText(fact.summary) : "";
    const contentDigest =
      fact.content_digest || sha256Prefixed(fact.text || fact.summary || fact.id);
    const uniqueEvidence = [...new Set(fact.evidence_event_ids)].sort();
    const node = {
      id: fact.id,
      kind: fact.kind,
      topic_id: fact.topic_id ?? null,
      time_bucket:
        fact.time_bucket ??
        (typeof fact.timestamp === "string" && fact.timestamp.length >= 10
          ? fact.timestamp.slice(0, 10)
          : "unknown"),
      timestamp: fact.timestamp ?? null,
      summary,
      content_digest: contentDigest,
      authority: fact.authority ?? "conversation_turn",
      epistemic_status: fact.epistemic_status,
      validity_status: validity,
      independent_support_count: 1,
      evidence_event_ids: uniqueEvidence,
    };
    return node;
  });

  const derivedEdges = [...derivedEdgesMap.values()].sort((a, b) =>
    `${a.source}|${a.relation}|${a.target}`.localeCompare(
      `${b.source}|${b.relation}|${b.target}`,
    ),
  );

  const sortedBoundaries = boundaries.sort((a, b) => a.id.localeCompare(b.id));
  const unresolvedNodeIds = new Set();
  for (const node of nodes) {
    if (node.epistemic_status === "unresolved") unresolvedNodeIds.add(node.id);
  }
  for (const bnd of sortedBoundaries) {
    for (const nid of bnd.node_ids) unresolvedNodeIds.add(nid);
  }

  const coverage = {
    eligible_nodes: nodes.length,
    sampled_nodes: nodes.length,
    unresolved_nodes: unresolvedNodeIds.size,
    sampled_node_ids: nodes.map((n) => n.id),
    omitted_node_ids: [],
    selection_policy_version: "graph.full.v1",
  };

  const generationPayload = {
    schema_version: "memory-tcg.graph.v1",
    source_snapshot_id: factsBundle.source_snapshot_id,
    policy_digest: policyDigest,
    seed,
    nodes,
    derived_edges: derivedEdges,
    possible_edges: [],
    boundaries: sortedBoundaries,
    coverage,
  };

  const generationId = sha256Prefixed(generationPayload);
  return {
    schema_version: "memory-tcg.graph.v1",
    generation_id: generationId,
    ...generationPayload,
  };
}

export function assertGraphInvariants(graph) {
  if (!graph || graph.schema_version !== "memory-tcg.graph.v1") {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Invalid graph schema_version",
    );
  }
  const nodeIds = new Set(graph.nodes.map((n) => n.id));
  const derivedTriples = new Set();

  for (const edge of graph.derived_edges) {
    if (!ALLOWED_DERIVED_RELATIONS.has(edge.relation)) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Derived edge ${edge.id} uses non-derived relation ${edge.relation}`,
      );
    }
    if (!edge.rule_id || !edge.rule_version) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Derived edge ${edge.id} lacks rule_id or rule_version`,
      );
    }
    if (!Array.isArray(edge.evidence_event_ids) || !edge.evidence_event_ids.length) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Derived edge ${edge.id} lacks evidence_event_ids`,
      );
    }
    if (!nodeIds.has(edge.source) || !nodeIds.has(edge.target)) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Derived edge ${edge.id} references unknown node(s)`,
      );
    }
    derivedTriples.add(`${edge.source}|${edge.relation}|${edge.target}`);
  }

  for (const pEdge of graph.possible_edges) {
    if (!ALLOWED_POSSIBLE_RELATIONS.has(pEdge.relation)) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Possible edge ${pEdge.id} uses invalid relation ${pEdge.relation}`,
      );
    }
    const triple = `${pEdge.source}|${pEdge.relation}|${pEdge.target}`;
    if (derivedTriples.has(triple)) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Possible edge shares triple with derived edge: ${triple}`,
      );
    }
    if (!nodeIds.has(pEdge.source) || !nodeIds.has(pEdge.target)) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Possible edge ${pEdge.id} references unknown node(s)`,
      );
    }
  }
  return true;
}
