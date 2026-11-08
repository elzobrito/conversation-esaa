import { createHash } from "node:crypto";

export const NORMALIZER_VERSION = "1.0.0";
export const ENGINE_VERSION = "0.1.0";

export const ALLOWED_FACT_KINDS = new Set([
  "episode",
  "decision",
  "topic",
  "task",
  "assertion",
  "constraint",
  "source",
]);

export const ALLOWED_DERIVED_RELATIONS = new Set([
  "topic_contains_event",
  "decision_supported_by_event",
  "task_related_to_topic",
  "explicit_supersedes",
  "duplicate_exact_content",
]);

export const ALLOWED_POSSIBLE_RELATIONS = new Set([
  "possibly_related",
  "possibly_duplicate",
  "possibly_contradicts",
  "possibly_supersedes",
]);

export const ALLOWED_EPISTEMIC_STATUS = new Set([
  "verified_explicit",
  "derived",
  "candidate",
  "unresolved",
]);

export const ALLOWED_VALIDITY_STATUS = new Set([
  "active",
  "superseded",
  "historical",
  "unknown",
]);

export class MemoryTcgError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "MemoryTcgError";
    this.code = code;
    this.details = details;
  }
}

export function normalizeUnicode(value) {
  if (typeof value !== "string") return "";
  return value.normalize("NFC").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

export function normalizeTextForDigest(value) {
  return normalizeUnicode(value).trim().replace(/\s+/g, " ");
}

const SECRET_PATTERNS = [
  /TEST-SECRET-DO-NOT-EXPOSE/gi,
  /\b(?:sk|pk|rk)_[A-Za-z0-9]{12,}\b/g,
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g,
  /\bBearer\s+[A-Za-z0-9._\-]{16,}\b/gi,
  /\b(?:api[_-]?key|secret|token|password)\s*[:=]\s*['"]?[A-Za-z0-9._\-]{8,}['"]?/gi,
];

export function redactSensitiveText(value) {
  let out = normalizeUnicode(value);
  for (const pattern of SECRET_PATTERNS) {
    out = out.replace(pattern, "[REDACTED]");
  }
  return out;
}

export function canonicalizeValue(value) {
  if (value === null || typeof value !== "object") {
    if (typeof value === "string") return normalizeUnicode(value);
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => canonicalizeValue(item));
  }
  const sortedKeys = Object.keys(value)
    .filter((k) => value[k] !== undefined)
    .sort();
  const out = {};
  for (const key of sortedKeys) {
    out[key] = canonicalizeValue(value[key]);
  }
  return out;
}

export function canonicalJson(value) {
  return JSON.stringify(canonicalizeValue(value));
}

export function sha256Hex(input) {
  const payload =
    typeof input === "string" ? normalizeUnicode(input) : canonicalJson(input);
  return createHash("sha256").update(payload, "utf8").digest("hex");
}

export function sha256Prefixed(input) {
  return `sha256:${sha256Hex(input)}`;
}

const SHA256_PREFIXED_RE = /^sha256:[a-f0-9]{64}$/;

export function isSha256Prefixed(value) {
  return typeof value === "string" && SHA256_PREFIXED_RE.test(value);
}

export function validateFactsBundle(bundle) {
  if (!bundle || typeof bundle !== "object" || Array.isArray(bundle)) {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "Facts bundle must be a non-null object",
    );
  }
  if (bundle.schema_version !== "memory-tcg.facts.v1") {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      `Unsupported facts schema_version: ${bundle.schema_version}`,
    );
  }
  if (!isSha256Prefixed(bundle.workspace_id)) {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "workspace_id must be a canonical sha256:<hex> digest without host paths",
    );
  }
  if (!isSha256Prefixed(bundle.source_snapshot_id)) {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "source_snapshot_id must be a canonical sha256:<hex> digest",
    );
  }
  if (
    bundle.watermark_event_id !== null &&
    (typeof bundle.watermark_event_id !== "string" ||
      bundle.watermark_event_id.trim() === "")
  ) {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "watermark_event_id must be a non-empty string or null",
    );
  }
  if (
    typeof bundle.normalizer_version !== "string" ||
    !bundle.normalizer_version.trim()
  ) {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "normalizer_version is required",
    );
  }
  if (!Array.isArray(bundle.facts) || !Array.isArray(bundle.relations)) {
    throw new MemoryTcgError(
      "UNSUPPORTED_FACT",
      "facts and relations must be arrays",
    );
  }

  const seenFactIds = new Set();
  for (const fact of bundle.facts) {
    if (!fact || typeof fact !== "object") {
      throw new MemoryTcgError("UNSUPPORTED_FACT", "Fact entry must be an object");
    }
    if (typeof fact.id !== "string" || !fact.id.trim()) {
      throw new MemoryTcgError("UNSUPPORTED_FACT", "Fact id must be non-empty");
    }
    if (seenFactIds.has(fact.id)) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Duplicate fact id: ${fact.id}`,
      );
    }
    seenFactIds.add(fact.id);

    if (!ALLOWED_FACT_KINDS.has(fact.kind)) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Unsupported fact kind '${fact.kind}' for ${fact.id}`,
      );
    }
    if (!ALLOWED_EPISTEMIC_STATUS.has(fact.epistemic_status)) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Invalid epistemic_status '${fact.epistemic_status}' for ${fact.id}`,
      );
    }
    if (!ALLOWED_VALIDITY_STATUS.has(fact.validity_status)) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Invalid validity_status '${fact.validity_status}' for ${fact.id}`,
      );
    }
    if (
      !Array.isArray(fact.evidence_event_ids) ||
      fact.evidence_event_ids.length === 0 ||
      fact.evidence_event_ids.some(
        (id) => typeof id !== "string" || !id.trim(),
      )
    ) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Fact '${fact.id}' must include at least one valid evidence_event_id`,
      );
    }
    if (
      fact.content_digest !== undefined &&
      !isSha256Prefixed(fact.content_digest)
    ) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Fact '${fact.id}' has invalid content_digest`,
      );
    }
  }

  for (const rel of bundle.relations) {
    if (!rel || typeof rel !== "object") {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        "Relation entry must be an object",
      );
    }
    if (
      typeof rel.source !== "string" ||
      !rel.source.trim() ||
      typeof rel.target !== "string" ||
      !rel.target.trim()
    ) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        "Relation requires non-empty source and target",
      );
    }
    if (!ALLOWED_DERIVED_RELATIONS.has(rel.relation)) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Unsupported relation '${rel.relation}' in facts bundle`,
      );
    }
    if (
      typeof rel.rule_id !== "string" ||
      !rel.rule_id.trim() ||
      typeof rel.rule_version !== "string" ||
      !rel.rule_version.trim()
    ) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Relation ${rel.source}->${rel.target} requires rule_id and rule_version`,
      );
    }
    if (
      !Array.isArray(rel.evidence_event_ids) ||
      rel.evidence_event_ids.length === 0 ||
      rel.evidence_event_ids.some((id) => typeof id !== "string" || !id.trim())
    ) {
      throw new MemoryTcgError(
        "UNSUPPORTED_FACT",
        `Relation ${rel.source}->${rel.target} requires non-empty evidence_event_ids`,
      );
    }
  }

  return true;
}
