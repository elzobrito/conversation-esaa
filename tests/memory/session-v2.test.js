import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,mkdirSync,writeFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createWorkspaceSnapshot } from '../../src/memory/adapter/snapshot.js';
import { runRrrCycle } from '../../src/memory/core/renormalize.js';

test('source-scoped session IDs survive snapshot and graph and affect conflicts',()=>{
 const root=mkdtempSync(path.join(tmpdir(),'memory-session-'));
 try{const dir=path.join(root,'.conversation-esaa');mkdirSync(dir);const ledger=path.join(dir,'activity.jsonl');
  const events=[{event_id:'a',ts:'2026-01-01T10:00:00Z',event:'conversation_turn',actor:'user',source:'cursor',source_session_id:'same',source_index:0,workspace_root:root,summary:'alpha postgres',text:'alpha postgres',conflict_key:'database_engine',conflict_value:'postgres'}, {event_id:'b',ts:'2026-01-02T10:00:00Z',event:'conversation_turn',actor:'user',source:'cursor',source_session_id:'same',source_index:1,workspace_root:root,summary:'beta sqlite',text:'beta sqlite',conflict_key:'database_engine',conflict_value:'sqlite'}];
  const calculate=()=>{writeFileSync(ledger,events.map(JSON.stringify).join('\n')+'\n');const snap=createWorkspaceSnapshot(root);const result=runRrrCycle(snap.factsBundle,{seed:42,budget:'all'});return {snap,result};};
  const same=calculate();const facts=same.snap.factsBundle.facts.filter(x=>x.kind==='episode');assert.equal(facts.length,2);assert.match(facts[0].session_id,/^sha256:/);assert.equal(facts[0].session_id,facts[1].session_id);assert.ok(same.result.graph.possible_edges.some(x=>x.relation==='possibly_contradicts'));assert.equal(same.result.proposal.policy_version,'rrr-policy.v2');assert.equal(same.snap.factsBundle.normalizer_version,'1.1.0');
  const other=mkdtempSync(path.join(tmpdir(),'memory-session-other-'));try{mkdirSync(path.join(other,'.conversation-esaa'));writeFileSync(path.join(other,'.conversation-esaa','activity.jsonl'),events.map(e=>JSON.stringify({...e,workspace_root:other})).join('\n')+'\n');const otherId=createWorkspaceSnapshot(other).factsBundle.facts.find(x=>x.kind==='episode').session_id;assert.notEqual(facts[0].session_id,otherId);}finally{rmSync(other,{recursive:true,force:true});}
  events[1].source_session_id='different';const different=calculate();assert.notEqual(same.snap.factsBundle.source_snapshot_id,different.snap.factsBundle.source_snapshot_id);assert.equal(different.result.graph.possible_edges.filter(x=>x.relation==='possibly_contradicts').length,0);
  events[1].source_session_id='same';events[1].source='grok';const differentSource=calculate();assert.equal(differentSource.result.graph.possible_edges.filter(x=>x.relation==='possibly_contradicts').length,0);
 }finally{rmSync(root,{recursive:true,force:true});}
});

test('rejects non-hashed session identifiers supplied through the API', async () => {
 const { validateFactsBundle, sha256Prefixed } = await import('../../src/memory/core/canonical.js');
 const root=mkdtempSync(path.join(tmpdir(),'memory-session-valid-'));
 try {const dir=path.join(root,'.conversation-esaa');mkdirSync(dir);writeFileSync(path.join(dir,'activity.jsonl'),JSON.stringify({event_id:'a',ts:'2026-01-01T10:00:00Z',event:'conversation_turn',actor:'user',source:'cursor',source_session_id:'s',source_index:0,workspace_root:root,text:'a'})+'\n');
 const bundle=createWorkspaceSnapshot(root).factsBundle;const fact=bundle.facts.find(f=>f.kind==='episode');
 for(const bad of ['private-session',{},null]) {fact.session_id=bad;assert.throws(()=>validateFactsBundle(bundle),/session_id/);}
 fact.session_id=sha256Prefixed('session');assert.doesNotThrow(()=>validateFactsBundle(bundle));
 }finally{rmSync(root,{recursive:true,force:true});}
});

test('v1 proposal becomes stale when a distinct Cursor event repeats an old source index', async () => {
 const {verifySnapshotFreshness}=await import('../../src/memory/adapter/snapshot.js');
 const root=mkdtempSync(path.join(tmpdir(),'memory-session-stale-'));
 try {const dir=path.join(root,'.conversation-esaa');mkdirSync(dir);const file=path.join(dir,'activity.jsonl');const base={ts:'2026-01-01T10:00:00Z',event:'conversation_turn',actor:'assistant',source:'cursor',source_path:'cursor-hook',source_session_id:'s',source_index:0,workspace_root:root};
 writeFileSync(file,JSON.stringify({...base,event_id:'a',text:'first'})+'\n');const old=createWorkspaceSnapshot(root,{normalizerVersion:'1.0.0'}).factsBundle;
 writeFileSync(file,JSON.stringify({...base,event_id:'a',text:'first'})+'\n'+JSON.stringify({...base,event_id:'b',text:'second'})+'\n');
 assert.throws(()=>verifySnapshotFreshness(root,old.source_snapshot_id,old.watermark_event_id,'1.0.0'),/changed since proposal/);
 }finally{rmSync(root,{recursive:true,force:true});}
});


test('proposal provenance preserves the normalizer of its input snapshot', () => {
 const root=mkdtempSync(path.join(tmpdir(),'memory-v1-provenance-'));
 try {mkdirSync(path.join(root,'.conversation-esaa'));writeFileSync(path.join(root,'.conversation-esaa','activity.jsonl'),JSON.stringify({event_id:'a',ts:'2026-01-01T10:00:00Z',event:'conversation_turn',actor:'user',source:'cursor',source_session_id:'s',source_index:0,workspace_root:root,text:'a'})+'\n');
 const bundle=createWorkspaceSnapshot(root,{normalizerVersion:'1.0.0'}).factsBundle;const result=runRrrCycle(bundle,{seed:42,budget:'all'});assert.equal(result.proposal.provenance.normalizer_version,'1.0.0');
 }finally{rmSync(root,{recursive:true,force:true});}
});
