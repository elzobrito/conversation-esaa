import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class V12ResultTest(unittest.TestCase):
    def test_report_invariants(self):
        rows = json.loads((ROOT / 'docs/qa/CONV-RRR-V12-OUTPUT.json').read_text())['runs']
        self.assertEqual(len(rows), 3 * 5 * 8 * 3)
        for r in rows:
            self.assertLessEqual(r['tokens'], r['budget'])
            self.assertTrue(r['oracle_bound_applicable'])
            self.assertLessEqual(r['decision_recall'], r['oracle_decision_recall'])
            if r['selected_decisions']:
                self.assertEqual(r['conditional_provenance_recall'], 1)
            else:
                self.assertIsNone(r['conditional_provenance_recall'])
        by = {(r['facts'], r['seed'], r['budget'], r['arm']): r for r in rows}
        for r in rows:
            if r['arm'] != 'C': continue
            n = by[(r['facts'], r['seed'], r['budget'], 'CN')]
            self.assertEqual(r['pre_budget_decision_recall'], n['pre_budget_decision_recall'])
            self.assertEqual(r['pre_budget_conflict_f1'], n['pre_budget_conflict_f1'])
            bp = by[(r['facts'], r['seed'], r['budget'], 'BP')]
            self.assertEqual(bp['pre_budget_decision_recall'], 1)
        small = by[(48, 42, 512, 'C')]
        larger = by[(48, 42, 1024, 'C')]
        self.assertEqual((small['conflict_tp'], small['conflict_fp']), (4, 1))
        self.assertEqual((larger['conflict_tp'], larger['conflict_fp']), (4, 5))

if __name__ == '__main__': unittest.main()
