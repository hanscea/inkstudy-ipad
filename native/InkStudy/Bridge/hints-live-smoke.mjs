import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { DeepSeekHintProvider, deepseekKeyFromDocument, hintCandidates } from './hints.mjs';

const [keyFile, report] = process.argv.slice(2);
if (!keyFile || !report) throw new Error('Provide credential document path and report path.');
const provider = new DeepSeekHintProvider({ apiKey: deepseekKeyFromDocument(keyFile) });
const cases = [
  { name: 'synthetic_unmixed', task: 'mix', target: 'orange', strokeCount: 2, metrics: { redPaintUnits: 1, yellowPaintUnits: 1, mixedAreaFraction: 0.1, pigmentRatioVariance: 0.3 } },
  { name: 'synthetic_missing_yellow', task: 'mix', target: 'orange', strokeCount: 1, metrics: { redPaintUnits: 1, yellowPaintUnits: 0 } },
  { name: 'synthetic_heavy', task: 'pressure', target: 'light', strokeCount: 1, metrics: { pencilSampleCount: 30, signedPressureError: 0.4, normalizedForceSD: 0.02 } },
  { name: 'synthetic_no_pressure', task: 'pressure', target: 'light', strokeCount: 1, metrics: { pencilSampleCount: 0, sampleCount: 30 } }
];
const results = [];
for (const { name, ...summary } of cases) {
  const start = performance.now();
  try {
    const result = await provider.select(summary, 1);
    results.push({ name, ...result, allowed: hintCandidates(summary).includes(result.strategy), milliseconds: Math.round(performance.now() - start) });
  } catch (error) { results.push({ name, allowed: false, error: /^[a-z0-9_]+$/.test(error.code ?? '') ? error.code : 'request_failed', milliseconds: Math.round(performance.now() - start) }); }
}
const result = { at: new Date().toISOString(), data: 'synthetic_only', maximumCalls: cases.length, results };
fs.writeFileSync(report, JSON.stringify(result, null, 2), { mode: 0o600 });
console.log(JSON.stringify(result));
if (results.some(result => !result.allowed)) process.exitCode = 1;
