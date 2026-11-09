import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
class CursorLongMessage(unittest.TestCase):
 def test_long_unicode_prompt_through_hook_stdin(self):
  with tempfile.TemporaryDirectory(prefix='cursor-long-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-Agents','cursor'],capture_output=True,text=True,check=True)
   hook=Path(tmp)/'.conversation-esaa/bin/cursor-hook.ps1';ledger=Path(tmp)/'.conversation-esaa/activity.jsonl'
   text='início ñ\n'+'z'*200000+'\nfim ✓'
   payload={'conversation_id':'long-test','text':text}
   r=subprocess.run([PW,'-NoProfile','-File',str(hook),'-WorkspaceRoot',tmp,'-Event','afterAgentResponse'],input=json.dumps(payload,ensure_ascii=False),text=True,capture_output=True,timeout=60)
   self.assertEqual(r.returncode,0,r.stderr)
   events=[json.loads(x) for x in ledger.read_text().splitlines()]
   self.assertEqual(len(events),1);self.assertEqual(events[0]['text'],text)
   log=(Path(tmp)/'.conversation-esaa/cursor-hook.log').read_text();self.assertNotIn('fail_open',log)
   second={'conversation_id':'another-session','prompt':'Olá antes\nlinha dois'}
   r=subprocess.run([PW,'-NoProfile','-File',str(hook),'-WorkspaceRoot',tmp,'-Event','beforeSubmitPrompt'],input=json.dumps(second,ensure_ascii=False),text=True,capture_output=True,timeout=60)
   self.assertEqual(r.returncode,0,r.stderr); self.assertTrue(json.loads(r.stdout)['continue'])
   events=[json.loads(x) for x in ledger.read_text().splitlines()];self.assertEqual(events[-1]['text'],second['prompt'])
   cli=Path(tmp)/'.conversation-esaa/bin/conversation-esaa.ps1'
   conflict=subprocess.run([PW,'-NoProfile','-File',str(cli),'sync','--agent','cursor','--workspace',tmp,'-CursorRole','user','-CursorPrompt','x','-CursorPromptStdin'],input='x',capture_output=True,text=True,timeout=30)
   self.assertNotEqual(conflict.returncode,0)
   gnu=subprocess.run([PW,'-NoProfile','-File',str(cli),'sync','--agent','cursor','--workspace',tmp,'--cursor-role','user','--cursor-session-id','gnu-session','--cursor-prompt-stdin'],input='mensagem GNU',capture_output=True,text=True,timeout=30)
   self.assertEqual(gnu.returncode,0,gnu.stderr);self.assertIn('mensagem GNU',ledger.read_text())
   sync=Path(tmp)/'.conversation-esaa/bin/conv-sync.ps1';sync.rename(sync.with_suffix('.disabled'))
   r=subprocess.run([PW,'-NoProfile','-File',str(hook),'-WorkspaceRoot',tmp,'-Event','beforeSubmitPrompt'],input=json.dumps({'conversation_id':'bad','prompt':'x'}),text=True,capture_output=True,timeout=30)
   self.assertEqual(r.returncode,0);self.assertTrue(json.loads(r.stdout)['continue']);self.assertIn('fail_open',(Path(tmp)/'.conversation-esaa/cursor-hook.log').read_text())
if __name__=='__main__': unittest.main()
