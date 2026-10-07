#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFile, realpath } from 'node:fs/promises';
import { resolve, sep, join } from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { validateExport } from './validate-export.mjs';

const hash = (data) => createHash('sha256').update(data).digest('hex');
async function safeFile(directory, name) {
  assert(typeof name === 'string' && !name.startsWith('/') && !name.split(/[\\/]/).includes('..'), 'Unsafe manifest path');
  const root = await realpath(directory), file = await realpath(resolve(directory, name));
  assert(file.startsWith(root + sep), 'Manifest points outside export'); return file;
}

export async function validateResearch(directory) {
  const manifest = JSON.parse(await readFile(join(directory, 'manifest.json')));
  assert.equal(manifest.format, 'inkstudy-research-export-v1');
  const record = JSON.parse(await readFile(join(directory, 'study.json')));
  assert.equal(record.format, 'inkstudy-research-v1'); assert.equal(record.configuration.id, manifest.sessionID);
  assert.equal(record.configuration.protocolVersion, manifest.protocolVersion);
  for (const [name, expected] of Object.entries(manifest.sha256)) assert.equal(hash(await readFile(await safeFile(directory, name))), expected, `Hash mismatch: ${name}`);
  const ids = new Set(), drawings = new Map();
  let prompts = 0, completedTasks = 0;
  for (const [index, event] of record.events.entries()) {
    assert.equal(event.sequence, index + 1); assert(!ids.has(event.id), 'Repeated event ID'); ids.add(event.id);
    assert(Number.isInteger(event.at)); assert.equal(Object.keys(event.action).length, 1);
    if (event.action.drawingLinked) {
      const reference = event.action.drawingLinked._0;
      assert(!drawings.has(reference.id), 'Repeated drawing reference'); drawings.set(reference.id, { reference, taskID: event.taskID, finished: false });
    }
    if (event.action.drawingFinished) {
      const result = event.action.drawingFinished, drawing = drawings.get(result.id);
      assert(drawing && !drawing.finished && drawing.taskID === event.taskID, 'Invalid drawing result association'); drawing.finished = true;
    }
    if (event.action.feedback?._0.allowed) {
      assert(['B', 'C'].includes(record.configuration.group));
      assert(!['V1a', 'V1b', 'V6', 'V7'].includes(record.configuration.visit), 'Feedback leaked into measurement visit'); prompts++;
    }
    if (event.action.taskCompleted) completedTasks++;
  }
  const missing = new Set(manifest.missingDrawingIDs), validated = [];
  for (const [id, drawing] of drawings) {
    if (missing.has(id)) continue;
    const folder = join(directory, 'drawings', id);
    const result = await validateExport(folder), raw = JSON.parse(await readFile(join(folder, 'raw.json')));
    assert.equal(raw.metadata.id, id); assert.equal(raw.metadata.context.sessionID, record.id ?? record.configuration.id);
    assert.equal(raw.metadata.context.taskID, drawing.taskID); assert.equal(raw.metadata.context.trialID, drawing.reference.trialID);
    validated.push(result);
  }
  for (const id of missing) assert(drawings.has(id), 'Missing ID was never associated');
  if (manifest.endReason === 'completed') assert(record.events.at(-1)?.action.taskCompleted, 'Completed manifest does not match journal');
  return { valid: true, sessionID: manifest.sessionID, visit: record.configuration.visit, endReason: manifest.endReason,
    events: record.events.length, completedTasks, prompts, drawings: drawings.size, missingDrawings: missing.size,
    validatedDrawings: validated.length, totalSamples: validated.reduce((sum, item) => sum + item.samples, 0) };
}

export async function validateGeneration(directory) {
  const record = JSON.parse(await readFile(join(directory, 'generation.json')));
  const original = await validateExport(join(directory, 'original'));
  const raw = JSON.parse(await readFile(join(directory, 'original/raw.json')));
  assert.equal(raw.metadata.id, record.sourceDocumentID);
  assert.equal(hash(await readFile(join(directory, 'original/artwork.png'))), record.sourcePNGHash);
  assert.equal(record.model, 'wanx2.1-imageedit'); assert.equal(record.function, 'doodle');
  assert.equal(record.imageCount, 1); assert.equal(record.isSketch, true); assert.equal(record.watermark, true);
  for (const receipt of record.receipts) assert.equal(receipt.id, record.id);
  if (record.downloadedFile) {
    const remote = record.receipts.at(-1); assert.equal(remote.status, 'SUCCEEDED');
    assert.equal(hash(await readFile(await safeFile(directory, record.downloadedFile))), remote.resultSHA256);
  }
  return { valid: true, generationID: record.id, sourceDocumentID: record.sourceDocumentID, status: record.receipts.at(-1)?.status ?? 'LOCAL_SAVED',
    generatedFilePresent: Boolean(record.downloadedFile), originalSamples: original.samples, receiptCount: record.receipts.length };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    assert(process.argv[2], 'Provide an unzipped export directory.');
    const fn = process.argv.includes('--generation') ? validateGeneration : validateResearch;
    process.stdout.write(JSON.stringify(await fn(resolve(process.argv[2])), null, 2) + '\n');
  } catch (error) { process.stderr.write('Export validation failed: ' + error.message + '\n'); process.exitCode = 1; }
}
