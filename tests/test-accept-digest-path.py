import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
CLI=ROOT/'.conversation-esaa/bin/conversation-esaa.ps1'
BOOT=ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'
LIMIT=256*1024
class AcceptDigestPath(unittest.TestCase):
 def test_accept_line_at_480_facts_is_at_most_256kib_and_omits_blobs(self):
  with tempfile.TemporaryDirectory(prefix='js04-480-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(BOOT),'-WorkspaceRoot',tmp,'-Agents','codex'],check=True,capture_output=True,timeout=60)
   ledger=Path(tmp)/'.conversation-esaa/activity.jsonl'
   rows=[]
   for i in range(480):
    assistant=i%2==1
    rows.append(json.dumps({'event_id':f'turn-{i:04d}','ts':'2026-11-09T12:00:00Z','event':'conversation_turn','actor':'assistant' if assistant else 'user','agent_id':'codex' if assistant else None,'workspace_root':tmp,'summary':f'turno sintetico {i}','text':f'turno sintetico {i}'},ensure_ascii=False))
   ledger.write_text('\n'.join(rows)+'\n',encoding='utf-8')
   def run(*args,timeout=180):
    r=subprocess.run([PW,'-NoProfile','-File',str(CLI),*args,'--workspace',tmp],capture_output=True,text=True,timeout=timeout)
    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    return r
   sleep=json.loads(run('memory','sleep','--mode','shadow','--seed','42','--budget','all','--json').stdout)
   self.assertEqual(sleep.get('status'),'OK')
   accepted=json.loads(run('memory','accept','--proposal-id',sleep['proposal_id'],'--json').stdout)
   self.assertEqual(accepted.get('status'),'OK')
   acc_lines=[ln for ln in ledger.read_text(encoding='utf-8').splitlines() if '"memory.consolidation.accepted"' in ln]
   self.assertEqual(len(acc_lines),1)
   raw=acc_lines[0].encode('utf-8')
   self.assertLessEqual(len(raw),LIMIT,f'accept line {len(raw)} bytes exceeds 256 KiB')
   ev=json.loads(acc_lines[0])
   self.assertIsNone(ev.get('graph'))
   self.assertIsNone(ev.get('proposal'))
   self.assertIsNone(ev.get('active_view'))
   self.assertEqual(ev.get('artifact_encoding'),'digest_path.v1')
   self.assertTrue(ev['proposal_path'].startswith('.conversation-esaa/memory/shadow/'))
   self.assertTrue(ev['graph_path'].startswith('.conversation-esaa/memory/generations/'))
   self.assertTrue((Path(tmp)/ev['proposal_path']).is_file())
   self.assertTrue((Path(tmp)/ev['graph_path']).is_file())
   run('project');run('verify')
   shutil.rmtree(Path(tmp)/'.conversation-esaa/memory')
   missing=subprocess.run([PW,'-NoProfile','-File',str(CLI),'project','--workspace',tmp],capture_output=True,text=True,timeout=90)
   self.assertNotEqual(missing.returncode,0)
   self.assertIn('INTEGRITY_FAILURE',missing.stdout+missing.stderr)
if __name__=='__main__': unittest.main()
