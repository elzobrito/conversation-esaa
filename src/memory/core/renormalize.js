import {
  ENGINE_VERSION,
  MemoryTcgError,
  NORMALIZER_VERSION,
  redactSensitiveText,
  sha256Prefixed,
} from "./canonical.js";
import { assertGraphInvariants, buildMemoryGraph } from "./graph.js";
import { runRinging } from "./ringing.js";
import { runResonance } from "./resonance.js";

export const RRR_POLICY_VERSION = "rrr-policy.v1";

export const ALLOWED_PROPOSAL_ACTIONS = new Set([
  "retain",
  "group_exact_duplicates",
  "deprioritize_in_active_view",
  "mark_historical_explicit",
  "flag_conflict",
]);

export function runRenormalization(graph, options = {}) {
  if (!graph || graph.schema_version !== "memory-tcg.graph.v1") {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "runRenormalization requires a memory-tcg.graph.v1 object",
    );
  }

  const workspaceId =
    options.workspace_id ||
    sha256Prefixed(`snapshot-workspace:${graph.source_snapshot_id}`);
  const watermarkEventId =
    options.watermark_event_id !== undefined ? options.watermark_event_id : null;
  const mode = options.mode === "manual" ? "manual" : "shadow";
  const samplingInfo = options.sampling || {
    seed: graph.seed ?? 42,
    strategy: "stratified-topics-time",
    budget: "all",
    sampled_ids:
      graph.coverage?.sampled_node_ids || graph.nodes.map((n) => n.id),
    omitted_ids: graph.coverage?.omitted_node_ids || [],
  };

  const sampledSet = new Set(samplingInfo.sampled_ids);
  const nodeMap = new Map(graph.nodes.map((n) => [n.id, n]));

  const explicitSupersedesMap = new Map();
  const supportedByDecisionEdges = new Set();
  const topicEventsByTopicNode = new Map();
  const duplicateClusters = new Map();
  const duplicateMemberToCanonical = new Map();

  for (const edge of graph.derived_edges) {
    if (edge.relation === "explicit_supersedes") {
      explicitSupersedesMap.set(edge.target, {
        superseding_id: edge.source,
        evidence_event_ids: edge.evidence_event_ids,
      });
    } else if (edge.relation === "decision_supported_by_event") {
      const srcNode = nodeMap.get(edge.source);
      if (srcNode && srcNode.validity_status === "active") {
        supportedByDecisionEdges.add(edge.target);
      }
    } else if (edge.relation === "topic_contains_event") {
      const srcNode = nodeMap.get(edge.source);
      if (srcNode && srcNode.validity_status === "active") {
        if (!topicEventsByTopicNode.has(edge.source)) {
          topicEventsByTopicNode.set(edge.source, []);
        }
        topicEventsByTopicNode.get(edge.source).push(edge.target);
      }
    } else if (edge.relation === "duplicate_exact_content") {
      const canonicalId = edge.target;
      const memberId = edge.source;
      duplicateMemberToCanonical.set(memberId, canonicalId);
      if (!duplicateClusters.has(canonicalId)) {
        duplicateClusters.set(canonicalId, new Set([canonicalId]));
      }
      duplicateClusters.get(canonicalId).add(memberId);
    }
  }

  // Select up to 5 most recent subject episodes linked to each active topic
  for (const node of graph.nodes) {
    if (node.kind === "episode" && node.topic_id) {
      const topicNode =
        nodeMap.get(node.topic_id) || nodeMap.get(`topic:${node.topic_id}`);
      if (topicNode && topicNode.kind === "topic" && topicNode.validity_status === "active") {
        if (!topicEventsByTopicNode.has(topicNode.id)) {
          topicEventsByTopicNode.set(topicNode.id, []);
        }
        topicEventsByTopicNode.get(topicNode.id).push(node.id);
      }
    }
  }
  const topicSubjectEpisodeIds = new Set();
  for (const targetIds of topicEventsByTopicNode.values()) {
    const uniqueTargetIds = [...new Set(targetIds)];
    const validNodes = uniqueTargetIds
      .map((id) => nodeMap.get(id))
      .filter(
        (n) =>
          n &&
          n.kind === "episode" &&
          n.authority !== "explicit_decision" &&
          !duplicateMemberToCanonical.has(n.id),
      )
      .sort((a, b) =>
        String(a.timestamp || "").localeCompare(String(b.timestamp || "")) ||
        a.id.localeCompare(b.id),
      );
    const chosen = validNodes.slice(-5);
    for (const n of chosen) {
      topicSubjectEpisodeIds.add(n.id);
    }
  }

  const conflictedNodeIds = new Set();
  const unresolvedList = [];
  const resonantCandidateScores = new Map();

  for (const bnd of graph.boundaries || []) {
    if (
      bnd.kind === "unresolved_conflict" ||
      bnd.kind === "unverified_supersession"
    ) {
      for (const nid of bnd.node_ids) conflictedNodeIds.add(nid);
      unresolvedList.push({
        conflict_id: bnd.id,
        reason_code: bnd.reason_code,
        memory_ids: [...bnd.node_ids].sort(),
        evidence_event_ids: [...new Set(bnd.evidence_event_ids)].sort(),
      });
    }
  }

  for (const pEdge of graph.possible_edges || []) {
    if (
      pEdge.relation === "possibly_contradicts" ||
      pEdge.relation === "possibly_supersedes"
    ) {
      conflictedNodeIds.add(pEdge.source);
      conflictedNodeIds.add(pEdge.target);
      const conflictId = `conf:${pEdge.id}`;
      const alreadyHas = unresolvedList.some(
        (u) =>
          u.memory_ids.includes(pEdge.source) &&
          u.memory_ids.includes(pEdge.target),
      );
      if (!alreadyHas) {
        unresolvedList.push({
          conflict_id: conflictId,
          reason_code: pEdge.reason_codes[0] || "POSSIBLE_CONFLICT",
          memory_ids: [pEdge.source, pEdge.target].sort(),
          evidence_event_ids: [...new Set(pEdge.evidence_event_ids)].sort(),
        });
      }
    } else if (pEdge.relation === "possibly_related" && graph.nodes.length > 50) {
      const prev = resonantCandidateScores.get(pEdge.source) || 0;
      if ((pEdge.score || 0) > prev) {
        resonantCandidateScores.set(pEdge.source, pEdge.score || 0);
      }
    }
  }

  // Retain top resonant subject episodes and recent time-bucket subject anchors on larger stores
  const resonantSubjectEpisodeIds = new Set();
  const subjectAnchorEpisodeIds = new Set();
  if (graph.nodes.length > 50) {
    const topResonant = [...resonantCandidateScores.entries()]
      .filter(
        ([id]) =>
          !duplicateMemberToCanonical.has(id) && !conflictedNodeIds.has(id),
      )
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 25);
    for (const [id] of topResonant) {
      resonantSubjectEpisodeIds.add(id);
    }

    const byTimeBucket = new Map();
    for (const node of graph.nodes) {
      if (
        node.kind === "episode" &&
        sampledSet.has(node.id) &&
        !duplicateMemberToCanonical.has(node.id) &&
        !conflictedNodeIds.has(node.id) &&
        (node.summary || "").trim().length >= 30
      ) {
        const tb = node.time_bucket || "unknown";
        if (!byTimeBucket.has(tb)) byTimeBucket.set(tb, []);
        byTimeBucket.get(tb).push(node);
      }
    }
    const recentBuckets = [...byTimeBucket.keys()]
      .filter((k) => k !== "unknown")
      .sort()
      .slice(-12);
    for (const tb of recentBuckets) {
      const candidates = byTimeBucket
        .get(tb)
        .sort(
          (a, b) =>
            String(a.timestamp || "").localeCompare(String(b.timestamp || "")) ||
            a.id.localeCompare(b.id),
        );
      for (const n of candidates.slice(-2)) {
        subjectAnchorEpisodeIds.add(n.id);
      }
    }
  }

  const actions = [];
  const sortedNodes = [...graph.nodes].sort((a, b) => a.id.localeCompare(b.id));
  const useSparseColdStorage = sortedNodes.length > 200;
  const implicitColdStorageIds = [];

  for (const node of sortedNodes) {
    if (!sampledSet.has(node.id) && node.kind !== "decision") {
      continue;
    }

    if (
      explicitSupersedesMap.has(node.id) ||
      node.validity_status === "superseded"
    ) {
      const supInfo = explicitSupersedesMap.get(node.id);
      const evidence = [
        ...new Set([
          ...node.evidence_event_ids,
          ...(supInfo ? supInfo.evidence_event_ids : []),
        ]),
      ].sort();
      actions.push({
        action: "mark_historical_explicit",
        memory_id: node.id,
        superseded_by_id: supInfo ? supInfo.superseding_id : null,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["EXPLICIT_SUPERSESSION"],
        evidence_event_ids: evidence,
      });
      continue;
    }

    if (node.kind === "decision" && node.validity_status === "active") {
      actions.push({
        action: "retain",
        memory_id: node.id,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["EXPLICIT_DECISION", "AUTHORITATIVE_ACTIVE_DECISION"],
        evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
      });
      continue;
    }

    if (duplicateClusters.has(node.id)) {
      const members = [...duplicateClusters.get(node.id)].sort();
      const mergedEvidence = new Set(node.evidence_event_ids);
      for (const mId of members) {
        const mNode = nodeMap.get(mId);
        if (mNode) {
          for (const ev of mNode.evidence_event_ids) mergedEvidence.add(ev);
        }
      }
      actions.push({
        action: "group_exact_duplicates",
        memory_id: node.id,
        target_memory_ids: members,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: [
          "EXACT_CONTENT_DIGEST_MATCH",
          "PRESERVE_ALL_SOURCE_EVENTS",
        ],
        evidence_event_ids: [...mergedEvidence].sort(),
      });
      continue;
    }

    if (duplicateMemberToCanonical.has(node.id)) {
      if (useSparseColdStorage) {
        implicitColdStorageIds.push(node.id);
        continue;
      }
      const canonicalId = duplicateMemberToCanonical.get(node.id);
      const canonicalNode = nodeMap.get(canonicalId);
      const evidence = [
        ...new Set([
          ...node.evidence_event_ids,
          ...(canonicalNode ? canonicalNode.evidence_event_ids : []),
        ]),
      ].sort();
      actions.push({
        action: "deprioritize_in_active_view",
        memory_id: node.id,
        target_memory_ids: [canonicalId],
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["EXACT_DUPLICATE_ECHO_DEPRIORITIZED"],
        evidence_event_ids: evidence,
      });
      continue;
    }

    if (
      node.epistemic_status === "unresolved" ||
      (conflictedNodeIds.has(node.id) && node.kind !== "decision")
    ) {
      actions.push({
        action: "flag_conflict",
        memory_id: node.id,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["UNRESOLVED_CONFLICT_NO_SILENT_WINNER"],
        evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
      });
      continue;
    }

    if (node.kind === "topic" || node.kind === "task") {
      if (node.validity_status === "active") {
        actions.push({
          action: "retain",
          memory_id: node.id,
          summary: redactSensitiveText(node.summary || node.id),
          reason_codes: [
            node.kind === "topic" ? "ACTIVE_TOPIC" : "ACTIVE_TASK",
          ],
          evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
        });
      } else if (!useSparseColdStorage) {
        actions.push({
          action: "deprioritize_in_active_view",
          memory_id: node.id,
          summary: redactSensitiveText(node.summary || node.id),
          reason_codes: ["COMPLETED_OR_HISTORICAL_ITEM"],
          evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
        });
      } else {
        implicitColdStorageIds.push(node.id);
      }
      continue;
    }

    if (supportedByDecisionEdges.has(node.id)) {
      actions.push({
        action: "retain",
        memory_id: node.id,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["DECISION_SUPPORT_EVIDENCE"],
        evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
      });
      continue;
    }

    if (topicSubjectEpisodeIds.has(node.id)) {
      actions.push({
        action: "retain",
        memory_id: node.id,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["TOPIC_SUBJECT_EVIDENCE", "CONSOLIDATED_SUBJECT_MATTER"],
        evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
      });
      continue;
    }

    if (resonantSubjectEpisodeIds.has(node.id)) {
      actions.push({
        action: "retain",
        memory_id: node.id,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: [
          "RESONANT_SUBJECT_EPISODE",
          "CONSOLIDATED_SUBJECT_MATTER",
        ],
        evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
      });
      continue;
    }

    if (subjectAnchorEpisodeIds.has(node.id)) {
      actions.push({
        action: "retain",
        memory_id: node.id,
        summary: redactSensitiveText(node.summary || node.id),
        reason_codes: ["SUBJECT_WINDOW_ANCHOR", "CONSOLIDATED_SUBJECT_MATTER"],
        evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
      });
      continue;
    }

    if (useSparseColdStorage) {
      implicitColdStorageIds.push(node.id);
      continue;
    }

    actions.push({
      action: "deprioritize_in_active_view",
      memory_id: node.id,
      summary: redactSensitiveText(node.summary || node.id),
      reason_codes: ["EPISODIC_DETAIL_DOWNSELECTED_TO_COLD_STORAGE"],
      evidence_event_ids: [...new Set(node.evidence_event_ids)].sort(),
    });
  }

  for (const act of actions) {
    if (!ALLOWED_PROPOSAL_ACTIONS.has(act.action)) {
      throw new MemoryTcgError(
        "POLICY_REJECTED",
        `Forbidden renormalization action: ${act.action}`,
      );
    }
    if (
      !Array.isArray(act.evidence_event_ids) ||
      act.evidence_event_ids.length === 0
    ) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Action for ${act.memory_id} missing evidence_event_ids`,
      );
    }
  }

  const explicitActionNodeIds = actions.map((a) => a.memory_id);
  const samplingPayload = useSparseColdStorage
    ? {
        seed: samplingInfo.seed,
        strategy: samplingInfo.strategy || "stratified-topics-time",
        budget: samplingInfo.budget ?? "all",
        sampled_count: samplingInfo.sampled_ids.length,
        omitted_count: (samplingInfo.omitted_ids || []).length,
        deprioritized_implicit_count: implicitColdStorageIds.length,
        deprioritized_implicit_digest: sha256Prefixed(implicitColdStorageIds),
        sampled_ids: explicitActionNodeIds,
        omitted_ids: (samplingInfo.omitted_ids || []).slice(0, 100),
      }
    : {
        seed: samplingInfo.seed,
        strategy: samplingInfo.strategy || "stratified-topics-time",
        budget: samplingInfo.budget ?? "all",
        sampled_ids: samplingInfo.sampled_ids,
        omitted_ids: samplingInfo.omitted_ids || [],
      };

  const sortedUnresolved = unresolvedList.sort((a, b) =>
    a.conflict_id.localeCompare(b.conflict_id),
  );

  const proposalBody = {
    schema_version: "conversation-esaa.memory.proposal.v1",
    workspace_id: workspaceId,
    snapshot_id: graph.source_snapshot_id,
    watermark_event_id: watermarkEventId,
    graph_generation_id: graph.generation_id,
    policy_version: RRR_POLICY_VERSION,
    mode,
    sampling: samplingPayload,
    actions,
    unresolved: sortedUnresolved,
    provenance: {
      normalizer_version: NORMALIZER_VERSION,
      engine_version: ENGINE_VERSION,
    },
  };

  const proposalId = sha256Prefixed(proposalBody);
  return {
    schema_version: "conversation-esaa.memory.proposal.v1",
    proposal_id: proposalId,
    ...proposalBody,
  };
}

function compactGraphForLargeStore(graph, proposal) {
  if (graph.nodes.length <= 500) {
    return graph;
  }
  const keepIds = new Set();
  for (const n of graph.nodes) {
    if (n.kind !== "episode") keepIds.add(n.id);
  }
  for (const e of graph.derived_edges) {
    keepIds.add(e.source);
    keepIds.add(e.target);
  }
  for (const p of graph.possible_edges) {
    keepIds.add(p.source);
    keepIds.add(p.target);
  }
  for (const b of graph.boundaries) {
    for (const nid of b.node_ids) keepIds.add(nid);
  }
  for (const a of proposal.actions) {
    keepIds.add(a.memory_id);
    for (const tid of a.target_memory_ids || []) keepIds.add(tid);
  }

  const keptNodes = graph.nodes.filter((n) => keepIds.has(n.id));
  const compactedCount = graph.nodes.length - keptNodes.length;
  const nextCoverage = {
    ...graph.coverage,
    sampled_node_ids: keptNodes.map((n) => n.id),
    omitted_node_ids: (graph.coverage?.omitted_node_ids || []).slice(0, 100),
    compacted_cold_episodes_count: compactedCount,
  };
  const payload = {
    schema_version: "memory-tcg.graph.v1",
    source_snapshot_id: graph.source_snapshot_id,
    policy_digest: graph.policy_digest,
    seed: graph.seed,
    nodes: keptNodes,
    derived_edges: graph.derived_edges,
    possible_edges: graph.possible_edges,
    boundaries: graph.boundaries,
    coverage: nextCoverage,
  };
  const compactedGraph = {
    schema_version: "memory-tcg.graph.v1",
    generation_id: sha256Prefixed(payload),
    ...payload,
  };
  assertGraphInvariants(compactedGraph);
  return compactedGraph;
}

export function runRrrCycle(factsBundle, options = {}) {
  const seed =
    Number.isInteger(options.seed) && options.seed >= 0 ? options.seed : 42;
  const budget = options.budget === undefined ? "all" : options.budget;

  const initialGraph = buildMemoryGraph(factsBundle, {
    seed,
    max_nodes: options.maxNodes ?? 25000,
    max_edges: options.maxEdges ?? 100000,
  });

  const ringingResult = runRinging(initialGraph, {
    seed,
    budget,
    maxAnalysisNodes: options.maxNodes ?? 25000,
    strictAnalysisBudget: options.strictAnalysisBudget === true,
  });

  const resonatedGraph = runResonance(
    ringingResult.graph,
    factsBundle,
    options,
  );

  const preliminaryProposal = runRenormalization(resonatedGraph, {
    workspace_id: factsBundle.workspace_id,
    watermark_event_id: factsBundle.watermark_event_id,
    mode: options.mode || "shadow",
    sampling: ringingResult.sampling,
  });

  if (resonatedGraph.nodes.length > 500) {
    const compactedGraph = compactGraphForLargeStore(
      resonatedGraph,
      preliminaryProposal,
    );
    const finalProposalBody = {
      schema_version: preliminaryProposal.schema_version,
      workspace_id: preliminaryProposal.workspace_id,
      snapshot_id: preliminaryProposal.snapshot_id,
      watermark_event_id: preliminaryProposal.watermark_event_id,
      graph_generation_id: compactedGraph.generation_id,
      policy_version: preliminaryProposal.policy_version,
      mode: preliminaryProposal.mode,
      sampling: preliminaryProposal.sampling,
      actions: preliminaryProposal.actions,
      unresolved: preliminaryProposal.unresolved,
      provenance: preliminaryProposal.provenance,
    };
    const finalProposal = {
      schema_version: preliminaryProposal.schema_version,
      proposal_id: sha256Prefixed(finalProposalBody),
      ...finalProposalBody,
    };
    return {
      graph: compactedGraph,
      proposal: finalProposal,
      sampling: finalProposal.sampling,
    };
  }

  return {
    graph: resonatedGraph,
    proposal: preliminaryProposal,
    sampling: ringingResult.sampling,
  };
}
