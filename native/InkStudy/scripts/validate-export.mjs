#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export async function validateExport(directory) {
  const files = {};
  for (const name of ["artwork.png", "raw.json", "samples.csv", "manifest.json"]) {
    files[name] = await readFile(join(directory, name));
  }
  const manifest = JSON.parse(files["manifest.json"]);
  const raw = JSON.parse(files["raw.json"]);
  assert.equal(manifest.format, "inkstudy-export-v1");
  assert.equal(raw.format, "inkstudy-raw-v1");
  assert.equal(raw.metadata.id, manifest.documentID);
  for (const name of ["artwork.png", "raw.json", "samples.csv"]) {
    assert.equal(createHash("sha256").update(files[name]).digest("hex"), manifest.sha256[name], `Hash mismatch: ${name}`);
  }
  const png = files["artwork.png"];
  assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", "Invalid PNG signature");
  assert.equal(png.readUInt32BE(16), manifest.artworkWidthPixels);
  assert.equal(png.readUInt32BE(20), manifest.artworkHeightPixels);
  assert.equal(manifest.artworkWidthPixels, raw.metadata.paperWidth * 2);
  assert.equal(manifest.artworkHeightPixels, raw.metadata.paperHeight * 2);

  const strokes = new Map();
  const eventIDs = new Set();
  let visible = [], redo = [], active;
  for (const [index, event] of raw.events.entries()) {
    assert.equal(event.documentID, raw.metadata.id);
    assert.equal(event.sequence, index + 1, "Journal sequence gap");
    assert(!eventIDs.has(event.id), "Duplicate journal event"); eventIDs.add(event.id);
    assert(Number.isInteger(event.recordedAt), "Wall-clock time must be integer epoch milliseconds");
    const entries = Object.entries(event.payload);
    assert.equal(entries.length, 1);
    const [kind, payload] = entries[0];
    const id = payload.strokeID;
    if (kind === "strokeBegan") {
      assert.equal(active, undefined); assert(!strokes.has(id)); assert(payload.samples.length > 0);
      strokes.set(id, { id, style: payload.style, transform: payload.transform, samples: [...payload.samples] });
      visible.push(id); redo = []; active = id;
    } else if (kind === "samplesAppended") {
      assert.equal(active, id); strokes.get(id).samples.push(...payload.samples);
    } else if (kind === "samplesRevised") {
      const stroke = strokes.get(id); assert(stroke, "Correction without a stroke");
      for (const revision of payload.samples) {
        const index = stroke.samples.findIndex(sample => sample.id === revision.id);
        assert(index >= 0); assert.equal(revision.source, "estimatedUpdate");
        assert.equal(revision.uptime, stroke.samples[index].uptime);
        assert.equal(revision.estimationIndex, stroke.samples[index].estimationIndex);
        stroke.samples[index] = revision;
      }
    } else if (kind === "strokeEnded") {
      assert.equal(active, id); strokes.get(id).endReason = payload.reason; active = undefined;
    } else if (kind === "undone") {
      assert.equal(active, undefined); assert.equal(visible.pop(), id); redo.push(id);
    } else if (kind === "redone") {
      assert.equal(active, undefined); assert.equal(redo.pop(), id); visible.push(id);
    } else {
      assert(["brushChanged", "fingerInputChanged"].includes(kind), `Unknown event: ${kind}`);
    }
  }
  assert.equal(active, undefined, "Export contains an unfinished stroke");
  assert.deepEqual([...strokes.values()], raw.strokes, "Journal replay does not match exported strokes");
  assert.deepEqual(visible, raw.visibleStrokeIDs); assert.deepEqual(redo, raw.redoStrokeIDs);
  assert.equal(manifest.visibleStrokeCount, visible.length);
  assert.equal(manifest.originalStrokeCount, strokes.size);
  assert.equal(manifest.eventCount, raw.events.length);
  const samples = raw.strokes.flatMap(stroke => stroke.samples.map(sample => ({ stroke, sample })));
  assert.equal(manifest.sampleCount, samples.length);
  assert.equal(new Set(samples.map(({ sample }) => sample.id)).size, samples.length, "Duplicate sample ID");

  const rows = parseCSV(files["samples.csv"].toString("utf8"));
  const header = rows.shift();
  assert.equal(rows.length, samples.length, "CSV and JSON sample counts differ");
  const actual = new Map(rows.map(row => {
    assert.equal(row.length, header.length, "CSV field count mismatch");
    const value = Object.fromEntries(header.map((key, index) => [key, row[index]]));
    return [value.sample_id, value];
  }));
  assert.equal(actual.size, samples.length);
  let pencilSamples = 0, fingerSamples = 0, unresolvedSamples = 0;
  for (const { stroke, sample } of samples) {
    const row = actual.get(sample.id); assert(row, "Sample missing from CSV");
    assert.equal(row.document_id, raw.metadata.id); assert.equal(row.stroke_id, stroke.id);
    assert.equal(row.visible, String(visible.includes(stroke.id)));
    assert.equal(row.input, sample.input); assert.equal(row.phase, sample.phase); assert.equal(row.source, sample.source);
    assert.equal(row.brush_color, stroke.style.color.hex); assert.equal(Number(row.brush_size), stroke.style.size);
    if (["spectral-palette-v3", "standard-palette-v4"].includes(raw.metadata.background?.pigmentModel)) {
      assert.equal(raw.metadata.schemaVersion, 2);
      assert.equal(row.pigment_load_id, stroke.style.pigmentLoadID ?? "");
      assert(raw.pigmentMixing.includes("50 in-bounds dabs"));
      if (raw.metadata.background.pigmentModel === "standard-palette-v4") {
        assert.equal(raw.metadata.colorPaletteVersion, "standard-rgb-v1-20260911");
        assert.equal(stroke.style.color.hex, {red: "#FF0000", yellow: "#FFFF00", blue: "#0000FF"}[stroke.style.color.id]);
        for (const hex of ["#FF0000", "#FFFF00", "#0000FF", "#FFA500", "#00FF00", "#800080"]) assert(raw.pigmentMixing.includes(hex));
      }
    }
    for (const [column, value] of Object.entries({
      uptime_seconds: sample.uptime, received_at_epoch_ms: sample.receivedAt,
      x_paper: sample.x, y_paper: sample.y, x_view: sample.viewX, y_view: sample.viewY,
      force_raw: sample.force, maximum_possible_force: sample.maximumPossibleForce,
      altitude_radians: sample.altitude, azimuth_radians: sample.azimuth, estimation_index: sample.estimationIndex,
      estimated_properties: sample.estimatedProperties, properties_expecting_updates: sample.propertiesExpectingUpdates,
    })) {
      if (value == null) assert.equal(row[column], "", `Missing value replaced in ${column}`);
      else assert.equal(Number(row[column]), value, `Sample changed in ${column}`);
    }
    const normalized = sample.input === "pencil" && sample.maximumPossibleForce > 0 && sample.force >= 0
      ? sample.force / sample.maximumPossibleForce : undefined;
    if (normalized === undefined) assert.equal(row.normalized_force, "");
    else assert.equal(Number(row.normalized_force), normalized);
    if (sample.input === "pencil") pencilSamples++;
    if (sample.input === "finger") fingerSamples++;
    if (sample.propertiesExpectingUpdates !== 0) unresolvedSamples++;
  }
  return { valid: true, artworkPixels: [manifest.artworkWidthPixels, manifest.artworkHeightPixels],
    visibleStrokes: visible.length, allStrokes: strokes.size, samples: samples.length,
    events: raw.events.length, pencilSamples, fingerSamples, unresolvedSamples,
    pressureVerification: raw.pressureVerification };
}

function parseCSV(text) {
  const rows = []; let row = [], cell = "", quoted = false;
  for (let n = 0; n < text.length; n++) {
    const char = text[n];
    if (char === '"') {
      if (quoted && text[n + 1] === '"') { cell += '"'; n++; }
      else quoted = !quoted;
    } else if (!quoted && char === ",") { row.push(cell); cell = ""; }
    else if (!quoted && (char === "\n" || char === "\r")) {
      if (char === "\r" && text[n + 1] === "\n") n++;
      row.push(cell); rows.push(row); row = []; cell = "";
    } else cell += char;
  }
  assert(!quoted, "Unclosed CSV quote");
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (!process.argv[2]) { process.stderr.write("Usage: node scripts/validate-export.mjs /path/to/export-directory\n"); process.exitCode = 2; }
  else {
    try { process.stdout.write(JSON.stringify(await validateExport(resolve(process.argv[2])), null, 2) + "\n"); }
    catch (error) { process.stderr.write(`Export validation failed: ${error.message}\n`); process.exitCode = 1; }
  }
}
