// LTC Bridge page: audio input → LTC decoder (audio worklet) → MTC engine → MIDI outputs
// (scheduled with exact send times) and Art-Net. Same behavior as the macOS app.
import { MTCEngine, MTCScheduler, Status, artNetTimecodePacket } from './core/engine.js';
import { FrameRate, allRates, format, fromFrameCount, parseOffset, parseTimecode, rateById } from './core/timecode.js';

const $ = (id) => document.getElementById(id);
const bridge = window.bridge ?? {
  // Fallbacks so the page also opens in a plain browser for development.
  platform: 'web', version: async () => 'dev', interfaces: async () => [], setArtNetTarget: async () => true,
  sendArtNet() {}, getLogin: async () => false, setLogin: async () => false, saveDiagnostics: async () => '',
  setOnTop() {}, setHeight() {}, reportStatus() {}, openMidiSetup() {}, openPrivacySettings() {},
};
document.body.classList.add('platform-' + bridge.platform);

// ---------------------------------------------------------------- settings

const defaults = {
  deviceId: '', deviceLabel: '', channel: 0, outputs: [], artNetChoice: 'off', artNetCustomIP: '',
  offset: '00:00:00:00', freewheel: 10, viewMode: 'routing', keepOnTop: false,
  testStart: '01:00:00:00', testRate: 0, routingHeight: null,
};
let settings = { ...defaults };
try { settings = { ...defaults, ...JSON.parse(localStorage.getItem('ltcbridge') || '{}') }; } catch {}
const save = () => { try { localStorage.setItem('ltcbridge', JSON.stringify(settings)); } catch {} };

// ---------------------------------------------------------------- engine

const engine = new MTCEngine();
const scheduler = new MTCScheduler(engine);
engine.freewheelFrames = settings.freewheel;
let offsetRate = FrameRate.fps30;
let micDenied = false;
let midiError = '';

function applyOffset() {
  const frames = parseOffset($('offset').value, offsetRate);
  $('offset').classList.toggle('invalid', frames == null);
  if (frames == null) return;
  engine.offsetFrames = frames;
  settings.offset = $('offset').value;
  save();
}

// ---------------------------------------------------------------- audio input

let audio = null;   // { ctx, stream, node, channels }
let lastAudioAt = 0, lastLevelAt = 0, levelPeak = 0, inputChannels = 1;
let ctxOffsets = [];   // recent (performance.now() - audio clock) samples; the minimum is the true offset
let ctxOffset = null;

async function listDevices() {
  let devices = await navigator.mediaDevices.enumerateDevices();
  if (devices.some((d) => d.kind === 'audioinput' && !d.label)) {
    // Labels only appear once audio permission is granted.
    try {
      const s = await navigator.mediaDevices.getUserMedia({ audio: true });
      s.getTracks().forEach((t) => t.stop());
      devices = await navigator.mediaDevices.enumerateDevices();
    } catch (e) { micDenied = e.name === 'NotAllowedError'; }
  }
  return devices.filter((d) => d.kind === 'audioinput' && d.deviceId !== 'communications');
}

async function refreshDevices() {
  const devices = await listDevices();
  const select = $('device');
  const current = settings.deviceId;
  select.innerHTML = '';
  if (current && !devices.some((d) => d.deviceId === current)) {
    select.add(new Option(`${settings.deviceLabel || 'Saved device'} (not connected)`, current));
  }
  for (const d of devices) select.add(new Option(d.label || 'Audio input', d.deviceId));
  if (!current && devices.length) {
    // Prefer Dante Virtual Soundcard if present.
    const dvs = devices.find((d) => /dante/i.test(d.label)) || devices[0];
    settings.deviceId = dvs.deviceId; settings.deviceLabel = dvs.label; save();
  }
  select.value = settings.deviceId;
  return devices;
}

function renderChannels() {
  const select = $('channel');
  const count = Math.max(inputChannels, settings.channel + 1, 1);
  if (select.options.length !== count) {
    select.innerHTML = '';
    for (let i = 0; i < count; i++) select.add(new Option(`Channel ${i + 1}`, i));
  }
  select.value = settings.channel;
}

async function stopInput() {
  if (!audio) return;
  audio.stream.getTracks().forEach((t) => t.stop());
  try { await audio.ctx.close(); } catch {}
  audio = null;
}

async function startInput() {
  await stopInput();
  engine.reset();
  ctxOffsets = []; ctxOffset = null;
  if (!settings.deviceId) { setInputMessage('Choose an input device'); return; }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        deviceId: { exact: settings.deviceId },
        echoCancellation: false, noiseSuppression: false, autoGainControl: false,
        channelCount: { ideal: 64 },
      },
    });
    micDenied = false;
    const track = stream.getAudioTracks()[0];
    inputChannels = track.getSettings().channelCount || 2;
    settings.deviceLabel = track.label || settings.deviceLabel; save();
    const ctx = new AudioContext({ latencyHint: 'interactive' });
    await ctx.audioWorklet.addModule(new URL('./ltc-worklet.js', import.meta.url));
    const source = ctx.createMediaStreamSource(stream);
    const node = new AudioWorkletNode(ctx, 'ltc-reader', {
      numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
      channelCount: inputChannels, channelCountMode: 'explicit', channelInterpretation: 'discrete',
      processorOptions: { channel: settings.channel },
    });
    node.port.onmessage = onWorkletMessage;
    const silent = ctx.createGain();
    silent.gain.value = 0;
    source.connect(node);
    node.connect(silent).connect(ctx.destination);   // keeps the worklet running
    audio = { ctx, stream, node };
    lastAudioAt = performance.now();
    setInputMessage(`${ctx.sampleRate} Hz`);
    renderChannels();
  } catch (e) {
    micDenied = e.name === 'NotAllowedError';
    setInputMessage(micDenied ? 'No audio permission' : `Can't open device (${e.name})`);
  }
}

/** Developer switch (?synthltc): plays synthesized 25 fps LTC from 02:00:00:00 into the
 *  decoder, exercising the full audio path without a device or audio permission. */
async function startSynthInput() {
  await stopInput();
  engine.reset();
  ctxOffsets = []; ctxOffset = null;
  const { synthesize } = await import('./core/ltc-generator.js');
  const ctx = new AudioContext({ latencyHint: 'interactive' });
  await ctx.audioWorklet.addModule(new URL('./ltc-worklet.js', import.meta.url));
  const samples = synthesize({ hours: 2, minutes: 0, seconds: 0, frames: 0 }, FrameRate.fps25, 1 / 25, 25 * 60, ctx.sampleRate, 0.3, 0.003);
  const buffer = ctx.createBuffer(1, samples.length, ctx.sampleRate);
  buffer.copyToChannel(samples, 0);
  const source = ctx.createBufferSource();
  source.buffer = buffer;
  const node = new AudioWorkletNode(ctx, 'ltc-reader', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1], processorOptions: { channel: 0 } });
  node.port.onmessage = onWorkletMessage;
  const silent = ctx.createGain(); silent.gain.value = 0;
  source.connect(node); node.connect(silent).connect(ctx.destination);
  source.start();
  audio = { ctx, stream: { getTracks: () => [] }, node };
  lastAudioAt = performance.now();
  setInputMessage(`test LTC · ${ctx.sampleRate} Hz`);
  console.log('synthetic LTC input running at', ctx.sampleRate, 'Hz');
}

/** Audio-clock ms → performance.now() ms. The smallest recent difference is the real offset
 *  (larger ones include message-delivery delay). */
function toPerf(ctxMs) { return ctxMs + (ctxOffset ?? 0); }

function onWorkletMessage(e) {
  const m = e.data;
  const now = performance.now();
  if (m.type === 'level') {
    const blockEnd = m.ctxMs + (128 * 1000) / audio.ctx.sampleRate;
    ctxOffsets.push(now - blockEnd);
    if (ctxOffsets.length > 100) ctxOffsets.shift();
    ctxOffset = Math.min(...ctxOffsets);
    engine.reportInputGap(now - lastAudioAt);
    lastAudioAt = now;
    levelPeak = Math.max(levelPeak, m.peak);
    if (m.channels && m.channels !== inputChannels) { inputChannels = m.channels; renderChannels(); }
  } else if (m.type === 'frame' && ctxOffset != null) {
    engine.ingest({ ...m.frame, endTime: toPerf(m.frame.endTime) });
  }
}

function setInputMessage(text) { $('inputMessage').textContent = text; }

// ---------------------------------------------------------------- MIDI output

let midi = null;
const kindOf = (name) =>
  /^IAC\b|IAC Driver/i.test(name) ? 'iac'
  : /loopmidi|loopback|virtual loop/i.test(name) ? 'loopback'
  : /network|session|rtpmidi/i.test(name) ? 'network'
  : 'device';
const kindLabel = { iac: 'IAC', loopback: 'LOOPBACK', network: 'NETWORK', device: 'DEVICE' };

async function startMidi() {
  try {
    midi = await navigator.requestMIDIAccess({ sysex: true });
    midi.onstatechange = () => renderOutputs();
    midiError = '';
  } catch (e) {
    midiError = `MIDI unavailable (${e.name}).`;
  }
  renderOutputs();
}

function midiOutputs() {
  return midi ? [...midi.outputs.values()].filter((o) => o.state !== 'disconnected') : [];
}

const isSelected = (o) => settings.outputs.some((s) => s.id === o.id || s.name === o.name);

/** Outputs MTC is going to right now. */
function activeOutputs() { return midiOutputs().filter(isSelected); }

function toggleOutput(o) {
  if (isSelected(o)) settings.outputs = settings.outputs.filter((s) => s.id !== o.id && s.name !== o.name);
  else settings.outputs = [...settings.outputs, { id: o.id, name: o.name }];
  save();
  renderOutputs();
}

function renderOutputs() {
  const list = $('outputs');
  list.innerHTML = '';
  const outs = midiOutputs();
  if (!outs.length && !settings.outputs.length) {
    const p = document.createElement('div');
    p.className = 'note'; p.style.color = 'var(--amber)';
    p.textContent = bridge.platform === 'darwin' ? 'No MIDI ports yet. Add an IAC bus in Audio MIDI Setup.' : 'No MIDI ports yet. Install loopMIDI and create a port.';
    list.append(p);
  }
  for (const o of outs) list.append(outputRow(o.name, kindOf(o.name), isSelected(o), () => toggleOutput(o)));
  for (const s of settings.outputs) {
    if (outs.some((o) => o.id === s.id || o.name === s.name)) continue;
    const row = outputRow(`${s.name} (not connected)`, null, true, () => {
      settings.outputs = settings.outputs.filter((x) => x !== s); save(); renderOutputs();
    });
    row.classList.add('missing');
    row.title = "This port isn't available right now. MTC resumes to it when it comes back. Untick to forget it.";
    list.append(row);
  }
  updateFooter();
}

function outputRow(name, kind, checked, onChange) {
  const label = document.createElement('label');
  label.className = 'out';
  const box = document.createElement('input');
  box.type = 'checkbox'; box.checked = checked; box.onchange = onChange;
  const text = document.createElement('span');
  text.className = 'name'; text.textContent = name;
  label.append(box, text);
  if (kind) {
    const badge = document.createElement('span');
    badge.className = 'badge ' + kind; badge.textContent = kindLabel[kind];
    label.append(badge);
  }
  return label;
}

// ---------------------------------------------------------------- Art-Net

let interfaces = [];
let artNetTarget = null;

async function renderArtNet() {
  interfaces = await bridge.interfaces();
  const select = $('artnet');
  const choice = settings.artNetChoice;
  select.innerHTML = '';
  select.add(new Option('Off', 'off'));
  for (const i of interfaces) select.add(new Option(`${i.name} · ${i.broadcast}`, i.broadcast));
  if (choice !== 'off' && choice !== 'custom' && !interfaces.some((i) => i.broadcast === choice)) select.add(new Option(`${choice} (not connected)`, choice));
  select.add(new Option('Custom IP…', 'custom'));
  select.value = choice;
  $('artnetIP').hidden = choice !== 'custom';
  $('artnetIP').value = settings.artNetCustomIP;
  await applyArtNet();
}

async function applyArtNet() {
  const choice = settings.artNetChoice;
  const target = choice === 'off' ? null : choice === 'custom' ? settings.artNetCustomIP.trim() : choice;
  const ok = await bridge.setArtNetTarget(target || null);
  $('artnetIP').classList.toggle('invalid', choice === 'custom' && !ok);
  artNetTarget = ok ? target || null : null;
  updateFooter();
}

// ---------------------------------------------------------------- MTC clock

// Every 4 ms, schedule the MTC due in the next 12 ms with exact send times, so the MIDI
// system delivers each quarter-frame on time even if this page is briefly busy.
const LOOKAHEAD = 12;
setInterval(() => {
  const now = performance.now();
  const out = scheduler.poll(now, now + LOOKAHEAD);
  if (out.messages.length) {
    const targets = activeOutputs();
    for (const m of out.messages) for (const o of targets) { try { o.send(m.bytes, m.time); } catch {} }
  }
  if (artNetTarget && out.frames.length && out.rate) {
    for (const f of out.frames) {
      const packet = artNetTimecodePacket(f.tc, out.rate);
      setTimeout(() => bridge.sendArtNet(packet), Math.max(0, f.time - now));
    }
  }
}, 4);

// ---------------------------------------------------------------- display

let shownFrame = null, shownGeneration = -1, lastStatus = null, statusSentAt = 0;
let relocationTimes = [], lastRelocations = 0, meterDB = -80, meterLit = -1;
let jumpWarning = false, loopWarning = false;
const segments = 24;

function buildMeter() {
  const meter = $('meter');
  for (let i = 0; i < segments; i++) {
    const seg = document.createElement('i');
    seg.style.setProperty('--c', i >= segments - 2 ? 'var(--red)' : i >= segments - 6 ? 'var(--amber)' : 'var(--green)');
    meter.append(seg);
  }
}

/** Writes text only when it changes (every DOM write forces a layout and repaint). */
function setText(id, text) { const el = $(id); if (el.textContent !== text) el.textContent = text; }
function setHidden(id, hidden) { const el = $(id); if (el.hidden !== hidden) el.hidden = hidden; }

function updateDisplay() {
  const now = performance.now();
  const snap = engine.snapshot(now);
  const status = snap.status;
  if (status !== lastStatus) {
    document.body.classList.remove('st-locked', 'st-freewheel', 'st-nosignal', 'st-test');
    document.body.classList.add({ [Status.locked]: 'st-locked', [Status.freewheel]: 'st-freewheel', [Status.noSignal]: 'st-nosignal', [Status.test]: 'st-test' }[status]);
    $('statusPill').textContent = status;
    renderTestButton(status === Status.test);
  }

  if (snap.rate) {
    setText('rate', snap.rate.label);
    if (snap.rate !== offsetRate) { offsetRate = snap.rate; applyOffset(); }
    if (status !== Status.noSignal) {
      // Never step backwards from tiny timing corrections; only on a real jump.
      let frame = Math.floor(snap.position(now));
      if (snap.generation === shownGeneration && shownFrame != null && frame < shownFrame) frame = shownFrame;
      shownFrame = frame; shownGeneration = snap.generation;
      const text = format(fromFrameCount(frame, snap.rate), snap.rate.drop);
      setText('tc', text);
    }
  } else setText('rate', '—');

  const raw = snap.lastLTC && snap.lastLTCAge < 0.5 ? format(snap.lastLTC) : '—';
  if ($('rawLTC').textContent !== raw) { $('rawLTC').textContent = raw; $('rawLTC').classList.toggle('live', raw !== '—'); }

  if (snap.relocations !== lastRelocations) { lastRelocations = snap.relocations; relocationTimes.push(now); }
  relocationTimes = relocationTimes.filter((t) => now - t < 10000);
  const loop = snap.looping, jump = relocationTimes.length >= 4 && !snap.looping;
  if (loop !== loopWarning || jump !== jumpWarning) { loopWarning = loop; jumpWarning = jump; renderWarnings(); }
  setHidden('loopNote', !(loop && settings.viewMode === 'timecode'));

  // Level meter: fast attack, slow release, redrawn only when a segment changes.
  const db = levelPeak > 0 ? Math.max(20 * Math.log10(levelPeak), -80) : -80;
  levelPeak = 0;
  meterDB = db > meterDB ? db : Math.max(db, meterDB - 1.5);
  const lit = Math.max(0, Math.min(segments, Math.floor((meterDB + 60) / 2.5) + 1));
  if (lit !== meterLit) {
    meterLit = lit;
    [...$('meter').children].forEach((seg, i) => seg.classList.toggle('on', i < lit && meterDB > -60 + i * 2.5));
  }

  updateHistory(status, db, now);

  const outputs = activeOutputs().map((o) => o.name);
  if (status !== lastStatus || now - statusSentAt > 1000) {
    bridge.reportStatus(status, $('tc').textContent, outputs);
    statusSentAt = now;
  }
  lastStatus = status;
}

// ---------------------------------------------------------------- signal history

const HISTORY = 600;
let history = [], slice = null, sliceLevel = -80, sliceTicks = 0, previousStatus = Status.noSignal, dropoutTimes = [];
const rank = { [Status.noSignal]: 0, [Status.test]: 1, [Status.locked]: 2, [Status.freewheel]: 3 };

function updateHistory(status, db, now) {
  if (previousStatus === Status.freewheel && status === Status.locked) dropoutTimes.push(now);
  previousStatus = status;
  if (slice == null || rank[status] > rank[slice]) slice = status;
  sliceLevel = Math.max(sliceLevel, db);
  if (++sliceTicks < 15) return;
  history.push({ status: slice, db: sliceLevel });
  if (history.length > HISTORY) history.shift();
  slice = null; sliceLevel = -80; sliceTicks = 0;
  dropoutTimes = dropoutTimes.filter((t) => now - t < 300000);
  const n = dropoutTimes.length;
  $('dropouts').textContent = n === 0 ? 'No dropouts' : `${n} dropout${n === 1 ? '' : 's'}`;
  $('dropouts').classList.toggle('bad', n > 0);
  if (settings.viewMode === 'routing') drawHistory();
}

function drawHistory() {
  const canvas = $('history');
  const w = canvas.clientWidth, h = canvas.clientHeight, dpr = devicePixelRatio || 1;
  if (canvas.width !== Math.round(w * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr); }
  const g = canvas.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, h);
  const css = getComputedStyle(document.body);
  const color = { [Status.locked]: css.getPropertyValue('--green'), [Status.freewheel]: css.getPropertyValue('--amber'), [Status.noSignal]: css.getPropertyValue('--red'), [Status.test]: css.getPropertyValue('--blue') };
  const bw = w / HISTORY;
  // Newest on the left; older samples move right.
  for (let i = 0; i < history.length; i++) {
    const s = history[history.length - 1 - i];
    const frac = Math.min(Math.max((s.db + 60) / 60, 0), 1);
    const bh = s.status === Status.noSignal ? 3 : s.status === Status.freewheel ? h : Math.max(4, h * frac);
    g.globalAlpha = s.status === Status.noSignal ? 0.45 : 1;
    g.fillStyle = color[s.status];
    g.fillRect(i * bw, h - bh, Math.max(bw, s.status === Status.freewheel ? 2 : 1), bh);
  }
  g.globalAlpha = 1;
}

// ---------------------------------------------------------------- warnings & footer

function renderWarnings() {
  const box = $('warnings');
  box.innerHTML = '';
  const add = (color, text, buttonText, onClick) => {
    const w = document.createElement('div');
    w.className = 'warning'; w.style.setProperty('--w', color);
    w.innerHTML = '<span class="dot"></span><span class="grow"></span>';
    w.querySelector('.grow').textContent = text;
    if (buttonText) { const b = document.createElement('button'); b.className = 'small'; b.textContent = buttonText; b.onclick = onClick; w.append(b); }
    box.append(w);
  };
  if (micDenied) add('var(--red)', 'LTC Bridge needs microphone (audio input) permission to hear timecode.', 'Open Settings', () => bridge.openPrivacySettings());
  if (midiError) add('var(--red)', midiError);
  if (!activeOutputs().length && !artNetTarget) add('var(--red)', "MTC isn't going anywhere. Tick a port under MTC Output → Send to.", bridge.platform === 'darwin' ? 'Audio MIDI Setup' : 'Get loopMIDI', () => bridge.openMidiSetup());
  if (loopWarning) add('var(--amber)', 'The input is replaying the same short piece of timecode (a stuck audio buffer upstream). Ignoring it.');
  if (jumpWarning) add('var(--amber)', 'Incoming timecode keeps jumping. Check the source or channel.');
}

function updateFooter() {
  const names = activeOutputs().map((o) => o.name);
  $('footerText').textContent = names.length
    ? `In your lighting software, select “${names[0]}” as the MIDI timecode input.`
    : 'Choose where to send MTC under MTC Output → Send to.';
  renderWarnings();
}

// ---------------------------------------------------------------- test generator

function renderTestRates() {
  const box = $('testRate');
  box.innerHTML = '';
  for (const r of allRates) {
    const b = document.createElement('button');
    b.textContent = r.short;
    b.classList.toggle('active', r.id === settings.testRate);
    b.onclick = () => { settings.testRate = r.id; save(); renderTestRates(); };
    box.append(b);
  }
}

function renderTestButton(running) {
  $('testButton').textContent = running ? '■ Stop Test' : '▶ Start Test';
  $('testButton').classList.toggle('running', running);
  $('testRate').classList.toggle('disabled', running);
  $('testStart').disabled = running;
}

function toggleTest() {
  if (engine.testMode) { engine.stopTest(); renderTestButton(false); return; }
  const rate = rateById(settings.testRate);
  const start = parseTimecode($('testStart').value, rate);
  $('testStart').classList.toggle('invalid', !start);
  if (!start) return;
  settings.testStart = $('testStart').value; save();
  engine.startTest(start, rate, performance.now());
  renderTestButton(true);
}

// ---------------------------------------------------------------- views & window size

function headerHeight() { return $('header').offsetHeight; }
function fullHeight() { return headerHeight() + $('routingInner').scrollHeight; }

function applyViewMode(animate) {
  const mode = settings.viewMode;
  document.body.classList.toggle('mode-timecode', mode === 'timecode');
  document.body.classList.toggle('mode-routing', mode === 'routing');
  [...$('viewSwitch').children].forEach((b) => b.classList.toggle('active', b.dataset.mode === mode));
  if (mode === 'timecode') {
    bridge.setHeight(headerHeight(), { animate, lockHeight: true });
  } else {
    const room = screen.availHeight - (window.screenY - (screen.availTop || 0)) - 8;
    const target = Math.max(headerHeight(), Math.min(settings.routingHeight ?? fullHeight(), fullHeight(), room));
    bridge.setHeight(target, { animate, lockHeight: false });
    setTimeout(drawHistory, 450);
  }
}

function setViewMode(mode) {
  if (mode === settings.viewMode) return;
  if (settings.viewMode === 'routing') settings.routingHeight = window.innerHeight;
  settings.viewMode = mode; save();
  applyViewMode(true);
}

let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (settings.viewMode === 'routing') { settings.routingHeight = window.innerHeight; save(); drawHistory(); }
  }, 600);
});

// ---------------------------------------------------------------- diagnostics

async function saveDiagnostics() {
  const now = performance.now();
  const snap = engine.snapshot(now);
  let text = 'LTC Bridge diagnostics\n';
  text += `app,${await bridge.version()},platform,${bridge.platform}\n`;
  text += `device,${settings.deviceLabel || 'none'},channel,${settings.channel + 1},sample rate,${audio ? audio.ctx.sampleRate : 0},input channels,${inputChannels}\n`;
  text += `status,${snap.status},rate,${snap.rate ? snap.rate.label : '-'},offset,${settings.offset},freewheel,${settings.freewheel}\n`;
  text += `outputs,${activeOutputs().map((o) => o.name).join(' | ') || 'none'},art-net,${artNetTarget || 'off'},dropouts in last 5 min,${dropoutTimes.length}\n\n`;
  text += 'seconds ago,ltc,drop frame,action,timing error (frames)\n';
  for (const e of engine.log) text += `${((now - e.time) / 1000).toFixed(4)},${format(e.timecode)},${e.dropFrame ? 'yes' : 'no'},${e.action},${e.error.toFixed(3)}\n`;
  await bridge.saveDiagnostics(text);
}

// ---------------------------------------------------------------- wiring

async function init() {
  buildMeter();
  renderTestRates();
  $('offset').value = settings.offset;
  $('testStart').value = settings.testStart;
  $('freewheel').textContent = `${settings.freewheel} frames`;
  $('midiSetup').textContent = bridge.platform === 'darwin' ? 'Set Up IAC or Network MIDI…' : 'Get loopMIDI (virtual MIDI ports)…';
  $('pin').setAttribute('aria-pressed', String(settings.keepOnTop));
  bridge.setOnTop(settings.keepOnTop);
  $('login').checked = await bridge.getLogin();

  $('device').onchange = () => {
    settings.deviceId = $('device').value;
    settings.deviceLabel = $('device').selectedOptions[0]?.textContent || '';
    settings.channel = 0; save(); startInput();
  };
  $('channel').onchange = () => {
    settings.channel = Number($('channel').value); save();
    engine.reset();
    audio?.node.port.postMessage({ type: 'channel', channel: settings.channel });
  };
  $('artnet').onchange = () => { settings.artNetChoice = $('artnet').value; save(); $('artnetIP').hidden = settings.artNetChoice !== 'custom'; applyArtNet(); };
  $('artnetIP').onchange = () => { settings.artNetCustomIP = $('artnetIP').value; save(); applyArtNet(); };
  $('offset').onchange = applyOffset;
  $('offset').onkeydown = (e) => { if (e.key === 'Enter') applyOffset(); };
  const setFreewheel = (v) => { settings.freewheel = Math.max(0, Math.min(120, v)); engine.freewheelFrames = settings.freewheel; $('freewheel').textContent = `${settings.freewheel} frames`; save(); };
  $('fwDown').onclick = () => setFreewheel(settings.freewheel - 1);
  $('fwUp').onclick = () => setFreewheel(settings.freewheel + 1);
  $('testButton').onclick = toggleTest;
  $('testStart').onkeydown = (e) => { if (e.key === 'Enter') toggleTest(); };
  $('login').onchange = async () => { $('login').checked = await bridge.setLogin($('login').checked); };
  $('pin').onclick = () => { settings.keepOnTop = !settings.keepOnTop; save(); $('pin').setAttribute('aria-pressed', String(settings.keepOnTop)); bridge.setOnTop(settings.keepOnTop); };
  $('midiSetup').onclick = () => bridge.openMidiSetup();
  $('saveDiag').onclick = saveDiagnostics;
  for (const b of $('viewSwitch').children) b.onclick = () => setViewMode(b.dataset.mode);
  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === '1') setViewMode('timecode');
    if ((e.ctrlKey || e.metaKey) && e.key === '2') setViewMode('routing');
  });

  applyOffset();
  renderChannels();
  // Size the window and start the display first, so a slow permission prompt can't hold them up.
  requestAnimationFrame(() => applyViewMode(false));
  setInterval(updateDisplay, 1000 / 30);
  await startMidi();
  await renderArtNet();
  const devParams = new URLSearchParams(location.search);
  if (devParams.has('synthltc')) await startSynthInput();
  else if (!devParams.has('noaudio')) {     // developer switch: skip audio input (MIDI-only tests)
    await refreshDevices();
    await startInput();
  }

  // Watchdog: reconnect when the device list changes or audio stops arriving.
  navigator.mediaDevices.addEventListener('devicechange', async () => {
    const had = audio != null;
    const devices = await refreshDevices();
    if (!had && devices.some((d) => d.deviceId === settings.deviceId)) startInput();
  });
  setInterval(async () => {
    if (audio && performance.now() - lastAudioAt > 2000 && !micDenied) { setInputMessage('Reconnecting…'); await startInput(); }
    else if (!audio && !micDenied && settings.deviceId) { const d = await listDevices(); if (d.some((x) => x.deviceId === settings.deviceId)) startInput(); }
  }, 2000);
  setInterval(async () => {
    const list = await bridge.interfaces();
    if (JSON.stringify(list) !== JSON.stringify(interfaces)) renderArtNet();
  }, 5000);

  // Developer switches: ?autotest starts the generator; &output=NAME ticks a MIDI port by name.
  const dev = new URLSearchParams(location.search);
  const devOutput = dev.get('output');
  if (devOutput) {
    const o = midiOutputs().find((x) => x.name.includes(devOutput));
    if (o && !isSelected(o)) toggleOutput(o);
    console.log('dev output:', o ? o.name : 'not found', '| outputs:', midiOutputs().map((x) => x.name).join(', '));
  }
  if (dev.has('autotest')) toggleTest();
  if (dev.has('cycleviews')) {   // developer switch: flip views to exercise the window animation
    setTimeout(() => setViewMode('timecode'), 1500);
    setTimeout(() => setViewMode('routing'), 3000);
  }
}

init();
