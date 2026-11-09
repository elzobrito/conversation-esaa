import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

test('memory CLI executes with spaces, accents and symlink; importing does not execute it', (t) => {
 const tmp=mkdtempSync(path.join(tmpdir(),'memory cli ç-'));
 try {
  const root=path.join(tmp,'dir com espaço ç # 100%');mkdirSync(root);writeFileSync(path.join(root,'package.json'),'{"type":"module"}');
  cpSync(path.resolve('src/memory'),path.join(root,'memory'),{recursive:true});
  const cli=path.join(root,'memory/adapter/cli.js'), ws=path.join(tmp,'workspace');mkdirSync(ws);
  const run=(file)=>spawnSync(process.execPath,[file,'status','--workspace',ws,'--json'],{encoding:'utf8'});
  let result=run(cli);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).status,'OK');
  const imported=spawnSync(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(pathToFileURL(cli).href)})`],{encoding:'utf8'});
  assert.equal(imported.status,0,imported.stderr);assert.equal(imported.stdout,'');
  if(process.platform!=='win32'){const link=path.join(tmp,'cli-link.js');symlinkSync(cli,link);result=run(link);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).status,'OK');}
  else t.diagnostic('Windows paths are exercised when the test runs on Windows; symlink case skipped');
 } finally {rmSync(tmp,{recursive:true,force:true});}
});
