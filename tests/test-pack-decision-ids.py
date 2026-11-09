import json, os, re, shutil, subprocess, tempfile, unittest
from pathlib import Path
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
PW = shutil.which('pwsh') or str(Path.home() / '.local/bin/pwsh')
BOOT = ROOT / '.conversation-esaa/bin/conv-bootstrap.ps1'
CLI = ROOT / '.conversation-esaa/bin/conversation-esaa.ps1'
SYNC = Path(os.environ.get('CONV_SYNC_UNDER_TEST', ROOT / '.conversation-esaa/bin/conv-sync.ps1'))


class PackDecisionIds(unittest.TestCase):
    def test_pack_lists_each_decision_id_once_with_active_memory(self):
        with tempfile.TemporaryDirectory(prefix='ps09-pack-') as tmp:
            subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations'],
                check=True, capture_output=True, timeout=60,
            )
            ledger = Path(tmp) / '.conversation-esaa/activity.jsonl'
            events = []
            for i in range(5):
                eid = f'dec-ps09-{i:03d}'
                events.append({
                    'schema_version': 'conversation-esaa.v1',
                    'event_id': eid,
                    'ts': f'2026-01-01T00:0{i}:00Z',
                    'event': 'decision.recorded',
                    'actor': 'assistant',
                    'agent_id': 'codex',
                    'workspace_root': tmp,
                    'decision': f'Adopt option {i} for PS-09 pack uniqueness',
                    'rationale': 'synthetic',
                    'related_turns': [],
                    'summary': f'Adopt option {i} for PS-09 pack uniqueness',
                    'text': f'Adopt option {i} for PS-09 pack uniqueness',
                })
            ledger.write_text(''.join(json.dumps(e) + '\n' for e in events), encoding='utf-8')
            for command in ('project', 'verify'):
                r = subprocess.run(
                    [PW, '-NoProfile', '-File', str(SYNC), command, '-WorkspaceRoot', tmp],
                    capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            sleep = subprocess.run(
                [PW, '-NoProfile', '-File', str(CLI), 'memory', 'sleep',
                 '--mode', 'shadow', '--seed', '42', '--workspace', tmp, '--json'],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(sleep.returncode, 0, sleep.stdout + sleep.stderr)
            proposal = json.loads(sleep.stdout)
            acc = subprocess.run(
                [PW, '-NoProfile', '-File', str(CLI), 'memory', 'accept',
                 '--proposal-id', proposal['proposal_id'], '--workspace', tmp, '--json'],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(acc.returncode, 0, acc.stdout + acc.stderr)
            subprocess.run(
                [PW, '-NoProfile', '-File', str(SYNC), 'project', '-WorkspaceRoot', tmp],
                check=True, capture_output=True, timeout=60,
            )
            pack = subprocess.run(
                [PW, '-NoProfile', '-File', str(SYNC), 'pack', '-WorkspaceRoot', tmp],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(pack.returncode, 0, pack.stdout + pack.stderr)
            ids = re.findall(r'decision:[A-Za-z0-9._-]+', pack.stdout)
            self.assertGreaterEqual(len(ids), 5, pack.stdout)
            counts = Counter(ids)
            dupes = {k: v for k, v in counts.items() if v > 1}
            self.assertEqual(dupes, {}, pack.stdout)
            self.assertIn('Get-HandoffWithoutMemoryProjection', SYNC.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
