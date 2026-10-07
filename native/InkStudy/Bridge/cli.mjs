import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { Bridge, RuntimeStore, WanxProvider, createServer, atomicJSON, UUID, acquireRuntimeLock, recoverRuntimeLock, extractAPIKey, redactAPIKeys } from './bridge.mjs';

const args = process.argv.slice(2), command = args.shift();
function option(name, fallback) { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : fallback; }
function options(name) { return args.flatMap((value, index) => value === name ? [args[index + 1]] : []); }
const runtime = path.resolve(option('--runtime', path.join(os.homedir(), 'Library/Application Support/InkStudyBridge')));
const store = new RuntimeStore(runtime);
const configFile = path.join(runtime, 'configuration.json');
const config = fs.existsSync(configFile) ? JSON.parse(fs.readFileSync(configFile, 'utf8')) : {};

function keyFromFile(filename) {
  if (!filename) return undefined;
  if (!path.isAbsolute(filename) || fs.statSync(filename).size > 65_536) throw new Error('Key file must be an absolute path to a small local text file.');
  return extractAPIKey(fs.readFileSync(filename, 'utf8'));
}
function hash(value) { return crypto.createHash('sha256').update(value).digest('hex'); }

try {
  if (command === 'configure') {
    const keyFile = option('--key-file', config.keyFile);
    keyFromFile(keyFile);
    const dailyLimit = Number(option('--daily-limit', config.dailyLimit ?? 10));
    if (!Number.isInteger(dailyLimit) || dailyLimit < 1 || dailyLimit > 500) throw new Error('Daily limit must be 1–500.');
    atomicJSON(configFile, { ...config, keyFile, dailyLimit, apiBase: option('--api-base', config.apiBase) });
    process.stdout.write('Configuration saved. API key remains in its local file and is not included in the app.\n');
  } else if (command === 'pair') {
    process.stdout.write(`One-use pairing code (valid 10 minutes): ${store.pairCode()}\n`);
  } else if (command === 'status') {
    const auth = store.auth();
    process.stdout.write(JSON.stringify({ runtime, configured: Boolean(config.keyFile || process.env.DASHSCOPE_API_KEY),
      dailyLimit: config.dailyLimit ?? 10, devices: auth.devices.map(({ id, label, createdAt }) => ({ id, label, createdAt })),
      jobs: store.list().map(({ id, status, providerTaskID, error }) => ({ id, status, providerTaskID, error })) }, null, 2) + '\n');
  } else if (command === 'approve-research') {
    const code = option('--participant'), studies = options('--study');
    if (!/^[A-Za-z0-9_-]{2,32}$/.test(code ?? '') || studies.length < 8) throw new Error('Provide participant code and eight exported study.json paths using repeated --study arguments.');
    const records = studies.map((filename) => {
      const data = fs.readFileSync(filename), record = JSON.parse(data);
      const manifest = JSON.parse(fs.readFileSync(path.join(path.dirname(filename), 'manifest.json'), 'utf8'));
      if (manifest.sha256?.['study.json'] !== hash(data) || manifest.endReason !== 'completed' || manifest.missingDrawingIDs?.length ||
          record.configuration.participantCode !== code || record.configuration.purpose !== 'pilot' ||
          !['native-research-v2-20260910-untimed', 'native-research-v3-20260910-0910V2'].includes(record.configuration.protocolVersion)) throw new Error('Export is incomplete, mismatched, or not an eligible pilot visit.');
      return { configuration: record.configuration, sha256: hash(data) };
    });
    const visits = new Set(records.map((record) => record.configuration.visit));
    if (!['V1a', 'V1b', 'V2', 'V3', 'V4', 'V5', 'V6', 'V7'].every((visit) => visits.has(visit))) throw new Error('All visits, including V7, are required.');
    const orders = new Set(records.map((record) => record.configuration.formOrder + ':' + record.configuration.windFirst));
    const groups = new Set(records.map((record) => record.configuration.group).filter((group) => group !== 'U'));
    if (orders.size !== 1 || groups.size !== 1) throw new Error('Counterbalance or group assignment does not match.');
    const auth = store.auth();
    auth.approvedParticipants = auth.approvedParticipants.filter((entry) => entry.code !== code);
    auth.approvedParticipants.push({ code, allVisitsCompleted: true, approvedAt: new Date().toISOString(), exports: records.map((record) => ({ visit: record.configuration.visit, sha256: record.sha256 })) });
    store.writeAuth(auth); process.stdout.write('Research experience released after checking all exported visits.\n');
  } else if (command === 'attach-task') {
    const id = option('--job'), taskID = option('--provider-task-id');
    if (!UUID.test(id ?? '') || !UUID.test(taskID ?? '')) throw new Error('Provide a job UUID and the verified provider task UUID.');
    const job = store.read(id);
    if (!job || job.status !== 'SUBMISSION_UNKNOWN') throw new Error('Only an uncertain submission can be reconciled this way.');
    const apiKey = process.env.DASHSCOPE_API_KEY || keyFromFile(option('--key-file', config.keyFile));
    if (!apiKey) throw new Error('Configure the server API key first.');
    const provider = new WanxProvider({ apiKey, base: config.apiBase });
    const response = await provider.poll(taskID);
    if (!response.output || response.output.task_status === 'UNKNOWN') throw new Error('The provider could not find this task.');
    job.providerTaskID = taskID; job.status = 'PENDING'; job.error = null; job.lastPolledAt = null;
    job.reconciledAt = new Date().toISOString(); store.write(job);
    process.stdout.write('Existing cloud task attached. No generation request was sent.\n');
  } else if (command === 'revoke-device') {
    const id = option('--device'), auth = store.auth();
    if (!UUID.test(id ?? '') || !auth.devices.some((device) => device.id === id)) throw new Error('Provide a paired device ID from status.');
    auth.devices = auth.devices.filter((device) => device.id !== id); store.writeAuth(auth);
    process.stdout.write('Device token revoked. Existing generation files were retained.\n');
  } else if (command === 'recover-runtime') {
    process.stdout.write(recoverRuntimeLock(runtime) ? 'Stale server lock removed. The next server start will recover pending jobs without resubmitting unknown tasks.\n' : 'No server lock exists.\n');
  } else if (command === 'serve') {
    const apiKey = process.env.DASHSCOPE_API_KEY || keyFromFile(option('--key-file', config.keyFile));
    const host = option('--host', '127.0.0.1'), port = Number(option('--port', 8787));
    if (!['127.0.0.1', '0.0.0.0', '::1'].includes(host) || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid bind address or port.');
    const provider = apiKey ? new WanxProvider({ apiKey, base: option('--api-base', config.apiBase) }) : null;
    // Acquire before job recovery: two processes must never submit the same queued job.
    const release = acquireRuntimeLock(runtime);
    process.once('exit', release);
    const bridge = new Bridge({ store, provider, dailyLimit: config.dailyLimit ?? 10 });
    const server = createServer(bridge);
    const timer = setInterval(() => { void bridge.tick().catch(() => process.stderr.write('Job persistence needs attention. No task was automatically resubmitted.\n')); }, 3000);
    server.listen(port, host, () => {
      process.stdout.write(`InkStudy bridge listening on ${host}:${port}. Provider ${apiKey ? 'configured' : 'not configured'}. Daily cap ${bridge.dailyLimit}.\n`);
      if (host === '0.0.0.0') {
        for (const entries of Object.values(os.networkInterfaces())) for (const entry of entries ?? []) {
          if (entry.family === 'IPv4' && !entry.internal) process.stdout.write(`Local test address: http://${entry.address}:${port}\n`);
        }
        process.stdout.write('HTTP is for trusted local testing only. Use HTTPS for deployed or participant-data operation.\n');
      }
    });
    server.on('error', (error) => { clearInterval(timer); process.stderr.write(`Server could not start: ${error.code ?? 'error'}\n`); process.exitCode = 1; });
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { clearInterval(timer); server.close(() => process.exit(0)); });
  } else {
    process.stdout.write('Commands: configure --key-file /absolute/file; serve [--host 0.0.0.0]; pair; status; recover-runtime; approve-research --participant CODE --study /export/study.json (eight visits).\n');
  }
} catch (error) {
  process.stderr.write(redactAPIKeys(error.message) + '\n'); process.exitCode = 1;
}
