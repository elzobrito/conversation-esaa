#!/usr/bin/env node
import {
  appendFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import {
  canonicalJson,
  ENGINE_VERSION,
  MemoryTcgError,
  NORMALIZER_VERSION,
  normalizeUnicode,
  redactSensitiveText,
  sha256Prefixed,
} from "../core/canonical.js";
import { assertGraphInvariants } from "../core/graph.js";
import {
  ALLOWED_PROPOSAL_ACTIONS,
  RRR_POLICY_VERSION,
  runRrrCycle,
} from "../core/renormalize.js";
import {
  assertNoSymlinkChain,
  createWorkspaceSnapshot,
  ensurePrivateMemoryDirs,
  hardenPrivatePath,
  verifySnapshotFreshness,
} from "./snapshot.js";

function parseCliArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        flags[key] = next;
        i++;
      } else {
        flags[key] = true;
      }
    } else {
      positional.push(arg);
    }
  }
  return {
    subcommand: positional[0] || "status",
    positional: positional.slice(1),
    flags,
  };
}

function normalizeDigestHex(id) {
  if (!id || typeof id !== "string") return "";
  return id.trim().replace(/^sha256:/i, "").toLowerCase();
}

export function verifyProposalIntegrity(proposal) {
  if (
    !proposal ||
    typeof proposal !== "object" ||
    proposal.schema_version !== "conversation-esaa.memory.proposal.v1"
  ) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Invalid proposal schema_version",
    );
  }
  if (
    typeof proposal.proposal_id !== "string" ||
    !/^sha256:[0-9a-f]{64}$/.test(proposal.proposal_id)
  ) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Proposal has invalid proposal_id format",
    );
  }
  const { proposal_id:actualId, ...rest } = proposal;
  const expectedBody = {
    schema_version: rest.schema_version,
    workspace_id: rest.workspace_id,
    snapshot_id: rest.snapshot_id,
    watermark_event_id: rest.watermark_event_id ?? null,
    graph_generation_id: rest.graph_generation_id,
    policy_version: rest.policy_version,
    mode: rest.mode,
    sampling: rest.sampling,
    actions: rest.actions,
    unresolved: rest.unresolved,
    provenance: rest.provenance,
  };
  const recomputedId = sha256Prefixed(expectedBody);
  if (recomputedId !== actualId) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      `Proposal digest mismatch: expected ${recomputedId}, got ${actualId}`,
    );
  }
  if (!Array.isArray(proposal.actions)) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Proposal actions must be an array",
    );
  }
  for (const act of proposal.actions) {
    if (!ALLOWED_PROPOSAL_ACTIONS.has(act.action)) {
      throw new MemoryTcgError(
        "POLICY_REJECTED",
        `Forbidden action in proposal: ${act.action}`,
      );
    }
    if (!Array.isArray(act.evidence_event_ids) || act.evidence_event_ids.length === 0) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Action for ${act.memory_id} has empty evidence_event_ids`,
      );
    }
  }
  return true;
}

export function verifyGraphIntegrity(graph) {
  assertGraphInvariants(graph);
  const { generation_id: actualGenId, ...rest } = graph;
  const recomputed = sha256Prefixed(rest);
  if (recomputed !== actualGenId) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      `Graph generation_id mismatch: expected ${recomputed}, got ${actualGenId}`,
    );
  }
  return true;
}

export function verifyActiveViewIntegrity(activeView, manifest = null) {
  if (
    !activeView ||
    typeof activeView !== "object" ||
    activeView.schema_version !== "conversation-esaa.memory.active.v1"
  ) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Invalid active.json schema_version",
    );
  }
  const { active_digest: actualDigest, ...body } = activeView;
  const expectedDigest = sha256Prefixed(body);
  if (expectedDigest !== actualDigest) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      `Active memory view digest mismatch: expected ${expectedDigest}, got ${actualDigest}`,
    );
  }
  if (manifest && manifest.active_digest && manifest.active_digest !== actualDigest) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      `Active memory view digest does not match manifest.json (${manifest.active_digest} vs ${actualDigest})`,
    );
  }
  if (
    manifest &&
    manifest.active_generation_id &&
    manifest.active_generation_id !== activeView.graph_generation_id
  ) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Active memory generation_id does not match manifest.json",
    );
  }
  return true;
}

export function buildActiveViewFromProposal(proposal, graph = null, acceptedAtEventId = null) {
  const nodeMap = new Map(
    graph && Array.isArray(graph.nodes) ? graph.nodes.map((n) => [n.id, n]) : [],
  );
  const memberships = new Map();
  for (const edge of graph?.derived_edges || []) {
    if (edge.relation !== "topic_contains_event") continue;
    if (!memberships.has(edge.target)) memberships.set(edge.target, new Set());
    memberships.get(edge.target).add(edge.source);
  }

  const retained = [];
  const groupedDuplicates = [];
  const historicalDecisions = [];
  const deprioritized = [];
  const flaggedConflicts = [];

  for (const act of proposal.actions) {
    const node = nodeMap.get(act.memory_id) || null;
    const item = {
      memory_id: act.memory_id,
      kind: node ? node.kind : act.memory_id.startsWith("decision:") ? "decision" : "episode",
      topic_id: node ? node.topic_id : null,
      topic_ids: [...new Set([act.memory_id, ...(act.target_memory_ids || [])].flatMap((id) => [
        nodeMap.get(id)?.topic_id, ...(memberships.get(id) || []),
      ]).filter(Boolean))].sort(),
      timestamp: node ? node.timestamp : null,
      summary: redactSensitiveText(act.summary || (node ? node.summary : act.memory_id)),
      text: redactSensitiveText(node ? node.text : act.summary || act.memory_id),
      action: act.action,
      superseded_by_id: act.superseded_by_id || null,
      target_memory_ids: act.target_memory_ids || [],
      reason_codes: act.reason_codes || [],
      evidence_event_ids: act.evidence_event_ids || [],
    };

    if (act.action === "retain") {
      retained.push(item);
    } else if (act.action === "group_exact_duplicates") {
      groupedDuplicates.push(item);
    } else if (act.action === "mark_historical_explicit") {
      historicalDecisions.push(item);
    } else if (act.action === "deprioritize_in_active_view") {
      deprioritized.push(item);
    } else if (act.action === "flag_conflict") {
      flaggedConflicts.push(item);
    }
  }

  const body = {
    schema_version: "conversation-esaa.memory.active.v1",
    workspace_id: proposal.workspace_id,
    proposal_id: proposal.proposal_id,
    snapshot_id: proposal.snapshot_id,
    watermark_event_id: proposal.watermark_event_id,
    graph_generation_id: proposal.graph_generation_id,
    policy_version: proposal.policy_version,
    accepted_event_id: acceptedAtEventId || null,
    sampling: proposal.sampling,
    retained,
    grouped_duplicates: groupedDuplicates,
    historical_decisions: historicalDecisions,
    deprioritized,
    flagged_conflicts: flaggedConflicts,
    unresolved: proposal.unresolved || [],
    provenance: proposal.provenance,
  };

  const activeDigest = sha256Prefixed(body);
  return {
    ...body,
    active_digest: activeDigest,
  };
}

function findProposalFile(shadowDir, proposalIdInput, manifest = null) {
  if (!existsSync(shadowDir)) {
    throw new MemoryTcgError(
      "NOT_FOUND",
      `Shadow directory does not exist: ${shadowDir}`,
    );
  }
  const files = readdirSync(shadowDir)
    .filter((f) => f.endsWith(".json"))
    .sort();
  if (files.length === 0) {
    throw new MemoryTcgError(
      "NOT_FOUND",
      "No shadow proposals found in .conversation-esaa/memory/shadow/",
    );
  }

  let targetQuery = proposalIdInput;
  if (!targetQuery || targetQuery === "latest") {
    if (manifest && manifest.last_shadow_proposal_id) {
      targetQuery = manifest.last_shadow_proposal_id;
    } else {
      return path.join(shadowDir, files[files.length - 1]);
    }
  }

  const hexPrefix = normalizeDigestHex(targetQuery);
  const matches = files.filter((f) =>
    f.replace(/\.json$/i, "").toLowerCase().startsWith(hexPrefix),
  );
  if (matches.length === 0) {
    throw new MemoryTcgError(
      "NOT_FOUND",
      `Shadow proposal not found for identifier: ${proposalIdInput}`,
    );
  }
  if (matches.length > 1) {
    throw new MemoryTcgError(
      "AMBIGUOUS_ID",
      `Multiple shadow proposals match prefix: ${proposalIdInput}`,
    );
  }
  return path.join(shadowDir, matches[0]);
}

function readJsonChecked(filePath, canonicalRoot) {
  assertNoSymlinkChain(filePath, canonicalRoot);
  const raw = readFileSync(filePath, "utf8");
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      `Corrupted JSON at ${filePath}: ${err.message}`,
    );
  }
}

function writeJsonPrivate(filePath, data, canonicalRoot) {
  assertNoSymlinkChain(filePath, canonicalRoot);
  const dir = path.dirname(filePath);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  hardenPrivatePath(dir, true);
  writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  hardenPrivatePath(filePath, false);
}

function appendRunTelemetry(logsDir, canonicalRoot, entry) {
  const logFile = path.join(logsDir, "runs.jsonl");
  assertNoSymlinkChain(logFile, canonicalRoot);
  const safeEntry = {
    ts: new Date().toISOString(),
    ...entry,
  };
  appendFileSync(logFile, `${JSON.stringify(safeEntry)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  hardenPrivatePath(logFile, false);
}

export function cmdStatus(workspaceRoot) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const convDir = path.join(canonicalRoot, ".conversation-esaa");
  const memoryDir = path.join(convDir, "memory");
  const shadowDir = path.join(memoryDir, "shadow");
  const generationsDir = path.join(memoryDir, "generations");
  const manifestPath = path.join(memoryDir, "manifest.json");
  const activePath = path.join(memoryDir, "active.json");

  assertNoSymlinkChain(convDir, canonicalRoot);
  if (existsSync(memoryDir)) {
    assertNoSymlinkChain(memoryDir, canonicalRoot);
  }

  let manifest = null;
  if (existsSync(manifestPath)) {
    manifest = readJsonChecked(manifestPath, canonicalRoot);
  }

  let activeView = null;
  let activeValid = false;
  if (existsSync(activePath)) {
    activeView = readJsonChecked(activePath, canonicalRoot);
    verifyActiveViewIntegrity(activeView, manifest);
    activeValid = true;
  }

  const shadowProposals = existsSync(shadowDir)
    ? readdirSync(shadowDir).filter((f) => f.endsWith(".json"))
    : [];
  const generations = existsSync(generationsDir)
    ? readdirSync(generationsDir).filter((d) =>
        existsSync(path.join(generationsDir, d, "graph.json")),
      )
    : [];

  let snapshotMeta = null;
  const activityPath = path.join(convDir, "activity.jsonl");
  if (existsSync(activityPath)) {
    try {
      snapshotMeta = createWorkspaceSnapshot(canonicalRoot).meta;
    } catch {
      snapshotMeta = null;
    }
  }

  const mode = activeValid
    ? "active"
    : shadowProposals.length > 0
      ? "shadow"
      : "off";

  return {
    status: "OK",
    mode,
    workspace_id:
      (manifest && manifest.workspace_id) ||
      (snapshotMeta && snapshotMeta.workspace_id) ||
      sha256Prefixed(`workspace:${canonicalRoot}`),
    active_generation_id: activeValid ? activeView.graph_generation_id : null,
    active_proposal_id: activeValid ? activeView.proposal_id : null,
    active_watermark_event_id: activeValid ? activeView.watermark_event_id : null,
    current_watermark_event_id: snapshotMeta ? snapshotMeta.watermark_event_id : null,
    last_shadow_proposal_id: manifest ? manifest.last_shadow_proposal_id || null : null,
    shadow_proposal_count: shadowProposals.length,
    generation_count: generations.length,
    unresolved_conflict_count: activeValid
      ? (activeView.unresolved || []).length
      : 0,
  };
}

export function cmdSleep(workspaceRoot, options = {}) {
  const startTime = Date.now();
  const mode = options.mode ? String(options.mode) : "shadow";
  if (mode !== "shadow" && mode !== "manual") {
    throw new MemoryTcgError(
      "POLICY_REJECTED",
      `Unsupported sleep mode '${mode}'. Auto-apply is forbidden in v1; use --mode shadow or --mode manual.`,
    );
  }

  const seed =
    options.seed !== undefined && options.seed !== null
      ? Number.parseInt(String(options.seed), 10)
      : 42;
  if (!Number.isInteger(seed) || seed < 0) {
    throw new MemoryTcgError("INVALID_SEED", "seed must be a non-negative integer");
  }

  const budget =
    options.budget === undefined || options.budget === "all"
      ? "all"
      : Number.parseInt(String(options.budget), 10);

  const maxNodes =
    options.maxNodes !== undefined
      ? Number.parseInt(String(options.maxNodes), 10)
      : 25000;
  const maxEdges =
    options.maxEdges !== undefined
      ? Number.parseInt(String(options.maxEdges), 10)
      : 100000;

  const dirs = ensurePrivateMemoryDirs(workspaceRoot);
  const { factsBundle, meta } = createWorkspaceSnapshot(dirs.workspaceRoot);

  const { graph, proposal } = runRrrCycle(factsBundle, {
    seed,
    budget,
    mode,
    maxNodes,
    maxEdges,
  });

  verifyGraphIntegrity(graph);
  verifyProposalIntegrity(proposal);

  const genHex = normalizeDigestHex(graph.generation_id);
  const propHex = normalizeDigestHex(proposal.proposal_id);

  const genDir = path.join(dirs.generationsDir, genHex);
  const graphPath = path.join(genDir, "graph.json");
  const proposalPath = path.join(dirs.shadowDir, `${propHex}.json`);
  const manifestPath = path.join(dirs.memoryDir, "manifest.json");

  writeJsonPrivate(graphPath, graph, dirs.workspaceRoot);
  writeJsonPrivate(proposalPath, proposal, dirs.workspaceRoot);

  let existingManifest = {};
  if (existsSync(manifestPath)) {
    try {
      existingManifest = readJsonChecked(manifestPath, dirs.workspaceRoot);
    } catch {
      existingManifest = {};
    }
  }

  const nextManifest = {
    schema_version: "conversation-esaa.memory.manifest.v1",
    workspace_id: factsBundle.workspace_id,
    active_generation_id: existingManifest.active_generation_id || null,
    active_proposal_id: existingManifest.active_proposal_id || null,
    active_digest: existingManifest.active_digest || null,
    active_watermark_event_id: existingManifest.active_watermark_event_id || null,
    last_shadow_proposal_id: proposal.proposal_id,
    last_shadow_generation_id: graph.generation_id,
    last_shadow_snapshot_id: factsBundle.source_snapshot_id,
    last_shadow_watermark_event_id: factsBundle.watermark_event_id,
    policy_version: RRR_POLICY_VERSION,
    normalizer_version: NORMALIZER_VERSION,
    engine_version: ENGINE_VERSION,
  };
  writeJsonPrivate(manifestPath, nextManifest, dirs.workspaceRoot);

  const durationMs = Date.now() - startTime;
  appendRunTelemetry(dirs.logsDir, dirs.workspaceRoot, {
    action: "sleep",
    mode,
    workspace_id: factsBundle.workspace_id,
    snapshot_id: factsBundle.source_snapshot_id,
    watermark_event_id: factsBundle.watermark_event_id,
    proposal_id: proposal.proposal_id,
    graph_generation_id: graph.generation_id,
    seed,
    budget,
    event_count: meta.event_count,
    node_count: graph.nodes.length,
    derived_edge_count: graph.derived_edges.length,
    possible_edge_count: graph.possible_edges.length,
    boundary_count: graph.boundaries.length,
    action_count: proposal.actions.length,
    unresolved_count: proposal.unresolved.length,
    duration_ms: durationMs,
  });

  const actionCounts = {};
  for (const act of proposal.actions) {
    actionCounts[act.action] = (actionCounts[act.action] || 0) + 1;
  }
  const implicitDeprioritized =
    proposal.sampling?.deprioritized_implicit_count || 0;
  if (implicitDeprioritized > 0) {
    actionCounts.deprioritize_in_active_view =
      (actionCounts.deprioritize_in_active_view || 0) + implicitDeprioritized;
  }
  const eligibleNodesCount =
    graph.coverage?.eligible_nodes || graph.nodes.length;

  return {
    status: "OK",
    mode,
    workspace_id: factsBundle.workspace_id,
    snapshot_id: factsBundle.source_snapshot_id,
    watermark_event_id: factsBundle.watermark_event_id,
    proposal_id: proposal.proposal_id,
    graph_generation_id: graph.generation_id,
    seed,
    budget,
    node_count: eligibleNodesCount,
    stored_node_count: graph.nodes.length,
    derived_edge_count: graph.derived_edges.length,
    possible_edge_count: graph.possible_edges.length,
    boundary_count: graph.boundaries.length,
    action_counts: actionCounts,
    unresolved_count: proposal.unresolved.length,
    proposal_path: proposalPath,
    graph_path: graphPath,
  };
}

export function cmdInspect(workspaceRoot, proposalIdInput, options = {}) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const memoryDir = path.join(canonicalRoot, ".conversation-esaa", "memory");
  const shadowDir = path.join(memoryDir, "shadow");
  const manifestPath = path.join(memoryDir, "manifest.json");

  const manifest = existsSync(manifestPath)
    ? readJsonChecked(manifestPath, canonicalRoot)
    : null;
  let proposalPath = null;
  let proposal = null;
  let source = "shadow";
  let memoryEvents = null;
  try {
    proposalPath = findProposalFile(shadowDir, proposalIdInput, manifest);
    proposal = readJsonChecked(proposalPath, canonicalRoot);
  } catch (error) {
    if (error.code !== "NOT_FOUND") throw error;
    const requested = (!proposalIdInput || proposalIdInput === "latest")
      ? manifest?.last_shadow_proposal_id : proposalIdInput;
    if (!requested) throw error;
    const prefix = normalizeDigestHex(requested);
    memoryEvents = scanMemoryLedgerEvents(canonicalRoot);
    const matches = memoryEvents.filter((event) => event.event === "memory.consolidation.accepted" &&
      event.proposal && normalizeDigestHex(event.proposal_id).startsWith(prefix));
    const ids = new Set(matches.map((event) => event.proposal_id));
    if (ids.size > 1) throw new MemoryTcgError("AMBIGUOUS_ID", `Multiple ledger proposals match: ${requested}`);
    if (!matches.length) throw error;
    proposal = matches.at(-1).proposal;
    source = "ledger";
  }
  verifyProposalIntegrity(proposal);
  memoryEvents ||= scanMemoryLedgerEvents(canonicalRoot);
  const acceptances = memoryEvents.filter((event) => event.event === "memory.consolidation.accepted" && event.proposal_id === proposal.proposal_id)
    .map((event) => ({ event_id: event.event_id, ts: event.ts, agent_id: event.agent_id,
      agent_id_source: event.agent_id_source || "legacy_unverified" }));

  const maxDeprioritizedPreview = options.full ? Infinity : 50;
  const deprioritizedAll = proposal.actions.filter(
    (a) => a.action === "deprioritize_in_active_view",
  );
  const nonDeprioritized = proposal.actions.filter(
    (a) => a.action !== "deprioritize_in_active_view",
  );
  const deprioritizedOmittedCount =
    deprioritizedAll.length > maxDeprioritizedPreview
      ? deprioritizedAll.length - maxDeprioritizedPreview
      : 0;
  const viewActions =
    deprioritizedOmittedCount > 0
      ? [
          ...nonDeprioritized,
          ...deprioritizedAll.slice(0, maxDeprioritizedPreview),
        ]
      : proposal.actions;

  return {
    status: "OK",
    proposal_path: proposalPath,
    proposal_source: source,
    acceptances,
    deprioritized_omitted_count: deprioritizedOmittedCount,
    proposal:
      deprioritizedOmittedCount > 0
        ? {
            ...proposal,
            total_actions_count: proposal.actions.length,
            deprioritized_omitted_count: deprioritizedOmittedCount,
            actions: viewActions,
          }
        : proposal,
  };
}

export function cmdDiff(workspaceRoot, proposalIdInput, options = {}) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const memoryDir = path.join(canonicalRoot, ".conversation-esaa", "memory");
  const shadowDir = path.join(memoryDir, "shadow");
  const manifestPath = path.join(memoryDir, "manifest.json");
  const activePath = path.join(memoryDir, "active.json");

  const manifest = existsSync(manifestPath)
    ? readJsonChecked(manifestPath, canonicalRoot)
    : null;
  const proposalPath = findProposalFile(shadowDir, proposalIdInput, manifest);
  const proposal = readJsonChecked(proposalPath, canonicalRoot);
  verifyProposalIntegrity(proposal);

  let currentActive = null;
  if (existsSync(activePath)) {
    currentActive = readJsonChecked(activePath, canonicalRoot);
    verifyActiveViewIntegrity(currentActive, manifest);
  }

  const prevRetainedIds = new Set(
    currentActive ? (currentActive.retained || []).map((r) => r.memory_id) : [],
  );

  const retained = proposal.actions.filter((a) => a.action === "retain");
  const groupedDuplicates = proposal.actions.filter(
    (a) => a.action === "group_exact_duplicates",
  );
  const markedHistorical = proposal.actions.filter(
    (a) => a.action === "mark_historical_explicit",
  );
  const deprioritized = proposal.actions.filter(
    (a) => a.action === "deprioritize_in_active_view",
  );
  const flaggedConflicts = proposal.actions.filter(
    (a) => a.action === "flag_conflict",
  );

  const addedRetained = retained.filter((r) => !prevRetainedIds.has(r.memory_id));
  const nextRetainedSet = new Set(retained.map((r) => r.memory_id));
  const removedRetainedIds = [...prevRetainedIds].filter(
    (id) => !nextRetainedSet.has(id),
  );

  const maxDeprioritizedPreview = options.full ? Infinity : 50;
  const implicitDeprioritized =
    proposal.sampling?.deprioritized_implicit_count || 0;
  const deprioritizedOmittedCount =
    (deprioritized.length > maxDeprioritizedPreview
      ? deprioritized.length - maxDeprioritizedPreview
      : 0) + implicitDeprioritized;

  return {
    status: "OK",
    proposal_id: proposal.proposal_id,
    graph_generation_id: proposal.graph_generation_id,
    watermark_event_id: proposal.watermark_event_id,
    compared_against_generation_id: currentActive
      ? currentActive.graph_generation_id
      : null,
    summary: {
      total_actions: proposal.actions.length + implicitDeprioritized,
      retained_count: retained.length,
      added_retained_count: addedRetained.length,
      removed_retained_count: removedRetainedIds.length,
      grouped_duplicates_count: groupedDuplicates.length,
      marked_historical_count: markedHistorical.length,
      deprioritized_count: deprioritized.length + implicitDeprioritized,
      deprioritized_omitted_count: deprioritizedOmittedCount,
      flagged_conflicts_count: flaggedConflicts.length,
      unresolved_count: (proposal.unresolved || []).length,
    },
    retained,
    grouped_duplicates: groupedDuplicates,
    marked_historical: markedHistorical,
    deprioritized:
      deprioritizedOmittedCount > 0
        ? deprioritized.slice(0, maxDeprioritizedPreview)
        : deprioritized,
    flagged_conflicts: flaggedConflicts,
    unresolved: proposal.unresolved || [],
  };
}

export function cmdPrepareAccept(workspaceRoot, proposalIdInput) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const memoryDir = path.join(canonicalRoot, ".conversation-esaa", "memory");
  const shadowDir = path.join(memoryDir, "shadow");
  const generationsDir = path.join(memoryDir, "generations");
  const manifestPath = path.join(memoryDir, "manifest.json");

  const manifest = existsSync(manifestPath)
    ? readJsonChecked(manifestPath, canonicalRoot)
    : null;
  const proposalPath = findProposalFile(shadowDir, proposalIdInput, manifest);
  const proposal = readJsonChecked(proposalPath, canonicalRoot);
  verifyProposalIntegrity(proposal);

  const currentSnapshot = createWorkspaceSnapshot(canonicalRoot);
  if (proposal.workspace_id !== currentSnapshot.factsBundle.workspace_id) {
    throw new MemoryTcgError(
      "WRONG_WORKSPACE",
      `Proposal workspace_id (${proposal.workspace_id}) does not match current workspace (${currentSnapshot.factsBundle.workspace_id})`,
    );
  }

  verifySnapshotFreshness(
    canonicalRoot,
    proposal.snapshot_id,
    proposal.watermark_event_id,
  );

  const genHex = normalizeDigestHex(proposal.graph_generation_id);
  const graphPath = path.join(generationsDir, genHex, "graph.json");
  if (!existsSync(graphPath)) {
    throw new MemoryTcgError(
      "NOT_FOUND",
      `Graph generation file missing at ${graphPath}`,
    );
  }
  const graph = readJsonChecked(graphPath, canonicalRoot);
  verifyGraphIntegrity(graph);
  if (graph.generation_id !== proposal.graph_generation_id) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      "Graph generation_id does not match proposal.graph_generation_id",
    );
  }

  const activeView = buildActiveViewFromProposal(proposal, graph, null);

  const eventPayload = {
    proposal_id: proposal.proposal_id,
    snapshot_id: proposal.snapshot_id,
    watermark_event_id: proposal.watermark_event_id,
    graph_generation_id: proposal.graph_generation_id,
    policy_version: proposal.policy_version,
    workspace_id: proposal.workspace_id,
    previous_generation_id:
      manifest && manifest.active_generation_id
        ? manifest.active_generation_id
        : null,
    active_digest: activeView.active_digest,
    active_view: activeView,
    proposal,
    graph: graph.nodes.length <= 500 ? graph : null,
  };

  return {
    status: "OK",
    proposal_id: proposal.proposal_id,
    graph_generation_id: proposal.graph_generation_id,
    watermark_event_id: proposal.watermark_event_id,
    active_digest: activeView.active_digest,
    event_payload: eventPayload,
  };
}

function scanMemoryLedgerEvents(canonicalRoot) {
  const activityPath = path.join(
    canonicalRoot,
    ".conversation-esaa",
    "activity.jsonl",
  );
  if (!existsSync(activityPath)) return [];
  assertNoSymlinkChain(activityPath, canonicalRoot);
  const raw = readFileSync(activityPath, "utf8");
  const lines = normalizeUnicode(raw)
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);

  const memoryEvents = [];
  for (let i = 0; i < lines.length; i++) {
    let ev;
    try {
      ev = JSON.parse(lines[i]);
    } catch {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Invalid JSON in activity.jsonl at line ${i + 1}`,
      );
    }
    if (
      ev.event === "memory.consolidation.accepted" ||
      ev.event === "memory.consolidation.rolled_back"
    ) {
      memoryEvents.push(ev);
    }
  }
  return memoryEvents;
}

export function cmdPrepareRollback(workspaceRoot, targetGenerationInput, reason = "") {
  const canonicalRoot = realpathSync(workspaceRoot);
  const memoryEvents = scanMemoryLedgerEvents(canonicalRoot);
  const acceptedByGen = new Map();
  const acceptedOrder = [];
  for (const ev of memoryEvents) {
    if (ev.event === "memory.consolidation.accepted" && ev.graph_generation_id) {
      acceptedByGen.set(ev.graph_generation_id, ev);
      acceptedOrder.push(ev.graph_generation_id);
    }
  }

  const memoryDir = path.join(canonicalRoot, ".conversation-esaa", "memory");
  const manifestPath = path.join(memoryDir, "manifest.json");
  const manifest = existsSync(manifestPath)
    ? readJsonChecked(manifestPath, canonicalRoot)
    : null;
  const currentActiveGen = manifest ? manifest.active_generation_id || null : null;

  let resolvedTargetGen = null;
  if (
    !targetGenerationInput ||
    targetGenerationInput === "previous" ||
    targetGenerationInput === "prev"
  ) {
    const idx = currentActiveGen ? acceptedOrder.lastIndexOf(currentActiveGen) : -1;
    resolvedTargetGen = idx > 0 ? acceptedOrder[idx - 1] : null;
  } else if (
    targetGenerationInput === "off" ||
    targetGenerationInput === "none" ||
    targetGenerationInput === "null"
  ) {
    resolvedTargetGen = null;
  } else {
    const qHex = normalizeDigestHex(targetGenerationInput);
    const matching = [...acceptedByGen.keys()].filter((g) =>
      normalizeDigestHex(g).startsWith(qHex),
    );
    if (matching.length === 0) {
      throw new MemoryTcgError(
        "NOT_FOUND",
        `Target generation not found in accepted ledger history: ${targetGenerationInput}`,
      );
    }
    if (matching.length > 1) {
      throw new MemoryTcgError(
        "AMBIGUOUS_ID",
        `Multiple accepted generations match prefix: ${targetGenerationInput}`,
      );
    }
    resolvedTargetGen = matching[0];
  }

  const workspaceId = sha256Prefixed(`workspace:${canonicalRoot}`);
  const eventPayload = {
    workspace_id: workspaceId,
    rolled_back_from_generation_id: currentActiveGen,
    restored_generation_id: resolvedTargetGen,
    reason: redactSensitiveText(reason || "Explicit operator rollback"),
  };

  return {
    status: "OK",
    rolled_back_from_generation_id: currentActiveGen,
    restored_generation_id: resolvedTargetGen,
    event_payload: eventPayload,
  };
}

export function cmdReconstructFromLedger(workspaceRoot) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const memoryEvents = scanMemoryLedgerEvents(canonicalRoot);
  const convDir = path.join(canonicalRoot, ".conversation-esaa");
  const memoryDir = path.join(convDir, "memory");
  const activePath = path.join(memoryDir, "active.json");
  const manifestPath = path.join(memoryDir, "manifest.json");

  if (memoryEvents.length === 0) {
    if (existsSync(activePath)) {
      rmSync(activePath, { force: true });
    }
    return {
      status: "OK",
      reconstructed: false,
      active_generation_id: null,
      memory_events_count: 0,
    };
  }

  const dirs = ensurePrivateMemoryDirs(canonicalRoot);
  const acceptedEventsByGen = new Map();
  let currentActiveEvent = null;

  for (const ev of memoryEvents) {
    if (ev.event === "memory.consolidation.accepted") {
      if (!ev.proposal || !ev.active_view) {
        throw new MemoryTcgError(
          "INTEGRITY_FAILURE",
          `memory.consolidation.accepted event ${ev.event_id} is missing proposal or active_view payload`,
        );
      }
      verifyProposalIntegrity(ev.proposal);
      verifyActiveViewIntegrity(ev.active_view);
      if (ev.graph) {
        verifyGraphIntegrity(ev.graph);
        const genHex = normalizeDigestHex(ev.graph.generation_id);
        const graphPath = path.join(dirs.generationsDir, genHex, "graph.json");
        writeJsonPrivate(graphPath, ev.graph, dirs.workspaceRoot);
      }
      const propHex = normalizeDigestHex(ev.proposal.proposal_id);
      const proposalPath = path.join(dirs.shadowDir, `${propHex}.json`);
      writeJsonPrivate(proposalPath, ev.proposal, dirs.workspaceRoot);

      acceptedEventsByGen.set(ev.graph_generation_id, ev);
      currentActiveEvent = ev;
    } else if (ev.event === "memory.consolidation.rolled_back") {
      const restoredGen = ev.restored_generation_id || null;
      if (restoredGen === null) {
        currentActiveEvent = null;
      } else {
        const targetEv = acceptedEventsByGen.get(restoredGen);
        if (!targetEv) {
          throw new MemoryTcgError(
            "INTEGRITY_FAILURE",
            `Rollback event ${ev.event_id} references unknown generation ${restoredGen}`,
          );
        }
        currentActiveEvent = targetEv;
      }
    }
  }

  let existingManifest = {};
  if (existsSync(manifestPath)) {
    try {
      existingManifest = readJsonChecked(manifestPath, dirs.workspaceRoot);
    } catch {
      existingManifest = {};
    }
  }

  const workspaceId = sha256Prefixed(`workspace:${canonicalRoot}`);

  if (currentActiveEvent) {
    const activeView = currentActiveEvent.active_view;
    verifyActiveViewIntegrity(activeView);
    writeJsonPrivate(activePath, activeView, dirs.workspaceRoot);

    const nextManifest = {
      schema_version: "conversation-esaa.memory.manifest.v1",
      workspace_id: workspaceId,
      active_generation_id: activeView.graph_generation_id,
      active_proposal_id: activeView.proposal_id,
      active_digest: activeView.active_digest,
      active_watermark_event_id: activeView.watermark_event_id,
      last_shadow_proposal_id:
        existingManifest.last_shadow_proposal_id || activeView.proposal_id,
      last_shadow_generation_id:
        existingManifest.last_shadow_generation_id || activeView.graph_generation_id,
      last_shadow_snapshot_id:
        existingManifest.last_shadow_snapshot_id || activeView.snapshot_id,
      last_shadow_watermark_event_id:
        existingManifest.last_shadow_watermark_event_id ||
        activeView.watermark_event_id,
      policy_version: activeView.policy_version || RRR_POLICY_VERSION,
      normalizer_version: NORMALIZER_VERSION,
      engine_version: ENGINE_VERSION,
    };
    writeJsonPrivate(manifestPath, nextManifest, dirs.workspaceRoot);

    return {
      status: "OK",
      reconstructed: true,
      active_generation_id: activeView.graph_generation_id,
      active_proposal_id: activeView.proposal_id,
      active_digest: activeView.active_digest,
      memory_events_count: memoryEvents.length,
    };
  } else {
    if (existsSync(activePath)) {
      rmSync(activePath, { force: true });
    }
    const nextManifest = {
      schema_version: "conversation-esaa.memory.manifest.v1",
      workspace_id: workspaceId,
      active_generation_id: null,
      active_proposal_id: null,
      active_digest: null,
      active_watermark_event_id: null,
      last_shadow_proposal_id: existingManifest.last_shadow_proposal_id || null,
      last_shadow_generation_id: existingManifest.last_shadow_generation_id || null,
      last_shadow_snapshot_id: existingManifest.last_shadow_snapshot_id || null,
      last_shadow_watermark_event_id:
        existingManifest.last_shadow_watermark_event_id || null,
      policy_version: RRR_POLICY_VERSION,
      normalizer_version: NORMALIZER_VERSION,
      engine_version: ENGINE_VERSION,
    };
    writeJsonPrivate(manifestPath, nextManifest, dirs.workspaceRoot);

    return {
      status: "OK",
      reconstructed: true,
      active_generation_id: null,
      active_proposal_id: null,
      active_digest: null,
      memory_events_count: memoryEvents.length,
    };
  }
}

export function cmdVerify(workspaceRoot) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const convDir = path.join(canonicalRoot, ".conversation-esaa");
  const memoryDir = path.join(convDir, "memory");
  const shadowDir = path.join(memoryDir, "shadow");
  const generationsDir = path.join(memoryDir, "generations");
  const manifestPath = path.join(memoryDir, "manifest.json");
  const activePath = path.join(memoryDir, "active.json");

  assertNoSymlinkChain(convDir, canonicalRoot);
  if (existsSync(memoryDir)) {
    assertNoSymlinkChain(memoryDir, canonicalRoot);
  }

  let verifiedProposals = 0;
  if (existsSync(shadowDir)) {
    assertNoSymlinkChain(shadowDir, canonicalRoot);
    const files = readdirSync(shadowDir)
      .filter((f) => f.endsWith(".json"))
      .sort();
    for (const file of files) {
      const pPath = path.join(shadowDir, file);
      const proposal = readJsonChecked(pPath, canonicalRoot);
      verifyProposalIntegrity(proposal);
      verifiedProposals++;
    }
  }

  let verifiedGraphs = 0;
  if (existsSync(generationsDir)) {
    assertNoSymlinkChain(generationsDir, canonicalRoot);
    const dirs = readdirSync(generationsDir).sort();
    for (const d of dirs) {
      const gPath = path.join(generationsDir, d, "graph.json");
      if (existsSync(gPath)) {
        const graph = readJsonChecked(gPath, canonicalRoot);
        verifyGraphIntegrity(graph);
        verifiedGraphs++;
      }
    }
  }

  const manifest = existsSync(manifestPath)
    ? readJsonChecked(manifestPath, canonicalRoot)
    : null;

  let activeGenerationId = null;
  if (existsSync(activePath)) {
    const activeView = readJsonChecked(activePath, canonicalRoot);
    verifyActiveViewIntegrity(activeView, manifest);
    activeGenerationId = activeView.graph_generation_id;
  } else if (manifest && manifest.active_generation_id) {
    throw new MemoryTcgError(
      "INTEGRITY_FAILURE",
      `manifest.json declares active_generation_id ${manifest.active_generation_id}, but active.json is missing`,
    );
  }

  const memoryEvents = scanMemoryLedgerEvents(canonicalRoot);
  if (memoryEvents.length > 0) {
    let expectedGen = null;
    const knownAccepted = new Set();
    for (const ev of memoryEvents) {
      if (ev.event === "memory.consolidation.accepted") {
        knownAccepted.add(ev.graph_generation_id);
        expectedGen = ev.graph_generation_id;
      } else if (ev.event === "memory.consolidation.rolled_back") {
        expectedGen = ev.restored_generation_id || null;
        if (expectedGen !== null && !knownAccepted.has(expectedGen)) {
          throw new MemoryTcgError(
            "INTEGRITY_FAILURE",
            `Ledger rollback references unknown generation ${expectedGen}`,
          );
        }
      }
    }
    if (expectedGen !== activeGenerationId) {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Active memory generation (${activeGenerationId}) is out of sync with activity.jsonl ledger (${expectedGen})`,
      );
    }
  }

  return {
    status: "OK",
    verified_proposals: verifiedProposals,
    verified_graphs: verifiedGraphs,
    active_generation_id: activeGenerationId,
    ledger_memory_events: memoryEvents.length,
  };
}

export function cmdContext(workspaceRoot, options = {}) {
  const canonicalRoot = realpathSync(workspaceRoot);
  const memoryDir = path.join(canonicalRoot, ".conversation-esaa", "memory");
  const manifestPath = path.join(memoryDir, "manifest.json");
  const activePath = path.join(memoryDir, "active.json");

  const topicFilter = options.topicId ? String(options.topicId) : null;
  const budgetChars =
    options.budgetChars !== undefined && options.budgetChars !== null
      ? Number.parseInt(String(options.budgetChars), 10)
      : 4000;

  if (!existsSync(activePath)) {
    return {
      status: "OFF",
      mode: "off",
      active_generation_id: null,
      markdown: "",
      retained_decisions: [],
      historical_decisions: [],
      consolidated_subjects: [],
      grouped_duplicates: [],
      unresolved_conflicts: [],
      omitted_memory_ids: [],
    };
  }

  let manifest = null;
  let activeView = null;
  try {
    if (existsSync(manifestPath)) {
      manifest = readJsonChecked(manifestPath, canonicalRoot);
    }
    activeView = readJsonChecked(activePath, canonicalRoot);
    verifyActiveViewIntegrity(activeView, manifest);
  } catch (err) {
    return {
      status: "FALLBACK_LEGACY",
      mode: "fallback",
      error_code: err.code || "INTEGRITY_FAILURE",
      reason: err.message,
      active_generation_id: null,
      markdown: "",
      retained_decisions: [],
      historical_decisions: [],
      consolidated_subjects: [],
      grouped_duplicates: [],
      unresolved_conflicts: [],
      omitted_memory_ids: [],
    };
  }

  const filterByTopic = (item) => {
    if (!topicFilter) return true;
    return item.topic_id === topicFilter || (item.topic_ids || []).includes(topicFilter) ||
      (item.kind === "topic" && item.memory_id === topicFilter);
  };
  // Keep technical turn fragments in the ledger, but not in subject summaries.
  const isTechnicalFragment = (item) => {
    const text = String(item.summary || "").trim();
    return /^(?:<\/?image>|i will wait for .+ to complete\.?|aguardando(?: a conclusão)?\.?|loading\.{0,3})$/i.test(text);
  };

  const sortByRecent = (a, b) =>
    String(b.timestamp || "").localeCompare(String(a.timestamp || "")) ||
    String(a.memory_id || "").localeCompare(String(b.memory_id || ""));

  const retainedDecisions = (activeView.retained || [])
    .filter((r) => r.kind === "decision" && filterByTopic(r))
    .sort(sortByRecent);
  const retainedTopicsAndTasks = (activeView.retained || []).filter(
    (r) => (r.kind === "topic" || r.kind === "task") && filterByTopic(r),
  );
  const retainedEpisodes = (activeView.retained || []).filter(
    (r) => r.kind === "episode" && filterByTopic(r),
  );
  const suppressedTechnicalIds = [...retainedEpisodes, ...(activeView.grouped_duplicates || []).filter(filterByTopic)]
    .filter(isTechnicalFragment).map((r) => r.memory_id);
  const subjectEpisodes = retainedEpisodes
    .filter((r) => (r.reason_codes || []).includes("CONSOLIDATED_SUBJECT_MATTER") && !isTechnicalFragment(r))
    .sort(sortByRecent);
  const decisionSupportEpisodes = retainedEpisodes.filter(
    (r) => !(r.reason_codes || []).includes("CONSOLIDATED_SUBJECT_MATTER"),
  );
  const groupedDuplicateSubjects = (activeView.grouped_duplicates || [])
    .filter(filterByTopic)
    .filter((r) => !isTechnicalFragment(r));
  const historicalDecisions = (activeView.historical_decisions || []).filter(
    filterByTopic,
  );
  const nodeById = new Map();
  for (const list of [
    activeView.retained || [],
    activeView.flagged_conflicts || [],
    activeView.historical_decisions || [],
    activeView.deprioritized || [],
  ]) {
    for (const item of list) {
      if (item && item.memory_id && !nodeById.has(item.memory_id)) {
        nodeById.set(item.memory_id, item);
      }
    }
  }
  const conflictMatchesTopic = (conf) => !topicFilter ||
    [...(conf.memory_ids || []), ...(conf.memory_id ? [conf.memory_id] : [])].some((id) => {
      const node = nodeById.get(id);
      return node && filterByTopic(node);
    });
  const flaggedConflicts = (activeView.flagged_conflicts || []).filter(conflictMatchesTopic);
  const activeDecisionIds = new Set(retainedDecisions.map((d) => d.memory_id));
  const activeDecisionEvidenceIds = new Set(
    retainedDecisions.flatMap((d) => d.evidence_event_ids || []),
  );
  const activeTopicIds = new Set(
    retainedTopicsAndTasks
      .filter((t) => t.kind === "topic")
      .map((t) => String(t.memory_id || "").replace(/^topic:/, "")),
  );

  const scoreConflictRelevance = (conf) => {
    const memIds = conf.memory_ids || [];
    const evIds = conf.evidence_event_ids || [];
    let linkedDecision = 0;
    let linkedTopic = 0;
    let latestTs = "";
    for (const id of memIds) {
      if (activeDecisionIds.has(id) || String(id).startsWith("decision:")) {
        linkedDecision = 1;
      }
      const node = nodeById.get(id);
      if (node) {
        if (
          node.topic_id &&
          (activeTopicIds.has(node.topic_id) || node.topic_id)
        ) {
          linkedTopic = 1;
        }
        const ts = String(node.timestamp || "");
        if (ts > latestTs) latestTs = ts;
      }
    }
    if (!linkedDecision) {
      for (const evId of evIds) {
        if (activeDecisionEvidenceIds.has(evId)) {
          linkedDecision = 1;
          break;
        }
      }
    }
    return {
      linkedDecision,
      linkedTopic,
      latestTs,
      evidenceCount: evIds.length,
      isEdge: String(conf.conflict_id || "").startsWith("conf:") ? 1 : 0,
    };
  };

  const unresolvedConflicts = [...(activeView.unresolved || [])].filter(conflictMatchesTopic).sort(
    (a, b) => {
      const sa = scoreConflictRelevance(a);
      const sb = scoreConflictRelevance(b);
      if (sb.linkedDecision !== sa.linkedDecision) {
        return sb.linkedDecision - sa.linkedDecision;
      }
      if (sb.linkedTopic !== sa.linkedTopic) {
        return sb.linkedTopic - sa.linkedTopic;
      }
      if (sb.latestTs !== sa.latestTs) {
        return sb.latestTs.localeCompare(sa.latestTs);
      }
      if (sb.evidenceCount !== sa.evidenceCount) {
        return sb.evidenceCount - sa.evidenceCount;
      }
      if (sb.isEdge !== sa.isEdge) {
        return sb.isEdge - sa.isEdge;
      }
      return String(a.conflict_id || "").localeCompare(
        String(b.conflict_id || ""),
      );
    },
  );

  const isLargeActiveStore =
    retainedDecisions.length + unresolvedConflicts.length > 20;
  const maxPerSection = isLargeActiveStore && budgetChars <= 5000 ? 4 : Infinity;

  const lines = [];
  lines.push("## Memory-TCG Consolidated Context (Active Generation)");
  lines.push(
    `- Generation: \`${activeView.graph_generation_id}\` | Proposal: \`${activeView.proposal_id}\` | Watermark: \`${activeView.watermark_event_id || "none"}\` | Unresolved: ${unresolvedConflicts.length} | Flagged Conflicts: ${flaggedConflicts.length}`,
  );
  if (suppressedTechnicalIds.length) lines.push(`- Technical fragments suppressed: ${suppressedTechnicalIds.length}`);

  const includedIds = [];
  const omittedIds = [];

  const appendSectionItem = (
    id,
    lineText,
    sectionCount = 0,
    sectionCap = maxPerSection,
    sectionHeader = null,
  ) => {
    if (sectionCount >= sectionCap) {
      omittedIds.push(id);
      return false;
    }
    const currentLen = lines.join("\n").length;
    const textToPush =
      isLargeActiveStore && lineText.length > 200
        ? `${lineText.slice(0, 197)}...`
        : lineText;
    const headerLen =
      sectionCount === 0 && sectionHeader ? sectionHeader.length + 2 : 0;
    if (
      budgetChars > 0 &&
      currentLen + headerLen + textToPush.length + 80 > budgetChars
    ) {
      omittedIds.push(id);
      return false;
    }
    if (sectionCount === 0 && sectionHeader) {
      lines.push("");
      lines.push(sectionHeader);
    }
    lines.push(textToPush);
    includedIds.push(id);
    return true;
  };

  if (retainedDecisions.length > 0) {
    let secAdded = 0;
    for (const dec of retainedDecisions) {
      const evStr = (dec.evidence_event_ids || []).slice(0, 3).join(", ");
      if (
        appendSectionItem(
          dec.memory_id,
          `- **[ACTIVE]** \`${dec.memory_id}\`: ${dec.summary} *(evidence: ${evStr})*`,
          secAdded,
          maxPerSection,
          "### Active Decisions (Verified Explicit)",
        )
      ) {
        secAdded++;
      }
    }
  }

  if (subjectEpisodes.length > 0 || groupedDuplicateSubjects.length > 0) {
    let secAdded = 0;
    const subjCap = isLargeActiveStore && budgetChars <= 5000 ? 3 : Infinity;
    for (const ep of subjectEpisodes) {
      const evStr = (ep.evidence_event_ids || []).slice(0, 3).join(", ");
      const topicPrefix = ep.topic_id ? `[${ep.topic_id}] ` : "";
      if (
        appendSectionItem(
          ep.memory_id,
          `- **${topicPrefix}**\`${ep.memory_id}\`: ${ep.summary} *(evidence: ${evStr})*`,
          secAdded,
          subjCap,
          "### Consolidated Subjects Discussed (Assuntos Tratados)",
        )
      ) {
        secAdded++;
      }
    }
    let grpAdded = 0;
    const grpCap = isLargeActiveStore && budgetChars <= 5000 ? 2 : Infinity;
    for (const grp of groupedDuplicateSubjects) {
      const count = (grp.evidence_event_ids || []).length;
      const topicPrefix = grp.topic_id ? `[${grp.topic_id}] ` : "";
      if (
        appendSectionItem(
          grp.memory_id,
          `- **${topicPrefix}[RECORRENTE x${count}]** \`${grp.memory_id}\`: ${grp.summary}`,
          grpAdded,
          grpCap,
          secAdded === 0
            ? "### Consolidated Subjects Discussed (Assuntos Tratados)"
            : null,
        )
      ) {
        grpAdded++;
        secAdded++;
      }
    }
  }

  if (unresolvedConflicts.length > 0) {
    let secAdded = 0;
    const confCap = isLargeActiveStore && budgetChars <= 5000 ? 4 : Infinity;
    const shortId = (id) => {
      const s = String(id || "");
      if (!isLargeActiveStore) return s;
      if (s.startsWith("decision:") && s.length > 21) return s.slice(0, 21);
      if (s.length > 16 && /^[a-z]+:[0-9a-f]{16,}$/i.test(s)) {
        const [prefix, hex] = s.split(":");
        return `${prefix}:${hex.slice(0, 12)}`;
      }
      return s.length > 16 ? s.slice(0, 12) : s;
    };
    for (const conf of unresolvedConflicts) {
      const evStr = (conf.evidence_event_ids || [])
        .slice(0, 3)
        .map(shortId)
        .join(", ");
      const memStr = (conf.memory_ids || [])
        .slice(0, 3)
        .map(shortId)
        .join(", ");
      const nodeHints = (conf.memory_ids || [])
        .slice(0, 2)
        .map((id) => {
          const n = nodeById.get(id);
          return n && n.summary ? `"${n.summary.slice(0, 38).trim()}"` : null;
        })
        .filter(Boolean)
        .join(" vs ");
      const hintPart = nodeHints ? ` — ${nodeHints}` : "";
      if (
        appendSectionItem(
          conf.conflict_id,
          `- **[UNRESOLVED CONFLICT]** \`${shortId(conf.conflict_id)}\` (${conf.reason_code}): nodes [${memStr}]${hintPart} *(evidence: ${evStr})*`,
          secAdded,
          confCap,
          "### Unresolved Conflicts / Boundaries (Requires Attention)",
        )
      ) {
        secAdded++;
      }
    }
  }

  if (historicalDecisions.length > 0) {
    let secAdded = 0;
    for (const hist of historicalDecisions) {
      const evStr = (hist.evidence_event_ids || []).slice(0, 3).join(", ");
      const supBy = hist.superseded_by_id
        ? ` superseded by \`${hist.superseded_by_id}\``
        : "";
      if (
        appendSectionItem(
          hist.memory_id,
          `- **[HISTORICAL / SUPERSEDED]** \`${hist.memory_id}\`: ${hist.summary}${supBy} *(evidence: ${evStr})*`,
          secAdded,
          maxPerSection,
          "### Historical / Superseded Decisions (Do Not Treat as Current)",
        )
      ) {
        secAdded++;
      }
    }
  }

  if (retainedTopicsAndTasks.length > 0) {
    let secAdded = 0;
    const ttCap = isLargeActiveStore && budgetChars <= 5000 ? 3 : Infinity;
    for (const item of retainedTopicsAndTasks) {
      const evStr = (item.evidence_event_ids || []).slice(0, 3).join(", ");
      if (
        appendSectionItem(
          item.memory_id,
          `- **[${item.kind.toUpperCase()}]** \`${item.memory_id}\`: ${item.summary} *(evidence: ${evStr})*`,
          secAdded,
          ttCap,
          "### Active Topics & Tasks",
        )
      ) {
        secAdded++;
      }
    }
  }

  if (decisionSupportEpisodes.length > 0) {
    let secAdded = 0;
    const dsCap = isLargeActiveStore && budgetChars <= 5000 ? 2 : Infinity;
    for (const ep of decisionSupportEpisodes) {
      const evStr = (ep.evidence_event_ids || []).slice(0, 3).join(", ");
      if (
        appendSectionItem(
          ep.memory_id,
          `- \`${ep.memory_id}\`: ${ep.summary} *(evidence: ${evStr})*`,
          secAdded,
          dsCap,
          "### Supporting Evidence Episodes",
        )
      ) {
        secAdded++;
      }
    }
  }

  if (omittedIds.length > 0) {
    lines.push("");
    const previewOmitted = omittedIds.slice(0, 8).join(", ");
    const moreSuffix =
      omittedIds.length > 8 ? `, ... (+${omittedIds.length - 8} more)` : "";
    lines.push(
      `> *[Budget Truncated: ${omittedIds.length} item(s) omitted due to --budget-chars ${budgetChars}: ${previewOmitted}${moreSuffix}]*`,
    );
  }

  const includedSet = new Set(includedIds);
  return {
    status: "OK",
    mode: "active",
    active_generation_id: activeView.graph_generation_id,
    proposal_id: activeView.proposal_id,
    watermark_event_id: activeView.watermark_event_id,
    retained_decisions: retainedDecisions.filter((x) => includedSet.has(x.memory_id)),
    retained_topics_and_tasks: retainedTopicsAndTasks.filter((x) => includedSet.has(x.memory_id)),
    supporting_episodes: decisionSupportEpisodes.filter((x) => includedSet.has(x.memory_id)),
    historical_decisions: historicalDecisions.filter((x) => includedSet.has(x.memory_id)),
    consolidated_subjects: subjectEpisodes.filter((x) => includedSet.has(x.memory_id)),
    grouped_duplicates: groupedDuplicateSubjects.filter((x) => includedSet.has(x.memory_id)),
    unresolved_conflicts: unresolvedConflicts.filter((x) => includedSet.has(x.conflict_id)),
    suppressed_technical_memory_ids: suppressedTechnicalIds,
    included_memory_ids: includedIds,
    omitted_memory_ids: omittedIds,
    markdown: lines.join("\n"),
  };
}

function main() {
  const { subcommand, positional, flags } = parseCliArgs(process.argv.slice(2));
  const workspaceRoot = flags.workspace || process.cwd();
  const asJson = Boolean(flags.json);

  try {
    let result;
    switch (subcommand) {
      case "status":
        result = cmdStatus(workspaceRoot);
        break;
      case "sleep":
      case "sonhar":
      case "dream":
        result = cmdSleep(workspaceRoot, {
          mode: flags.mode || "shadow",
          seed: flags.seed,
          budget: flags.budget,
          maxNodes: flags["max-nodes"],
          maxEdges: flags["max-edges"],
        });
        break;
      case "inspect":
        result = cmdInspect(
          workspaceRoot,
          flags["proposal-id"] || positional[0] || "latest",
        );
        break;
      case "diff":
        result = cmdDiff(
          workspaceRoot,
          flags["proposal-id"] || positional[0] || "latest",
        );
        break;
      case "verify":
        result = cmdVerify(workspaceRoot);
        break;
      case "prepare-accept":
        result = cmdPrepareAccept(
          workspaceRoot,
          flags["proposal-id"] || positional[0] || "latest",
        );
        break;
      case "prepare-rollback":
        result = cmdPrepareRollback(
          workspaceRoot,
          flags["generation-id"] || positional[0] || "previous",
          flags.reason || "",
        );
        break;
      case "reconstruct-from-ledger":
        result = cmdReconstructFromLedger(workspaceRoot);
        break;
      case "context":
        result = cmdContext(workspaceRoot, {
          topicId: flags["topic-id"] || null,
          budgetChars: flags["budget-chars"] || 4000,
        });
        break;
      default:
        throw new MemoryTcgError(
          "UNKNOWN_SUBCOMMAND",
          `Unknown memory subcommand: ${subcommand}`,
        );
    }

    if (asJson) {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    } else {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    }
    process.exitCode = 0;
  } catch (err) {
    const errorPayload = {
      status: "ERROR",
      error_code: err && err.code ? err.code : "INTERNAL_ERROR",
      message: err && err.message ? err.message : String(err),
      details: err && err.details ? err.details : null,
    };
    if (asJson) {
      process.stdout.write(`${JSON.stringify(errorPayload, null, 2)}\n`);
    } else {
      process.stderr.write(
        `[CONV-MEMORY][${errorPayload.error_code}] ${errorPayload.message}\n`,
      );
      process.stdout.write(`${JSON.stringify(errorPayload, null, 2)}\n`);
    }
    process.exitCode = 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
