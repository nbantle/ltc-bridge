// Self-test for the Windows/Electron core: node test/selftest.mjs
import { readFileSync, existsSync } from 'node:fs';
import { LTCDecoder } from '../src/core/ltc-decoder.js';
import { SampleClock } from '../src/core/sample-clock.js';
import { synthesize } from '../src/core/ltc-generator.js';
import { MTCEngine, MTCScheduler, Status, isSuccessor, artNetTimecodePacket, fullFrame } from '../src/core/engine.js';
import { FrameRate, allRates, frameCount, fromFrameCount, framesPerDay, format, parseOffset, parseTimecode, tc, tcEqual } from '../src/core/timecode.js';

let failures = 0;
const expect = (ok, msg) => { if (!ok) { failures++; console.log('  FAIL: ' + msg); } };
const f2 = (x) => x.toFixed(2);

// ---- LTC synthesis (shared with the app's developer test input)

function feed(decoder, audio, chunk, startTime = 0, ticksPerSample = 1) {
  for (let i = 0; i < audio.length; i += chunk) decoder.process(audio.subarray(i, Math.min(i + chunk, audio.length)), startTime + i * ticksPerSample, ticksPerSample);
}

// ---- Decoder
console.log('Decoder:');
for (const rate of allRates) for (const sr of [44100, 48000, 96000]) {
  const start = tc(1, 8, 59, 20);
  const audio = synthesize(start, rate, rate.period, 120, sr, 0.1, 0.01, sr === 48000);
  const dec = new LTCDecoder(sr); const got = []; dec.onFrame = (f) => got.push(f);
  feed(dec, audio, 128);
  let ok = got.length >= 118, worst = 0;
  const fs = rate.period * sr;
  for (const f of got) { const idx = frameCount(f.timecode, rate) - frameCount(start, rate); worst = Math.max(worst, Math.abs(f.endTime - (idx + 1) * fs)); if (f.dropFrame !== rate.drop) ok = false; }
  for (let i = 1; i < got.length; i++) if (!isSuccessor(got[i - 1].timecode, got[i].timecode)) ok = false;
  console.log(`  ${rate.label} @ ${sr} Hz: ${got.length} frames, first ${got[0] ? format(got[0].timecode) : '-'}, max edge error ${f2(worst)} samples`);
  expect(ok, `${rate.label} @ ${sr} decoded incorrectly`); expect(worst < 3, `${rate.label} @ ${sr} timing`);
}

// ---- Timecode math
console.log('Timecode math:');
for (const rate of allRates) { let ok = true; for (let n = 0; n < framesPerDay(rate); n += 997) if (frameCount(fromFrameCount(n, rate), rate) !== n) { ok = false; break; } expect(ok, rate.label + ' round trip'); }
expect(tcEqual(fromFrameCount(1800, FrameRate.fps2997DF), tc(0, 1, 0, 2)), 'DF skip at 1 min');
expect(tcEqual(fromFrameCount(17982, FrameRate.fps2997DF), tc(0, 10, 0, 0)), 'DF no skip at 10 min');
expect(parseOffset('-00:00:01:05', FrameRate.fps30) === -35, 'offset parse');
expect(parseTimecode('01:01:00:00', FrameRate.fps2997DF).frames === 2, 'DF start parse');
console.log('  done');

// ---- Simulated real time: engine + scheduler with look-ahead scheduling
function simulate({ rate, drift = 1, seconds, jumpAt = null, chunk = 128, jitterMs = 0, bursty = false }) {
  const sr = 48000, realPeriod = rate.period * drift, periodMs = realPeriod * 1000;
  const start = tc(10, 0, 58, 0), jumpStart = tc(2, 30, 0, 0);
  const frames = Math.floor(seconds / realPeriod);
  let audio = synthesize(start, rate, realPeriod, frames, sr, 0.2, 0.005, false);
  let jumpSample = Infinity;
  if (jumpAt != null) {
    jumpSample = Math.floor(Math.floor(jumpAt / realPeriod) * realPeriod * sr);
    const tail = synthesize(jumpStart, rate, realPeriod, frames, sr, 0.2, 0.005, false);
    const joined = new Float32Array(Math.floor(seconds * sr));
    joined.set(audio.subarray(0, jumpSample)); joined.set(tail.subarray(0, joined.length - jumpSample), jumpSample);
    audio = joined;
  }
  const engine = new MTCEngine(), sched = new MTCScheduler(engine), dec = new LTCDecoder(sr);
  const sampleClock = new SampleClock(sr);
  dec.onFrame = (f) => engine.ingest(f);
  const msPerSample = 1000 / sr, t0 = 10;
  const sent = [], artnet = [], statuses = {};
  let seed = 99, lastDelivery = t0, n = 0, clock = t0;
  const lookahead = 12, tick = 4;
  const jumpTime = t0 + jumpSample * msPerSample;
  const expected = (t) => t >= jumpTime ? frameCount(jumpStart, rate) + (t - jumpTime) / periodMs : frameCount(start, rate) + (t - t0) / periodMs;
  for (let i = 0; i + chunk <= audio.length; i += chunk, n++) {
    const capture = t0 + i * msPerSample;
    const delivery = capture + chunk * msPerSample * (bursty && n % 2 === 0 ? 2 : 1);
    // Run the scheduler's timer ticks up to this delivery.
    while (clock + tick <= delivery) { clock += tick; const o = sched.poll(clock, clock + lookahead); sent.push(...o.messages); artnet.push(...o.frames); }
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    const jitter = ((seed >>> 8) / (1 << 24) - 0.5) * 2 * jitterMs;
    engine.reportInputGap(delivery - lastDelivery); lastDelivery = delivery;
    const startMs = sampleClock.timestamp(capture + jitter, chunk);
    dec.process(audio.subarray(i, i + chunk), startMs, sampleClock.msPerSample);
    const el = (capture - t0) / 1000;
    if (el > 0.6 && el < seconds - 0.2 && !(jumpAt != null && Math.abs(el - jumpAt) < 0.4)) { const s = engine.snapshot(delivery).status; statuses[s] = (statuses[s] || 0) + 1; }
  }
  for (let k = 0; k < 150; k++) { clock += tick; const o = sched.poll(clock, clock + lookahead); sent.push(...o.messages); }
  // Reconstruct MTC from quarter-frames, as a receiver would.
  const pieces = new Array(8).fill(0); let expPiece = 0, badOrder = 0, full = 0; const errs = [], gaps = []; let lastQ = null; const codes = new Set();
  for (const m of sent) {
    if (m.bytes[0] === 0xf0) { full++; expPiece = 0; continue; }
    const piece = m.bytes[1] >> 4; if (piece !== expPiece) badOrder++; expPiece = (piece + 1) & 7; pieces[piece] = m.bytes[1] & 15;
    if (lastQ != null && m.time - lastQ < periodMs) gaps.push((m.time - lastQ) / (periodMs / 4)); lastQ = m.time;
    if (piece === 7) {
      const t = tc(pieces[6] | ((pieces[7] & 1) << 4), pieces[4] | (pieces[5] << 4), pieces[2] | (pieces[3] << 4), pieces[0] | (pieces[1] << 4));
      codes.add(pieces[7] >> 1);
      if (Math.abs(m.time - jumpTime) > periodMs * 4) errs.push(frameCount(t, rate) + 1.75 - expected(m.time));
    }
  }
  const worstMs = Math.max(...errs.map(Math.abs)) * periodMs, worstQ = Math.max(...gaps.map((g) => Math.abs(g - 1)));
  const label = `${rate.label}${drift !== 1 ? ` (+${((drift - 1) * 100).toFixed(1)}% drift)` : ''}${jumpAt != null ? ' with jump' : ''}${jitterMs || bursty ? ` [${chunk}-sample, ${bursty ? 'bursty, ' : ''}±${jitterMs} ms]` : ''}`;
  console.log(`  ${label}: ${errs.length} cycles, worst error ${f2(worstMs)} ms, QF spacing worst ${(worstQ * 100).toFixed(1)}%, full-frames ${full}, status ${JSON.stringify(statuses)}`);
  expect(errs.length > frames / 2 - 8, label + ': too few cycles');
  expect(worstMs < (jitterMs ? 4 : 1.5), label + ': position error ' + worstMs);
  expect(badOrder === 0, label + ': out of order');
  expect(worstQ < 0.3, label + ': QF spacing');
  expect(codes.size === 1 && codes.has(rate.id), label + ': rate code');
  expect(full === (jumpAt == null ? 1 : 2), label + ': full-frame count ' + full);
  expect(Object.keys(statuses).every((k) => k === Status.locked), label + ': left LOCKED while playing');
  expect(engine.snapshot(clock).status === Status.noSignal, label + ': should stop after LTC ends');
  return { artnet };
}
console.log('Simulated real time (engine + look-ahead scheduler):');
simulate({ rate: FrameRate.fps30, seconds: 3 });
simulate({ rate: FrameRate.fps25, seconds: 2 });
simulate({ rate: FrameRate.fps24, seconds: 2 });
simulate({ rate: FrameRate.fps2997DF, seconds: 3 });
simulate({ rate: FrameRate.fps30, drift: 1.002, seconds: 3, jumpAt: 1.5 });
simulate({ rate: FrameRate.fps30, seconds: 4, chunk: 1024, jitterMs: 8, bursty: true });
const { artnet } = simulate({ rate: FrameRate.fps25, drift: 1.0005, seconds: 4, jumpAt: 2, chunk: 512, jitterMs: 5, bursty: true });

// ---- Art-Net packets
console.log('Art-Net:');
const pkt = artNetTimecodePacket(tc(1, 2, 3, 4), FrameRate.fps25);
expect(pkt.length === 19 && String.fromCharCode(...pkt.slice(0, 7)) === 'Art-Net' && pkt[8] === 0x00 && pkt[9] === 0x97 && pkt[11] === 14 && pkt[14] === 4 && pkt[17] === 1 && pkt[18] === 1, 'packet layout');
const perFrame = artnet.filter((f, i) => i === 0 || f.time - artnet[i - 1].time > 1).length;
console.log(`  packet layout ok; ${artnet.length} frame events over 4 s at 25 fps`);
expect(artnet.length >= 90 && artnet.length <= 104, 'art-net frame events ' + artnet.length);
expect(fullFrame(tc(1, 0, 0, 0), FrameRate.fps30)[5] === ((3 << 5) | 1), 'full frame rate bits');

// ---- False locks, stuck loop, test generator
console.log('False-lock protection and generator:');
{
  const e = new MTCEngine(), d = new LTCDecoder(48000); d.onFrame = (f) => e.ingest(f);
  const noise = new Float32Array(480000); let seed = 7;
  for (let i = 0; i < noise.length; i++) { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; noise[i] = ((seed >>> 8) / (1 << 24) - 0.5) * (i < 160000 ? 0.01 : i < 320000 ? 0.2 : 1); }
  feed(d, noise, 128, 0, 1000 / 48000);
  expect(e.relocations === 0, 'noise caused a lock'); console.log('  noise: ' + (e.relocations === 0 ? 'no lock' : 'LOCKED (bad)'));

  // The show-log case: 16,384 samples of 24 fps LTC replaying, then real LTC elsewhere.
  const stuck = synthesize(tc(1, 1, 34, 14), FrameRate.fps24, 1 / 24, 9, 48000, 0.2, 0.002, false).subarray(0, 16384);
  const real = synthesize(tc(1, 5, 0, 0), FrameRate.fps24, 1 / 24, 48, 48000, 0.2, 0.002, false);
  const audio = new Float32Array(16384 * 60 + 24000 + real.length);
  for (let k = 0; k < 60; k++) audio.set(stuck, k * 16384);
  audio.set(real, 16384 * 60 + 24000);
  const e2 = new MTCEngine(), d2 = new LTCDecoder(48000); d2.onFrame = (f) => e2.ingest(f);
  let sawLoop = false, lockedDuringLoop = 0; const ms = 1000 / 48000;
  for (let i = 0; i + 256 <= audio.length; i += 256) {
    d2.process(audio.subarray(i, i + 256), i * ms, ms);
    const s = e2.snapshot((i + 256) * ms);
    if (i < 16384 * 60) { if (s.looping) sawLoop = true; if (i > 16384 * 2 + 12000 && s.status !== Status.noSignal) lockedDuringLoop++; }
  }
  const s3 = e2.snapshot(audio.length * ms);
  expect(sawLoop && lockedDuringLoop === 0, 'stuck loop not ignored'); expect(s3.status === Status.locked && s3.lastLTC.minutes === 5, 'no lock to real LTC after loop');
  console.log(`  stuck 16,384-sample loop: ${sawLoop && lockedDuringLoop === 0 ? 'ignored' : 'NOT ignored'}, then real LTC: ${s3.status}`);

  const e3 = new MTCEngine(), sc = new MTCScheduler(e3);
  e3.startTest(tc(1, 59, 59, 0), FrameRate.fps25, 0);
  const msgs = []; for (let t = 0; t < 2000; t += 4) msgs.push(...sc.poll(t, t + 12).messages);
  e3.ingest({ timecode: tc(5, 0, 0, 0), dropFrame: false, endTime: 2000 });
  const mid = e3.snapshot(2000).status; e3.stopTest();
  let after = 0; for (let t = 2000; t < 2400; t += 4) after += sc.poll(t, t + 12).messages.length;
  const qf = msgs.filter((m) => m.bytes[0] === 0xf1).length;
  console.log(`  generator: ${qf} quarter-frames in 2 s at 25 fps (expect ~200), status ${mid}, after stop: ${after}`);
  expect(qf >= 190 && qf <= 202 && mid === Status.test && after === 0, 'generator');
}

// ---- The real show file, if the Ableton drive is connected
const wav = '/Volumes/Ableton/Worship Loops/Timecode/LTC_01_00_00_00__10mins_24.wav';
if (existsSync(wav)) {
  console.log('Real LTC file (10 min, 24 fps, 44.1 kHz):');
  const buf = readFileSync(wav);
  let off = 12, fmt = null, data = null;
  while (off < buf.length) { const id = buf.toString('ascii', off, off + 4), size = buf.readUInt32LE(off + 4); if (id === 'fmt ') fmt = { ch: buf.readUInt16LE(off + 10), sr: buf.readUInt32LE(off + 12), bits: buf.readUInt16LE(off + 22) }; if (id === 'data') { data = buf.subarray(off + 8, off + 8 + size); break; } off += 8 + size + (size & 1); }
  const n = data.length / 2 / fmt.ch, samples = new Float32Array(n);
  for (let i = 0; i < n; i++) samples[i] = data.readInt16LE(i * 2 * fmt.ch) / 32768;
  const e = new MTCEngine(), d = new LTCDecoder(fmt.sr); let count = 0, gaps = 0, prev = null, notLocked = 0;
  d.onFrame = (f) => { e.ingest(f); count++; if (prev && !isSuccessor(prev, f.timecode)) gaps++; prev = f.timecode; };
  const ms = 1000 / fmt.sr;
  for (let i = 0; i + 512 <= n; i += 512) { d.process(samples.subarray(i, i + 512), i * ms, ms); if (i > fmt.sr && i < n - fmt.sr && e.snapshot((i + 512) * ms).status !== Status.locked) notLocked++; }
  console.log(`  ${count} frames, last ${format(prev)}, rate ${e.rate?.label}, discontinuities ${gaps}, buffers not locked ${notLocked}`);
  expect(count >= 14390 && gaps === 0 && notLocked === 0 && e.rate === FrameRate.fps24, 'real file');
}

console.log(failures === 0 ? '\nALL TESTS PASSED' : `\n${failures} FAILURE(S)`);
process.exit(failures ? 1 : 0);
