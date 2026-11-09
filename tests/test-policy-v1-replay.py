import io,json,os,shutil,subprocess,tarfile,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
NEW=Path(os.environ.get('CONV_NEW_MEMORY_CLI', ROOT/'src/memory/adapter/cli.js'))
V1_COMMIT='b689548715c7e0fbb367648a9c3cc1e637dbf458'
class PolicyReplay(unittest.TestCase):
 def test_accepted_v1_reconstructs_with_v2_engine(self):
  with tempfile.TemporaryDirectory(prefix='rrr-v1-replay-') as tmp:
   tmp=Path(tmp); old=tmp/'old-engine';old.mkdir();ws=tmp/'workspace';ws.mkdir()
   archive=subprocess.check_output(['git','-C',str(ROOT),'archive',V1_COMMIT,'src/memory','package.json'])
   with tarfile.open(fileobj=io.BytesIO(archive)) as tar:tar.extractall(old)
   old_cli=old/'src/memory/adapter/cli.js';env1={**os.environ,'CONV_ESAA_MEMORY_CLI':str(old_cli)};env2={**os.environ,'CONV_ESAA_MEMORY_CLI':str(NEW)}
   def run(args,env):
    cli=ROOT/'.conversation-esaa/bin/conversation-esaa.ps1';r=subprocess.run([PW,'-NoProfile','-File',str(cli),*args,'--workspace',str(ws)],capture_output=True,text=True,env=env,timeout=90);self.assertEqual(r.returncode,0,r.stderr);return r.stdout
   run(['init'],env1);run(['decide','Synthetic durable decision','--agent','codex'],env1)
   pending=json.loads(run(['memory','sleep','--mode','shadow','--seed','42','--budget','all','--json'],env1))
   self.assertEqual(pending['status'],'OK')
   accepted=json.loads(run(['memory','accept','--proposal-id',pending['proposal_id'],'--json'],env2));self.assertEqual(accepted.get('status'),'OK')
   memory=ws/'.conversation-esaa/memory';before=json.loads((memory/'active.json').read_text());self.assertEqual(before['policy_version'],'rrr-policy.v1')
   context_before=json.loads(run(['memory','context','--budget-chars','4000','--json'],env1));(memory/'active.json').unlink();(memory/'manifest.json').unlink()
   run(['project'],env2);run(['verify'],env2)
   after=json.loads((memory/'active.json').read_text());self.assertEqual(after['active_digest'],before['active_digest']);self.assertEqual(after['graph_generation_id'],before['graph_generation_id']);self.assertEqual(after['policy_version'],'rrr-policy.v1')
   context_after=json.loads(run(['memory','context','--budget-chars','4000','--json'],env2));self.assertEqual(context_before['markdown'],context_after['markdown'])
   v2=json.loads(run(['sonhar','--accept','--seed','42','--budget','all','--json'],env2));self.assertTrue(v2.get('accepted'))
   current=json.loads((memory/'active.json').read_text());self.assertEqual(current['policy_version'],'rrr-policy.v2')
   rollback=json.loads(run(['memory','rollback','--generation-id','previous','--reason','synthetic replay test','--json'],env2));self.assertEqual(rollback['status'],'OK')
   restored=json.loads((memory/'active.json').read_text());self.assertEqual(restored['active_digest'],before['active_digest']);self.assertEqual(restored['policy_version'],'rrr-policy.v1');run(['verify'],env2)
   pending2=json.loads(run(['memory','sleep','--mode','shadow','--seed','42','--budget','all','--json'],env1))
   run(['decide','A genuinely later synthetic decision','--agent','codex'],env2)
   cli=ROOT/'.conversation-esaa/bin/conversation-esaa.ps1'
   rejected=subprocess.run([PW,'-NoProfile','-File',str(cli),'memory','accept','--proposal-id',pending2['proposal_id'],'--workspace',str(ws),'--json'],capture_output=True,text=True,env=env2,timeout=90)
   self.assertNotEqual(rejected.returncode,0);self.assertIn('STALE_PROPOSAL',rejected.stdout+rejected.stderr)
if __name__=='__main__':unittest.main()
