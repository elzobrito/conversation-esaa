import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { sha256Prefixed } from '../../src/memory/core/canonical.js';
import { cmdContext } from '../../src/memory/adapter/cli.js';

test('policy v2 ranks active topic conflicts before cold topics; v1 stays compatible',()=>{
 const root=mkdtempSync(path.join(tmpdir(),'policy-v2-'));
 try {const dir=path.join(root,'.conversation-esaa/memory');mkdirSync(dir,{recursive:true});
  const retained=[{memory_id:'TOP-A',kind:'topic',topic_id:'TOP-A',summary:'active',evidence_event_ids:[]},{memory_id:'cold-node',kind:'episode',topic_id:'TOP-C',summary:'cold',evidence_event_ids:[]},{memory_id:'active-node',kind:'episode',topic_id:'TOP-A',summary:'active',evidence_event_ids:[]}];
  const unresolved=[{conflict_id:'a-cold',memory_ids:['cold-node'],evidence_event_ids:[]},{conflict_id:'z-active',memory_ids:['active-node'],evidence_event_ids:[]}];
  const view=(policy)=>{const body={schema_version:'conversation-esaa.memory.active.v1',graph_generation_id:'g',proposal_id:'p',watermark_event_id:'w',policy_version:policy,retained,unresolved,grouped_duplicates:[],historical_decisions:[],deprioritized:[],flagged_conflicts:[]};writeFileSync(path.join(dir,'active.json'),JSON.stringify({...body,active_digest:sha256Prefixed(body)}));return cmdContext(root,{budgetChars:20000}).unresolved_conflicts.map(x=>x.conflict_id);};
  assert.deepEqual(view('rrr-policy.v1'),['a-cold','z-active']);assert.deepEqual(view('rrr-policy.v2'),['z-active','a-cold']);
 } finally {rmSync(root,{recursive:true,force:true});}
});

