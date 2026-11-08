import { MemoryTcgError, sha256Prefixed } from "./canonical.js";

export const RINGING_POLICY_VERSION = "ringing.stratified.v1";

export function createSeededRng(seed = 42) {
  let state = (Number(seed) >>> 0) || 1;
  return function nextFloat() {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function deterministicShuffle(items, rng) {
  const arr = [...items];
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    const tmp = arr[i];
    arr[i] = arr[j];
    arr[j] = tmp;
  }
  return arr;
}

export function runRinging(graph, options = {}) {
  if (!graph || graph.schema_version !== "memory-tcg.graph.v1") {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "runRinging requires a memory-tcg.graph.v1 object",
    );
  }

  const seed =
    Number.isInteger(options.seed) && options.seed >= 0
      ? options.seed
      : Number.isInteger(graph.seed)
        ? graph.seed
        : 42;
  const budget = options.budget === undefined ? "all" : options.budget;
  const maxAnalysisNodes =
    Number.isInteger(options.maxAnalysisNodes) && options.maxAnalysisNodes > 0
      ? options.maxAnalysisNodes
      : 25000;

  const sortedNodes = [...graph.nodes].sort((a, b) => a.id.localeCompare(b.id));
  if (sortedNodes.length > maxAnalysisNodes) {
    throw new MemoryTcgError(
      "LIMIT_EXCEEDED",
      `Graph node count (${sortedNodes.length}) exceeds maxAnalysisNodes (${maxAnalysisNodes})`,
      { count: sortedNodes.length, limit: maxAnalysisNodes },
    );
  }

  if (budget !== "all") {
    if (!Number.isInteger(budget) || budget <= 0) {
      throw new MemoryTcgError(
        "LIMIT_EXCEEDED",
        `Invalid ringing budget: ${budget}. Must be 'all' or a positive integer.`,
      );
    }
    if (options.strictAnalysisBudget === true && budget < sortedNodes.length) {
      throw new MemoryTcgError(
        "LIMIT_EXCEEDED",
        `Strict analysis budget (${budget}) is smaller than eligible node count (${sortedNodes.length})`,
        { budget, eligible_nodes: sortedNodes.length },
      );
    }
  }

  const targetBudget =
    budget === "all"
      ? sortedNodes.length
      : Math.min(budget, sortedNodes.length);

  const partitionsMap = new Map();
  for (const node of sortedNodes) {
    const topicKey = node.topic_id || "_unscoped_";
    const timeKey = node.time_bucket || "unknown";
    const partKey = `${topicKey}::${timeKey}`;
    if (!partitionsMap.has(partKey)) {
      partitionsMap.set(partKey, []);
    }
    partitionsMap.get(partKey).push(node);
  }

  const partitionKeys = [...partitionsMap.keys()].sort();
  const rng = createSeededRng(seed);
  const shuffledPartitions = new Map();
  for (const key of partitionKeys) {
    const group = partitionsMap.get(key);
    const decisions = group.filter((n) => n.kind === "decision");
    const others = group.filter((n) => n.kind !== "decision");
    shuffledPartitions.set(key, [
      ...deterministicShuffle(decisions, rng),
      ...deterministicShuffle(others, rng),
    ]);
  }

  const adjacency = new Map();
  for (const node of sortedNodes) {
    adjacency.set(node.id, new Set());
  }
  const sortedEdges = [...graph.derived_edges].sort((a, b) =>
    `${a.source}|${a.relation}|${a.target}`.localeCompare(
      `${b.source}|${b.relation}|${b.target}`,
    ),
  );
  for (const edge of sortedEdges) {
    if (adjacency.has(edge.source) && adjacency.has(edge.target)) {
      adjacency.get(edge.source).add(edge.target);
      adjacency.get(edge.target).add(edge.source);
    }
  }

  const visited = new Set();
  const orderedVisited = [];
  const partitionOrder = deterministicShuffle(partitionKeys, rng);

  let addedInRound = true;
  while (orderedVisited.length < targetBudget && addedInRound) {
    addedInRound = false;
    for (const partKey of partitionOrder) {
      if (orderedVisited.length >= targetBudget) break;
      const bucket = shuffledPartitions.get(partKey);
      while (bucket.length > 0) {
        const candidate = bucket.shift();
        if (!visited.has(candidate.id)) {
          visited.add(candidate.id);
          orderedVisited.push(candidate.id);
          addedInRound = true;

          const queue = [candidate.id];
          while (queue.length > 0 && orderedVisited.length < targetBudget) {
            const curr = queue.shift();
            const neighbors = [...(adjacency.get(curr) || [])].sort();
            for (const nb of neighbors) {
              if (orderedVisited.length >= targetBudget) break;
              if (!visited.has(nb)) {
                visited.add(nb);
                orderedVisited.push(nb);
                queue.push(nb);
              }
            }
          }
          break;
        }
      }
    }
  }

  const sampledNodeIds = [...orderedVisited];
  const omittedNodeIds = sortedNodes
    .map((n) => n.id)
    .filter((id) => !visited.has(id));
  const omittedReasons = omittedNodeIds.map((id) => ({
    id,
    reason_code: "BUDGET_NOT_REACHED",
  }));

  const coverage = {
    eligible_nodes: sortedNodes.length,
    sampled_nodes: sampledNodeIds.length,
    unresolved_nodes: graph.coverage?.unresolved_nodes || 0,
    sampled_node_ids: sampledNodeIds,
    omitted_node_ids: omittedNodeIds,
    selection_policy_version: RINGING_POLICY_VERSION,
  };

  const nextGraphPayload = {
    schema_version: "memory-tcg.graph.v1",
    source_snapshot_id: graph.source_snapshot_id,
    policy_digest: graph.policy_digest,
    seed,
    nodes: graph.nodes,
    derived_edges: graph.derived_edges,
    possible_edges: graph.possible_edges,
    boundaries: graph.boundaries,
    coverage,
  };

  return {
    graph: {
      schema_version: "memory-tcg.graph.v1",
      generation_id: sha256Prefixed(nextGraphPayload),
      ...nextGraphPayload,
    },
    sampling: {
      seed,
      strategy: "stratified-topics-time",
      policy_version: RINGING_POLICY_VERSION,
      budget,
      partitions_count: partitionKeys.length,
      sampled_ids: sampledNodeIds,
      omitted_ids: omittedNodeIds,
      omitted_reasons: omittedReasons,
    },
  };
}
