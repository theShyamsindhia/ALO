#!/usr/bin/env node
// Numeric evidence only: software-clock agreement is not acoustic alignment.
import fs from 'node:fs';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

const number = '([+-]?(?:[0-9]+(?:\\.[0-9]+)?))';
const values = (text, expression) => [...text.matchAll(expression)].map(m => Number(m[1]));
const maximum = list => list.length ? list.reduce((max, value) => Math.max(max, value), -Infinity) : null;
const percentile = (list, p) => list.length ? [...list].sort((a, b) => a - b)[Math.ceil(p * list.length) - 1] : null;

export function analyzeRows(rows, { start, end, requiredSeconds = 660 } = {}) {
  const from = start === undefined ? -Infinity : Date.parse(start);
  const to = end === undefined ? Infinity : Date.parse(end);
  if (Number.isNaN(from) || Number.isNaN(to) || from >= to || !Number.isFinite(requiredSeconds) || requiredSeconds <= 0) {
    throw new Error('Invalid capture interval or duration');
  }
  const samples = [], groups = new Map(), issues = new Set(), failures = new Set();
  let relevantLines = 0;
  for (const row of rows) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) { issues.add('invalid log record'); continue; }
    const message = row.eventMessage;
    if (typeof message !== 'string' || !message.startsWith('Dev timing sample')) continue;
    const time = Date.parse(String(row.timestamp).replace(' ', 'T'));
    if (!Number.isFinite(time)) { issues.add('invalid sample timestamp'); continue; }
    if (time < from || time > to) continue;
    relevantLines++;
    const process = `${row.bootUUID ?? ''}:${row.processID ?? 'unknown'}:${row.processImageUUID ?? 'unknown'}`;
    if (row.processID === undefined) issues.add('missing process identity');
    if (/<…>|<\.\.\.>/.test(message)) { issues.add('truncated sample'); continue; }
    const chunk = message.match(/^Dev timing sample monotonic_ns=(\d+) part=(\d+)\/(\d+)(?: snapshot=([0-9A-Fa-f-]{36}))?: (.*)$/s);
    if (chunk) {
      const [, clock, indexText, countText, snapshot, payload] = chunk;
      if (!snapshot) { issues.add('chunk lacks unique snapshot identity'); continue; }
      const index = Number(indexText), count = Number(countText);
      if (!Number.isSafeInteger(index) || !Number.isSafeInteger(count) || count < 1 || count > 128 || index < 1 || index > count) {
        issues.add('invalid chunk bounds'); continue;
      }
      const key = `${process}:${snapshot}`;
      const group = groups.get(key) ?? { clock, count, process, time, lastTime: time, parts: new Map(), invalid: false };
      if (group.clock !== clock || group.count !== count || group.parts.has(index)) group.invalid = true;
      group.time = Math.min(group.time, time); group.lastTime = Math.max(group.lastTime, time);
      group.parts.set(index, payload); groups.set(key, group);
    } else if (/^Dev timing sample monotonic_ns=\d+ outcome=/.test(message)) {
      const [, clock, text] = message.match(/^Dev timing sample monotonic_ns=(\d+) (.*)$/s);
      samples.push({ time, process, clock: BigInt(clock), text });
    } else issues.add('unrecognized sample framing');
  }
  for (const group of groups.values()) {
    if (group.invalid || group.parts.size !== group.count || group.lastTime - group.time > 3000) {
      issues.add('incomplete, duplicated or inconsistent chunked sample'); continue;
    }
    const text = Array.from({ length: group.count }, (_, i) => group.parts.get(i + 1)).join('');
    samples.push({ time: group.time, process: group.process, clock: BigInt(group.clock), text });
  }
  samples.sort((a, b) => a.time - b.time);
  const drift = [], ages = [], reportAges = [], rtts = [], gaps = [];
  let previous, measured = 0;
  for (const sample of samples) {
    const { text } = sample;
    if (previous) gaps.push((sample.time - previous.time) / 1000);
    if (!/^outcome=passed(?::|$)/.test(text) || (text.match(/\boutcome=/g) ?? []).length !== 1) issues.add('missing, duplicated or unsuccessful outcome');
    for (const label of ['render drift', 'sample age', 'playback report age', 'RTT']) {
      for (const occurrence of text.matchAll(new RegExp(`\\b${label} `, 'g'))) {
        // The explanatory warning "low RTT does not prove clock accuracy" is
        // prose, not a second RTT metric. Metrics start at a field boundary.
        if (label === 'RTT' && text.slice(Math.max(0, occurrence.index - 4)).startsWith('low RTT does not prove clock accuracy ·')) continue;
        const token = text.slice(occurrence.index + label.length + 1).match(new RegExp(`^${number} ms(?:,| ·|$)`));
        if (!token || !Number.isFinite(Number(token[1]))) issues.add('malformed or nonfinite timing metric');
      }
    }
    const d = values(text, new RegExp(`render drift ${number} ms`, 'g')).map(Math.abs);
    const a = values(text, new RegExp(`sample age ${number} ms`, 'g'));
    const r = values(text, new RegExp(`playback report age ${number} ms`, 'g'));
    const t = values(text, new RegExp(`RTT ${number} ms`, 'g'));
    drift.push(...d); ages.push(...a); reportAges.push(...r); rtts.push(...t);
    if (text.includes('render observation measured,')) measured++;
    else issues.add('local render observation not measured');
    if (!d.length || !a.length || !t.length) issues.add('missing timing metrics');
    if (/unavailable|not currently measured|not reported|not currently verified|outcome=(?!passed)/.test(text)) issues.add('reported unavailable or unverified telemetry');
    if (d.some(v => v >= 40)) failures.add('software drift reaches 40 ms');
    if (a.some(v => v < 0 || v > 500)) failures.add('render sample age outside 0–500 ms');
    if (r.some(v => v < 0 || v > 2500)) failures.add('peer report age outside 0–2500 ms');
    if (t.some(v => v < 0 || v >= 40)) issues.add('RTT outside low-latency test range');
    const late = values(text, /\blate (\d+),/g), resync = values(text, /\bresyncs (\d+)/g);
    if (!late.length || !resync.length) issues.add('missing continuity counters');
    if (previous) {
      if (sample.process !== previous.process) issues.add('process changed during capture');
      else {
        const monotonicDeltaMilliseconds = Number(sample.clock - previous.clock) / 1e6;
        if (sample.clock <= previous.clock) issues.add('monotonic sample clock did not advance');
        if (Math.abs(monotonicDeltaMilliseconds - (sample.time - previous.time)) > 250) issues.add('monotonic and wall clock intervals disagree');
        for (const [current, prior] of [[late, previous.late], [resync, previous.resync]]) {
        if (current.length !== prior.length) issues.add('continuity counter shape changed');
        else current.forEach((value, i) => {
          if (value > prior[i]) failures.add('late/resync counter increased');
          if (value < prior[i]) issues.add('continuity counter reset');
        });
        }
      }
    }
    previous = { ...sample, late, resync };
  }
  const spanSeconds = samples.length > 1 ? (samples.at(-1).time - samples[0].time) / 1000 : 0;
  if (spanSeconds < requiredSeconds - Math.min(2, requiredSeconds * .01)) issues.add('insufficient observation duration');
  if (!samples.length) issues.add('no complete samples');
  if ((maximum(gaps) ?? 0) > 3) issues.add('sample gap exceeds 3 seconds');
  if (Number.isFinite(from) && samples.length && samples[0].time - from > 2000) issues.add('capture begins after requested window');
  if (Number.isFinite(to) && samples.length && to - samples.at(-1).time > 2000) issues.add('capture ends before requested window');
  return {
    verdict: failures.size ? 'software criteria failed' : issues.size ? 'inconclusive' : 'sampled software criteria met',
    acousticAlignment: 'not measured', relevantLines, samples: samples.length, measuredSamples: measured,
    firstUTC: samples.length ? new Date(samples[0].time).toISOString() : null,
    lastUTC: samples.length ? new Date(samples.at(-1).time).toISOString() : null, spanSeconds,
    driftMilliseconds: { p50: percentile(drift, .5), p95: percentile(drift, .95), max: maximum(drift) },
    sampleAgeMaxMilliseconds: maximum(ages), peerReportAgeMaxMilliseconds: maximum(reportAges),
    rttMaxMilliseconds: maximum(rtts), sampleGapMaxSeconds: maximum(gaps),
    failures: [...failures], limitations: [...issues]
  };
}

async function main() {
  const [file, start, end] = process.argv.slice(2);
  if (!file || process.argv.length > 5) throw new Error('Usage: node scripts/analyze-sync-capture.mjs FILE [START_ISO END_ISO]');
  if (fs.statSync(file).size > 64 * 1024 * 1024) throw new Error('Capture exceeds 64 MiB; split it into bounded windows');
  const rows = []; let malformedLines = 0;
  for await (const line of readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity })) {
    if (!line.trim() || line.startsWith('Filtering the log data')) continue;
    try { rows.push(JSON.parse(line)); } catch { malformedLines++; }
  }
  const report = analyzeRows(rows, { start, end });
  if (malformedLines) {
    report.limitations.push(`${malformedLines} malformed log lines`);
    if (!report.failures.length) report.verdict = 'inconclusive';
  }
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = report.verdict === 'sampled software criteria met' ? 0 : 2;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
