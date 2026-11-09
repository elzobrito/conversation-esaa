import subprocess,tempfile,unittest
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[1]; PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
class IgnoreTest(unittest.TestCase):
 def test_generated_private_paths_are_ignored_and_bootstrap_idempotent(self):
  with tempfile.TemporaryDirectory(prefix='conv-ignore-') as tmp:
   subprocess.run(['git','init','-q',tmp],check=True)
   cmd=[PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-SkipAgentIntegrations']
   subprocess.run(cmd,capture_output=True,text=True,check=True)
   ignore=Path(tmp)/'.gitignore'; before=ignore.read_text(); subprocess.run(cmd,capture_output=True,text=True,check=True); self.assertEqual(ignore.read_text(),before)
   names=['activity.jsonl','decisions.md','tasks.json','topics.md','topics.json','codex-watch.log','antigravity-hook.log','cursor-hook.log','run/cursor-foo.txt','run/conversation-esaa.lock','activity.jsonl.bak-1','activity.jsonl.tmp-1']
   for name in names:
    with self.subTest(name=name):
     r=subprocess.run(['git','-C',tmp,'check-ignore','-q','--no-index',f'.conversation-esaa/{name}'])
     self.assertEqual(r.returncode,0)
   r=subprocess.run(['git','-C',tmp,'check-ignore','-q','--no-index','.claude/.settings.json.tmp-synthetic'])
   self.assertEqual(r.returncode,0)
if __name__=='__main__':unittest.main()
