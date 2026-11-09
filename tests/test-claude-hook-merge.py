import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh'); CLI=Path(os.environ.get('CONV_CLI_UNDER_TEST',ROOT/'.conversation-esaa/bin/conversation-esaa.ps1'))
class ClaudeHookMerge(unittest.TestCase):
 def test_preserves_settings_and_other_hooks_is_idempotent_and_rejects_bad_json(self):
  with tempfile.TemporaryDirectory(prefix='claude-hook-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-SkipAgentIntegrations'],capture_output=True,check=True)
   d=Path(tmp)/'.claude';d.mkdir(exist_ok=True);file=d/'settings.json'
   original={'marker':'KEEP-ME','permissions':{'allow':['Read']},'hooks':{'Stop':[{'matcher':'x','hooks':[{'type':'command','command':'echo keep'}]}],'OtherEvent':[{'hooks':[{'type':'command','command':'echo other'}]}]}}
   original['hooks']['Stop'][0]['hooks'].append({'type':'command','command':f'echo {CLI} sync --agent claude && echo custom'})
   file.write_text(json.dumps(original),encoding='utf-8-sig'); file.chmod(0o600)
   def run():return subprocess.run([PW,'-NoProfile','-File',str(CLI),'enable-hooks','--agent','claude','--workspace',tmp],capture_output=True,text=True)
   r=run();self.assertEqual(r.returncode,0,r.stderr);result=json.loads(file.read_text())
   self.assertEqual(result['marker'],'KEEP-ME');self.assertEqual(result['permissions'],original['permissions']);self.assertEqual(result['hooks']['OtherEvent'],original['hooks']['OtherEvent']);self.assertEqual(result['hooks']['Stop'][0],original['hooks']['Stop'][0]); self.assertEqual(file.stat().st_mode & 0o777,0o600)
   for event in ['Stop','UserPromptSubmit','PreCompact']:
    self.assertEqual(sum('--agent claude' in h.get('command','') and h.get('command','').startswith(chr(34)) for g in result['hooks'][event] for h in g['hooks']),1)
   r=run();self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(file.read_text()),result)
   customized=json.loads(file.read_text()); customized['hooks']['PreCompact'][-1]['matcher']='CustomCondition'
   file.write_text(json.dumps(customized)); before=file.read_bytes(); r=run();self.assertNotEqual(r.returncode,0);self.assertEqual(file.read_bytes(),before)
   file.write_text('{bad json');before=file.read_bytes();r=run();self.assertNotEqual(r.returncode,0);self.assertEqual(file.read_bytes(),before)
   if os.name != 'nt':
    other=d/'other.json';other.write_text('{}');file.unlink();file.symlink_to(other)
    r=run();self.assertNotEqual(r.returncode,0);self.assertTrue(file.is_symlink());self.assertEqual(other.read_text(),'{}')
 def test_npm_install_then_enable_has_one_hook_per_event(self):
  node=shutil.which('node')
  if not node: self.skipTest('Node unavailable')
  with tempfile.TemporaryDirectory(prefix='claude-node-install-') as tmp:
   r=subprocess.run([node,str(ROOT/'src/cli.js'),'install','--workspace',tmp,'--agents','claude','--non-interactive'],capture_output=True,text=True,timeout=60)
   self.assertEqual(r.returncode,0,r.stderr)
   target=Path(tmp)/'.conversation-esaa/bin/conversation-esaa.ps1';shutil.copyfile(CLI,target)
   settings=Path(tmp)/'.claude/settings.json';before=json.loads(settings.read_text())
   custom={'type':'command','command':f'echo {target} sync --agent claude && echo custom'}
   before['hooks']['PreCompact'][0]['hooks'].append(custom);settings.write_text(json.dumps(before))
   r=subprocess.run([PW,'-NoProfile','-File',str(target),'enable-hooks','--agent','claude','--workspace',tmp],capture_output=True,text=True,timeout=30)
   self.assertEqual(r.returncode,0,r.stderr);after=json.loads(settings.read_text())
   for event in ['Stop','UserPromptSubmit','PreCompact']:
    canonical=[h for g in after['hooks'][event] for h in g['hooks'] if h.get('command','').startswith('"') and '--agent claude' in h.get('command','')]
    self.assertEqual(len(canonical),1,(event,canonical))
   self.assertIn(custom,[h for g in after['hooks']['PreCompact'] for h in g['hooks']])
if __name__=='__main__':unittest.main()
