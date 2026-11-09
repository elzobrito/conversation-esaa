// Instructionist baseline: most recent explicit decision per topic and key.
// Episodes never replace decisions; no conflict detector is assumed.
export function runAuthorityBaseline(bundle) {
  const ordered = [...bundle.facts].sort((a, b) =>
    String(a.timestamp || "").localeCompare(String(b.timestamp || "")) || a.id.localeCompare(b.id));
  const slots = new Map();
  for (const fact of ordered) {
    if (fact.kind !== "decision" || fact.authority !== "explicit_decision") continue;
    const key = fact.conflict_key ? `${fact.topic_id || ""}|${fact.conflict_key}` : `id:${fact.id}`;
    if (fact.supersedes_id && !fact.conflict_key) slots.delete(`id:${fact.supersedes_id}`);
    slots.set(key, fact);
  }
  const active = [...slots.values()];
  return { active_ids: new Set(active.map(f => f.id)),
    provenance_by_id: new Map(active.map(f => [f.id, [...f.evidence_event_ids]])),
    flagged_conflict_pairs: [] };
}
