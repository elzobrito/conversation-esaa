import json,os,shutil,subprocess,tempfile,unittest,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
class CursorIdentity(unittest.TestCase):
 def test_live_ambiguity_explicit_index_legacy_and_transcripts(self):
  with tempfile.TemporaryDirectory(prefix='cursor-identity-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-Agents','cursor'],capture_output=True,check=True)
   b=Path(tmp)/'.conversation-esaa/bin';ledger=Path(tmp)/'.conversation-esaa/activity.jsonl';hook=b/'cursor-hook.ps1';sync=b/'conv-sync.ps1'
   def hookcall(payload):
    r=subprocess.run([PW,'-NoProfile','-File',str(hook),'-WorkspaceRoot',tmp,'-Event','afterAgentResponse'],input=json.dumps(payload),capture_output=True,text=True,timeout=40);self.assertEqual(r.returncode,0,r.stderr)
   def call(*args):
    r=subprocess.run([PW,'-NoProfile','-File',str(sync),*args,'-WorkspaceRoot',tmp],capture_output=True,text=True,timeout=40);self.assertEqual(r.returncode,0,r.stderr);return r.stdout
   payload={'conversation_id':'sess','generation_id':'generation-a','text':'same'}
   hookcall(payload);hookcall(payload)
   events=[json.loads(x) for x in ledger.read_text().splitlines()];self.assertEqual(len(events),2);self.assertEqual([x['source_index'] for x in events],[0,1]);self.assertTrue(all(x['source_generation_id']=='generation-a' for x in events))
   hookcall({'conversation_id':'sess','text':'same'})
   for _ in range(2):call('sync-cursor','-CursorSessionId','explicit','-CursorRole','user','-CursorPrompt','fixed','-CursorSourceIndex','7')
   events=[json.loads(x) for x in ledger.read_text().splitlines()];self.assertEqual(len(events),4)
   old_id=hashlib.sha256(b'cursor|legacy-explicit|7|user|fixed').hexdigest()
   historic={'event_id':old_id,'ts':'2026-01-01T00:00:00Z','event':'conversation_turn','actor':'user','agent_id':None,'source':'cursor','source_session_id':'legacy-explicit','source_path':'cursor-hook','source_index':7,'workspace_root':tmp,'text':'fixed','summary':'fixed'}
   with ledger.open('a') as f:f.write(json.dumps(historic)+'\n')
   (Path(tmp)/'.conversation-esaa/sync-state.json').unlink();n=len(ledger.read_text().splitlines())
   call('sync-cursor','-CursorSessionId','legacy-explicit','-CursorRole','user','-CursorPrompt','fixed','-CursorSourceIndex','7');self.assertEqual(len(ledger.read_text().splitlines()),n)
   legacy={**events[0],'event_id':'legacy-distinct','text':'old distinct','summary':'old distinct','source_index':0}
   with ledger.open('a') as f:f.write(json.dumps(legacy)+'\n')
   out=json.loads(call('context','-ContextJson','-ContextLast','30'));self.assertEqual(len(out),6);self.assertIn('legacy-distinct',[e['event_id'] for e in out])
   transcript=Path(tmp)/'transcript.jsonl'
   hookcall({'conversation_id':'mixed-a','generation_id':'g','text':'response A'});transcript.write_text(json.dumps({'role':'assistant','text':'response A'})+'\n')
   for _ in range(2):call('sync-cursor','-CursorSessionId','mixed-a','-CursorTranscriptPath',str(transcript))
   out=json.loads(call('context','-ContextJson','-ContextLast','30'));self.assertEqual(sum(e['text']=='response A' for e in out),2)
   transcript.write_text(json.dumps({'role':'assistant','text':'response B'})+'\n')
   for _ in range(2):call('sync-cursor','-CursorSessionId','mixed-b','-CursorTranscriptPath',str(transcript))
   hookcall({'conversation_id':'mixed-b','generation_id':'g','text':'response B'})
   out=json.loads(call('context','-ContextJson','-ContextLast','30'));self.assertEqual(sum(e['text']=='response B' for e in out),2)
   transcript.write_text(json.dumps({'role':'assistant','text':'response C'})+'\n');call('sync-cursor','-CursorSessionId','mixed-c','-CursorTranscriptPath',str(transcript))
   call('sync-cursor','-CursorSessionId','mixed-c','-CursorRole','assistant','-CursorPrompt','response C','-CursorSourceIndex','0')
   out=json.loads(call('context','-ContextJson','-ContextLast','30'));self.assertEqual(sum(e['text']=='response C' for e in out),2)
if __name__=='__main__':unittest.main()
