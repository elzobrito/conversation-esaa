import {
  accessSync,
  chmodSync,
  constants,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import path from "node:path";
import {
  MemoryTcgError,
  NORMALIZER_VERSION,
  normalizeTextForDigest,
  normalizeUnicode,
  redactSensitiveText,
  sha256Prefixed,
} from "../core/canonical.js";

export function assertNoSymlinkChain(targetPath, stopAtRoot) {
  const resolvedRoot = realpathSync(stopAtRoot);
  const rel = path.relative(resolvedRoot, path.resolve(targetPath));
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new MemoryTcgError(
      "UNSAFE_PATH",
      `Path escapes workspace root: ${targetPath}`,
    );
  }
  const parts = rel ? rel.split(path.sep) : [];
  let current = resolvedRoot;
  for (const part of parts) {
    current = path.join(current, part);
    try {
      const st = lstatSync(current);
      if (st.isSymbolicLink()) {
        throw new MemoryTcgError(
          "UNSAFE_PATH",
          `Symbolic link is forbidden in memory/activity path: ${current}`,
        );
      }
    } catch (err) {
      if (err instanceof MemoryTcgError) throw err;
      if (err && err.code === "ENOENT") continue;
      throw err;
    }
  }
}

export function hardenPrivatePath(targetPath, isDirectory = false) {
  if (process.platform === "win32") return;
  try {
    const st = lstatSync(targetPath);
    if (st.isSymbolicLink()) {
      throw new MemoryTcgError(
        "UNSAFE_PATH",
        `Refusing to chmod symbolic link: ${targetPath}`,
      );
    }
    chmodSync(targetPath, isDirectory ? 0o700 : 0o600);
  } catch (err) {
    if (err instanceof MemoryTcgError) throw err;
  }
}

export function ensurePrivateMemoryDirs(workspaceRoot) {
  if (!workspaceRoot || typeof workspaceRoot !== "string") {
    throw new MemoryTcgError("UNSAFE_PATH", "workspaceRoot is required");
  }
  const rootStat = lstatSync(workspaceRoot);
  if (rootStat.isSymbolicLink()) {
    throw new MemoryTcgError(
      "UNSAFE_PATH",
      "workspaceRoot must not be a symbolic link",
    );
  }
  const canonicalRoot = realpathSync(workspaceRoot);
  const convDir = path.join(canonicalRoot, ".conversation-esaa");
  const memoryDir = path.join(convDir, "memory");
  const shadowDir = path.join(memoryDir, "shadow");
  const generationsDir = path.join(memoryDir, "generations");
  const logsDir = path.join(memoryDir, "logs");

  assertNoSymlinkChain(convDir, canonicalRoot);
  assertNoSymlinkChain(memoryDir, canonicalRoot);

  for (const dir of [memoryDir, shadowDir, generationsDir, logsDir]) {
    assertNoSymlinkChain(dir, canonicalRoot);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    hardenPrivatePath(dir, true);
  }

  return {
    workspaceRoot: canonicalRoot,
    convDir,
    memoryDir,
    shadowDir,
    generationsDir,
    logsDir,
  };
}

function normalizePathForComparison(p) {
  if (!p || typeof p !== "string") return "";
  const cleaned = p.replace(/[\\/]+$/, "");
  try {
    return realpathSync(cleaned);
  } catch {
    return path.resolve(cleaned);
  }
}

function extractTimeBucket(ts) {
  if (typeof ts === "string" && ts.length >= 10) {
    const m = ts.match(/^(\d{4}-\d{2}-\d{2})/);
    if (m) return m[1];
  }
  return "unknown";
}

function extractConflictHint(event) {
  if (event.conflict_key && event.conflict_value) {
    return {
      conflict_key: String(event.conflict_key),
      conflict_value: String(event.conflict_value),
    };
  }
  const text = normalizeUnicode(
    event.text || event.summary || event.decision || "",
  );
  const dbMatch = text.match(
    /\b(?:banco(?:\s+de\s+dados)?\s+(?:oficial|adotado|escolhido|definitivo|principal)|(?:primary|official)\s+(?:database|db))(?:\s+(?:é|is)|(?:\s*(?:=|:|->)))\s*(postgresql|postgres|sqlite|mysql|mongodb|mariadb|redis|memcached|oracle|sqlserver|dynamodb|cassandra|cockroachdb)\b/i,
  );
  if (dbMatch) {
    const raw = dbMatch[1].toLowerCase();
    return {
      conflict_key: "primary_database",
      conflict_value: raw === "postgres" ? "postgresql" : raw,
    };
  }
  if (event.event === "decision.recorded") {
    const concMatch = text.match(/^concorr[eê]ncia(?:\s+cloud)?\s+(v\d+)\b/i);
    if (concMatch) {
      return {
        conflict_key: "backup_concurrency_policy",
        conflict_value: concMatch[1].toLowerCase(),
      };
    }
    if (/\bbloqueio\s+pr[eé]-cloud\b/i.test(text)) {
      return {
        conflict_key: "backup_cloud_gate",
        conflict_value: "blocked",
      };
    }
    if (/\bautorizo\s+execu[cç][aã]o\s+cloud\s+aceita\b/i.test(text)) {
      return {
        conflict_key: "backup_cloud_gate",
        conflict_value: "authorized",
      };
    }
    if (/\bn[aã]o\s+o\s+livro-centro\b/i.test(text)) {
      return {
        conflict_key: "editorial_active_focus",
        conflict_value: "arquivo-zero",
      };
    }
    if (
      /\bo\s+pr[oó]ximo\s+original\s+a\s+escrever\s+[eé](?:\s|$).*\blivro-centro\b/i.test(
        text,
      )
    ) {
      return {
        conflict_key: "editorial_active_focus",
        conflict_value: "livro-centro",
      };
    }
    const corrHandoff = text.match(
      /\bcorre[cç][aã]o\s+do\s+handoff\s+(20\d{2}-\d{2}-\d{2})\b/i,
    );
    if (corrHandoff) {
      return {
        conflict_key: `handoff_state_${corrHandoff[1]}`,
        conflict_value: "corrected",
      };
    }
    const baseHandoff = text.match(/^handoff\s+(20\d{2}-\d{2}-\d{2})\b/i);
    if (baseHandoff) {
      return {
        conflict_key: `handoff_state_${baseHandoff[1]}`,
        conflict_value: "initial",
      };
    }
  }
  return { conflict_key: null, conflict_value: null };
}

export function createWorkspaceSnapshot(workspaceRoot, options = {}) {
  if (!workspaceRoot || typeof workspaceRoot !== "string") {
    throw new MemoryTcgError("UNSAFE_PATH", "workspaceRoot is required");
  }
  const rootStat = lstatSync(workspaceRoot);
  if (rootStat.isSymbolicLink()) {
    throw new MemoryTcgError(
      "UNSAFE_PATH",
      "workspaceRoot cannot be a symbolic link",
    );
  }
  const canonicalRoot = realpathSync(workspaceRoot);
  const convDir = path.join(canonicalRoot, ".conversation-esaa");
  const activityPath = path.join(convDir, "activity.jsonl");

  assertNoSymlinkChain(convDir, canonicalRoot);
  assertNoSymlinkChain(activityPath, canonicalRoot);

  try {
    accessSync(activityPath, constants.R_OK);
  } catch {
    throw new MemoryTcgError(
      "NOT_READY",
      `activity.jsonl not found or unreadable at ${activityPath}`,
    );
  }

  const rawContent = readFileSync(activityPath, "utf8");
  const lines = normalizeUnicode(rawContent)
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

  const workspaceId = sha256Prefixed(`workspace:${canonicalRoot}`);
  const parsedEvents = [];
  let excludedExternalCount = 0;
  let excludedMemoryEventsCount = 0;

  for (let idx = 0; idx < lines.length; idx++) {
    let event;
    try {
      event = JSON.parse(lines[idx]);
    } catch {
      throw new MemoryTcgError(
        "INTEGRITY_FAILURE",
        `Invalid JSON in activity.jsonl at line ${idx + 1}`,
      );
    }

    if (event.workspace_root) {
      const eventRoot = normalizePathForComparison(String(event.workspace_root));
      if (eventRoot !== canonicalRoot) {
        excludedExternalCount++;
        continue;
      }
    }

    if (
      typeof event.event === "string" &&
      event.event.startsWith("memory.")
    ) {
      excludedMemoryEventsCount++;
      continue;
    }

    parsedEvents.push(event);
  }

  const seenSourceTurns = new Set();
  const dedupedEvents = [];
  for (const event of parsedEvents) {
    const hasSourceIdentity =
      event.source &&
      event.source_session_id &&
      event.source_index !== undefined &&
      event.source_index !== null &&
      event.actor;
    if (hasSourceIdentity) {
      const key = `${event.source}|${event.source_session_id}|${event.source_index}|${event.actor}`;
      if (seenSourceTurns.has(key)) continue;
      seenSourceTurns.add(key);
    }
    dedupedEvents.push(event);
  }

  let watermarkEventId = null;
  for (let i = dedupedEvents.length - 1; i >= 0; i--) {
    if (dedupedEvents[i].event_id) {
      watermarkEventId = String(dedupedEvents[i].event_id);
      break;
    }
  }

  const factsMap = new Map();
  const relations = [];
  const topicMembership = new Map();
  const decisionIndexById = new Map();
  const taskStateMap = new Map();
  const topicStateMap = new Map();

  for (const event of dedupedEvents) {
    const eid = event.event_id ? String(event.event_id) : null;
    if (!eid) continue;
    const evType = String(event.event || "conversation_turn");

    if (evType === "topic.created") {
      const tid = String(event.topic_id || "");
      if (!tid) continue;
      topicStateMap.set(tid, {
        id: tid,
        title: String(event.title || tid),
        summary: String(event.summary || event.title || tid),
        status: String(event.status || "active"),
        timestamp: event.ts ? String(event.ts) : null,
        evidence_event_ids: new Set([eid]),
        linked_event_ids: new Set(
          Array.isArray(event.event_ids) ? event.event_ids.map(String) : [],
        ),
      });
    } else if (evType === "topic.updated" || evType === "topic.closed") {
      const tid = String(event.topic_id || "");
      const t = topicStateMap.get(tid);
      if (t) {
        if (event.title) t.title = String(event.title);
        if (event.summary) t.summary = String(event.summary);
        if (evType === "topic.closed") t.status = "completed";
        else if (event.status) t.status = String(event.status);
        t.evidence_event_ids.add(eid);
      }
    } else if (evType === "topic.event.linked") {
      const tid = String(event.topic_id || "");
      const t = topicStateMap.get(tid);
      if (t) {
        t.evidence_event_ids.add(eid);
        const linked = Array.isArray(event.event_ids)
          ? event.event_ids
          : event.linked_event_id
            ? [event.linked_event_id]
            : [];
        for (const le of linked) {
          t.linked_event_ids.add(String(le));
          topicMembership.set(String(le), tid);
        }
      }
    } else if (
      evType === "task.created" ||
      evType === "task.updated" ||
      evType === "task.closed"
    ) {
      const taskId = String(event.task_id || "");
      if (!taskId) continue;
      if (!taskStateMap.has(taskId)) {
        taskStateMap.set(taskId, {
          id: `task:${taskId}`,
          raw_id: taskId,
          title: String(event.title || taskId),
          status: String(event.status || "open"),
          topic_id: event.topic_id ? String(event.topic_id) : null,
          timestamp: event.ts ? String(event.ts) : null,
          evidence_event_ids: new Set([eid]),
        });
      } else {
        const tk = taskStateMap.get(taskId);
        if (event.title) tk.title = String(event.title);
        if (evType === "task.closed") tk.status = "completed";
        else if (event.status) tk.status = String(event.status);
        if (event.topic_id) tk.topic_id = String(event.topic_id);
        tk.evidence_event_ids.add(eid);
      }
    }
  }

  for (const t of topicStateMap.values()) {
    for (const le of t.linked_event_ids) {
      if (!topicMembership.has(le)) {
        topicMembership.set(le, t.id);
      }
    }
  }

  for (const event of dedupedEvents) {
    const eid = event.event_id ? String(event.event_id) : null;
    if (!eid) continue;
    const evType = String(event.event || "conversation_turn");
    // Resolve memberships only after the first pass has discovered all topics.
    if (evType === "conversation_turn" || evType === "pre_compact_sync") {
      const eventTopics = [event.topic_id, ...(Array.isArray(event.topic_ids) ? event.topic_ids : [])].filter(Boolean);
      for (const tid of new Set(eventTopics.map(String))) {
        const topic = topicStateMap.get(tid);
        if (topic) topic.linked_event_ids.add(eid);
      }
    }
    const ts = event.ts ? String(event.ts) : null;
    const timeBucket = extractTimeBucket(ts);
    const directTopic = event.topic_id
      ? String(event.topic_id)
      : Array.isArray(event.topic_ids) && event.topic_ids.length > 0
        ? String(event.topic_ids[0])
        : topicMembership.get(eid) || null;

    if (evType === "conversation_turn" || evType === "pre_compact_sync") {
      const rawText = String(event.text || event.summary || "");
      const digest = sha256Prefixed(normalizeTextForDigest(rawText));
      const { conflict_key, conflict_value } = extractConflictHint(event);
      factsMap.set(eid, {
        id: eid,
        kind: "episode",
        timestamp: ts,
        topic_id: directTopic,
        time_bucket: timeBucket,
        actor: event.actor ? String(event.actor) : null,
        agent_id: event.agent_id ? String(event.agent_id) : null,
        summary: redactSensitiveText(String(event.summary || rawText.slice(0, 200))),
        text: redactSensitiveText(rawText),
        content_digest: digest,
        authority: "conversation_turn",
        epistemic_status: "verified_explicit",
        validity_status: "active",
        supersedes_id: null,
        conflict_key,
        conflict_value,
        evidence_event_ids: [eid],
      });
    } else if (evType === "decision.recorded") {
      const decText = String(event.decision || event.text || event.summary || "");
      const digest = sha256Prefixed(normalizeTextForDigest(decText));
      const decNodeId = `decision:${eid}`;
      decisionIndexById.set(eid, decNodeId);
      decisionIndexById.set(decNodeId, decNodeId);

      const relatedTurns = Array.isArray(event.related_turns)
        ? event.related_turns.map(String).filter(Boolean)
        : [];
      const evidenceIds = [...new Set([eid, ...relatedTurns])];

      let supersedesNodeId = null;
      const rawSupersedes =
        event.supersedes || event.supersedes_decision_id || null;
      if (rawSupersedes) {
        const supStr = String(rawSupersedes);
        supersedesNodeId = decisionIndexById.get(supStr) ||
          (supStr.startsWith("decision:") ? supStr : `decision:${supStr}`);
      }

      factsMap.set(eid, {
        id: eid,
        kind: "episode",
        timestamp: ts,
        topic_id: directTopic,
        time_bucket: timeBucket,
        actor: event.actor ? String(event.actor) : "assistant",
        agent_id: event.agent_id ? String(event.agent_id) : null,
        summary: redactSensitiveText(String(event.summary || decText)),
        text: redactSensitiveText(decText),
        content_digest: digest,
        authority: "explicit_decision",
        epistemic_status: "verified_explicit",
        validity_status: "active",
        supersedes_id: null,
        conflict_key: null,
        conflict_value: null,
        evidence_event_ids: [eid],
      });

      const { conflict_key: decConflictKey, conflict_value: decConflictValue } =
        extractConflictHint(event);

      const supersedesLinks = Array.isArray(event.supersedes_links)
        ? event.supersedes_links
        : [];
      for (const link of supersedesLinks) {
        if (!link || !link.source || !link.target) continue;
        const rawSrc = String(link.source);
        const rawTgt = String(link.target);
        const srcNodeId =
          decisionIndexById.get(rawSrc) ||
          (rawSrc.startsWith("decision:") ? rawSrc : `decision:${rawSrc}`);
        const tgtNodeId =
          decisionIndexById.get(rawTgt) ||
          (rawTgt.startsWith("decision:") ? rawTgt : `decision:${rawTgt}`);
        relations.push({
          source: srcNodeId,
          relation: "explicit_supersedes",
          target: tgtNodeId,
          rule_id: "explicit_supersedes_link_event",
          rule_version: "1.0.0",
          evidence_event_ids: [
            ...new Set([
              eid,
              rawSrc.replace(/^decision:/, ""),
              rawTgt.replace(/^decision:/, ""),
            ]),
          ].sort(),
        });
      }

      if (!event.link_only) {
        factsMap.set(decNodeId, {
          id: decNodeId,
          kind: "decision",
          timestamp: ts,
          topic_id: directTopic,
          time_bucket: timeBucket,
          actor: event.actor ? String(event.actor) : "assistant",
          agent_id: event.agent_id ? String(event.agent_id) : null,
          summary: redactSensitiveText(decText),
          text: redactSensitiveText(
            event.rationale ? `${decText} — ${event.rationale}` : decText,
          ),
          content_digest: digest,
          authority: "explicit_decision",
          epistemic_status: "verified_explicit",
          validity_status: "active",
          supersedes_id: supersedesNodeId,
          conflict_key: decConflictKey,
          conflict_value: decConflictValue,
          evidence_event_ids: evidenceIds,
        });

        relations.push({
          source: decNodeId,
          relation: "decision_supported_by_event",
          target: eid,
          rule_id: "explicit_decision_event",
          rule_version: "1.0.0",
          evidence_event_ids: [eid],
        });

        for (const relTurn of relatedTurns) {
          relations.push({
            source: decNodeId,
            relation: "decision_supported_by_event",
            target: relTurn,
            rule_id: "explicit_decision_related_turn",
            rule_version: "1.0.0",
            evidence_event_ids: [eid, relTurn],
          });
        }
      }
    }
  }

  for (const t of topicStateMap.values()) {
    const topicDigest = sha256Prefixed(normalizeTextForDigest(`${t.id}:${t.title}:${t.summary}`));
    factsMap.set(t.id, {
      id: t.id,
      kind: "topic",
      timestamp: t.timestamp,
      topic_id: t.id,
      time_bucket: extractTimeBucket(t.timestamp),
      actor: "assistant",
      agent_id: null,
      summary: redactSensitiveText(`${t.title}: ${t.summary}`),
      text: redactSensitiveText(t.summary),
      content_digest: topicDigest,
      authority: "curated_topic",
      epistemic_status: "verified_explicit",
      validity_status: t.status === "active" ? "active" : "historical",
      supersedes_id: null,
      conflict_key: null,
      conflict_value: null,
      evidence_event_ids: [...t.evidence_event_ids].sort(),
    });

    for (const linkedId of t.linked_event_ids) {
      relations.push({
        source: t.id,
        relation: "topic_contains_event",
        target: linkedId,
        rule_id: "explicit_topic_link",
        rule_version: "1.0.0",
        evidence_event_ids: [...t.evidence_event_ids, linkedId].sort(),
      });
    }
  }

  for (const tk of taskStateMap.values()) {
    const taskDigest = sha256Prefixed(normalizeTextForDigest(`${tk.raw_id}:${tk.title}`));
    factsMap.set(tk.id, {
      id: tk.id,
      kind: "task",
      timestamp: tk.timestamp,
      topic_id: tk.topic_id,
      time_bucket: extractTimeBucket(tk.timestamp),
      actor: "assistant",
      agent_id: null,
      summary: redactSensitiveText(tk.title),
      text: redactSensitiveText(tk.title),
      content_digest: taskDigest,
      authority: "curated_task",
      epistemic_status: "verified_explicit",
      validity_status: tk.status === "completed" ? "historical" : "active",
      supersedes_id: null,
      conflict_key: null,
      conflict_value: null,
      evidence_event_ids: [...tk.evidence_event_ids].sort(),
    });

    if (tk.topic_id && topicStateMap.has(tk.topic_id)) {
      relations.push({
        source: tk.id,
        relation: "task_related_to_topic",
        target: tk.topic_id,
        rule_id: "explicit_task_topic",
        rule_version: "1.0.0",
        evidence_event_ids: [...tk.evidence_event_ids].sort(),
      });
    }
  }

  const facts = [...factsMap.values()].sort((a, b) => a.id.localeCompare(b.id));
  const sortedRelations = relations.sort((a, b) =>
    `${a.source}|${a.relation}|${a.target}`.localeCompare(
      `${b.source}|${b.relation}|${b.target}`,
    ),
  );

  const sourceSnapshotId = sha256Prefixed({
    normalizer_version: NORMALIZER_VERSION,
    workspace_id: workspaceId,
    watermark_event_id: watermarkEventId,
    facts: facts.map((f) => ({
      id: f.id,
      kind: f.kind,
      content_digest: f.content_digest,
      validity_status: f.validity_status,
      evidence_event_ids: f.evidence_event_ids,
    })),
    relations: sortedRelations,
  });

  const factsBundle = {
    schema_version: "memory-tcg.facts.v1",
    workspace_id: workspaceId,
    source_snapshot_id: sourceSnapshotId,
    watermark_event_id: watermarkEventId,
    normalizer_version: NORMALIZER_VERSION,
    facts,
    relations: sortedRelations,
  };

  return {
    factsBundle,
    meta: {
      workspace_id: workspaceId,
      source_snapshot_id: sourceSnapshotId,
      watermark_event_id: watermarkEventId,
      event_count: dedupedEvents.length,
      excluded_external_workspace_count: excludedExternalCount,
      excluded_memory_events_count: excludedMemoryEventsCount,
    },
  };
}

export function verifySnapshotFreshness(
  workspaceRoot,
  expectedSnapshotId,
  expectedWatermarkEventId,
) {
  const current = createWorkspaceSnapshot(workspaceRoot);
  if (
    current.factsBundle.source_snapshot_id !== expectedSnapshotId ||
    current.factsBundle.watermark_event_id !== expectedWatermarkEventId
  ) {
    throw new MemoryTcgError(
      "STALE_PROPOSAL",
      "Workspace activity ledger has changed since proposal snapshot was created",
      {
        expected_snapshot_id: expectedSnapshotId,
        actual_snapshot_id: current.factsBundle.source_snapshot_id,
        expected_watermark: expectedWatermarkEventId,
        actual_watermark: current.factsBundle.watermark_event_id,
      },
    );
  }
  return current;
}
