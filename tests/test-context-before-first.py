import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'.conversation-esaa/bin'
SYNC=Path(os.environ.get('CONV_SYNC_UNDER_TEST', BIN/'conv-sync.ps1'))
class ContextBefore(unittest.TestCase):
 def test_before_first_and_later_events(self):
  with tempfile.TemporaryDirectory(prefix='conv-context-before-') as tmp:
   subprocess.run([PW,'-NoProfile','-File',str(BIN/'conv-bootstrap.ps1'),'-WorkspaceRoot',tmp,'-SkipAgentIntegrations'],capture_output=True,check=True)
   events=[]
   for i in range(3):
    events.append(dict(event_id=f'event-{i}',ts='2026-01-01T00:00:00Z',event='decision.recorded',actor='assistant',agent_id='codex',workspace_root=tmp,decision=f'synthetic {i}',rationale=''))
   (Path(tmp)/'.conversation-esaa/activity.jsonl').write_text('\n'.join(json.dumps(e) for e in events)+'\n')
   def invoke(before):
    r=subprocess.run([PW,'-NoProfile','-File',str(SYNC),'context','-WorkspaceRoot',tmp,'-ContextBefore',before,'-ContextJson'],capture_output=True,text=True)
    self.assertEqual(r.returncode,0,r.stderr)
    return json.loads(r.stdout)
   self.assertEqual(invoke('event-0'),[])
   later=invoke('event-2'); self.assertEqual([e['event_id'] for e in later],['event-0','event-1'])
if __name__=='__main__': unittest.main()
