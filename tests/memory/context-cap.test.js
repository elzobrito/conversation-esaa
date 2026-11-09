import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { sha256Prefixed } from '../../src/memory/core/canonical.js';
import { cmdContext } from '../../src/memory/adapter/cli.js';

test('context cap is configurable while default behavior is preserved', (t) => {
 const root=mkdtempSync(path.join(tmpdir(),'conv-context-cap-'));
 try {
  const dir=path.join(root,'.conversation-esaa','memory'); mkdirSync(dir,{recursive:true});
  const body={schema_version:'conversation-esaa.memory.active.v1',graph_generation_id:'gen',proposal_id:'prop',watermark_event_id:'wm',retained:[...Array.from({length:30},(_,i)=>({memory_id:`decision:${i}`,kind:'decision',summary:`synthetic ${i}`,evidence_event_ids:[]})),...Array.from({length:3},(_,i)=>({memory_id:`ep:${i}`,kind:'episode',summary:`subject ${i}`,reason_codes:['CONSOLIDATED_SUBJECT_MATTER'],evidence_event_ids:[]}))],grouped_duplicates:Array.from({length:2},(_,i)=>({memory_id:`group:${i}`,kind:'episode',summary:`group ${i}`,evidence_event_ids:[]})),historical_decisions:[],deprioritized:[],flagged_conflicts:[],unresolved:[]};
  writeFileSync(path.join(dir,'active.json'),JSON.stringify({...body,active_digest:sha256Prefixed(body)}));
  const count=(opts)=> (cmdContext(root,opts).markdown.match(/\*\*\[ACTIVE\]\*\*/g)||[]).length;
  assert.equal(count({budgetChars:4000}),4); assert.equal(count({budgetChars:4000,maxPerSection:2}),2);
  assert.equal(count({budgetChars:20000}),30); assert.equal(count({budgetChars:20000,maxPerSection:2}),2);
  const limited=cmdContext(root,{budgetChars:20000,maxPerSection:2}).markdown;
  const subjects=limited.split('### Consolidated Subjects Discussed (Assuntos Tratados)')[1].split('###')[0];
  assert.equal((subjects.match(/^- /gm)||[]).length,2); assert.match(limited,/--max-per-section 2/);
  assert.throws(()=>cmdContext(root,{maxPerSection:'0'}),/positive integer/);
  const cli=path.resolve('src/memory/adapter/cli.js');
  const result=spawnSync(process.execPath,[cli,'context','--workspace',root,'--budget-chars','4000','--max-per-section','2','--json'],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr); assert.equal((JSON.parse(result.stdout).markdown.match(/\*\*\[ACTIVE\]\*\*/g)||[]).length,2);
  const pw=process.env.PWSH || 'pwsh';
  const powershell=spawnSync(pw,['-NoProfile','-File',path.resolve('.conversation-esaa/bin/conversation-esaa.ps1'),'memory','context','--workspace',root,'--budget-chars','4000','--max-per-section','2','--json'],{encoding:'utf8'});
  if (powershell.error?.code === 'ENOENT') { t.diagnostic('PowerShell not available: public CLI portion not executed'); return; }
  assert.equal(powershell.status,0,powershell.stderr); assert.equal((JSON.parse(powershell.stdout).markdown.match(/\*\*\[ACTIVE\]\*\*/g)||[]).length,2);
  const cliPath=path.resolve('.conversation-esaa/bin/conversation-esaa.ps1');
  const equals=spawnSync(pw,['-NoProfile','-File',cliPath,'memory','context','--workspace',root,'--max-per-section=2','--json'],{encoding:'utf8'});
  assert.equal(equals.status,0,equals.stderr); assert.equal((JSON.parse(equals.stdout).markdown.match(/\*\*\[ACTIVE\]\*\*/g)||[]).length,2);
  const quote=(s)=>`'${s.replaceAll("'", "''")}'`;
  const command=`& ${quote(cliPath)} memory context --workspace ${quote(root)} --max-per-section=2 --json`;
  const operator=spawnSync(pw,['-NoProfile','-Command',command],{encoding:'utf8'});
  assert.equal(operator.status,0,operator.stderr); assert.equal((JSON.parse(operator.stdout).markdown.match(/\*\*\[ACTIVE\]\*\*/g)||[]).length,2);
  for (const value of ['0','-1']) {
   const invalid=spawnSync(pw,['-NoProfile','-File',path.resolve('.conversation-esaa/bin/conversation-esaa.ps1'),'memory','context','--workspace',root,'--max-per-section',value,'--json'],{encoding:'utf8'});
   assert.notEqual(invalid.status,0,`invalid cap ${value} must fail`);
  }
 } finally {rmSync(root,{recursive:true,force:true});}
});
