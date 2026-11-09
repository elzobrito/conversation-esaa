import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
class AppendOnly(unittest.TestCase):
 def test_legacy_user_events_are_read_without_rewriting_and_foreign_roots_rejected(self):
  with tempfile.TemporaryDirectory(prefix='legacy-ledger-') as tmp, tempfile.TemporaryDirectory(prefix='other-ws-') as foreign:
   subprocess.run([PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-Agents','cursor'],check=True,capture_output=True)
   bin=Path(tmp)/'.conversation-esaa/bin';sync=bin/'conv-sync.ps1';shutil.copy2(os.environ.get('PS08_CANDIDATE',ROOT/'.conversation-esaa/bin/conv-sync.ps1'),sync)
   ledger=Path(tmp)/'.conversation-esaa/activity.jsonl'
   base={'ts':'2025-01-01T00:00:00Z','event':'conversation_turn','actor':'user','source':'cursor','source_session_id':'old','source_path':'cursor-hook','source_index':0,'summary':'legado','text':'legado'}
   old=({**base,'event_id':'legacy-a'},{**base,'event_id':'legacy-b','source_index':1,'agent_id':''})
   original=('\r\n'.join(json.dumps(e,ensure_ascii=False) for e in old)+'\r\n').encode();ledger.write_bytes(original)
   def call(*args): return subprocess.run([PW,'-NoProfile','-File',str(sync),*args,'-WorkspaceRoot',tmp],capture_output=True,text=True,timeout=50)
   r=call('verify');self.assertNotEqual(r.returncode,0);self.assertEqual(ledger.read_bytes(),original)
   r=call('sync-cursor','-CursorSessionId','new','-CursorRole','user','-CursorPrompt','new','-CursorSourceIndex','0');self.assertNotEqual(r.returncode,0);self.assertIn('missing',r.stdout+r.stderr);self.assertEqual(ledger.read_bytes(),original)
   foreign_event={**base,'event_id':'foreign','workspace_root':foreign,'agent_id':None};ledger.write_bytes(json.dumps(foreign_event).encode()+b'\n')
   before=ledger.read_bytes();r=call('verify');self.assertNotEqual(r.returncode,0);self.assertIn('another workspace',r.stdout+r.stderr);self.assertEqual(ledger.read_bytes(),before)
   r=call('sync-cursor','-CursorSessionId','bad','-CursorRole','user','-CursorPrompt','new');self.assertNotEqual(r.returncode,0);self.assertEqual(ledger.read_bytes(),before)
   invalid_decision={'event_id':'bad-decision','ts':'2025-01-01T00:00:00Z','event':'decision.recorded','actor':'assistant','agent_id':'codex','workspace_root':tmp,'rationale':'x'};broken=json.dumps(invalid_decision).encode()+b'\n';ledger.write_bytes(broken);r=call('sync-cursor','-CursorSessionId','bad','-CursorRole','user','-CursorPrompt','new');self.assertNotEqual(r.returncode,0);self.assertEqual(ledger.read_bytes(),broken)
   malformed=b'{invalid json}\n';ledger.write_bytes(malformed);r=call('sync-cursor','-CursorSessionId','bad','-CursorRole','user','-CursorPrompt','new');self.assertNotEqual(r.returncode,0);self.assertEqual(ledger.read_bytes(),malformed)
 def test_sync_preserves_prefix_with_optional_final_newline(self):
  for suffix in (b'',b'\n',b'\r',b'\r\n'):
   with self.subTest(suffix=suffix), tempfile.TemporaryDirectory(prefix='ledger-line-end-') as tmp:
    subprocess.run([PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-Agents','cursor'],check=True,capture_output=True)
    bin=Path(tmp)/'.conversation-esaa/bin';sync=bin/'conv-sync.ps1';ledger=Path(tmp)/'.conversation-esaa/activity.jsonl'
    old={'ts':'2025-01-01T00:00:00Z','event':'conversation_turn','actor':'user','source':'cursor','source_session_id':'old','source_path':'cursor-hook','source_index':0,'summary':'legado','text':'legado','event_id':'legacy','workspace_root':tmp,'agent_id': '' if suffix == b'\r' else None}
    prefix=json.dumps(old).encode()+suffix;ledger.write_bytes(prefix)
    def call(*args):return subprocess.run([PW,'-NoProfile','-File',str(sync),*args,'-WorkspaceRoot',tmp],capture_output=True,text=True,timeout=50)
    for cmd in ('project','verify'):
     r=call(cmd);self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertEqual(ledger.read_bytes(),prefix)
    r=call('sync-cursor','-CursorSessionId','new','-CursorRole','user','-CursorPrompt','new','-CursorSourceIndex','0');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    data=ledger.read_bytes();self.assertTrue(data.startswith(prefix));self.assertEqual(len(data.splitlines()),2);self.assertEqual(len([json.loads(line) for line in data.splitlines()]),2)
    r=call('verify');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    js="import {createWorkspaceSnapshot} from './src/memory/adapter/snapshot.js'; console.log(createWorkspaceSnapshot(process.argv[1]).factsBundle.facts.length)"
    r=subprocess.run(['node','--input-type=module','-e',js,tmp],cwd=ROOT,capture_output=True,text=True,timeout=30);self.assertEqual(r.returncode,0,r.stdout+r.stderr)

if __name__=='__main__': unittest.main()
