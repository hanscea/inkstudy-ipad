import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { RuntimeStore, atomicJSON, acquireRuntimeLock, recoverRuntimeLock } from './bridge.mjs';
import { HintBridge, DeepSeekHintProvider, deepseekKeyFromDocument, createHintServer } from './hints.mjs';

const args = process.argv.slice(2), command = args.shift();
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const directory = path.resolve(option('--runtime', path.join(os.homedir(), 'Library/Application Support/InkStudyHintBridge')));
const store = new RuntimeStore(directory), file = path.join(directory, 'configuration.json');
const config = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
try {
  if (command === 'configure') {
    const keyFile = option('--key-file', config.keyFile), dailyLimit = Number(option('--daily-limit', config.dailyLimit ?? 30));
    deepseekKeyFromDocument(keyFile);
    if (!Number.isInteger(dailyLimit) || dailyLimit < 1 || dailyLimit > 200) throw new Error();
    atomicJSON(file, { keyFile, dailyLimit });
    process.stdout.write('DeepSeek hint configuration saved. No key copied or printed.\n');
  } else if (command === 'pair') {
    process.stdout.write(`One-use hint pairing code (10 minutes): ${store.pairCode()}\n`);
  } else if (command === 'bootstrap') {
    const destination = option('--destination'), endpoint = option('--endpoint');
    if (!destination || !path.isAbsolute(destination)) throw new Error();
    const address = new URL(endpoint);
    if (!['http:', 'https:'].includes(address.protocol) || address.username || address.password || address.search || address.hash || address.pathname !== '/') throw new Error();
    atomicJSON(destination, { endpoint: address.origin, code: store.pairCode() });
    process.stdout.write('One-use adult rehearsal bootstrap written. Contains pairing code only, not an API key.\n');
  } else if (command === 'status') {
    process.stdout.write(JSON.stringify({ configured: Boolean(config.keyFile), dailyLimit: config.dailyLimit ?? 30, devices: store.auth().devices.map(({ id }) => id) }) + '\n');
  } else if (command === 'recover-runtime') {
    process.stdout.write(recoverRuntimeLock(directory) ? 'Stale hint runtime lock recovered.\n' : 'No lock exists.\n');
  } else if (command === 'serve') {
    const key = deepseekKeyFromDocument(config.keyFile), host = option('--host', '127.0.0.1'), port = Number(option('--port', 8788));
    if (!['127.0.0.1', '0.0.0.0'].includes(host) || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error();
    const release = acquireRuntimeLock(directory); process.once('exit', release);
    const bridge = new HintBridge({ directory, provider: new DeepSeekHintProvider({ apiKey: key }), dailyLimit: config.dailyLimit ?? 30 });
    const server = createHintServer(bridge);
    server.listen(port, host, () => {
      process.stdout.write(`Hint preview bridge: ${host}:${port}; model deepseek-flash; daily request cap ${bridge.dailyLimit}. Adult/synthetic rehearsal only.\n`);
      if (host === '0.0.0.0') for (const entries of Object.values(os.networkInterfaces())) for (const e of entries ?? []) {
        if (e.family === 'IPv4' && !e.internal) process.stdout.write(`Local test address: http://${e.address}:${port}\n`);
      }
    });
    server.on('error', () => { process.stderr.write('Hint server could not start. No credential printed.\n'); process.exitCode = 1; });
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close(() => process.exit(0)));
  } else process.stdout.write('Commands: configure --key-file /absolute/document --daily-limit 30; serve --host 0.0.0.0; pair; status; recover-runtime.\n');
} catch { process.stderr.write('Hint configuration or runtime failed. Check file, labelled DeepSeek key, and runtime lock. No credential printed.\n'); process.exitCode = 1; }
