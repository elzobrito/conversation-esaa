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


test('policy v2 deterministic proposal matches golden',async()=>{
 const {readFileSync}=await import('node:fs');
 const {RRR_POLICY_VERSION,runRrrCycle}=await import('../../src/memory/core/renormalize.js');
 const facts=[{id:'d1',kind:'decision',timestamp:'2026-01-01T00:00:00Z',topic_id:'TOP-A',time_bucket:'2026-01-01',summary:'Synthetic decision',content_digest:sha256Prefixed('d1'),authority:'explicit_decision',epistemic_status:'verified_explicit',validity_status:'active',evidence_event_ids:['d1']}];
 const bundle={schema_version:'memory-tcg.facts.v1',workspace_id:sha256Prefixed('ws'),source_snapshot_id:sha256Prefixed('snapshot'),watermark_event_id:'d1',normalizer_version:'1.1.0',facts,relations:[]};
 const result=runRrrCycle(bundle,{seed:42,budget:'all'});const golden=JSON.parse(readFileSync(new URL('./fixtures/policy-v2-golden.json',import.meta.url),'utf8'));
 assert.equal(RRR_POLICY_VERSION,'rrr-policy.v2');assert.equal(result.proposal.policy_version,golden.policy_version);assert.equal(result.graph.generation_id,golden.graph_generation_id);assert.equal(result.proposal.proposal_id,golden.proposal_id);
});
