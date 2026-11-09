import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
BOOT=ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'
SYNC=Path(os.environ.get('CONV_SYNC_UNDER_TEST', ROOT/'.conversation-esaa/bin/conv-sync.ps1'))
class DecideFailClosed(unittest.TestCase):
 def test_decide_and_accept_do_not_grow_invalid_ledger(self):
  with tempfile.TemporaryDirectory(prefix='ps04-decide-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(BOOT),'-WorkspaceRoot',tmp,'-SkipAgentIntegrations'],check=True,capture_output=True,timeout=60)
   ledger=Path(tmp)/'.conversation-esaa/activity.jsonl'
   broken={'event_id':'bad-decision','ts':'2026-01-01T00:00:00Z','event':'decision.recorded','actor':'assistant','agent_id':'codex','workspace_root':tmp,'rationale':'x'}
   original=(json.dumps(broken,ensure_ascii=False)+'\n').encode()
   ledger.write_bytes(original)
   def call(*args):
    return subprocess.run([PW,'-NoProfile','-File',str(SYNC),*args,'-WorkspaceRoot',tmp],capture_output=True,text=True,timeout=60)
   r=call('decide','-DecisionText','should not append','-DecisionAgent','codex')
   self.assertNotEqual(r.returncode,0)
   self.assertEqual(ledger.read_bytes(),original)
   r=call('memory-accept','-MemoryProposalId','latest')
   self.assertNotEqual(r.returncode,0)
   self.assertEqual(ledger.read_bytes(),original)
   r=call('task','-TaskAction','create','-TaskTitle','should not append','-CuratorAgent','codex')
   self.assertNotEqual(r.returncode,0)
   self.assertEqual(ledger.read_bytes(),original)
 def test_valid_decide_still_appends(self):
  with tempfile.TemporaryDirectory(prefix='ps04-ok-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(BOOT),'-WorkspaceRoot',tmp,'-SkipAgentIntegrations'],check=True,capture_output=True,timeout=60)
   r=subprocess.run([PW,'-NoProfile','-File',str(SYNC),'decide','-DecisionText','Adopt digest+path','-DecisionAgent','codex','-WorkspaceRoot',tmp],capture_output=True,text=True,timeout=60)
   self.assertEqual(r.returncode,0,r.stdout+r.stderr)
   ledger=Path(tmp)/'.conversation-esaa/activity.jsonl'
   events=[json.loads(ln) for ln in ledger.read_text(encoding='utf-8').splitlines() if ln.strip()]
   self.assertTrue(any(e.get('event')=='decision.recorded' for e in events))
if __name__=='__main__': unittest.main()
