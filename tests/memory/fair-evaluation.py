"""Exploratory controlled-output evaluation; requires pinned tiktoken 0.12.0."""
import hashlib, json, pathlib, subprocess, sys, time
import tiktoken

root = pathlib.Path(__file__).resolve().parents[2]
enc = tiktoken.get_encoding("cl100k_base")
budget = 1024
out = []
for topics in (5, 50, 200):
    for seed in (11, 29, 42, 73, 101):
        for arm in ("A", "B", "C", "CP", "D1", "D2"):
            p = subprocess.run(["node", "tests/memory/fair-worker.js", str(topics), str(seed), arm], cwd=root, text=True, capture_output=True, check=True)
            d = json.loads(p.stdout.splitlines()[0]); facts = {x["id"]: x for x in d["facts"]}
            ids = sorted(d["active_ids"], key=lambda x: (0 if facts[x]["kind"] == "decision" else 1, x))
            candidates = [("id", x, json.dumps({"id": x, "summary": facts[x]["summary"], "evidence": d["provenance"].get(x, [])}, ensure_ascii=False, sort_keys=True)) for x in ids]
            candidates += [("conflict", pair, json.dumps({"conflict": sorted(pair)}, ensure_ascii=False, sort_keys=True)) for pair in d["conflicts"]]
            rendered = ""; selected = []; omitted = 0
            for typ, val, item in candidates:
                new = rendered + item + "\n"
                if len(enc.encode(new)) <= budget:
                    rendered = new; selected.append((typ, val))
                else: omitted += 1
            active = {v for t, v in selected if t == "id"}
            predicted = {tuple(sorted(v)) for t, v in selected if t == "conflict"}
            expected = {tuple(sorted(v)) for v in d["truth"]["conflicts"]}
            correct = len(predicted & expected); fp = len(predicted - expected); fn = len(expected - predicted)
            active_truth = set(d["truth"]["decisions"])
            selected_decisions = {x for x in active if facts[x]["kind"] == "decision"}
            contaminants = set(d["truth"]["superseded"]) | set(d["truth"]["echoes"])
            prov_hit = sum(len(set(d["provenance"].get(x, [])) & set(e)) for x, e in d["truth"]["decisions"].items() if x in active)
            prov_all = sum(len(e) for e in d["truth"]["decisions"].values())
            prov_returned = sum(len(d["provenance"].get(x, [])) for x in active_truth & active)
            out.append({"facts": d["facts_count"], "seed": seed, "arm": arm, "tokens": len(enc.encode(rendered)),
                "output_bytes": len(rendered.encode()), "omitted": omitted, "latency_ms": round(d["elapsed_ms"], 3),
                "max_rss_kib": d["max_rss_kib"], "decision_recall": len(active & active_truth) / len(active_truth),
                "decision_precision": len(selected_decisions & active_truth) / len(selected_decisions) if selected_decisions else 0,
                "target_decision_share": len(active & active_truth) / len(active) if active else 0,
                "historical_contamination": len(active & contaminants) / len(contaminants),
                "provenance_recall": prov_hit / prov_all if prov_all else 0,
                "provenance_precision": prov_hit / prov_returned if prov_returned else 0,
                "conflict_tp": correct, "conflict_fp": fp, "conflict_fn": fn,
                "conflict_f1": (2 * correct / (2 * correct + fp + fn)) if (2 * correct + fp + fn) else 1,
                "context_sha256": hashlib.sha256(rendered.encode()).hexdigest()})
report = {"schema": "conv-rrr.fair.v1", "tokenizer": "tiktoken 0.12.0 cl100k_base", "budget": budget,
          "selection": "decisions first, then ids and conflict pairs; identical adapter for all arms",
          "limitations": ["fixed synthetic templates", "seed varies sampling, not fixture", "one process per arm includes runtime overhead", "not Mem0"], "runs": out}
pathlib.Path(sys.argv[1]).write_text(json.dumps(report, indent=2) + "\n")
