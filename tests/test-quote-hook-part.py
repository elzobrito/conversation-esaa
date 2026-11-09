"""PS-16: Quote-CommandPart / Quote-HookPart must double embedded quotes.

Linux runtime of the replacement is measured here. Windows cmd.exe quoting
of the resulting hook command is unmeasured.
"""
import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PW = shutil.which('pwsh') or str(Path.home() / '.local/bin/pwsh')
BOOT = ROOT / '.conversation-esaa/bin/conv-bootstrap.ps1'
CLI = ROOT / '.conversation-esaa/bin/conversation-esaa.ps1'
ESCAPE = r"""-replace '"', '""'"""


class QuoteHookPart(unittest.TestCase):
    def test_source_doubles_quotes(self):
        for path in (BOOT, CLI):
            text = path.read_text(encoding='utf-8')
            self.assertIn(ESCAPE, text, path.name)
            self.assertNotIn("""-replace '"', '"'""", text.replace(ESCAPE, ''))

    def test_runtime_quote_helpers_double_embedded_quotes(self):
        script = r'''
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-Quote([string]$Name, [scriptblock]$Fn) {
    $got = & $Fn 'a"b'
    if ($got -ne '"a""b"') { throw "$Name produced $got" }
}
$boot = Get-Content -LiteralPath $env:BOOT -Raw
if ($boot -notmatch '(?s)function Quote-CommandPart\(\[string\]\$Value\) \{.*?\}') {
    throw 'Quote-CommandPart not found'
}
Invoke-Expression $Matches[0]
Assert-Quote 'Quote-CommandPart' { param($v) Quote-CommandPart $v }
$cli = Get-Content -LiteralPath $env:CLI -Raw
if ($cli -notmatch '(?s)function Quote-HookPart\(\[string\]\$Value\) \{.*?\}') {
    throw 'Quote-HookPart not found'
}
Invoke-Expression $Matches[0]
Assert-Quote 'Quote-HookPart' { param($v) Quote-HookPart $v }
Write-Output 'ok'
'''
        env = {**os.environ, 'BOOT': str(BOOT), 'CLI': str(CLI)}
        r = subprocess.run(
            [PW, '-NoProfile', '-Command', script],
            capture_output=True, text=True, timeout=30, env=env,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('ok', r.stdout)

    def test_bootstrap_hook_quotes_workspace_with_embedded_quote(self):
        with tempfile.TemporaryDirectory(prefix='ps16-quote-') as tmp:
            ws = Path(tmp) / 'proj"ect'
            ws.mkdir()
            r = subprocess.run(
                [PW, '-NoProfile', '-File', str(BOOT), '-WorkspaceRoot', str(ws),
                 '-Agents', 'grok', '-Json'],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            hook = json.loads((ws / '.grok/hooks/conversation-esaa.json').read_text(encoding='utf-8'))
            command = hook['hooks']['Stop'][0]['hooks'][0]['command']
            self.assertIn('proj""ect', command)
            self.assertRegex(command, r'--workspace "[^"]*proj""ect"')


if __name__ == '__main__':
    unittest.main()
