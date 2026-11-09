import json, os, shutil, subprocess, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PW = shutil.which('pwsh') or str(Path.home() / '.local/bin/pwsh')
BOOT = ROOT / '.conversation-esaa/bin/conv-bootstrap.ps1'
SYNC = Path(os.environ.get('CONV_SYNC_UNDER_TEST', ROOT / '.conversation-esaa/bin/conv-sync.ps1'))


class SkipIfLockedOrphan(unittest.TestCase):
    def test_orphan_lock_is_reclaimed_even_with_skip_if_locked(self):
        with tempfile.TemporaryDirectory(prefix='ps03-orphan-') as tmp:
            subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations'],
                check=True, capture_output=True, timeout=60,
            )
            lock = Path(tmp) / '.conversation-esaa/run/conversation-esaa.lock'
            lock.parent.mkdir(parents=True, exist_ok=True)
            lock.write_text(json.dumps({
                'pid': 99999999,
                'command': 'stale-test',
                'started_at': '2026-01-01T00:00:00-03:00',
                'workspace_root': tmp,
            }) + '\n', encoding='utf-8')
            r = subprocess.run(
                [PW, '-NoProfile', '-File', str(SYNC), 'project', '-WorkspaceRoot', tmp, '-SkipIfLocked'],
                capture_output=True, text=True, timeout=60,
            )
            combined = r.stdout + r.stderr
            self.assertEqual(r.returncode, 0, combined)
            self.assertNotIn('pipeline lock busy', combined)
            self.assertRegex(combined, r'project: regenerated|reclaiming unheld pipeline lock')

    def test_live_lock_still_skips_with_skip_if_locked(self):
        with tempfile.TemporaryDirectory(prefix='ps03-live-') as tmp:
            subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations'],
                check=True, capture_output=True, timeout=60,
            )
            lock = Path(tmp) / '.conversation-esaa/run/conversation-esaa.lock'
            lock.parent.mkdir(parents=True, exist_ok=True)
            holder_script = rf'''
$ErrorActionPreference = 'Stop'
$lock = '{lock}'
$fs = [System.IO.FileStream]::new($lock, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {{
    Start-Sleep -Seconds 25
}} finally {{
    $fs.Dispose()
}}
'''
            holder = subprocess.Popen(
                [PW, '-NoProfile', '-Command', holder_script],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.time() + 5
                while time.time() < deadline:
                    if lock.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(lock.exists(), 'holder did not create lock')
                r = subprocess.run(
                    [PW, '-NoProfile', '-File', str(SYNC), 'project', '-WorkspaceRoot', tmp, '-SkipIfLocked'],
                    capture_output=True, text=True, timeout=30,
                )
                combined = r.stdout + r.stderr
                self.assertEqual(r.returncode, 0, combined)
                self.assertIn('pipeline lock busy', combined)
            finally:
                holder.terminate()
                try:
                    holder.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    holder.kill()


if __name__ == '__main__':
    unittest.main()
