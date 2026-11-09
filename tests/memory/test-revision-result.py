"""Checks the reported experimental invariants, not comparative hypotheses."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class RevisionResultTest(unittest.TestCase):
    def test_budget_and_oracle(self):
        report = json.loads((ROOT / 'docs/qa/CONV-RRR-REVISION-OUTPUT.json').read_text())
        rows = report['runs']
        self.assertEqual(len(rows), 3 * 5 * 7 * 3)
        for r in rows:
            self.assertLessEqual(r['tokens'], r['budget'])
            self.assertLessEqual(r['oracle_tokens'], r['budget'])
            self.assertTrue(r['oracle_bound_applicable'])
            self.assertLessEqual(r['decision_recall'], r['oracle_decision_recall'])
        by = {(r['facts'], r['seed'], r['budget'], r['arm']): r for r in rows}
        for r in rows:
            if r['arm'] != 'C': continue
            n = by[(r['facts'], r['seed'], r['budget'], 'CN')]
            self.assertEqual(r['pre_budget_decision_recall'], n['pre_budget_decision_recall'])
            self.assertEqual(r['pre_budget_conflict_f1'], n['pre_budget_conflict_f1'])

if __name__ == '__main__': unittest.main()
