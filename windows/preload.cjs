// Exposes the few main-process features the page needs, without giving it Node access.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bridge', {
  platform: process.platform,
  version: () => ipcRenderer.invoke('version'),
  interfaces: () => ipcRenderer.invoke('interfaces'),
  setArtNetTarget: (ip) => ipcRenderer.invoke('artnet-target', ip),
  sendArtNet: (bytes) => ipcRenderer.send('artnet-send', bytes),
  getLogin: () => ipcRenderer.invoke('get-login'),
  setLogin: (on) => ipcRenderer.invoke('set-login', on),
  saveDiagnostics: (text) => ipcRenderer.invoke('save-diagnostics', text),
  setOnTop: (on) => ipcRenderer.send('on-top', on),
  setHeight: (height, options) => ipcRenderer.send('set-height', height, options),
  reportStatus: (status, timecode, outputs) => ipcRenderer.send('status', status, timecode, outputs),
  openMidiSetup: () => ipcRenderer.send('open-midi-setup'),
  openPrivacySettings: () => ipcRenderer.send('open-privacy'),
});
