// Locks onto decoded LTC frames and generates correctly timed MTC.
// JavaScript port of Sources/Core/MTCEngine.swift. Time is in milliseconds
// (performance.now() in the app; a simulated clock in the tests).

import { FrameRate, frameCount, fromFrameCount } from './timecode.js';

export const Status = Object.freeze({ noSignal: 'NO SIGNAL', locked: 'LOCKED', freewheel: 'FREEWHEEL', test: 'TEST' });

/** Frames a jump must hold steady before the output follows it. */
export const framesToLock = 4;
/** Timing disagreement (in frames) absorbed smoothly instead of treated as a jump. */
export const jitterTolerance = 1.5;
/** A jump back to timecode already heard within this many seconds is treated as a stuck loop. */
export const loopWindow = 1.0;

export class MTCEngine {
  constructor() {
    this.offsetFramesValue = 0;
    this.freewheelFrames = 10;
    this.previous = null;          // { tc, time }
    this.observedFPS = null;
    this.maxFrameSeen = 0;
    this.measuredPeriod = null;    // ms, EMA of frame intervals
    this.consecutive = 0;
    this.rate = null;
    this.running = false;
    this.generation = 0;
    this.anchorTime = 0;
    this.anchorFrame = 0;
    this.lastAccepted = 0;
    this.lastLTC = null;
    this.lastDecoded = 0;
    this.relocations = 0;
    this.inputGap = 0;
    this.recent = [];              // { count, time }
    this.lastLoopDetected = -Infinity;
    this.testMode = false;
    this.log = [];
  }

  get offsetFrames() { return this.offsetFramesValue; }
  set offsetFrames(v) {
    if (this.running && v !== this.offsetFramesValue) { this.anchorFrame += v - this.offsetFramesValue; this.generation++; }
    this.offsetFramesValue = v;
  }

  /** Called for every decoded LTC frame. frame = { timecode, dropFrame, endTime } */
  ingest(frame) {
    const t = frame.endTime;
    const tc = frame.timecode;
    this.lastDecoded = t;
    if (this.testMode) { this.lastLTC = tc; this.record(frame, 'test running', 0); return; }
    this.maxFrameSeen = Math.max(this.maxFrameSeen, tc.frames);

    const prev = this.previous;
    if (prev && isSuccessor(prev.tc, tc)) {
      this.consecutive++;
      if (tc.frames === 0 && prev.tc.frames >= 23) this.observedFPS = prev.tc.frames + 1;
      const interval = t - prev.time;
      const seconds = interval / 1000;
      if (seconds > 1 / 31 && seconds < 1 / 23) {
        this.measuredPeriod = this.measuredPeriod == null ? interval : this.measuredPeriod + (interval - this.measuredPeriod) * 0.05;
      }
    } else {
      this.consecutive = 0;
    }
    this.previous = { tc, time: t };

    const detected = this.classifyRate(frame.dropFrame);
    if (detected !== this.rate) {
      this.rate = detected;
      if (this.running) this.relocate(tc, t);
    }
    const rate = this.rate;
    if (!rate) { this.record(frame, 'detecting rate', 0); return; }

    const period = this.measuredPeriod ?? rate.period * 1000;
    const count = frameCount(tc, rate);
    // The frame just ended, so the position at t is the following frame.
    const measured = count + 1 + this.offsetFramesValue;

    // Was this exact frame already heard moments ago, before the current run of frames?
    const windowMs = loopWindow * 1000;
    const earlier = this.recent.slice(0, Math.max(0, this.recent.length - this.consecutive));
    const heardRecently = earlier.some((r) => r.count === count && t - r.time < windowMs);
    this.recent.push({ count, time: t });
    while (this.recent.length > 256 || (this.recent.length && t - this.recent[0].time > windowMs * 2)) this.recent.shift();

    if (this.running) {
      const predicted = this.anchorFrame + (t - this.anchorTime) / period;
      const error = measured - predicted;
      if (Math.abs(error) < jitterTolerance) {
        this.anchorTime = t;
        this.anchorFrame = predicted + error * 0.1;
        this.lastAccepted = t;
        this.lastLTC = tc;
        this.record(frame, 'ok', error);
        return;
      }
      if (heardRecently) { this.lastLoopDetected = t; this.record(frame, 'loop ignored', error); }
      else if (this.consecutive >= framesToLock - 1) { this.record(frame, 'jump', error); this.relocate(tc, t); }
      else this.record(frame, 'ignored', error);
      return;
    }
    if (heardRecently) { this.lastLoopDetected = t; this.record(frame, 'loop ignored', 0); }
    else if (this.consecutive >= framesToLock - 1) { this.record(frame, 'lock', 0); this.relocate(tc, t); }
    else this.record(frame, 'waiting', 0);
  }

  relocate(tc, t) {
    if (!this.rate) return;
    this.anchorTime = t;
    this.anchorFrame = frameCount(tc, this.rate) + 1 + this.offsetFramesValue;
    this.lastAccepted = t;
    this.lastLTC = tc;
    this.running = true;
    this.generation++;
    this.relocations++;
  }

  classifyRate(dropFrame) {
    if (dropFrame) return FrameRate.fps2997DF;
    if (this.observedFPS === 24) return FrameRate.fps24;
    if (this.observedFPS === 25) return FrameRate.fps25;
    if (this.observedFPS === 30) return FrameRate.fps30;
    if (this.measuredPeriod == null) return null;
    const seconds = this.measuredPeriod / 1000;
    const candidates = [FrameRate.fps24, FrameRate.fps25, FrameRate.fps30].filter((r) => r.fps > this.maxFrameSeen);
    let best = null;
    for (const r of candidates) if (!best || Math.abs(r.period - seconds) < Math.abs(best.period - seconds)) best = r;
    return best;
  }

  record(frame, action, error) {
    this.log.push({ time: frame.endTime, timecode: frame.timecode, dropFrame: frame.dropFrame, action, error });
    if (this.log.length > 4000) this.log.shift();
  }

  /** Wall-clock gap between audio deliveries, so freewheel allows for buffering. */
  reportInputGap(ms) { this.inputGap = Math.max(ms, this.inputGap * 0.995); }

  startTest(start, rate, now) {
    this.testMode = true;
    this.rate = rate;
    this.measuredPeriod = null;
    this.anchorTime = now;
    this.anchorFrame = frameCount(start, rate);
    this.running = true;
    this.generation++;
  }

  stopTest() {
    this.testMode = false;
    this.running = false;
    this.rate = null; this.previous = null; this.observedFPS = null; this.maxFrameSeen = 0; this.consecutive = 0;
    this.generation++;
  }

  reset() {
    this.previous = null; this.observedFPS = null; this.maxFrameSeen = 0; this.measuredPeriod = null;
    this.consecutive = 0; this.rate = null; this.running = false; this.lastLTC = null; this.generation++;
    this.testMode = false; this.lastDecoded = 0; this.inputGap = 0; this.recent = []; this.lastLoopDetected = -Infinity;
  }

  /** Updates dropout state and returns a consistent view for the scheduler/UI. */
  snapshot(now) {
    const period = this.measuredPeriod ?? (this.rate ? this.rate.period : 1 / 30) * 1000;
    let status = Status.noSignal;
    if (this.testMode) status = Status.test;
    else if (this.running) {
      const age = (now - this.lastAccepted - this.inputGap) / period;
      if (age > this.freewheelFrames + 1.5) { this.running = false; this.consecutive = 0; }
      else status = age > 2.5 ? Status.freewheel : Status.locked;
    }
    const anchorTime = this.anchorTime, anchorFrame = this.anchorFrame;
    return {
      status, rate: this.rate, generation: this.generation, periodMs: period,
      lastLTC: this.lastLTC,
      lastLTCAge: this.lastDecoded > 0 ? (now - this.lastDecoded) / 1000 : Infinity,
      relocations: this.relocations,
      looping: now - this.lastLoopDetected < 2000,
      position: (t) => anchorFrame + (t - anchorTime) / period,
      timeAtFrame: (f) => anchorTime + (f - anchorFrame) * period,
    };
  }
}

export function isSuccessor(a, b) {
  if (b.hours === a.hours && b.minutes === a.minutes && b.seconds === a.seconds) return b.frames === a.frames + 1;
  if (b.frames > 2 || a.frames < 23) return false;
  let s = a.seconds + 1, m = a.minutes, h = a.hours;
  if (s === 60) { s = 0; m++; }
  if (m === 60) { m = 0; h++; }
  if (h === 24) h = 0;
  if (b.seconds !== s || b.minutes !== m || b.hours !== h) return false;
  // Drop-frame skips frames 0 and 1 at the start of most minutes.
  return b.frames === 0 || (b.frames === 2 && s === 0 && m % 10 !== 0);
}

/**
 * Turns the engine's timeline into MTC messages, each with the time it should be sent.
 * Eight quarter-frames span two frames; piece 0 is always on an even frame boundary.
 * Messages are produced up to `horizon` ahead so the MIDI system can send them on time.
 */
export class MTCScheduler {
  constructor(engine) {
    this.engine = engine;
    this.generation = -1;
    this.rate = null;
    this.nextQuarter = null;
    this.latched = { hours: 0, minutes: 0, seconds: 0, frames: 0 };
  }

  /** @returns {{ messages: {time:number, bytes:number[]}[], frames: {time:number, tc:object}[], rate, status }} */
  poll(now, horizon) {
    const snap = this.engine.snapshot(now);
    const out = { messages: [], frames: [], rate: snap.rate, status: snap.status };
    if (snap.status === Status.noSignal || !snap.rate) { this.nextQuarter = null; return out; }
    const rate = snap.rate;
    const quarter = snap.periodMs / 4;

    if (snap.generation !== this.generation || rate !== this.rate || this.nextQuarter == null) {
      this.generation = snap.generation;
      this.rate = rate;
      this.relocate(snap, now, rate, out);
    }
    for (;;) {
      const q = this.nextQuarter;
      const due = snap.timeAtFrame(q / 4);
      if (due > horizon) break;
      if (now - due > quarter * 2) { this.relocate(snap, now, rate, out); continue; }   // fell behind
      const piece = q & 7;
      if (piece === 0) this.latched = fromFrameCount(q / 4, rate);
      const time = Math.max(due, now);
      if ((q & 3) === 0) out.frames.push({ time, tc: fromFrameCount(q >> 2, rate) });
      out.messages.push({ time, bytes: [0xf1, (piece << 4) | nibble(piece, this.latched, rate)] });
      this.nextQuarter = q + 1;
    }
    return out;
  }

  relocate(snap, now, rate, out) {
    const pos = snap.position(now);
    const t = fromFrameCount(Math.floor(pos), rate);
    out.messages.push({ time: now, bytes: fullFrame(t, rate) });
    out.frames.push({ time: now, tc: t });
    const q = Math.ceil(pos * 4) + 1;
    this.nextQuarter = Math.ceil(q / 8) * 8;
  }
}

function nibble(piece, t, rate) {
  switch (piece) {
    case 0: return t.frames & 0x0f;
    case 1: return t.frames >> 4;
    case 2: return t.seconds & 0x0f;
    case 3: return t.seconds >> 4;
    case 4: return t.minutes & 0x0f;
    case 5: return t.minutes >> 4;
    case 6: return t.hours & 0x0f;
    default: return (rate.id << 1) | ((t.hours >> 4) & 1);
  }
}

export function fullFrame(t, rate) {
  return [0xf0, 0x7f, 0x7f, 0x01, 0x01, (rate.id << 5) | t.hours, t.minutes, t.seconds, t.frames, 0xf7];
}

/** Art-Net ArtTimeCode packet (OpCode 0x9700, protocol 14). */
export function artNetTimecodePacket(t, rate) {
  const header = [...'Art-Net'].map((c) => c.charCodeAt(0));
  return [...header, 0, 0x00, 0x97, 0, 14, 0, 0, t.frames, t.seconds, t.minutes, t.hours, rate.id];
}

