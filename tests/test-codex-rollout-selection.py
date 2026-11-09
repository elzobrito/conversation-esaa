import json,os,subprocess,tempfile,time,unittest,shutil
from pathlib import Path
import shutil
PW=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh')
ROOT=Path(__file__).resolve().parents[1]
SYNC=Path(os.environ.get('CONV_SYNC_UNDER_TEST', ROOT/'.conversation-esaa/bin/conv-sync.ps1'))
WATCH=Path(os.environ.get('CONV_WATCH_UNDER_TEST', ROOT/'.conversation-esaa/bin/codex-watch.ps1'))

def make_functions(directory):
 source=SYNC.read_text(); start=source.index('function Test-CodexWorkspaceMatch'); end=source.index('\nfunction Invoke-SyncCodex',start)
 script=Path(directory)/'match.ps1'; script.write_text('param([string]$TestRoot)\nSet-StrictMode -Version Latest\n'+source[start:end]+'\nFind-LatestCodexRollout -WorkspaceRoot $TestRoot\n'); return str(script)
class CodexMatch(unittest.TestCase):
 def test_metadata_and_no_unrelated_fallback(self):
  with tempfile.TemporaryDirectory(prefix='codex-match-') as tmp:
   root=Path(tmp)/'workspace';root.mkdir(); home=Path(tmp)/'home'; sessions=home/'.codex/sessions'; sessions.mkdir(parents=True)
   target=sessions/'rollout-a.jsonl';other=sessions/'rollout-b.jsonl';decoy=sessions/'rollout-c.jsonl'
   def put(p,payload):p.write_text(json.dumps({'type':'session_meta','payload':payload})+'\n')
   put(target,{'cwd':str(root),'id':'a'});put(other,{'cwd':str(root)+'-other','id':'b'});put(decoy,{'cwd':str(root.parent),'note':str(root),'id':'c'})
   now=time.time();os.utime(target,(now-20,now-20));os.utime(other,(now-10,now-10));os.utime(decoy,(now,now))
   env={**os.environ,'HOME':str(home)}; script=make_functions(tmp)
   def find():return subprocess.run([PW,'-NoProfile','-File',script,str(root)],capture_output=True,text=True,env=env,check=True).stdout.strip()
   self.assertEqual(find(),str(target));target.unlink();self.assertEqual(find(),'')
   put(target,{'cwd':'C:\\not-the-root','runtime_workspace_roots':[str(root)],'id':'a'});self.assertEqual(find(),str(target))
 def test_global_home_matches_descendant_but_not_sibling(self):
  with tempfile.TemporaryDirectory() as tmp:
   home=Path(tmp)/'home'; home.mkdir(); child=home/'project';child.mkdir(); sessions=home/'.codex/sessions';sessions.mkdir(parents=True)
   target=sessions/'rollout-a.jsonl'; target.write_text(json.dumps({'type':'session_meta','payload':{'cwd':str(child)}})+'\n')
   script=make_functions(tmp); env={**os.environ,'HOME':str(home)}
   r=subprocess.run([PW,'-NoProfile','-File',script,str(home)],capture_output=True,text=True,env=env,check=True)
   self.assertEqual(r.stdout.strip(),str(target))
   target.write_text(json.dumps({'type':'session_meta','payload':{'cwd':str(home)+'-sibling'}})+'\n')
   r=subprocess.run([PW,'-NoProfile','-File',script,str(home)],capture_output=True,text=True,env=env,check=True)
   self.assertEqual(r.stdout.strip(),'')
   outside=Path(tmp)/'outside';outside.mkdir()
   for candidate in [str(home/'missing'/'..'/'..'/'outside'),str(home/'project'/'..'/'..'/'outside')]:
    target.write_text(json.dumps({'type':'session_meta','payload':{'cwd':candidate}})+'\n')
    r=subprocess.run([PW,'-NoProfile','-File',script,str(home)],capture_output=True,text=True,env=env,check=True)
    self.assertEqual(r.stdout.strip(),'')
   if os.name != 'nt':
    (home/'escape').symlink_to(outside,target_is_directory=True)
    target.write_text(json.dumps({'type':'session_meta','payload':{'cwd':str(home/'escape')}})+'\n')
    r=subprocess.run([PW,'-NoProfile','-File',script,str(home)],capture_output=True,text=True,env=env,check=True)
    self.assertEqual(r.stdout.strip(),'')
 def test_watcher_tracks_the_selected_workspace(self):
  with tempfile.TemporaryDirectory(prefix='watch-rollout-') as tmp:
   home=Path(tmp)/'home';home.mkdir(); ws=Path(tmp)/'workspace';ws.mkdir(); sessions=home/'.codex/sessions';sessions.mkdir(parents=True)
   env={**os.environ,'HOME':str(home)}
   bootstrap=ROOT/'.conversation-esaa/bin/conv-bootstrap.ps1'
   subprocess.run([PW,'-NoProfile','-File',str(bootstrap),'-WorkspaceRoot',str(ws),'-SkipAgentIntegrations'],capture_output=True,check=True,env=env)
   b=ws/'.conversation-esaa/bin';shutil.copyfile(SYNC,b/'conv-sync.ps1');shutil.copyfile(WATCH,b/'codex-watch.ps1')
   def entry(text):return {'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':text}]}}
   target=sessions/'rollout-a.jsonl';other=sessions/'rollout-b.jsonl'
   target.write_text(json.dumps({'type':'session_meta','payload':{'id':'a','cwd':str(ws)}})+'\n'+json.dumps(entry('wanted one'))+'\n')
   other.write_text(json.dumps({'type':'session_meta','payload':{'id':'b','cwd':str(ws)+'-other'}})+'\n'+json.dumps(entry('wrong workspace'))+'\n')
   now=time.time();os.utime(target,(now-10,now-10));os.utime(other,(now,now))
   proc=subprocess.Popen([PW,'-NoProfile','-File',str(b/'codex-watch.ps1'),'-WorkspaceRoot',str(ws),'-PollSeconds','1'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   try:
    ledger=ws/'.conversation-esaa/activity.jsonl'
    def waitfor(value):
     end=time.monotonic()+25
     while time.monotonic()<end:
      if ledger.exists() and value in ledger.read_text(): return
      if proc.poll() is not None: break
      time.sleep(.2)
     self.fail(f'watcher did not capture {value}; log: '+(ws/'.conversation-esaa/codex-watch.log').read_text())
    waitfor('wanted one')
    with target.open('a') as f:f.write(json.dumps(entry('wanted two'))+'\n')
    waitfor('wanted two');self.assertNotIn('wrong workspace',ledger.read_text())
   finally:
    proc.terminate();proc.wait(timeout=10)
 @unittest.skipUnless(os.name == 'nt', 'Windows filesystem not available')
 def test_json_windows_escaping(self):
  # Exercise parsed JSON metadata and the same equality helper with a Windows-style path.
  with tempfile.TemporaryDirectory() as tmp:
   home=Path(tmp);sessions=home/'.codex/sessions';sessions.mkdir(parents=True)
   path=sessions/'rollout-a.jsonl';cwd=r'C:\tmp\proj';path.write_text(json.dumps({'type':'session_meta','payload':{'cwd':cwd}})+'\n')
   script=make_functions(tmp)
   r=subprocess.run([PW,'-NoProfile','-File',script,cwd],capture_output=True,text=True,env={**os.environ,'HOME':tmp},check=True)
   self.assertEqual(r.stdout.strip(),str(path))
if __name__=='__main__':unittest.main()
