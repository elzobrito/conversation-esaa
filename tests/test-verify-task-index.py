import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PW = shutil.which('pwsh') or str(Path.home() / '.local/bin/pwsh')
ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / '.conversation-esaa/bin'
SYNC = Path(os.environ.get('CONV_SYNC_UNDER_TEST', BIN / 'conv-sync.ps1'))

class VerifyTaskIndex(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='conv-verify-index-')
        cls.ws = Path(cls.temp.name)
        subprocess.run([PW, '-NoProfile', '-File', str(BIN / 'conv-bootstrap.ps1'), '-WorkspaceRoot', str(cls.ws), '-SkipAgentIntegrations'], check=True, capture_output=True)
    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
    def event(self, kind, ident, seq):
        e = dict(event_id=str(seq), ts='2026-01-01T00:00:00Z', event='task.'+kind, actor='assistant', workspace_root=str(self.ws), task_id=ident)
        if kind == 'created': e.update(title='synthetic', status='open')
        return json.dumps(e)
    def verify(self, lines):
        (self.ws / '.conversation-esaa/activity.jsonl').write_text('\n'.join(lines)+'\n', encoding='utf-8')
        return subprocess.run([PW, '-NoProfile', '-File', str(SYNC), 'verify', '-WorkspaceRoot', str(self.ws)], capture_output=True, text=True)
    def test_existing_and_future_creation_and_numeric_compatibility(self):
        for created, updated in [('CONV-001','conv-001'), (1,'01')]:
            for reverse in (False, True):
                with self.subTest(created=created, reverse=reverse):
                    lines=[self.event('created',created,1), self.event('updated',updated,2)]
                    if reverse: lines.reverse()
                    result=self.verify(lines)
                    self.assertEqual(result.returncode,0,result.stderr)
    def test_unknown_task_rejected(self):
        result=self.verify([self.event('updated','CONV-404',1)])
        self.assertNotEqual(result.returncode,0)
        self.assertIn('unknown task_id',result.stderr)
    def test_malformed_ledger_reports_first_failure(self):
        for lines, message in [(['{"event":"task.created"}'], "Task event missing 'event_id'"), (['{'], 'Invalid JSON at activity.jsonl line 1')]:
            with self.subTest(message=message):
                result=self.verify(lines)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(message,result.stderr)
if __name__ == '__main__': unittest.main()
