import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
class WorkspacePrecedence(unittest.TestCase):
 def test_project_ignores_environment_global_preserves_environment_and_explicit_wins(self):
  with tempfile.TemporaryDirectory(prefix='conv-roots-') as tmp:
   base=Path(tmp);a=base/'a';b=base/'b';home=base/'home';[x.mkdir() for x in (a,b,home)]
   bootstrap=ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'
   for ws in (a,b,home):subprocess.run([PW,'-NoProfile','-File',str(bootstrap),'-WorkspaceRoot',str(ws),'-SkipAgentIntegrations'],capture_output=True,check=True)
   candidate=Path(os.environ.get('PS11_CANDIDATES',ROOT/'.conversation-esaa/bin'))
   for ws in (a,home):
    for n in ['conversation-esaa.ps1','conv-sync.ps1','conv-memory.ps1','conv-rag.ps1']:shutil.copyfile(candidate/n,ws/'.conversation-esaa/bin'/n)
   def run(script,args,env=None):
    r=subprocess.run([PW,'-NoProfile','-File',str(script),*args],capture_output=True,text=True,env=env,timeout=30);self.assertEqual(r.returncode,0,r.stderr);return r.stdout
   # Keep project ledgers distinguishable without accessing any real workspace.
   for ws,msg in [(a,'only-project-a'),(b,'only-project-b')]:run(ROOT/'.conversation-esaa/bin/conversation-esaa.ps1',['decide',msg,'--workspace',str(ws)])
   env={**os.environ,'HOME':str(home),'GROK_WORKSPACE_ROOT':str(b),'CONV_ESAA_MEMORY_CLI':str(ROOT/'src/memory/adapter/cli.js')}
   for cmd in [a/'.conversation-esaa/bin/conversation-esaa.ps1',a/'.conversation-esaa/bin/conv-sync.ps1']:
    out=run(cmd,['context'],env);self.assertIn('only-project-a',out);self.assertNotIn('only-project-b',out)
   out=run(a/'.conversation-esaa/bin/conversation-esaa.ps1',['context','--workspace',str(b)],env);self.assertIn('only-project-b',out)
   out=run(home/'.conversation-esaa/bin/conversation-esaa.ps1',['context'],env);self.assertIn('only-project-b',out)
   out=run(home/'.conversation-esaa/bin/conversation-esaa.ps1',['context','--workspace',str(a)],env);self.assertIn('only-project-a',out)
   def mem(script,args):return json.loads(run(script,['status',*args,'--json'],env))['workspace_id']
   amem=a/'.conversation-esaa/bin/conv-memory.ps1'; self.assertEqual(mem(amem,[]),mem(amem,['-WorkspaceRoot',str(a)]));self.assertNotEqual(mem(amem,[]),mem(amem,['-WorkspaceRoot',str(b)]))
   self.assertEqual(mem(home/'.conversation-esaa/bin/conv-memory.ps1',[]),mem(amem,['-WorkspaceRoot',str(b)]))
   # Direct RAG actions use the same precedence, including destructive purge.
   for ws in (a,b):
    rag=ws/'.conversation-esaa/rag';rag.mkdir(exist_ok=True);(rag/'synthetic.txt').write_text('synthetic')
   arag=a/'.conversation-esaa/bin/conv-rag.ps1'; hrag=home/'.conversation-esaa/bin/conv-rag.ps1'
   astatus=json.loads(run(arag,['-Action','status','-Json'],env));bstatus=json.loads(run(hrag,['-Action','status','-Json'],env))
   self.assertEqual(astatus['workspace'],str(a));self.assertEqual(bstatus['workspace'],str(b))
   run(arag,['-Action','disable','-Purge'],env);self.assertFalse((a/'.conversation-esaa/rag').exists());self.assertTrue((b/'.conversation-esaa/rag/synthetic.txt').exists())
   run(hrag,['-Action','disable','-Purge'],env);self.assertFalse((b/'.conversation-esaa/rag').exists())
if __name__=='__main__':unittest.main()
