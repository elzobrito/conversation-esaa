import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PW = shutil.which('pwsh') or str(Path.home() / '.local/bin/pwsh')
BOOT = ROOT / '.conversation-esaa/bin/conv-bootstrap.ps1'
SYNC = Path(os.environ.get('CONV_SYNC_UNDER_TEST', ROOT / '.conversation-esaa/bin/conv-sync.ps1'))


def _events(ledger):
    return [json.loads(ln) for ln in ledger.read_text(encoding='utf-8').splitlines() if ln.strip()]


class CuratedEventId(unittest.TestCase):
    def test_two_identical_decides_get_distinct_ids_and_verify(self):
        with tempfile.TemporaryDirectory(prefix='ps14-decide-') as tmp:
            subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations'],
                check=True, capture_output=True, timeout=60,
            )
            def decide():
                return subprocess.run(
                    [PW, '-NoProfile', '-File', str(SYNC), 'decide',
                     '-DecisionText', 'Same payload twice', '-DecisionAgent', 'codex',
                     '-WorkspaceRoot', tmp],
                    capture_output=True, text=True, timeout=60,
                )
            r1, r2 = decide(), decide()
            self.assertEqual(r1.returncode, 0, r1.stdout + r1.stderr)
            self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)
            ledger = Path(tmp) / '.conversation-esaa/activity.jsonl'
            ids = [e['event_id'] for e in _events(ledger) if e.get('event') == 'decision.recorded']
            self.assertEqual(len(ids), 2)
            self.assertEqual(len(set(ids)), 2)
            verify = subprocess.run(
                [PW, '-NoProfile', '-File', str(SYNC), 'verify', '-WorkspaceRoot', tmp],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_frozen_timestamp_still_allocates_unique_ids(self):
        with tempfile.TemporaryDirectory(prefix='ps14-frozen-') as tmp:
            subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations'],
                check=True, capture_output=True, timeout=60,
            )
            src = SYNC.read_text(encoding='utf-8')
            frozen = src.replace(
                'return $dto.ToString("yyyy-MM-dd\'T\'HH:mm:ss.fffK")',
                'return \'2026-01-01T00:00:00.000-03:00\'',
            )
            self.assertNotEqual(frozen, src)
            script = Path(tmp) / 'sync-frozen.ps1'
            script.write_text(frozen, encoding='utf-8')
            def decide():
                return subprocess.run(
                    [PW, '-NoProfile', '-File', str(script), 'decide',
                     '-DecisionText', 'Frozen collision', '-DecisionAgent', 'codex',
                     '-WorkspaceRoot', tmp],
                    capture_output=True, text=True, timeout=60,
                )
            r1, r2 = decide(), decide()
            self.assertEqual(r1.returncode, 0, r1.stdout + r1.stderr)
            self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)
            ledger = Path(tmp) / '.conversation-esaa/activity.jsonl'
            decisions = [e for e in _events(ledger) if e.get('event') == 'decision.recorded']
            self.assertEqual(len(decisions), 2)
            self.assertEqual({e['ts'] for e in decisions}, {'2026-01-01T00:00:00.000-03:00'})
            self.assertEqual(len({e['event_id'] for e in decisions}), 2)
            verify = subprocess.run(
                [PW, '-NoProfile', '-File', str(script), 'verify', '-WorkspaceRoot', tmp],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_source_uses_millis_and_disambiguation_suffix(self):
        text = SYNC.read_text(encoding='utf-8')
        self.assertIn("yyyy-MM-dd'T'HH:mm:ss.fffK", text)
        self.assertIn('"$basePayload|$n"', text)
        self.assertIn('after 1000 attempts', text)


if __name__ == '__main__':
    unittest.main()
