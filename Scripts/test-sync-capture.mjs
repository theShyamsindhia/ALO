import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeRows } from './analyze-sync-capture.mjs';

const detail = 'outcome=passed: RTT 3 ms · late 0, resyncs 0 · render drift 0.4 ms, sample age 20 ms · render observation measured, age 1 ms';
const row = (second, text = detail) => ({ timestamp: new Date(1700000000000 + second * 1000).toISOString(), processID: 12, processImageUUID: 'build', eventMessage: `Dev timing sample monotonic_ns=${(second + 100) * 1e9} ${text}` });
const rows = () => Array.from({ length: 661 }, (_, i) => row(i));

test('long measured stream is software-only evidence, never acoustic proof', () => {
  const report = analyzeRows(rows());
  assert.equal(report.verdict, 'sampled software criteria met');
  assert.equal(report.acousticAlignment, 'not measured');
  assert.equal(report.samples, 661);
});
test('drift and stale samples fail even when outcome claims passed', () => {
  const input = rows(); input[300] = row(300, detail.replace('0.4 ms', '41 ms').replace('20 ms', '501 ms'));
  assert.equal(analyzeRows(input).failures.length, 2);
});
test('missing host telemetry, truncation, gaps and short captures cannot pass', () => {
  assert.equal(analyzeRows([row(0)]).verdict, 'inconclusive');
  const input = rows(); input[4] = row(4, detail.replace('measured,', 'unavailable (no local poll recorded)'));
  assert.equal(analyzeRows(input).verdict, 'inconclusive');
  input.splice(20, 4); input[25] = row(29, '<…>');
  const result = analyzeRows(input);
  assert.ok(result.limitations.includes('truncated sample'));
  assert.ok(result.limitations.includes('sample gap exceeds 3 seconds'));
});
test('counter increase fails; reset and process change remain inconclusive', () => {
  const input = rows(); input[200] = row(200, detail.replace('late 0', 'late 1'));
  assert.ok(analyzeRows(input).failures.includes('late/resync counter increased'));
  const changed = rows(); changed[100].processID = 99;
  assert.equal(analyzeRows(changed).verdict, 'inconclusive');
});
test('unique chunks reassemble out of order; incomplete and duplicate chunks cannot pass', () => {
  const base = row(1), snapshot = '00000000-0000-4000-8000-000000000001';
  const part = (i, payload) => ({ ...base, eventMessage: `Dev timing sample monotonic_ns=101 part=${i}/2 snapshot=${snapshot}: ${payload}` });
  const chunks = [part(2, detail.slice(35)), part(1, detail.slice(0, 35))];
  assert.equal(analyzeRows(chunks, { requiredSeconds: 1 }).samples, 1);
  assert.equal(analyzeRows(chunks.slice(1), { requiredSeconds: 1 }).samples, 0);
  assert.equal(analyzeRows([...chunks, chunks[0]], { requiredSeconds: 1 }).samples, 0);
});
test('same-clock different snapshot parts must never combine', () => {
  const input = [1, 2].map(i => ({ ...row(1), eventMessage: `Dev timing sample monotonic_ns=101 part=${i}/2 snapshot=00000000-0000-4000-8000-00000000000${i}: ${detail}` }));
  assert.equal(analyzeRows(input, { requiredSeconds: 1 }).samples, 0);
});
test('window coverage and invalid intervals are checked', () => {
  assert.throws(() => analyzeRows(rows(), { start: 'nonsense' }));
  const report = analyzeRows(rows(), { start: new Date(1699999990000).toISOString(), end: new Date(1700000670000).toISOString() });
  assert.ok(report.limitations.includes('capture begins after requested window'));
  assert.ok(report.limitations.includes('capture ends before requested window'));
});
test('invalid JSON values and missing process identity cannot pass', () => {
  assert.equal(analyzeRows([...rows(), null]).verdict, 'inconclusive');
  const input = rows(); delete input[0].processID;
  assert.equal(analyzeRows(input).verdict, 'inconclusive');
});
test('repeated monotonic clocks cannot masquerade as fresh periodic observations', () => {
  const input = rows().map(r => ({ ...r, eventMessage: r.eventMessage.replace(/monotonic_ns=\d+/, 'monotonic_ns=100') }));
  assert.equal(analyzeRows(input).verdict, 'inconclusive');
});
test('malformed additional peer metrics cannot hide behind valid local values', () => {
  const input = rows().map(r => ({ ...r, eventMessage: r.eventMessage + ' · listener 1 render drift NaN ms, sample age NaN ms · RTT NaN ms' }));
  assert.equal(analyzeRows(input).verdict, 'inconclusive');
});
test('chunk payload without outcome cannot pass', () => {
  const input = rows().map((r, i) => ({ ...r, eventMessage: `Dev timing sample monotonic_ns=${(i + 100) * 1e9} part=1/1 snapshot=00000000-0000-4000-8000-${String(i).padStart(12, '0')}: ${detail.replace('outcome=passed: ', '')}` }));
  assert.equal(analyzeRows(input).verdict, 'inconclusive');
});
test('the acoustic limitation prose is not interpreted as an RTT value', () => {
  const input = rows().map(r => ({ ...r, eventMessage: r.eventMessage.replace('RTT 3 ms', 'Estimated software timing; low RTT does not prove clock accuracy · RTT 3 ms') }));
  assert.equal(analyzeRows(input).verdict, 'sampled software criteria met');
});
test('malformed host listener clock RTT cannot evade validation', () => {
  const input = rows().map(r => ({ ...r, eventMessage: r.eventMessage + ' · listener 2 clock RTT NaN ms' }));
  assert.equal(analyzeRows(input).verdict, 'inconclusive');
});
