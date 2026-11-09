import os,shutil,subprocess,tempfile,unittest
from pathlib import Path
pw=shutil.which('pwsh') or str(Path.home()/'.local/bin/pwsh'); battery=os.environ.get('CONV_BATTERY_UNDER_TEST',str(Path(__file__).resolve().parents[1]/'.conversation-esaa/bin/conv-test-battery.ps1'))
class BatteryReporting(unittest.TestCase):
 def test_missing_partial_and_failing_suites(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp); b=root/'.conversation-esaa/bin';b.mkdir(parents=True);(b/'conv-test.ps1').write_text("Write-Output 'conv-test: 1 passed, 0 failed'\n")
   def run():return subprocess.run([pw,'-NoProfile','-File',battery,'-RepoRoot',tmp,'-SkipLab','-SkipEsaa'],capture_output=True,text=True)
   a=run();self.assertEqual(a.returncode,0,a.stderr);self.assertIn('SKIP  memory_e2e',a.stdout)
   conv=root/'.conversation-esaa/bin/conv-test.ps1'
   conv.write_text("Write-Output 'conv-test: 1 passed, 0 failed'\nexit 1\n")
   bad=run();self.assertNotEqual(bad.returncode,0)
   conv.write_text("Write-Output 'no summary'\nexit 0\n")
   missing=run();self.assertNotEqual(missing.returncode,0)
   conv.write_text("Write-Output 'conv-test: 1 passed, 0 failed'\n")
   tests=root/'tests';tests.mkdir();(tests/'test-memory-shadow.ps1').write_text("Write-Output '=== Summary: 1 passed, 0 failed ==='\n")
   b=run();self.assertNotEqual(b.returncode,0);self.assertIn('incomplete repository test suite',b.stdout)
   skip=subprocess.run([pw,'-NoProfile','-File',battery,'-RepoRoot',tmp,'-SkipLab','-SkipEsaa','-SkipMemory'],capture_output=True,text=True)
   self.assertEqual(skip.returncode,0);self.assertIn('operator requested',skip.stdout)
   (tests/'test-memory-read-path.ps1').write_text("Write-Output '=== Summary: 1 passed, 0 failed ==='\n")
   (tests/'test-memory-accept-replay.ps1').write_text("Write-Output '=== Summary: 1 passed, 0 failed ==='\nexit 1\n")
   c=run();self.assertNotEqual(c.returncode,0);self.assertIn('FAIL  test-memory-accept-replay.ps1',c.stdout)
if __name__=='__main__':unittest.main()
