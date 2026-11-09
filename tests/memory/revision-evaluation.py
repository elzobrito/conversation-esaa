"""RRR revision experiment: isolated workers, oracle, native order, three budgets."""
import hashlib, json, pathlib, subprocess, sys
import tiktoken

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENC = tiktoken.get_encoding('cl100k_base')
SEEDS = (11, 29, 42, 73, 101)
BUDGETS = (512, 1024, 4096)
ARMS = ('A', 'B', 'C', 'CP', 'CN', 'D1', 'D2')

def encode_item(obj):
    text = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n'
    return text, len(ENC.encode(text))

def main(output):
    result = []
    for n in (5, 50, 200):
      for seed in SEEDS:
        for arm in ARMS:
          p = subprocess.run(['node', 'tests/memory/revision-worker.js', str(n), str(seed), arm], cwd=ROOT, text=True, capture_output=True, check=True)
          d = json.loads(p.stdout.splitlines()[0]); facts = {f['id']: f for f in d['facts']}
          active_set = set(d['active_ids']); truth = d['truth']; expected_dec = set(truth['decisions'])
          expected_conflicts = {tuple(sorted(x)) for x in truth['conflicts']}
          def candidate_id(x, active=True, provenance=None):
              item = {'id': x, 'summary': facts[x]['summary'], 'evidence': (provenance or {}).get(x, [])}
              text, cost = encode_item(item)
              return {'kind': 'id', 'id': x, 'is_active': active, 'text': text, 'cost': cost}
          def candidate_conflict(pair):
              pair = sorted(pair); text, cost = encode_item({'conflict': pair})
              return {'kind': 'conflict', 'pair': pair, 'text': text, 'cost': cost}
          common_ids = sorted(active_set, key=lambda x: (0 if facts[x]['kind'] == 'decision' else 1, x))
          common = [candidate_id(x, True, d['provenance']) for x in common_ids] + [candidate_conflict(x) for x in d['conflicts']]
          if arm == 'CN':
              candidates = []
              for entry in d['native_order']:
                  if entry['type'] == 'conflict': candidates.append(candidate_conflict(entry['ids']))
                  elif entry['id'] in facts: candidates.append(candidate_id(entry['id'], entry['id'] in active_set, d['provenance']))
          else: candidates = common
          # The exact cardinality optimum for decision-only JSON records, under
          # additive per-record token accounting. Conflict and provenance coverage
          # have separate objectives and do not share this oracle ceiling.
          oracle = sorted((candidate_id(x) for x in expected_dec), key=lambda x: (x['cost'], x['id']))
          for limit in BUDGETS:
            def fit(items):
                chosen=[]; used=0
                for item in items:
                    if used + item['cost'] <= limit: chosen.append(item); used += item['cost']
                return chosen, used
            chosen, used = fit(candidates); selected = {c['id'] for c in chosen if c['kind']=='id' and c['is_active']}
            predicted = {tuple(c['pair']) for c in chosen if c['kind']=='conflict'}
            matches = len(predicted & expected_conflicts); fp = len(predicted - expected_conflicts); fn = len(expected_conflicts - predicted)
            raw_predicted = {tuple(sorted(pair)) for pair in d['conflicts']}
            raw_tp = len(raw_predicted & expected_conflicts); raw_fp = len(raw_predicted - expected_conflicts); raw_fn = len(expected_conflicts - raw_predicted)
            contaminant = set(truth['superseded']) | set(truth['echoes'])
            hits=sum(len(set(d['provenance'].get(x, [])) & set(e)) for x,e in truth['decisions'].items() if x in selected)
            total=sum(len(e) for e in truth['decisions'].values())
            oracle_selected, oracle_cost = fit(oracle)
            # Every evaluated true decision must cost at least its empty-evidence
            # oracle representation for the cardinality bound to apply.
            costs_by_id={x['id']: x['cost'] for x in oracle}
            bound_applicable=all(c['cost'] >= costs_by_id[c['id']] for c in candidates if c['kind']=='id' and c['id'] in costs_by_id)
            result.append({'facts':len(facts),'seed':seed,'arm':arm,'budget':limit,'tokens':used,
              'decision_recall':len(selected & expected_dec)/len(expected_dec),
              'pre_budget_decision_recall':len(active_set & expected_dec)/len(expected_dec),
              'pre_budget_conflict_f1':2*raw_tp/max(1,2*raw_tp+raw_fp+raw_fn),
              'historical_contamination':len(selected & contaminant)/max(1,len(contaminant)),
              'provenance_recall':hits/max(1,total),'conflict_f1':2*matches/max(1,2*matches+fp+fn),
              'conflict_tp':matches,'conflict_fp':fp,'conflict_fn':fn,
              'oracle_decision_recall':len(oracle_selected)/len(expected_dec),
              'oracle_tokens':oracle_cost,'oracle_bound_applicable':bound_applicable,
              'selected_decisions':len(selected & expected_dec),'oracle_decisions':len(oracle_selected),
              'pre_budget_selected_decisions':len(active_set & expected_dec),
              'pre_budget_selected_episodes':sum(facts[x]['kind']=='episode' for x in active_set),
              'elapsed_ms':round(d['analysis_ms'],3),'max_rss_kib':d['max_rss_kib'],
              'output_bytes':sum(len(c['text'].encode()) for c in chosen),
              'output_hash':hashlib.sha256(''.join(c['text'] for c in chosen).encode()).hexdigest()})
    payload={'schema':'conv-rrr.revision.v1','tokenizer':'tiktoken 0.12.0 cl100k_base',
      'token_accounting':'sum of independently tokenized canonical JSON lines; excludes chat framing',
      'oracle':'exact maximum number of ground-truth decision stubs; no provenance or conflict ceiling',
      'native':'production cmdContext full-order replay with a standardized token serializer; not exact production rendering',
      'limitations':['synthetic templates','same corpus across seeds','simplified instructionist B','no independent replication'], 'runs':result}
    pathlib.Path(output).write_text(json.dumps(payload,indent=2)+'\n')

if __name__ == '__main__': main(sys.argv[1])
