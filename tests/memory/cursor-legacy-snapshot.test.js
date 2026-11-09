import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,mkdirSync,writeFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createWorkspaceSnapshot } from '../../src/memory/adapter/snapshot.js';
test('snapshot keeps distinct legacy Cursor hook events that reused an index',()=>{
 const root=mkdtempSync(path.join(tmpdir(),'cursor-snapshot-'));
 try{const dir=path.join(root,'.conversation-esaa');mkdirSync(dir);const base={ts:'2026-01-01T00:00:00Z',event:'conversation_turn',actor:'assistant',agent_id:'cursor',workspace_root:root,source:'cursor',source_path:'cursor-hook',source_session_id:'s',source_index:1};
 const events=[{...base,event_id:'old-a',summary:'alpha',text:'alpha'},{...base,event_id:'old-b',summary:'beta',text:'beta'}];writeFileSync(path.join(dir,'activity.jsonl'),events.map(JSON.stringify).join('\n')+'\n');
 const {factsBundle}=createWorkspaceSnapshot(root);const ids=factsBundle.facts.map(x=>x.id);assert.ok(ids.includes('old-a'));assert.ok(ids.includes('old-b'));
 }finally{rmSync(root,{recursive:true,force:true});}
});
