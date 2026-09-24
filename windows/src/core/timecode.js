// Timecode math shared by the LTC decoder and the MTC generator.
// JavaScript port of Sources/Core/Timecode.swift.

export const FrameRate = Object.freeze({
  fps24: { id: 0, fps: 24, drop: false, period: 1 / 24, label: '24 fps', short: '24' },
  fps25: { id: 1, fps: 25, drop: false, period: 1 / 25, label: '25 fps', short: '25' },
  fps2997DF: { id: 2, fps: 30, drop: true, period: 1001 / 30000, label: '29.97 DF', short: '29.97 DF' },
  fps30: { id: 3, fps: 30, drop: false, period: 1 / 30, label: '30 fps', short: '30' },
});

export const allRates = [FrameRate.fps24, FrameRate.fps25, FrameRate.fps2997DF, FrameRate.fps30];
export const rateById = (id) => allRates.find((r) => r.id === id);

/** Frames in 24 hours. */
export const framesPerDay = (rate) => (rate.drop ? 2589408 : 24 * 3600 * rate.fps);

export function tc(hours, minutes, seconds, frames) {
  return { hours, minutes, seconds, frames };
}

export const tcEqual = (a, b) =>
  a.hours === b.hours && a.minutes === b.minutes && a.seconds === b.seconds && a.frames === b.frames;

/** Timecode → absolute frame count since 00:00:00:00. */
export function frameCount(t, rate) {
  let count = ((t.hours * 60 + t.minutes) * 60 + t.seconds) * rate.fps + t.frames;
  if (rate.drop) {
    const totalMinutes = t.hours * 60 + t.minutes;
    count -= 2 * (totalMinutes - Math.floor(totalMinutes / 10));
  }
  return count;
}

/** Absolute frame count → timecode, wrapping at 24 h. */
export function fromFrameCount(count, rate) {
  const perDay = framesPerDay(rate);
  let n = ((count % perDay) + perDay) % perDay;
  if (rate.drop) {
    const d = Math.floor(n / 17982);
    const m = n % 17982;
    n += 18 * d + (m < 2 ? 0 : 2 * Math.floor((m - 2) / 1798));
  }
  const fps = rate.fps;
  return tc(Math.floor(n / (fps * 3600)) % 24, Math.floor(n / (fps * 60)) % 60, Math.floor(n / fps) % 60, n % fps);
}

const two = (v) => (v < 10 ? '0' + v : '' + v);
export function format(t, dropFrame = false) {
  return `${two(t.hours)}:${two(t.minutes)}:${two(t.seconds)}${dropFrame ? ';' : ':'}${two(t.frames)}`;
}

function parts(text) {
  const p = text.trim().split(/[:;.]/).map((s) => s.trim());
  if (p.length !== 4 || p.some((s) => !/^\d+$/.test(s))) return null;
  return p.map(Number);
}

/** Parses a signed "HH:MM:SS:FF" duration into a frame count (no drop-frame adjustment). */
export function parseOffset(text, rate) {
  let s = text.trim();
  let sign = 1;
  if (s.startsWith('-')) { sign = -1; s = s.slice(1); } else if (s.startsWith('+')) { s = s.slice(1); }
  const p = parts(s);
  if (!p || p[1] >= 60 || p[2] >= 60 || p[3] >= rate.fps) return null;
  return sign * (((p[0] * 60 + p[1]) * 60 + p[2]) * rate.fps + p[3]);
}

/** Parses "HH:MM:SS:FF" as a position; non-existent drop-frame labels move to frame 2. */
export function parseTimecode(text, rate) {
  const p = parts(text);
  if (!p || p[0] >= 24 || p[1] >= 60 || p[2] >= 60 || p[3] >= rate.fps) return null;
  const t = tc(p[0], p[1], p[2], p[3]);
  if (rate.drop && t.seconds === 0 && t.minutes % 10 !== 0 && t.frames < 2) t.frames = 2;
  return t;
}
