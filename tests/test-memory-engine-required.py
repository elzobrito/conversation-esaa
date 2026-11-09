import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh'); SYNC=Path(os.environ.get('CONV_SYNC_UNDER_TEST',ROOT/'.conversation-esaa/bin/conv-sync.ps1'))
class MissingEngine(unittest.TestCase):
 def test_memory_events_require_engine_but_legacy_workspace_does_not(self):
  with tempfile.TemporaryDirectory(prefix='conv-missing-engine-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-SkipAgentIntegrations'],capture_output=True,check=True)
   # Isolated copy removes all engine lookup paths; real engine is untouched.
   s=SYNC.read_text();start=s.index('function Resolve-MemoryCliScriptForSync {');end=s.index('\nfunction Invoke-MemoryReconstructIfPresent',start)
   script=Path(tmp)/'sync-no-engine.ps1';script.write_text(s[:start]+'function Resolve-MemoryCliScriptForSync { return $null }\n'+s[end:])
   def run(command):return subprocess.run([PW,'-NoProfile','-File',str(script),command,'-WorkspaceRoot',tmp],capture_output=True,text=True)
   r=run('verify');self.assertEqual(r.returncode,0,r.stderr)
   e={'event_id':'memory-event','ts':'2026-01-01T00:00:00Z','event':'memory.consolidation.accepted','actor':'assistant','agent_id':'codex','workspace_root':tmp,'proposal_id':'p','snapshot_id':'s','graph_generation_id':'g','workspace_id':'w','active_digest':'d'}
   (Path(tmp)/'.conversation-esaa/activity.jsonl').write_text(json.dumps(e)+'\n')
   for command in ['verify','project']:
    r=run(command);self.assertNotEqual(r.returncode,0,command);self.assertIn('Memory-TCG',r.stderr)
   no_node={**os.environ,'PATH':'','CONV_ESAA_MEMORY_CLI':str(ROOT/'src/memory/adapter/cli.js')}
   for command in ['verify','project']:
    r=subprocess.run([PW,'-NoProfile','-File',str(SYNC),command,'-WorkspaceRoot',tmp],capture_output=True,text=True,env=no_node)
    self.assertNotEqual(r.returncode,0,command); self.assertIn('Node',r.stderr)
   fake=Path(tmp)/'broken-engine.js';fake.write_text('process.stderr.write("synthetic engine failure"); process.exit(1);')
   broken_env={**os.environ,'CONV_ESAA_MEMORY_CLI':str(fake)}
   for command in ['verify','project']:
    r=subprocess.run([PW,'-NoProfile','-File',str(SYNC),command,'-WorkspaceRoot',tmp],capture_output=True,text=True,env=broken_env)
    self.assertNotEqual(r.returncode,0,command)
if __name__=='__main__':unittest.main()
