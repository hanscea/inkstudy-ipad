import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import dns from 'node:dns/promises';

export const MODEL = 'wanx2.1-imageedit';
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const IMAGE_LIMIT = 10 * 1024 * 1024;
const TERMINAL = new Set(['SUCCEEDED', 'FAILED', 'SUBMISSION_UNKNOWN']);
const sha = (value) => crypto.createHash('sha256').update(value).digest('hex');
const iso = () => new Date().toISOString();

export function redactAPIKeys(value) {
  return String(value).replace(/sk-[A-Za-z0-9._~+\/=\x2d]+/g, '[redacted]');
}
export function extractAPIKey(text) {
  const values = [...new Set(text.match(/sk-[A-Za-z0-9._~+\/=\x2d]{16,}/g) ?? [])];
  if (values.length !== 1) throw new Error('Key file must contain exactly one DashScope API key. No key was printed.');
  return values[0];
}

export class BridgeError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const invalid = (code, message) => new BridgeError(400, code, message);
export function atomicJSON(filename, value) {
  fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
  const temporary = filename + '.' + crypto.randomUUID() + '.partial';
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try { fs.writeFileSync(descriptor, JSON.stringify(value, null, 2)); fs.fsyncSync(descriptor); }
  finally { fs.closeSync(descriptor); }
  fs.renameSync(temporary, filename);
  const directory = fs.openSync(path.dirname(filename), 'r');
  try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
}

export function acquireRuntimeLock(directory) {
  const filename = path.join(directory, 'server.lock');
  const owner = { pid: process.pid, nonce: crypto.randomUUID(), createdAt: iso() };
  let descriptor;
  try { descriptor = fs.openSync(filename, 'wx', 0o600); }
  catch (error) {
    if (error.code === 'EEXIST') throw new Error('This runtime already has a server lock. Stop the existing server first; after an abnormal exit, use recover-runtime.');
    throw error;
  }
  try { fs.writeFileSync(descriptor, JSON.stringify(owner)); fs.fsyncSync(descriptor); }
  finally { fs.closeSync(descriptor); }
  return () => {
    if (fs.existsSync(filename) && JSON.parse(fs.readFileSync(filename, 'utf8')).nonce === owner.nonce) fs.unlinkSync(filename);
  };
}

export function recoverRuntimeLock(directory) {
  const filename = path.join(directory, 'server.lock');
  if (!fs.existsSync(filename)) return false;
  const owner = JSON.parse(fs.readFileSync(filename, 'utf8'));
  if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0 || !UUID.test(owner.nonce ?? '')) throw new Error('The runtime lock is damaged. Inspect it manually before recovery.');
  try { process.kill(owner.pid, 0); }
  catch (error) {
    if (error.code !== 'ESRCH') throw new Error('Cannot establish that the lock owner has exited. The lock was retained.');
    if (JSON.parse(fs.readFileSync(filename, 'utf8')).nonce !== owner.nonce) throw new Error('The runtime lock changed during recovery.');
    fs.unlinkSync(filename); return true;
  }
  throw new Error('The lock owner is still running. Stop that server before recovery.');
}

const crcTable = Array.from({ length: 256 }, (_, value) => {
  let crc = value;
  for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  return crc >>> 0;
});
export function crc32(bytes) {
  let crc = 0xffffffff;
  for (const value of bytes) crc = (crc >>> 8) ^ crcTable[(crc ^ value) & 255];
  return (crc ^ 0xffffffff) >>> 0;
}
export function inspectPNG(bytes) {
  if (bytes.length < 45 || bytes.length > IMAGE_LIMIT || !bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
    throw invalid('invalid_png', '请使用 App 导出的 PNG，文件不得超过 10 MB。');
  }
  let offset = 8, width, height, imageData = false, ended = false;
  while (offset + 12 <= bytes.length) {
    const size = bytes.readUInt32BE(offset), end = offset + 12 + size;
    if (end > bytes.length) throw invalid('invalid_png', 'PNG 数据不完整。');
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if (crc32(bytes.subarray(offset + 4, end - 4)) !== bytes.readUInt32BE(end - 4)) throw invalid('invalid_png', 'PNG 校验失败。');
    if (offset === 8) {
      if (type !== 'IHDR' || size !== 13) throw invalid('invalid_png', '缺少 PNG 图像头。');
      width = bytes.readUInt32BE(offset + 8); height = bytes.readUInt32BE(offset + 12);
      if (width < 512 || height < 512 || width > 4096 || height > 4096) throw invalid('image_dimensions', '图像宽高须在 512–4096 像素之间。');
    } else if (type === 'IHDR') throw invalid('invalid_png', '重复的 PNG 图像头。');
    if (type === 'IDAT') imageData = true;
    offset = end;
    if (type === 'IEND') { ended = size === 0 && offset === bytes.length; break; }
  }
  if (!ended || !imageData) throw invalid('invalid_png', 'PNG 数据不完整。');
  return { width, height, bytes: bytes.length, sha256: sha(bytes) };
}

export function normalizeRequest(body) {
  if (!body || typeof body !== 'object' || !UUID.test(body.sourceDocumentID ?? '')) throw invalid('source_required', '缺少原画编号。');
  if (typeof body.prompt !== 'string' || body.prompt.trim().length < 2 || [...body.prompt].length > 500) throw invalid('invalid_prompt', '画面描述须为 2–500 个字符。');
  if (!['independent', 'research'].includes(body.mode) || body.uploadConsent !== true) throw invalid('consent_required', '须确认上传授权及体验用途。');
  if (body.mode === 'research' && !/^[A-Za-z0-9_-]{2,32}$/.test(body.participantCode ?? '')) throw invalid('participant_required', '研究体验须填写参与者代号。');
  if (typeof body.imageBase64 !== 'string' || body.imageBase64.length > Math.ceil(IMAGE_LIMIT / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(body.imageBase64)) throw invalid('invalid_image', '图像编码无效。');
  const image = Buffer.from(body.imageBase64, 'base64');
  if (image.toString('base64') !== body.imageBase64) throw invalid('invalid_image', '图像编码无效。');
  const imageInfo = inspectPNG(image);
  const seed = body.seed;
  if (!Number.isInteger(seed) || seed < 0 || seed > 2147483647) throw invalid('invalid_seed', '生成种子无效。');
  const request = {
    model: MODEL, function: 'doodle', parameters: { is_sketch: true, n: 1, watermark: true, seed },
    prompt: body.prompt.trim(), sourceDocumentID: body.sourceDocumentID.toUpperCase(), source: imageInfo,
    mode: body.mode, participantCode: body.mode === 'research' ? body.participantCode : null, uploadConsent: true,
    consentVersion: 'native-image-upload-v1', appVersion: String(body.appVersion ?? 'unknown').slice(0, 40)
  };
  return { image, request, fingerprint: sha(JSON.stringify(request)) };
}

export class RuntimeStore {
  constructor(directory) {
    this.directory = directory;
    fs.mkdirSync(path.join(directory, 'jobs'), { recursive: true, mode: 0o700 });
    this.authFile = path.join(directory, 'auth.json');
    if (!fs.existsSync(this.authFile)) atomicJSON(this.authFile, { devices: [], pairing: null, approvedParticipants: [] });
  }
  auth() { return JSON.parse(fs.readFileSync(this.authFile, 'utf8')); }
  writeAuth(auth) { atomicJSON(this.authFile, auth); }
  jobDirectory(id) { if (!UUID.test(id)) throw invalid('invalid_id', '任务编号无效。'); return path.join(this.directory, 'jobs', id.toUpperCase()); }
  read(id) {
    const filename = path.join(this.jobDirectory(id), 'job.json');
    return fs.existsSync(filename) ? JSON.parse(fs.readFileSync(filename, 'utf8')) : null;
  }
  write(job) { atomicJSON(path.join(this.jobDirectory(job.id), 'job.json'), job); }
  list() {
    return fs.readdirSync(path.join(this.directory, 'jobs')).filter((name) => UUID.test(name)).map((id) => this.read(id)).filter(Boolean);
  }
  create(id, owner, normalized) {
    const directory = this.jobDirectory(id);
    const job = { id: id.toUpperCase(), owner, status: 'QUEUED', createdAt: iso(), updatedAt: iso(),
      request: normalized.request, fingerprint: normalized.fingerprint, providerTaskID: null, providerRequestID: null,
      resultFile: null, resultSHA256: null, resultMimeType: null, error: null, lastPolledAt: null };
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const filename = path.join(directory, 'original.png');
    const handle = fs.openSync(filename, 'w', 0o600);
    try { fs.writeFileSync(handle, normalized.image); fs.fsyncSync(handle); } finally { fs.closeSync(handle); }
    this.write(job); return job;
  }
  recover() {
    for (const job of this.list()) {
      if (job.status === 'SUBMITTING') {
        job.status = job.providerTaskID ? 'PENDING' : 'SUBMISSION_UNKNOWN';
        job.error = job.providerTaskID ? null : { code: 'submission_unknown', message: '提交时连接中断，可能已创建云端任务。请核对百炼任务记录，不会自动重复提交。' };
        job.updatedAt = iso(); this.write(job);
      }
    }
  }
  pairCode() {
    const code = String(crypto.randomInt(10000000, 100000000)), auth = this.auth();
    auth.pairing = { hash: sha(code), expiresAt: Date.now() + 10 * 60_000 };
    this.writeAuth(auth); return code;
  }
  pair(code, deviceID, label) {
    const auth = this.auth(), expected = auth.pairing;
    if (!expected || expected.expiresAt < Date.now() || !safeEqual(expected.hash, sha(String(code)))) throw new BridgeError(401, 'invalid_pairing', '配对码无效或已过期。');
    if (!UUID.test(deviceID ?? '')) throw invalid('invalid_device', '设备编号无效。');
    const token = crypto.randomBytes(32).toString('base64url');
    auth.devices = auth.devices.filter((device) => device.id !== deviceID);
    auth.devices.push({ id: deviceID, hash: sha(token), label: String(label ?? 'iPad').slice(0, 80), createdAt: iso() });
    auth.pairing = null; this.writeAuth(auth);
    return { token, deviceID };
  }
  authenticate(header) {
    const match = /^Bearer ([A-Za-z0-9_-]{40,80})$/.exec(header ?? '');
    if (!match) throw new BridgeError(401, 'authentication_required', '请先与服务端配对。');
    const hash = sha(match[1]), device = this.auth().devices.find((item) => safeEqual(item.hash, hash));
    if (!device) throw new BridgeError(401, 'authentication_required', '配对已失效，请重新配对。');
    return device.id;
  }
}
function safeEqual(a, b) { return typeof a === 'string' && a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b)); }

async function boundedBody(response, limit) {
  const length = Number(response.headers.get('content-length') ?? 0);
  if (length > limit) throw new Error('response_too_large');
  const parts = []; let size = 0;
  for await (const part of response.body) { size += part.length; if (size > limit) throw new Error('response_too_large'); parts.push(part); }
  return Buffer.concat(parts);
}
export function allowedResultURL(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') ||
      !['.aliyuncs.com', '.alicdn.com'].some((suffix) => url.hostname.endsWith(suffix))) throw new Error('unsafe_result_url');
  return url;
}
function privateAddress(value) {
  if (value.includes(':')) return value === '::1' || /^(fc|fd|fe8|fe9|fea|feb|::ffff:)/i.test(value);
  const [a, b] = value.split('.').map(Number);
  return a === 0 || a === 10 || a === 127 || a === 169 && b === 254 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 || a >= 224;
}
export class WanxProvider {
  constructor({ apiKey, base = 'https://dashscope.aliyuncs.com/api/v1' }) {
    const url = new URL(base);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.port || url.pathname.replace(/\/$/, '') !== '/api/v1' ||
        !(url.hostname === 'dashscope.aliyuncs.com' || /^[a-z0-9-]+\.cn-beijing\.maas\.aliyuncs\.com$/.test(url.hostname))) throw new Error('invalid_provider_endpoint');
    this.apiKey = apiKey; this.base = base.replace(/\/$/, '');
  }
  async json(route, options = {}) {
    const response = await fetch(this.base + route, { ...options, redirect: 'error', signal: AbortSignal.timeout(30_000),
      headers: { Authorization: `Bearer ${this.apiKey}`, 'Content-Type': 'application/json', ...options.headers } });
    const data = JSON.parse((await boundedBody(response, 1024 * 1024)).toString('utf8'));
    if (!response.ok || data.code) {
      const error = new Error(String(data.code ?? 'provider_http_' + response.status));
      error.providerCode = data.code; error.requestID = data.request_id;
      error.definiteRejection = response.status >= 400 && response.status < 500;
      throw error;
    }
    return data;
  }
  async submit(request, image) {
    const data = await this.json('/services/aigc/image2image/image-synthesis', { method: 'POST', headers: { 'X-DashScope-Async': 'enable' }, body: JSON.stringify({
      model: MODEL, input: { function: 'doodle', prompt: request.prompt, base_image_url: 'data:image/png;base64,' + image.toString('base64') }, parameters: request.parameters
    }) });
    if (!UUID.test(data.output?.task_id ?? '')) throw new Error('missing_provider_task_id');
    return { taskID: data.output.task_id, requestID: data.request_id ?? null };
  }
  async poll(taskID) { if (!UUID.test(taskID)) throw new Error('invalid_provider_task_id'); return this.json('/tasks/' + taskID); }
  async download(value) {
    const url = allowedResultURL(value), addresses = await dns.lookup(url.hostname, { all: true });
    if (!addresses.length || addresses.some((entry) => privateAddress(entry.address))) throw new Error('unsafe_result_address');
    const response = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(60_000) });
    if (!response.ok) throw new Error('result_download_http_' + response.status);
    const data = await boundedBody(response, 32 * 1024 * 1024);
    const png = data.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'));
    const jpeg = data[0] === 255 && data[1] === 216 && data[2] === 255;
    if (!png && !jpeg) throw new Error('unsupported_result_image');
    return { data, extension: png ? 'png' : 'jpg', mime: png ? 'image/png' : 'image/jpeg' };
  }
}

export class Bridge {
  constructor({ store, provider, dailyLimit = 10, pollMilliseconds = 5000 }) {
    this.store = store; this.provider = provider; this.dailyLimit = dailyLimit; this.pollMilliseconds = pollMilliseconds;
    this.working = false; this.volatile = new Map(); this.store.recover();
  }
  get(id) { return this.volatile.get(id.toUpperCase()) ?? this.store.read(id); }
  save(job) { job.updatedAt = iso(); this.volatile.set(job.id, job); this.store.write(job); this.volatile.delete(job.id); }
  create(id, owner, body) {
    if (!this.provider?.apiKey && !(this.provider?.isTestProvider)) throw new BridgeError(503, 'provider_not_configured', '服务端尚未配置万相 API Key。');
    const normalized = normalizeRequest(body), existing = this.get(id);
    if (existing) {
      if (existing.owner !== owner) throw new BridgeError(404, 'not_found', '未找到任务。');
      if (existing.fingerprint !== normalized.fingerprint) throw new BridgeError(409, 'idempotency_conflict', '同一任务编号不能替换原图或描述。');
      return existing;
    }
    if (normalized.request.mode === 'research' && !this.store.auth().approvedParticipants.some((entry) => entry.code === normalized.request.participantCode && entry.allVisitsCompleted === true)) {
      throw new BridgeError(403, 'research_not_released', '该参与者尚未在服务端核准：须完成 V1a–V7 全部测量。');
    }
    const today = iso().slice(0, 10), jobs = this.store.list();
    if (jobs.filter((job) => job.createdAt.startsWith(today)).length >= this.dailyLimit) throw new BridgeError(429, 'daily_limit', '已达到服务端每日生成上限，请由研究者核查用量。');
    if (jobs.filter((job) => !TERMINAL.has(job.status)).length >= 2) throw new BridgeError(429, 'queue_full', '已有生成任务，请等待完成。');
    return this.store.create(id, owner, normalized);
  }
  async tick() {
    if (this.working || !this.provider) return; this.working = true;
    try {
      for (const job of this.volatile.values()) this.save(job);
      for (const job of this.store.list()) {
        if (job.status === 'QUEUED') {
          job.status = 'SUBMITTING'; this.save(job);
          try {
            const receipt = await this.provider.submit(job.request, fs.readFileSync(path.join(this.store.jobDirectory(job.id), 'original.png')));
            job.providerTaskID = receipt.taskID; job.providerRequestID = receipt.requestID;
            job.status = 'PENDING'; this.save(job);
          } catch (error) {
            job.status = job.providerTaskID ? 'PENDING' : error.definiteRejection ? 'FAILED' : 'SUBMISSION_UNKNOWN';
            job.error = { code: safeCode(error), message: job.status === 'FAILED' ? '万相未接受请求，请检查密钥、额度、地域或内容要求。' : '提交结果尚不确定，不会自动重复生成。请核对云端任务。' };
            this.save(job);
          }
        } else if (['PENDING', 'RUNNING', 'RESULT_PENDING'].includes(job.status) && (!job.lastPolledAt || Date.now() - Date.parse(job.lastPolledAt) >= this.pollMilliseconds)) {
          job.lastPolledAt = iso(); this.save(job);
          try {
            const response = await this.provider.poll(job.providerTaskID), output = response.output;
            if (!output || !['PENDING', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELED', 'UNKNOWN'].includes(output.task_status)) throw new Error('invalid_provider_response');
            job.providerRequestID = response.request_id ?? job.providerRequestID;
            if (output.task_status === 'SUCCEEDED') {
              const url = output.results?.find((result) => result.url)?.url;
              if (!url) throw new Error('missing_result_url');
              job.status = 'RESULT_PENDING'; job.resultURL = url; this.save(job);
              const result = await this.provider.download(url);
              const resultFile = 'generated.' + result.extension, filename = path.join(this.store.jobDirectory(job.id), resultFile);
              const handle = fs.openSync(filename, 'w', 0o600);
              try { fs.writeFileSync(handle, result.data); fs.fsyncSync(handle); } finally { fs.closeSync(handle); }
              job.resultFile = resultFile; job.resultSHA256 = sha(result.data); job.resultMimeType = result.mime;
              job.status = 'SUCCEEDED'; job.error = null; job.completedAt = iso(); job.usage = response.usage ?? null;
            } else if (['FAILED', 'CANCELED', 'UNKNOWN'].includes(output.task_status)) {
              job.status = 'FAILED'; job.error = { code: safeCode({ message: output.code ?? output.task_status }), message: '云端任务未完成，请保留原画并查看任务记录。' };
            } else { job.status = output.task_status; job.error = null; }
            this.save(job);
          } catch (error) {
            job.error = { code: safeCode(error), message: '查询或下载暂时失败；保留原任务编号后继续查询，不会重新生成。' };
            this.save(job);
          }
        }
      }
    } finally { this.working = false; }
  }
}
function safeCode(error) { return redactAPIKeys(error.providerCode ?? error.message ?? 'internal_error').replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 100); }
export function publicJob(job) {
  const { owner, fingerprint, resultURL, ...safe } = job;
  return safe;
}

async function jsonBody(request, max) {
  if (!(request.headers['content-type'] ?? '').startsWith('application/json')) throw new BridgeError(415, 'json_required', '请使用 JSON 请求。');
  if (Number(request.headers['content-length'] ?? 0) > max) throw new BridgeError(413, 'request_too_large', '请求超过大小限制。');
  let bytes = 0; const parts = [];
  for await (const part of request) { bytes += part.length; if (bytes > max) throw new BridgeError(413, 'request_too_large', '请求超过大小限制。'); parts.push(part); }
  try { return JSON.parse(Buffer.concat(parts).toString('utf8')); } catch { throw invalid('invalid_json', 'JSON 无效。'); }
}
export function createServer(bridge) {
  const attempts = new Map();
  function rate(ip) {
    const now = Date.now();
    for (const [key, item] of attempts) if (item.reset < now) attempts.delete(key);
    const item = attempts.get(ip) ?? { count: 0, reset: now + 60_000 };
    item.count++; attempts.set(ip, item);
    if (item.count > 5 || attempts.size > 2000) throw new BridgeError(429, 'pair_rate_limit', '尝试次数过多，请一分钟后再试。');
  }
  return http.createServer({ requestTimeout: 30_000, headersTimeout: 15_000 }, async (request, response) => {
    response.setHeader('Cache-Control', 'no-store'); response.setHeader('X-Content-Type-Options', 'nosniff');
    function send(status, data) { response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); response.end(JSON.stringify(data)); }
    try {
      if (request.headers.origin) throw new BridgeError(403, 'native_client_only', '此接口仅供已配对原生客户端使用。');
      const url = new URL(request.url, 'http://localhost');
      if (url.pathname === '/health' && request.method === 'GET') return send(200, { service: 'inkstudy-wanx-bridge', version: 1 });
      if (url.pathname === '/v1/pair' && request.method === 'POST') {
        rate(request.socket.remoteAddress);
        const body = await jsonBody(request, 4096);
        return send(200, bridge.store.pair(body.code, body.deviceID, body.label));
      }
      const owner = bridge.store.authenticate(request.headers.authorization);
      if (url.pathname === '/v1/status' && request.method === 'GET') return send(200, { model: MODEL, configured: Boolean(bridge.provider?.apiKey), dailyLimit: bridge.dailyLimit, imageCount: 1, watermark: true });
      const match = /^\/v1\/generations\/([a-fA-F0-9-]+)(\/image)?$/.exec(url.pathname);
      if (!match || !UUID.test(match[1])) throw new BridgeError(404, 'not_found', '未找到接口。');
      const id = match[1].toUpperCase();
      if (request.method === 'PUT' && !match[2]) {
        const job = bridge.create(id, owner, await jsonBody(request, 14 * 1024 * 1024));
        send(202, publicJob(job));
        void bridge.tick().catch(() => {}); return;
      }
      if (request.method !== 'GET') throw new BridgeError(405, 'method_not_allowed', '不支持此操作。');
      const job = bridge.get(id);
      if (!job || job.owner !== owner) throw new BridgeError(404, 'not_found', '未找到任务。');
      if (!match[2]) return send(200, publicJob(job));
      if (job.status !== 'SUCCEEDED' || !job.resultFile) throw new BridgeError(409, 'image_not_ready', '生成图尚未保存。');
      const data = fs.readFileSync(path.join(bridge.store.jobDirectory(id), job.resultFile));
      if (sha(data) !== job.resultSHA256) throw new BridgeError(500, 'image_integrity_error', '生成文件校验失败，请保留原任务并联系研究者。');
      response.writeHead(200, { 'Content-Type': job.resultMimeType, 'Content-Length': data.length }); response.end(data);
    } catch (error) {
      if (!response.headersSent) send(error.status ?? 500, { error: { code: error.code ?? 'internal_error', message: error.status ? error.message : '服务端暂时无法处理请求，原画未被修改。' } });
      else response.destroy();
    }
  });
}
