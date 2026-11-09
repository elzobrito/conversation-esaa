"""RRR v1.3: v1.2 arms plus a 20% conflict-quota fit on C (arm CQ)."""
import hashlib, json, pathlib, subprocess, sys
import tiktoken

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENC = tiktoken.get_encoding('cl100k_base')
SEEDS = (11, 29, 42, 73, 101)
BUDGETS = (512, 1024, 4096)
ARMS = ('A', 'B', 'BP', 'C', 'CP', 'CN', 'D1', 'D2')
CONFLICT_QUOTA = 0.20


def encode_item(obj):
    text = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n'
    return text, len(ENC.encode(text))


def greedy(items, limit):
    chosen, used = [], 0
    for item in items:
        if used + item['cost'] <= limit:
            chosen.append(item)
            used += item['cost']
    return chosen, used


def fit_quota(items, limit, frac=CONFLICT_QUOTA):
    """Reserve frac of the budget for conflicts in proposal order; leftover goes to actives, then remaining conflicts."""
    reserved = int(limit * frac)
    actives = [i for i in items if i['kind'] != 'conflict']
    conflicts = [i for i in items if i['kind'] == 'conflict']
    chosen_c, used_c = greedy(conflicts, reserved)
    chosen_a, used_a = greedy(actives, limit - used_c)
    leftover = limit - used_a - used_c
    taken = {id(c) for c in chosen_c}
    remaining_c = [c for c in conflicts if id(c) not in taken]
    extra_c, used_e = greedy(remaining_c, leftover)
    return chosen_a + chosen_c + extra_c, used_a + used_c + used_e


def metrics(chosen, used, d, facts, expected_dec, expected_conflicts, active_set, contaminant, limit, arm, seed, n_facts):
    selected = {c['id'] for c in chosen if c['kind'] == 'id' and c['is_active']}
    predicted = {tuple(c['pair']) for c in chosen if c['kind'] == 'conflict'}
    matches = len(predicted & expected_conflicts)
    fp = len(predicted - expected_conflicts)
    fn = len(expected_conflicts - predicted)
    raw_predicted = {tuple(sorted(pair)) for pair in d['conflicts']}
    raw_tp = len(raw_predicted & expected_conflicts)
    raw_fp = len(raw_predicted - expected_conflicts)
    raw_fn = len(expected_conflicts - raw_predicted)
    hits = sum(len(set(d['provenance'].get(x, [])) & set(e)) for x, e in d['truth']['decisions'].items() if x in selected)
    total = sum(len(e) for e in d['truth']['decisions'].values())
    returned_truth = selected & expected_dec
    returned_evidence_total = sum(len(d['truth']['decisions'][x]) for x in returned_truth)
    complete_count = sum(set(d['truth']['decisions'][x]).issubset(set(d['provenance'].get(x, []))) for x in returned_truth)
    return {
        'facts': n_facts, 'seed': seed, 'arm': arm, 'budget': limit, 'tokens': used,
        'decision_recall': len(selected & expected_dec) / len(expected_dec),
        'pre_budget_decision_recall': len(active_set & expected_dec) / len(expected_dec),
        'pre_budget_conflict_f1': 2 * raw_tp / max(1, 2 * raw_tp + raw_fp + raw_fn),
        'pre_budget_conflict_tp': raw_tp, 'pre_budget_conflict_fp': raw_fp, 'pre_budget_conflict_fn': raw_fn,
        'historical_contamination': len(selected & contaminant) / max(1, len(contaminant)),
        'provenance_recall': hits / max(1, total),
        'conditional_provenance_recall': hits / returned_evidence_total if returned_evidence_total else None,
        'complete_provenance_fraction': complete_count / len(returned_truth) if returned_truth else None,
        'conflict_precision': matches / (matches + fp) if matches + fp else None,
        'conflict_recall': matches / (matches + fn) if matches + fn else None,
        'conflict_f1': 2 * matches / max(1, 2 * matches + fp + fn),
        'conflict_tp': matches, 'conflict_fp': fp, 'conflict_fn': fn,
        'selected_decisions': len(selected & expected_dec),
        'pre_budget_selected_decisions': len(active_set & expected_dec),
        'pre_budget_selected_episodes': sum(facts[x]['kind'] == 'episode' for x in active_set),
        'elapsed_ms': round(d['analysis_ms'], 3), 'max_rss_kib': d['max_rss_kib'],
        'output_bytes': sum(len(c['text'].encode()) for c in chosen),
        'output_hash': hashlib.sha256(''.join(c['text'] for c in chosen).encode()).hexdigest(),
        'quota_frac': CONFLICT_QUOTA if arm == 'CQ' else None,
    }


def main(output):
    result = []
    for n in (5, 50, 200):
        for seed in SEEDS:
            for arm in ARMS:
                p = subprocess.run(
                    ['node', 'tests/memory/v12-worker.js', str(n), str(seed), arm],
                    cwd=ROOT, text=True, capture_output=True, check=True,
                )
                d = json.loads(p.stdout.splitlines()[0])
                facts = {f['id']: f for f in d['facts']}
                active_set = set(d['active_ids'])
                truth = d['truth']
                expected_dec = set(truth['decisions'])
                expected_conflicts = {tuple(sorted(x)) for x in truth['conflicts']}
                contaminant = set(truth['superseded']) | set(truth['echoes'])

                def candidate_id(x, active=True, provenance=None):
                    item = {'id': x, 'summary': facts[x]['summary'], 'evidence': (provenance or {}).get(x, [])}
                    text, cost = encode_item(item)
                    return {'kind': 'id', 'id': x, 'is_active': active, 'text': text, 'cost': cost}

                def candidate_conflict(pair):
                    pair = sorted(pair)
                    text, cost = encode_item({'conflict': pair})
                    return {'kind': 'conflict', 'pair': pair, 'text': text, 'cost': cost}

                common_ids = sorted(active_set, key=lambda x: (0 if facts[x]['kind'] == 'decision' else 1, x))
                common = [candidate_id(x, True, d['provenance']) for x in common_ids] + [
                    candidate_conflict(x) for x in d['conflicts']
                ]
                if arm == 'CN':
                    candidates = []
                    for entry in d['native_order']:
                        if entry['type'] == 'conflict':
                            candidates.append(candidate_conflict(entry['ids']))
                        elif entry['id'] in facts:
                            candidates.append(candidate_id(entry['id'], entry['id'] in active_set, d['provenance']))
                else:
                    candidates = common

                oracle_items = []
                for x in expected_dec:
                    text, cost = encode_item({'id': x, 'summary': facts[x]['summary'], 'evidence': []})
                    oracle_items.append({'kind': 'id', 'id': x, 'is_active': True, 'text': text, 'cost': cost})
                oracle_items.sort(key=lambda x: (x['cost'], x['id']))
                costs_by_id = {x['id']: x['cost'] for x in oracle_items}
                bound_applicable = all(
                    c['cost'] >= costs_by_id[c['id']]
                    for c in candidates if c['kind'] == 'id' and c['id'] in costs_by_id
                )

                for limit in BUDGETS:
                    chosen, used = greedy(candidates, limit)
                    row = metrics(
                        chosen, used, d, facts, expected_dec, expected_conflicts,
                        active_set, contaminant, limit, arm, seed, len(facts),
                    )
                    oracle_selected, oracle_cost = greedy(oracle_items, limit)
                    row['oracle_decision_recall'] = len(oracle_selected) / len(expected_dec)
                    row['oracle_tokens'] = oracle_cost
                    row['oracle_bound_applicable'] = bound_applicable
                    row['oracle_decisions'] = len(oracle_selected)
                    result.append(row)

                    if arm == 'C':
                        q_chosen, q_used = fit_quota(candidates, limit)
                        qrow = metrics(
                            q_chosen, q_used, d, facts, expected_dec, expected_conflicts,
                            active_set, contaminant, limit, 'CQ', seed, len(facts),
                        )
                        qrow['oracle_decision_recall'] = row['oracle_decision_recall']
                        qrow['oracle_tokens'] = oracle_cost
                        qrow['oracle_bound_applicable'] = bound_applicable
                        qrow['oracle_decisions'] = len(oracle_selected)
                        result.append(qrow)

    payload = {
        'schema': 'conv-rrr.v13.v1',
        'tokenizer': 'tiktoken 0.12.0 cl100k_base',
        'token_accounting': 'sum of independently tokenized canonical JSON lines; excludes chat framing',
        'oracle': 'exact maximum number of ground-truth decision stubs; no provenance or conflict ceiling',
        'native': 'production cmdContext full-order replay with a standardized token serializer; not exact production rendering',
        'conflict_quota': {
            'arm': 'CQ',
            'frac': CONFLICT_QUOTA,
            'base_arm': 'C',
            'ranking': 'proposal unresolved order (conflict_id); the implementation does not export a per-conflict confidence score',
            'policy': 'reserve floor(budget*frac) tokens for conflicts in that order; leftover fills actives, then remaining conflicts',
        },
        'limitations': [
            'synthetic templates',
            'same corpus across seeds',
            'simplified instructionist baselines B and BP',
            'CQ uses proposal order, not a learned confidence score',
            'no independent replication',
        ],
        'runs': result,
    }
    pathlib.Path(output).write_text(json.dumps(payload, indent=2) + '\n')


if __name__ == '__main__':
    main(sys.argv[1])
