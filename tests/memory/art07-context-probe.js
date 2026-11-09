import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { buildScaledScenario } from './benchmark.js';
import { runRrrCycle } from '../../src/memory/core/renormalize.js';
import { buildActiveViewFromProposal, cmdContext } from '../../src/memory/adapter/cli.js';
const s=buildScaledScenario(50);const r=runRrrCycle(s.factsBundle,{seed:11,budget:'all',mode:'shadow'});const active=buildActiveViewFromProposal(r.proposal,r.graph);
const tmp=mkdtempSync(path.join(tmpdir(),'art07-synthetic-'));try {const dir=path.join(tmp,'.conversation-esaa/memory');mkdirSync(dir,{recursive:true});writeFileSync(path.join(dir,'active.json'),JSON.stringify(active));for (const budgetChars of [3200,4000,20000]){const c=cmdContext(tmp,{budgetChars});console.log(JSON.stringify({facts:s.factsBundle.facts.length,budgetChars,status:c.status,decisions:c.retained_decisions?.length,conflicts:c.unresolved_conflicts?.length,omitted:c.omitted_memory_ids?.length,chars:c.markdown?.length}));}}finally{rmSync(tmp,{recursive:true,force:true})}
