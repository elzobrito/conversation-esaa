import os, shutil, subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PW = shutil.which('pwsh') or str(Path.home() / '.local/bin/pwsh')
BOOT = ROOT / '.conversation-esaa/bin/conv-bootstrap.ps1'
SYNC = ROOT / '.conversation-esaa/bin/conv-sync.ps1'
MEM = ROOT / '.conversation-esaa/bin/conv-memory.ps1'
HOME_FALLBACK = '/home/elzobrito/desenvolvimento/conversation-esaa'


class MemoryEngineBundled(unittest.TestCase):
    def test_runtime_scripts_have_no_machine_specific_fallback(self):
        for path in (SYNC, MEM):
            text = path.read_text(encoding='utf-8')
            self.assertNotIn(HOME_FALLBACK, text, path.name)

    def test_bootstrap_ships_memory_engine_and_isolated_runtime_resolves_it(self):
        with tempfile.TemporaryDirectory(prefix='ps12-boot-') as tmp:
            r = subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations'],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            bundled = Path(tmp) / '.conversation-esaa/bin/memory/adapter/cli.js'
            self.assertTrue(bundled.is_file(), bundled)
            module = Path(tmp) / '.conversation-esaa/bin/memory/package.json'
            self.assertEqual(module.read_text(encoding='utf-8'), '{"type":"module"}\n')

            env = {k: v for k, v in os.environ.items() if k != 'CONV_ESAA_MEMORY_CLI'}
            status = subprocess.run(
                [PW, '-NoProfile', '-File', str(Path(tmp) / '.conversation-esaa/bin/conv-memory.ps1'),
                 'status', '-WorkspaceRoot', tmp, '-Json'],
                capture_output=True, text=True, timeout=60, env=env,
            )
            self.assertEqual(status.returncode, 0, status.stdout + status.stderr)

            isolated = Path(tmp) / 'isolated-runtime'
            shutil.copytree(Path(tmp) / '.conversation-esaa/bin', isolated)
            iso_status = subprocess.run(
                [PW, '-NoProfile', '-File', str(isolated / 'conv-memory.ps1'),
                 'status', '-WorkspaceRoot', tmp, '-Json'],
                capture_output=True, text=True, timeout=60, env=env,
            )
            self.assertEqual(iso_status.returncode, 0, iso_status.stdout + iso_status.stderr)

    def test_isolated_scripts_without_engine_do_not_use_home_checkout(self):
        with tempfile.TemporaryDirectory(prefix='ps12-iso-') as tmp:
            dest = Path(tmp) / 'bin'
            dest.mkdir()
            shutil.copy2(MEM, dest / 'conv-memory.ps1')
            env = {k: v for k, v in os.environ.items() if k != 'CONV_ESAA_MEMORY_CLI'}
            r = subprocess.run(
                [PW, '-NoProfile', '-File', str(dest / 'conv-memory.ps1'),
                 'status', '-WorkspaceRoot', tmp, '-Json'],
                capture_output=True, text=True, timeout=30, env=env,
            )
            self.assertNotEqual(r.returncode, 0)
            combined = r.stdout + r.stderr
            self.assertIn('Memory-TCG Node CLI not found', combined)
            self.assertNotIn(HOME_FALLBACK + '/src/memory', combined)

    def test_bootstrap_preserves_modified_engine_without_force(self):
        with tempfile.TemporaryDirectory(prefix='ps12-mod-') as tmp:
            cmd = [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', tmp, '-SkipAgentIntegrations']
            subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=True)
            cli = Path(tmp) / '.conversation-esaa/bin/memory/adapter/cli.js'
            original = cli.read_bytes()
            cli.write_text('modified-engine-sentinel\n', encoding='utf-8')
            subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=True)
            self.assertEqual(cli.read_text(encoding='utf-8'), 'modified-engine-sentinel\n')
            subprocess.run(cmd + ['-Force'], capture_output=True, text=True, timeout=60, check=True)
            self.assertEqual(cli.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
