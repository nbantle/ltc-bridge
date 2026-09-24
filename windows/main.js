// LTC Bridge (Electron) main process: window, tray light, Art-Net sender, login item,
// diagnostics and window sizing. All timecode work happens in the page (src/app.js).
import { app, BrowserWindow, Menu, Tray, dialog, ipcMain, nativeImage, powerSaveBlocker, session, shell, systemPreferences } from 'electron';
import dgram from 'node:dgram';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const isWindows = process.platform === 'win32';
const isMac = process.platform === 'darwin';

// Timecode must keep flowing when the window is hidden, minimized or covered.
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-background-timer-throttling');
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');

if (!app.requestSingleInstanceLock()) app.quit();

let win = null;
let tray = null;
let quitting = false;
let lastStatus = 'NO SIGNAL';

// ---------------------------------------------------------------- window

function createWindow() {
  win = new BrowserWindow({
    width: 780,
    height: 197,
    minWidth: 520,
    minHeight: 150,
    show: false,
    backgroundColor: '#141416',
    title: 'LTC Bridge',
    icon: path.join(here, 'assets', isWindows ? 'icon.ico' : 'icon.png'),
    autoHideMenuBar: true,
    titleBarStyle: 'hidden',
    ...(isWindows ? { titleBarOverlay: { color: '#141416', symbolColor: '#8e8e96', height: 34 } } : {}),
    ...(isMac ? { trafficLightPosition: { x: 12, y: 12 } } : {}),
    webPreferences: {
      preload: path.join(here, 'preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      backgroundThrottling: false,
    },
  });
  // Developer switches (never set in normal use): LTC_DEV_QUERY is passed to the page,
  // LTC_DEBUG prints the page's console here.
  win.loadFile(path.join(here, 'index.html'), process.env.LTC_DEV_QUERY ? { search: process.env.LTC_DEV_QUERY } : {});
  if (process.env.LTC_DEBUG) win.webContents.on('console-message', (_e, level, message) => console.log(`[page ${level}] ${message}`));
  win.once('ready-to-show', () => win.show());

  // Closing the window keeps timecode running in the tray; quit from the tray menu.
  win.on('close', (e) => {
    if (!quitting) { e.preventDefault(); win.hide(); }
  });
}

function showWindow() {
  if (!win) return;
  win.show();
  win.focus();
}

// ---------------------------------------------------------------- tray light

const colors = { 'LOCKED': [61, 220, 132], 'FREEWHEEL': [255, 176, 32], 'NO SIGNAL': [255, 69, 58], 'TEST': [77, 163, 255] };
const dotCache = {};

/** A colored dot drawn straight into a bitmap (no image files needed). */
function dot(status) {
  if (dotCache[status]) return dotCache[status];
  const size = 32, [r, g, b] = colors[status] || colors['NO SIGNAL'];
  const buf = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const d = Math.hypot(x + 0.5 - size / 2, y + 0.5 - size / 2);
    const alpha = Math.max(0, Math.min(1, size * 0.36 - d + 0.5));
    const i = (y * size + x) * 4;
    buf[i] = b; buf[i + 1] = g; buf[i + 2] = r; buf[i + 3] = Math.round(alpha * 255);   // BGRA
  }
  const img = nativeImage.createFromBitmap(buf, { width: size, height: size, scaleFactor: 2 });
  dotCache[status] = img;
  return img;
}

function createTray() {
  tray = new Tray(dot('NO SIGNAL'));
  tray.setToolTip('LTC Bridge');
  tray.on('click', showWindow);
  updateTrayMenu('NO SIGNAL', '--:--:--:--', []);
}

function updateTrayMenu(status, timecode, outputs) {
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: `${status}   ${timecode}`, enabled: false },
    { label: outputs.length ? `Output: ${outputs.join(', ')}` : 'Output: none selected', enabled: false },
    { type: 'separator' },
    { label: 'Show LTC Bridge', click: showWindow },
    { type: 'separator' },
    { label: 'Quit LTC Bridge', click: () => app.quit() },
  ]));
}

let trayMenuKey = '';
ipcMain.on('status', (_e, status, timecode, outputs) => {
  if (status !== lastStatus) tray?.setImage(dot(status));
  lastStatus = status;
  tray?.setToolTip(`LTC Bridge: ${status} ${timecode}`);
  const key = status + outputs.join('|');
  if (key !== trayMenuKey) { trayMenuKey = key; updateTrayMenu(status, timecode, outputs); }
});

// Quitting while timecode runs asks first, so a stray click can't cut the lighting off mid-song.
app.on('before-quit', (e) => {
  if (quitting) return;
  if (lastStatus !== 'NO SIGNAL') {
    const choice = dialog.showMessageBoxSync(win?.isVisible() ? win : null, {
      type: 'warning', buttons: ['Keep Running', 'Quit'], defaultId: 0, cancelId: 0,
      message: 'Timecode is running',
      detail: 'Quitting LTC Bridge stops MIDI timecode to your lighting software.',
    });
    if (choice === 0) { e.preventDefault(); return; }
  }
  quitting = true;
});

// ---------------------------------------------------------------- window height

// Animates the content height with the top edge fixed, on the same curve as the page's
// transition. lockHeight fixes the height (Timecode view); otherwise it's resizable.
let heightTimer = null;
function bezier(x, c) {
  const coord = (t, p1, p2) => 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t;
  let lo = 0, hi = 1, t = x;
  for (let i = 0; i < 30; i++) { t = (lo + hi) / 2; if (coord(t, c[0], c[2]) < x) lo = t; else hi = t; }
  return coord(t, c[1], c[3]);
}
ipcMain.on('set-height', (_e, height, { animate = true, lockHeight = false, duration = 420 } = {}) => {
  if (!win) return;
  clearInterval(heightTimer);
  const target = Math.round(height);
  const minW = 520;
  win.setMaximumSize(10000, 10000);
  win.setMinimumSize(minW, Math.min(target, 150));
  const startBounds = win.getContentBounds();
  const from = startBounds.height;
  const finish = () => {
    if (lockHeight) { win.setMinimumSize(minW, target); win.setMaximumSize(10000, target); }
    else win.setMinimumSize(minW, 150);
  };
  if (!animate || Math.abs(target - from) < 1) {
    win.setContentBounds({ ...win.getContentBounds(), height: target });
    finish();
    return;
  }
  const t0 = Date.now();
  heightTimer = setInterval(() => {
    const p = Math.min((Date.now() - t0) / duration, 1);
    const h = Math.round(from + (target - from) * bezier(p, [0.33, 0, 0.2, 1]));
    win.setContentBounds({ ...win.getContentBounds(), height: h });   // x/y are the top-left: the top stays put
    if (p >= 1) {
      clearInterval(heightTimer); finish();
      if (process.env.LTC_DEBUG) { const b = win.getContentBounds(); console.log(`[size] ${from} -> ${target}: now ${b.width}x${b.height} at top ${b.y}, locked ${lockHeight}`); }
    }
  }, 8);
});

ipcMain.on('on-top', (_e, on) => win?.setAlwaysOnTop(!!on, 'floating'));

// ---------------------------------------------------------------- Art-Net

let artSocket = null;
let artTarget = null;
function ensureSocket() {
  if (artSocket) return artSocket;
  artSocket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  artSocket.on('error', () => {});
  artSocket.bind(() => { try { artSocket.setBroadcast(true); } catch {} });
  return artSocket;
}
ipcMain.handle('artnet-target', (_e, ip) => {
  const valid = typeof ip === 'string' && /^(\d{1,3})(\.\d{1,3}){3}$/.test(ip) && ip.split('.').every((n) => +n <= 255);
  artTarget = valid ? ip : null;
  if (artTarget) ensureSocket();
  return valid || ip == null;
});
ipcMain.on('artnet-send', (_e, bytes) => {
  if (!artTarget || !artSocket) return;
  artSocket.send(Buffer.from(bytes), 6454, artTarget);
});

/** IPv4 interfaces with their broadcast addresses. */
ipcMain.handle('interfaces', () => {
  const list = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const ip = a.address.split('.').map(Number), mask = a.netmask.split('.').map(Number);
      const broadcast = ip.map((b, i) => (b | (~mask[i] & 255))).join('.');
      list.push({ name, address: a.address, broadcast });
    }
  }
  return list;
});

// ---------------------------------------------------------------- misc

ipcMain.handle('version', () => app.getVersion());
ipcMain.handle('get-login', () => app.getLoginItemSettings().openAtLogin);
ipcMain.handle('set-login', (_e, on) => { app.setLoginItemSettings({ openAtLogin: !!on }); return app.getLoginItemSettings().openAtLogin; });

ipcMain.handle('save-diagnostics', (_e, text) => {
  const stamp = new Date().toISOString().replace(/[:T]/g, '.').slice(0, 19);
  const file = path.join(app.getPath('desktop'), `LTC Bridge Log ${stamp}.csv`);
  fs.writeFileSync(file, text);
  shell.showItemInFolder(file);
  return file;
});

ipcMain.on('open-midi-setup', () => {
  if (isMac) shell.openPath('/System/Applications/Utilities/Audio MIDI Setup.app');
  else shell.openExternal('https://www.tobias-erichsen.de/software/loopmidi.html');
});
ipcMain.on('open-privacy', () => {
  if (isWindows) shell.openExternal('ms-settings:privacy-microphone');
  else shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone');
});

// ---------------------------------------------------------------- start

app.whenReady().then(async () => {
  // Allow audio input and MIDI (including SysEx, for MTC full-frame messages).
  const allowed = new Set(['media', 'midi', 'midiSysex']);
  session.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => callback(allowed.has(permission)));
  session.defaultSession.setPermissionCheckHandler((_wc, permission) => allowed.has(permission));
  if (isMac && !(process.env.LTC_DEV_QUERY || '').includes('noaudio')) {
    try { await systemPreferences.askForMediaAccess('microphone'); } catch {}
  }

  powerSaveBlocker.start('prevent-app-suspension');
  createWindow();
  createTray();
});

app.on('second-instance', showWindow);
app.on('activate', showWindow);
app.on('window-all-closed', () => {});   // keep running in the tray
