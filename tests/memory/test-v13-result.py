import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class V13ResultTest(unittest.TestCase):
    def test_report_invariants(self):
        payload = json.loads((ROOT / 'docs/qa/CONV-RRR-V13-OUTPUT.json').read_text())
        self.assertEqual(payload['schema'], 'conv-rrr.v13.v1')
        rows = payload['runs']
        # 3 scales × 5 seeds × (8 arms + CQ) × 3 budgets
        self.assertEqual(len(rows), 3 * 5 * 9 * 3)
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
            if r['arm'] != 'C':
                continue
            n = by[(r['facts'], r['seed'], r['budget'], 'CN')]
            self.assertEqual(r['pre_budget_decision_recall'], n['pre_budget_decision_recall'])
            self.assertEqual(r['pre_budget_conflict_f1'], n['pre_budget_conflict_f1'])
            bp = by[(r['facts'], r['seed'], r['budget'], 'BP')]
            self.assertEqual(bp['pre_budget_decision_recall'], 1)
            cq = by[(r['facts'], r['seed'], r['budget'], 'CQ')]
            self.assertEqual(cq['quota_frac'], 0.2)
            self.assertEqual(cq['pre_budget_conflict_tp'], r['pre_budget_conflict_tp'])
        small = by[(48, 42, 512, 'C')]
        larger = by[(48, 42, 1024, 'C')]
        self.assertEqual((small['conflict_tp'], small['conflict_fp']), (4, 1))
        self.assertEqual((larger['conflict_tp'], larger['conflict_fp']), (4, 5))
        self.assertEqual((larger['pre_budget_conflict_tp'], larger['pre_budget_conflict_fp']), (4, 5))
        mid = by[(480, 42, 1024, 'C')]
        self.assertEqual((mid['pre_budget_conflict_tp'], mid['pre_budget_conflict_fp'], mid['pre_budget_conflict_fn']), (40, 50, 0))
        big = by[(1920, 42, 1024, 'C')]
        self.assertEqual((big['pre_budget_conflict_tp'], big['pre_budget_conflict_fp'], big['pre_budget_conflict_fn']), (160, 200, 0))
        d1 = by[(48, 42, 1024, 'D1')]
        self.assertEqual(d1['decision_recall'], 0.4)
        self.assertEqual(by[(48, 42, 1024, 'C')]['decision_recall'], 1.0)
        # Quota must surface conflicts at 480/4096 where C has none.
        c4096 = by[(480, 42, 4096, 'C')]
        cq4096 = by[(480, 42, 4096, 'CQ')]
        self.assertEqual(c4096['conflict_tp'], 0)
        self.assertGreater(cq4096['conflict_tp'], 0)


if __name__ == '__main__':
    unittest.main()
