import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { RuntimeStore, BridgeError, atomicJSON, UUID } from './bridge.mjs';

export const HINT_VERSION = 'multimodal-preview-v1-20260917';
export const DEEPSEEK_MODEL = 'deepseek-flash';
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const fail = (status, code) => new BridgeError(status, code, code);
const metricKeys = new Set(['redPaintUnits', 'yellowPaintUnits', 'bluePaintUnits', 'mixedAreaFraction', 'pigmentRatioVariance',
  'signedPressureError', 'pressureMAE', 'normalizedForceSD', 'pencilSampleCount', 'sampleCount', 'dynamicPressureTarget']);
const pairs = { orange: ['red', 'yellow'], green: ['yellow', 'blue'], violet: ['red', 'blue'] };
const pressureTargets = ['light', 'medium', 'firm', 'lightToFirm', 'firmToLight', 'lightFirmLight'];
const plain = value => value && typeof value === 'object' && !Array.isArray(value);
function exactKeys(value, keys) {
  if (!plain(value) || Object.keys(value).some(key => !keys.includes(key))) throw fail(400, 'unexpected_fields');
}

export function deepseekKeyFromDocument(filename) {
  if (!path.isAbsolute(filename) || fs.statSync(filename).size > 65_536) throw fail(400, 'invalid_key_file');
  const text = fs.readFileSync(filename, 'utf8');
  // The supplied document also contains a different provider's key. Never guess between them.
  const keys = [...text.matchAll(/(?:^|\n)\s*DeepSeek\s+API\s*KEY\s*:\s*(sk-[A-Za-z0-9_-]{16,})/gi)].map(m => m[1]);
  if (keys.length !== 1) throw fail(400, 'one_deepseek_labeled_key_required');
  return keys[0];
}

export function normalizeHintRequest(body) {
  exactKeys(body, ['version', 'requestID', 'mode', 'uploadConsent', 'group', 'level', 'summary']);
  if (body.version !== HINT_VERSION || !UUID.test(body.requestID ?? '') || body.mode !== 'adult_rehearsal' ||
      body.uploadConsent !== true || body.group !== 'C' || ![1, 2, 3].includes(body.level)) throw fail(400, 'rehearsal_consent_required');
  const s = body.summary;
  exactKeys(s, ['task', 'target', 'strokeCount', 'metrics']);
  if (!['mix', 'pressure'].includes(s.task) || !(s.task === 'mix' ? Object.hasOwn(pairs, s.target) : pressureTargets.includes(s.target)) ||
      !Number.isInteger(s.strokeCount) || s.strokeCount < 1 || s.strokeCount > 100_000) throw fail(400, 'invalid_summary');
  if (!plain(s.metrics) || Object.entries(s.metrics).some(([key, value]) => !metricKeys.has(key) || typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > 1_000_000)) throw fail(400, 'invalid_metrics');
  const metrics = Object.fromEntries(Object.entries(s.metrics).sort(([a], [b]) => a.localeCompare(b)));
  return { version: HINT_VERSION, requestID: body.requestID.toUpperCase(), mode: 'adult_rehearsal', uploadConsent: true,
    group: 'C', level: body.level, summary: { task: s.task, target: s.target, strokeCount: s.strokeCount, metrics } };
}

export function hintCandidates(s) {
  const m = s.metrics;
  if (s.task === 'mix') {
    const pair = pairs[s.target], amounts = pair.map(color => Math.max(0, m[color + 'PaintUnits'] ?? 0));
    if (amounts[0] < 0.02 && amounts[1] >= 0.02) return ['mix_add_' + pair[0], 'mix_observe'];
    if (amounts[1] < 0.02 && amounts[0] >= 0.02) return ['mix_add_' + pair[1], 'mix_observe'];
    if (amounts[0] + amounts[1] < 0.04) return ['mix_observe'];
    if ((m.mixedAreaFraction ?? 0) < 0.65 || (m.pigmentRatioVariance ?? 1) > 0.08) return ['mix_stir', 'mix_observe'];
    if (amounts[0] > amounts[1] * 2) return ['mix_add_' + pair[1], 'mix_compare'];
    if (amounts[1] > amounts[0] * 2) return ['mix_add_' + pair[0], 'mix_compare'];
    return ['mix_compare', 'mix_observe'];
  }
  if ((m.pencilSampleCount ?? 0) < 8) return ['pressure_pencil', 'pressure_observe'];
  if ((m.dynamicPressureTarget ?? 0) === 1) return ['pressure_follow', 'pressure_observe'];
  if ((m.signedPressureError ?? 0) > 0.10) return ['pressure_lighter', 'pressure_observe'];
  if ((m.signedPressureError ?? 0) < -0.10) return ['pressure_firmer', 'pressure_observe'];
  if ((m.normalizedForceSD ?? 0) > 0.12) return ['pressure_steady', 'pressure_observe'];
  return ['pressure_observe', 'pressure_steady'];
}

export class DeepSeekHintProvider {
  constructor({ apiKey, fetchImpl = fetch, timeout = 8000 }) { this.apiKey = apiKey; this.fetchImpl = fetchImpl; this.timeout = timeout; }
  async select(summary, level) {
    const candidates = hintCandidates(summary);
    const response = await this.fetchImpl('https://api.deepseek.com/chat/completions', {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(this.timeout),
      headers: { Authorization: 'Bearer ' + this.apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: DEEPSEEK_MODEL, thinking: { type: 'disabled' }, max_tokens: 96,
        response_format: { type: 'json_object' }, messages: [
          { role: 'system', content: 'You select one safe action hint for an adult rehearsal of a child drawing app. Return JSON only: {"strategy":"allowed_id"}. Choose exclusively from allowedStrategies. Use the measured evidence; negative signedPressureError means too light, positive means too heavy. Missing Pencil data is not measured pressure. If pigments are still separate, choose stirring rather than more pigment. Never infer emotions, ability, or diagnoses. No prose, scores, coordinates, tools, or extra keys.' },
          { role: 'user', content: JSON.stringify({ summary, hintLevel: level, allowedStrategies: candidates }) }
        ] })
    });
    if (!response.ok) throw fail(502, 'provider_http_' + response.status);
    const chunks = []; let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length; if (size > 32_768) throw fail(502, 'provider_response_too_large'); chunks.push(chunk);
    }
    let data, result;
    try { data = JSON.parse(Buffer.concat(chunks)); result = JSON.parse(data.choices?.[0]?.message?.content ?? ''); }
    catch { throw fail(502, 'provider_invalid_json'); }
    if (data.choices?.[0]?.finish_reason !== 'stop' || !plain(result) || Object.keys(result).length !== 1 || !candidates.includes(result.strategy)) throw fail(502, 'provider_invalid_strategy');
    return { strategy: result.strategy, model: typeof data.model === 'string' && /^deepseek-[a-z0-9.-]{1,70}$/.test(data.model) ? data.model : DEEPSEEK_MODEL };
  }
}

export class HintBridge {
  constructor({ directory, provider, dailyLimit = 30, now = () => new Date() }) {
    if (!Number.isInteger(dailyLimit) || dailyLimit < 1 || dailyLimit > 200) throw fail(400, 'invalid_daily_limit');
    this.store = new RuntimeStore(directory); this.provider = provider; this.dailyLimit = dailyLimit; this.now = now;
    this.requests = path.join(directory, 'hint-requests'); fs.mkdirSync(this.requests, { recursive: true, mode: 0o700 });
    this.inflight = new Map(); this.lastRequests = new Map(); this.pairAttempts = new Map();
  }
  async select(owner, body) {
    const request = normalizeHintRequest(body), id = request.requestID, file = path.join(this.requests, id + '.json');
    const fingerprint = sha(JSON.stringify(request)), day = this.now().toISOString().slice(0, 10);
    if (fs.existsSync(file)) {
      const saved = JSON.parse(fs.readFileSync(file));
      if (saved.owner !== owner || saved.fingerprint !== fingerprint) throw fail(409, 'request_conflict');
      if (saved.result) return saved.result;
      if (this.inflight.has(id)) return this.inflight.get(id);
      throw fail(409, 'request_not_repeated');
    }
    const recent = this.lastRequests.get(owner);
    if (recent && this.now().getTime() - recent < 2000) throw fail(429, 'request_cooldown');
    if (this.inflight.size >= 2) throw fail(429, 'server_busy');
    const count = fs.readdirSync(this.requests).filter(name => name.endsWith('.json')).filter(name => JSON.parse(fs.readFileSync(path.join(this.requests, name))).day === day).length;
    if (count >= this.dailyLimit) throw fail(429, 'daily_limit');
    if (!this.provider) throw fail(503, 'provider_not_configured');
    // Persist before calling. Retries/restarts never silently spend on the same request twice.
    const receipt = { id, owner, fingerprint, day, status: 'pending', result: null };
    atomicJSON(file, receipt); this.lastRequests.set(owner, this.now().getTime());
    const run = (async () => {
      const started = performance.now();
      try {
        const selected = await this.provider.select(request.summary, request.level);
        if (!hintCandidates(request.summary).includes(selected.strategy)) throw fail(502, 'provider_invalid_strategy');
        const result = { requestID: id, strategy: selected.strategy, model: selected.model, latencyMilliseconds: Math.round(performance.now() - started), version: HINT_VERSION };
        atomicJSON(file, { ...receipt, status: 'succeeded', result }); return result;
      } catch (error) {
        const code = error instanceof BridgeError ? error.code : 'provider_unavailable';
        atomicJSON(file, { ...receipt, status: 'failed', error: code }); throw fail(502, code);
      }
    })();
    this.inflight.set(id, run);
    try { return await run; } finally { this.inflight.delete(id); }
  }
}

export function createHintServer(bridge) {
  const server = http.createServer(async (req, res) => {
    function send(status, body) { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(body)); }
    try {
      if (req.headers.origin || req.headers['sec-fetch-site']) throw fail(403, 'native_clients_only');
      if (!['GET', 'POST'].includes(req.method)) throw fail(405, 'method_not_allowed');
      let body;
      if (req.method === 'POST') {
        if (!req.headers['content-type']?.startsWith('application/json')) throw fail(415, 'json_required');
        const chunks = []; let size = 0;
        for await (const part of req) { size += part.length; if (size > 8192) throw fail(413, 'request_too_large'); chunks.push(part); }
        try { body = JSON.parse(Buffer.concat(chunks)); } catch { throw fail(400, 'invalid_json'); }
      }
      if (req.method === 'POST' && req.url === '/v1/pair') {
        const ip = req.socket.remoteAddress, now = Date.now();
        const recent = (bridge.pairAttempts.get(ip) ?? []).filter(t => now - t < 60_000);
        if (recent.length >= 5) throw fail(429, 'pairing_rate_limit');
        bridge.pairAttempts.set(ip, [...recent, now]);
        exactKeys(body, ['code', 'deviceID', 'label']);
        if (typeof body.code !== 'string' || !/^\d{8}$/.test(body.code)) throw fail(400, 'invalid_pairing');
        return send(200, bridge.store.pair(body.code, body.deviceID, 'Hint preview iPad'));
      }
      const owner = bridge.store.authenticate(req.headers.authorization);
      if (req.method === 'GET' && req.url === '/v1/status') return send(200, { configured: Boolean(bridge.provider), model: DEEPSEEK_MODEL, version: HINT_VERSION, dailyLimit: bridge.dailyLimit });
      if (req.method === 'POST' && req.url === '/v1/hints') return send(200, await bridge.select(owner, body));
      throw fail(404, 'not_found');
    } catch (error) {
      send(error instanceof BridgeError ? error.status : 500, { error: { code: error instanceof BridgeError ? error.code : 'internal_error' } });
    }
  });
  server.requestTimeout = 12_000; server.headersTimeout = 10_000;
  return server;
}
