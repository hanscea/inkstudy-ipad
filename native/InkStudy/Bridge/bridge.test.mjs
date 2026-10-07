import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { Bridge, RuntimeStore, WanxProvider, createServer, normalizeRequest, inspectPNG, crc32, allowedResultURL, publicJob, acquireRuntimeLock, recoverRuntimeLock, extractAPIKey, redactAPIKeys } from './bridge.mjs';

function png(width = 512, height = 512) {
  function chunk(type, data) {
    const header = Buffer.alloc(8), checksum = Buffer.alloc(4); header.writeUInt32BE(data.length); header.write(type, 4);
    checksum.writeUInt32BE(crc32(Buffer.concat([header.subarray(4), data])));
    return Buffer.concat([header, data, checksum]);
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2;
  const pixels = Buffer.alloc(height * (width * 3 + 1), 255);
  for (let row = 0; row < height; row++) pixels[row * (width * 3 + 1)] = 0;
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]);
}
const image = png();

test('key file parsing and error redaction preserve complete long-form bearer tokens', () => {
  const legacy = 'sk-' + 'a'.repeat(32), dotted = 'sk-test.unit-test.token.' + 'b'.repeat(64);
  assert.equal(extractAPIKey(legacy), legacy);
  assert.equal(extractAPIKey(`DASHSCOPE_API_KEY="${dotted}"\n`), dotted);
  assert.equal(redactAPIKeys(`Provider rejected ${dotted}`), 'Provider rejected [redacted]');
  assert.throws(() => extractAPIKey(`${legacy}\n${dotted}`));
  assert.throws(() => extractAPIKey('sk-***'));
});
function request(overrides = {}) { return { imageBase64: image.toString('base64'), sourceDocumentID: crypto.randomUUID(), prompt: 'Synthetic adult test drawing of a tree.',
  seed: 17, mode: 'independent', uploadConsent: true, appVersion: 'unit-test', ...overrides }; }
function setup(t, providerOverrides = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'InkStudyBridgeTest-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const store = new RuntimeStore(directory);
  const provider = {
    isTestProvider: true, submitted: 0,
    async submit() { this.submitted++; return { taskID: crypto.randomUUID(), requestID: 'unit-test' }; },
    async poll() { return { output: { task_status: 'SUCCEEDED', results: [{ url: 'https://test.oss-cn-beijing.aliyuncs.com/test.png' }] }, usage: { image_count: 1 } }; },
    async download() { return { data: image, mime: 'image/png', extension: 'png' }; }, ...providerOverrides
  };
  return { store, provider, bridge: new Bridge({ store, provider, pollMilliseconds: 0 }) };
}

test('normalization fixes model, sketch mode, watermark and one-image count', () => {
  const normalized = normalizeRequest(request({ parameters: { n: 99, watermark: false }, model: 'other' }));
  assert.equal(normalized.request.model, 'wanx2.1-imageedit');
  assert.deepEqual(normalized.request.parameters, { is_sketch: true, n: 1, watermark: true, seed: 17 });
  assert.equal(normalized.request.source.width, 512);
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
  assert.throws(() => inspectPNG(png(511)), /512/);
  const damaged = Buffer.from(image); damaged[45] ^= 1; assert.throws(() => inspectPNG(damaged));
  assert.throws(() => normalizeRequest(request({ uploadConsent: false })));
  assert.throws(() => normalizeRequest(request({ imageBase64: 'abcd' })));
});

test('provider destination and returned image URLs cannot target arbitrary servers', () => {
  assert.throws(() => new WanxProvider({ apiKey: 'test', base: 'http://localhost/api/v1' }));
  assert.throws(() => new WanxProvider({ apiKey: 'test', base: 'https://example.com/api/v1' }));
  assert.throws(() => allowedResultURL('https://127.0.0.1/image.png'));
  assert.throws(() => allowedResultURL('https://evil.aliyuncs.com.attacker.test/image.png'));
  assert.throws(() => allowedResultURL('https://user:pass@bucket.aliyuncs.com/image.png'));
  assert.equal(allowedResultURL('https://bucket.oss-cn-beijing.aliyuncs.com/result.png').protocol, 'https:');
});

test('same request ID never creates a second provider task', async (t) => {
  const { bridge, provider, store } = setup(t), id = crypto.randomUUID(), body = request();
  bridge.create(id, 'device-1', body); bridge.create(id, 'device-1', body);
  await bridge.tick(); assert.equal(provider.submitted, 1);
  bridge.create(id, 'device-1', body); await bridge.tick();
  assert.equal(provider.submitted, 1); assert.equal(bridge.get(id).status, 'SUCCEEDED');
  assert.throws(() => bridge.create(id, 'device-1', { ...body, prompt: 'Different prompt.' }), /不能替换/);
  assert.throws(() => bridge.create(id, 'device-2', body), /未找到/);
  const job = store.read(id), safe = publicJob(job);
  assert.ok(!('owner' in safe)); assert.ok(!('resultURL' in safe)); assert.ok(job.resultSHA256);
  assert.deepEqual(fs.readFileSync(path.join(store.jobDirectory(id), 'original.png')), image);
});

test('a crash during submission becomes unknown and is never auto-resubmitted', async (t) => {
  const { bridge, provider, store } = setup(t), id = crypto.randomUUID();
  const job = bridge.create(id, 'device-1', request()); job.status = 'SUBMITTING'; store.write(job);
  const reopened = new Bridge({ store: new RuntimeStore(store.directory), provider });
  assert.equal(reopened.get(id).status, 'SUBMISSION_UNKNOWN');
  await reopened.tick(); assert.equal(provider.submitted, 0);
});

test('network timeout on submission cannot spend twice', async (t) => {
  const { bridge, provider } = setup(t, { async submit() { this.submitted++; throw new Error('network_timeout'); } });
  const id = crypto.randomUUID(), body = request(); bridge.create(id, 'device-1', body);
  await bridge.tick(); bridge.create(id, 'device-1', body); await bridge.tick();
  assert.equal(bridge.get(id).status, 'SUBMISSION_UNKNOWN'); assert.equal(provider.submitted, 1);
});

test('result-download failures retry the existing task without regenerating', async (t) => {
  let downloads = 0;
  const { bridge, provider } = setup(t, { async download() { if (++downloads === 1) throw new Error('offline'); return { data: image, mime: 'image/png', extension: 'png' }; } });
  const id = crypto.randomUUID(); bridge.create(id, 'device-1', request());
  await bridge.tick(); await bridge.tick(); assert.equal(bridge.get(id).status, 'RESULT_PENDING');
  await bridge.tick(); assert.equal(bridge.get(id).status, 'SUCCEEDED'); assert.equal(provider.submitted, 1);
});

test('research access needs server approval; client flags alone do not release it', (t) => {
  const { bridge } = setup(t);
  assert.throws(() => bridge.create(crypto.randomUUID(), 'device-1', request({ mode: 'research', participantCode: 'P01', allVisitsCompleted: true })), /V1a/);
  const auth = bridge.store.auth(); auth.approvedParticipants.push({ code: 'P01', allVisitsCompleted: true }); bridge.store.writeAuth(auth);
  assert.equal(bridge.create(crypto.randomUUID(), 'device-1', request({ mode: 'research', participantCode: 'P01' })).status, 'QUEUED');
});

test('one-use pairing and revocation protect source and output access', async (t) => {
  const { bridge, store } = setup(t); const server = createServer(bridge);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(base + '/v1/status')).status, 401);
  const code = store.pairCode(), deviceID = crypto.randomUUID();
  const pairedResponse = await fetch(base + '/v1/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code, deviceID }) });
  assert.equal(pairedResponse.status, 200); const { token } = await pairedResponse.json();
  assert.throws(() => store.pair(code, crypto.randomUUID(), 'other'));
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, id = crypto.randomUUID();
  const created = await fetch(base + '/v1/generations/' + id, { method: 'PUT', headers, body: JSON.stringify(request()) });
  assert.equal(created.status, 202);
  const read = await fetch(base + '/v1/generations/' + id, { headers }); assert.equal(read.status, 200);
  assert.equal((await fetch(base + '/v1/status', { headers: { ...headers, Origin: 'https://attacker.test' } })).status, 403);
  const auth = store.auth(); auth.devices = []; store.writeAuth(auth);
  assert.equal((await fetch(base + '/v1/generations/' + id, { headers })).status, 401);
});

test('daily cap is enforced before another provider submission', (t) => {
  const { bridge } = setup(t); bridge.dailyLimit = 1;
  bridge.create(crypto.randomUUID(), 'device-1', request());
  assert.throws(() => bridge.create(crypto.randomUUID(), 'device-1', request()), /每日/);
});

test('one runtime cannot run two workers, including on different ports', (t) => {
  const { store } = setup(t);
  const release = acquireRuntimeLock(store.directory);
  assert.throws(() => acquireRuntimeLock(store.directory), /server lock/);
  assert.throws(() => recoverRuntimeLock(store.directory), /still running/);
  release(); release();
  const replacement = acquireRuntimeLock(store.directory); replacement();
  assert.equal(recoverRuntimeLock(store.directory), false);
});
