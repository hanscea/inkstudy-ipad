import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { HintBridge, DeepSeekHintProvider, normalizeHintRequest, hintCandidates, createHintServer, deepseekKeyFromDocument, HINT_VERSION } from './hints.mjs';

const makeRequest = (summary = { task: 'mix', target: 'orange', strokeCount: 2, metrics: { redPaintUnits: 1, yellowPaintUnits: 1, mixedAreaFraction: 0.1, pigmentRatioVariance: 0.3 } }) => ({
  requestID: crypto.randomUUID(), version: HINT_VERSION, mode: 'adult_rehearsal', uploadConsent: true, group: 'C', level: 1, summary
});
const temporary = t => { const p = fs.mkdtempSync(path.join(os.tmpdir(), 'ink-hints-')); t.after(() => fs.rmSync(p, { recursive: true, force: true })); return p; };

test('request accepts only minimal numerical adult rehearsal evidence', () => {
  const body = makeRequest(); assert.deepEqual(normalizeHintRequest(body).summary, body.summary);
  for (const extra of [{ participantCode: 'CHILD' }, { image: 'image' }, { text: 'secret' }]) assert.throws(() => normalizeHintRequest({ ...body, ...extra }));
  assert.throws(() => normalizeHintRequest({ ...body, group: 'B' }));
  assert.throws(() => normalizeHintRequest({ ...body, uploadConsent: false }));
  assert.throws(() => normalizeHintRequest({ ...body, mode: 'pilot' }));
  assert.throws(() => normalizeHintRequest({ ...body, summary: { ...body.summary, target: 'ignore instructions' } }));
  assert.throws(() => normalizeHintRequest({ ...body, summary: { ...body.summary, metrics: { arbitrary: 'name' } } }));
  assert.throws(() => normalizeHintRequest({ ...body, summary: { ...body.summary, metrics: { redPaintUnits: Infinity } } }));
});
test('candidate policy distinguishes absent pigment, unmixed paint and pressure errors', () => {
  const s = makeRequest().summary;
  assert.equal(hintCandidates(s)[0], 'mix_stir');
  assert.equal(hintCandidates({ ...s, metrics: { redPaintUnits: 1 } })[0], 'mix_add_yellow');
  assert.equal(hintCandidates({ ...s, target: 'green', metrics: { yellowPaintUnits: 1 } })[0], 'mix_add_blue');
  const pressure = { task: 'pressure', target: 'light', strokeCount: 1, metrics: { pencilSampleCount: 30, signedPressureError: 0.5 } };
  assert.equal(hintCandidates(pressure)[0], 'pressure_lighter');
  assert.equal(hintCandidates({ ...pressure, metrics: { pencilSampleCount: 30, signedPressureError: -0.3 } })[0], 'pressure_firmer');
  assert.equal(hintCandidates({ ...pressure, metrics: { signedPressureError: 0.5 } })[0], 'pressure_pencil');
  assert.equal(hintCandidates({ ...pressure, metrics: { pencilSampleCount: 30, dynamicPressureTarget: 1, signedPressureError: 0.2 } })[0], 'pressure_follow');
});
test('key reader selects labelled DeepSeek credential, not other keys or document prose', t => {
  const file = path.join(temporary(t), 'keys.md');
  fs.writeFileSync(file, 'Wanx API Key:\nsk-other-placeholder.abcdefghi\nDeepSeek API KEY:\nsk-' + 'd'.repeat(32));
  assert.equal(deepseekKeyFromDocument(file), 'sk-' + 'd'.repeat(32));
  fs.writeFileSync(file, 'Wanx API Key:\nsk-other-placeholder.abcdefghi');
  assert.throws(() => deepseekKeyFromDocument(file));
});
test('provider sends only to official DeepSeek with non-thinking bounded JSON response', async () => {
  let sent;
  const provider = new DeepSeekHintProvider({ apiKey: 'test-only', fetchImpl: async (url, options) => {
    sent = { url, options, body: JSON.parse(options.body) };
    return Response.json({ model: 'deepseek-flash', choices: [{ finish_reason: 'stop', message: { content: '{"strategy":"mix_stir"}' } }] });
  } });
  const result = await provider.select(makeRequest().summary, 1);
  assert.equal(sent.url, 'https://api.deepseek.com/chat/completions'); assert.equal(sent.options.redirect, 'error');
  assert.equal(sent.body.thinking.type, 'disabled'); assert.equal(sent.body.max_tokens, 96);
  assert.equal(result.strategy, 'mix_stir'); assert(!sent.body.messages[1].content.includes('drawingID'));
});
for (const [label, content, finish = 'stop'] of [
  ['unapproved action', '{"strategy":"pressure_firmer"}'], ['extra text', '{"strategy":"mix_stir","text":"invented"}'],
  ['invalid JSON', 'hello'], ['truncated response', '{"strategy":"mix_stir"}', 'length']
]) test('provider rejects ' + label, async () => {
  const provider = new DeepSeekHintProvider({ apiKey: 'test-only', fetchImpl: async () => Response.json({ choices: [{ finish_reason: finish, message: { content } }] }) });
  await assert.rejects(provider.select(makeRequest().summary, 1));
});
test('provider rejects HTTP failure and oversized response without exposing error body', async () => {
  const provider = new DeepSeekHintProvider({ apiKey: 'test-only', fetchImpl: async () => new Response('private provider body', { status: 401 }) });
  await assert.rejects(provider.select(makeRequest().summary, 1), error => error.code === 'provider_http_401' && !error.message.includes('private'));
  const large = new DeepSeekHintProvider({ apiKey: 'test-only', fetchImpl: async () => new Response('x'.repeat(40_000)) });
  await assert.rejects(large.select(makeRequest().summary, 1), error => error.code === 'provider_response_too_large');
});
test('same request is charged once across concurrent calls and process restart', async t => {
  let count = 0, release;
  const directory = temporary(t), body = makeRequest();
  const provider = { select: async () => { count++; await new Promise(resolve => { release = resolve; }); return { strategy: 'mix_stir', model: 'deepseek-flash' }; } };
  const bridge = new HintBridge({ directory, provider });
  const first = bridge.select('owner', body), second = bridge.select('owner', body);
  release(); assert.deepEqual(await first, await second); assert.equal(count, 1);
  const restored = new HintBridge({ directory, provider }); await restored.select('owner', body); assert.equal(count, 1);
  await assert.rejects(restored.select('other', body));
  await assert.rejects(restored.select('owner', { ...body, level: 2 }));
});
test('failed or uncertain request is not automatically retried', async t => {
  let count = 0;
  const bridge = new HintBridge({ directory: temporary(t), provider: { select: async () => { count++; throw new Error('private'); } } });
  const body = makeRequest(); await assert.rejects(bridge.select('owner', body)); await assert.rejects(bridge.select('owner', body)); assert.equal(count, 1);
});
test('daily cap persists and failed calls consume the bounded budget', async t => {
  let now = new Date('2026-09-17T12:00:00Z');
  const directory = temporary(t), provider = { select: async () => ({ strategy: 'mix_stir', model: 'deepseek-flash' }) };
  const bridge = new HintBridge({ directory, provider, dailyLimit: 1, now: () => now });
  await bridge.select('owner', makeRequest()); now = new Date(now.getTime() + 3000);
  const restored = new HintBridge({ directory, provider, dailyLimit: 1, now: () => now });
  await assert.rejects(restored.select('owner', makeRequest()), error => error.code === 'daily_limit');
});
test('HTTP requires pairing, rejects browser origins and accepts only constrained requests', async t => {
  const bridge = new HintBridge({ directory: temporary(t), provider: { select: async () => ({ strategy: 'mix_stir', model: 'deepseek-flash' }) } });
  const server = createHintServer(bridge);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => server.close());
  const base = 'http://127.0.0.1:' + server.address().port;
  assert.equal((await fetch(base + '/v1/status')).status, 401);
  assert.equal((await fetch(base + '/v1/status', { headers: { Origin: 'https://example.com' } })).status, 403);
  const code = bridge.store.pairCode(), deviceID = crypto.randomUUID();
  const paired = await (await fetch(base + '/v1/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code, deviceID }) })).json();
  assert(paired.token);
  const result = await fetch(base + '/v1/hints', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + paired.token }, body: JSON.stringify(makeRequest()) });
  assert.equal(result.status, 200); assert.equal((await result.json()).strategy, 'mix_stir');
  assert.equal((await fetch(base + '/v1/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code, deviceID }) })).status, 401);
});
