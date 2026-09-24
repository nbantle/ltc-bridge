# LTC Bridge — User Guide

LTC Bridge listens for SMPTE linear timecode (LTC) on an audio input and turns it into
MIDI timecode (MTC). It sends the MTC to the MIDI ports you choose, typically an IAC bus
that other apps on the same Mac, such as Jands Vista, use as their timecode input. It
replaces Figure 53's Lockstep, which is no longer supported on current macOS.

```
Ableton (LTC audio) → Dante network → Dante Virtual Soundcard → LTC Bridge → IAC bus → Vista
```

It can send to several places at once: IAC buses, network MIDI sessions (to other Macs)
and Art-Net timecode over the network.

---

## Contents
1. Requirements
2. Installing
3. Quick start
4. The window, explained
5. Settings reference
6. How it works
7. Status lights and what they mean
8. Troubleshooting
9. Diagnostics log
10. Tips for show use
11. Limitations and known issues
12. Building from source

---

## 1. Requirements
- A Mac running macOS 13 Ventura or newer (Apple Silicon or Intel).
- An audio input that carries LTC, such as Dante Virtual Soundcard, an audio interface, or a loopback device.
- Audio input permission (macOS asks the first time the app opens).

## 2. Installing
1. Unzip `LTC-Bridge.zip` and drag **LTC Bridge** into **Applications**.
2. Open it. macOS will say it can't verify the developer, because the app isn't from the
   App Store. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**
   next to the LTC Bridge message. You only need to do this once per version.
4. When asked, **Allow** audio input access. Without it the app only hears silence.

To update, quit LTC Bridge, replace the app in Applications, and repeat step 3 if asked.
Your settings are kept.

## 3. Quick start
1. Quit Lockstep or any other LTC-to-MTC converter, so Vista isn't getting two sources.
2. In **Dante Controller**, route the LTC channel from the Ableton computer to a receive
   channel on this Mac's Dante Virtual Soundcard.
3. In LTC Bridge, set **Device** to *Dante Virtual Soundcard* and **Channel** to that
   receive channel.
4. Press play in Ableton. The level meter should move, and the status should turn green
   and read **LOCKED**.
5. Set up an IAC bus if you don't have one (section 10), then tick it under
   **MTC Output → Send to**.
6. In Vista, choose that IAC bus as the MIDI timecode input.

No Ableton handy? Use the **Test Generator** (section 5) to check Vista on its own.

---

## 4. The window, explained

### Two views
Switch with the pill at the top right, or from the **View** menu.

| View | Shortcut | What it shows |
|---|---|---|
| **Timecode** | ⌘1 | Only the timecode panel and status: a compact strip you can leave on screen. |
| **Routing** | ⌘2 | The same timecode panel, with everything else below it: input and output settings, signal history, test generator and app settings. |

The timecode panel stays in the same place in both views. Switching views only grows or
shrinks the window from the bottom edge, and the routing controls slide in or out below
the panel.

### Resizing and tiling
- **Width:** drag either side, or use macOS window tiling (for example **Window → Move &
  Resize → Left**, or drag the window to the screen edge) to fit it beside other apps.
  The minimum width is 520 points. On narrower windows the Input and Output cards stack
  one above the other, joined by a vertical wire; the Test Generator and App cards stack too.
- **Height, Timecode view:** locked to the timecode panel.
- **Height, Routing view:** drag it to any height. If the window is shorter than the
  controls, scroll to see the rest. LTC Bridge remembers the height you chose and returns
  to it each time you switch back to Routing. The first time, it fits the controls (or the
  screen, if that's smaller).

The **pin** button next to the switch (or **View → Keep on Top**, ⌥⌘T) keeps the window
floating above other apps, including Vista. The app remembers which view you used last.

### Timecode display (top)
The large numbers show the timecode being sent out as MTC right now, with any offset
applied. The color shows the status: green while receiving, amber while freewheeling,
red when stopped, blue while the test generator runs (section 7). When stopped it keeps
showing the last position. For 29.97 drop-frame, the last separator is shown as `;`.

### Status badge
LOCKED, FREEWHEEL, NO SIGNAL or TEST. See section 7.

### Frame rate
The rate LTC Bridge detected from the incoming timecode: 24, 25, 29.97 DF or 30 fps.
It is detected automatically; see section 6.

### LTC Input card
| Item | What it shows |
|---|---|
| **Device** | The audio device to listen to. Shows *(Not connected)* if a saved device is missing. |
| **Channel** | Which input channel of that device carries LTC. |
| **Level** | Peak level of the chosen channel as an LED bar. Green is healthy, amber is hot, red is close to clipping. |
| **LTC in** | The most recent incoming LTC frame, before offset. Shows "—" when none has arrived in the last half second. The text on the right shows the sample rate or connection status. |

### The MTC wire
The line joining the two cards animates while MTC is flowing. It turns amber and stops
moving during freewheel, and becomes a dotted red line when stopped.

### MTC Output card
| Item | What it does |
|---|---|
| **Send to** | A checklist of every MIDI port on the Mac. MTC goes to each ticked port. Labels show the kind: **IAC** (a bus between apps on this Mac), **NETWORK** (a network MIDI session to another Mac), **DEVICE** (hardware) or **APP** (a port another app created). Tick one or several. |
| **Art-Net** | Optionally sends Art-Net timecode over the network. |
| **Offset** | Shifts the outgoing timecode. See section 5. |
| **Freewheel** | How long MTC keeps running after LTC disappears. See section 5. |

### Signal History card
A timeline of the last 5 minutes, with the newest moment on the left ("now") flowing
right toward "5 min ago". Each bar is half a second: its height is the input level, and
its color is the status (green locked, amber dropout, red no signal, blue
test). Dropouts are drawn full height so they're easy to spot. The count at the top right
is how many **dropouts** happened in the last 5 minutes: times LTC vanished briefly and
then came back. Stopping Ableton normally isn't counted.

### Test Generator card
Sends MTC without Ableton. See section 5.

### App card
**Open at login** and **Status light in menu bar**. See section 5.

### Warnings
| Warning | Meaning |
|---|---|
| **Audio permission** | LTC Bridge isn't allowed to hear audio. Click **Open Settings**. |
| **Loop warning** | The input keeps replaying the same short piece of timecode. LTC Bridge ignores the repeats. |
| **No output** (red) | Nothing is ticked under **Send to** (or the ticked ports are missing) and Art-Net is off, so MTC isn't going anywhere. |
| **Jump warning** | The output had to jump to a new position 4 or more times in 10 seconds. That points to a glitching source or the wrong channel. |

### Save Diagnostics
Bottom right of the Routing view. Saves a log of recent timecode activity to your
Desktop. See section 9.

### Menu bar light
A colored dot in the menu bar shows the status even when the window is closed: green,
amber, red or blue as above. Click it for the current timecode, input, the ports MTC is
going to and the dropout count, plus **Show LTC Bridge**, **Hide Menu Bar Icon** and **Quit**.

---

## 5. Settings reference

All settings are saved automatically and restored the next time the app opens.

### Device
Any macOS audio input with at least one input channel. The list refreshes every second,
so devices that appear later (for example after Dante Virtual Soundcard starts) show up
without restarting the app. Changing the device restarts listening and clears the lock.

If the chosen device disappears, LTC Bridge keeps the choice and reconnects on its own
when the device comes back. It also reconnects if the device stops delivering audio for
2 seconds or its sample rate changes.

### Channel
The input channel number, starting at 1, as shown in Dante Controller or your interface's
routing. With Dante Virtual Soundcard this is the DVS receive channel you routed LTC to.
Picking a channel with no audio gives a flat meter and NO SIGNAL; that isn't an error.

### Send to (MIDI outputs)
Tick every port MTC should go to. Any combination works: one IAC bus, or an IAC bus plus a
network session, and so on.
- **IAC bus:** the usual choice for Vista on the same Mac. See section 10 for setup.
- **Network MIDI:** to send MTC to another Mac, create a session in **Audio MIDI Setup →
  Window → Show MIDI Studio → Network** on both Macs, connect them, then tick the session
  here.
- **Set Up IAC or Network MIDI…** under the list opens Audio MIDI Setup.
- New ports appear in the list within a second, with no restart needed.
- If a ticked port disappears (for example a network session disconnects), it stays in the
  list as *(not connected)*, and MTC resumes to it as soon as it comes back. Untick it to
  forget it.
- If nothing is ticked and Art-Net is off, a red warning says MTC isn't going anywhere.

Don't tick a port that feeds back into another timecode converter, or you can create a loop.
Before 1.9 LTC Bridge also made its own "LTC Bridge" virtual port. That port is gone,
because it was recreated every time the app opened, and Vista would only pick it up again
after its settings were opened. IAC buses don't have that problem.

### Art-Net
Sends Art-Net timecode (ArtTimeCode) once per frame, on UDP port 6454, for lighting
consoles and media servers that accept it.
- **Off** (default).
- **An interface** (for example `en0 · 192.168.1.255`): broadcasts on that network.
  Choose the interface your lighting network is on.
- **Custom IP…:** sends to one device (unicast) or a broadcast address you type.
  Press **Return** to apply; red text means the address isn't valid.

The frame rate type in the packets matches the detected rate. Art-Net follows everything
MTC does: offset, freewheel and the test generator.

### Offset
Adds or subtracts a fixed amount of time from the outgoing MTC.
- Format: `HH:MM:SS:FF`. `;` and `.` also work as separators.
- Put a `-` in front to subtract, e.g. `-01:00:00:00` turns incoming `01:00:10:00` into `00:00:10:00`.
- Press **Return** to apply. If the text turns red, it isn't valid; the last valid offset stays in use.
- The frames part must be below the detected frame rate (for example below 24 at 24 fps).
- The offset is a plain length of time and doesn't depend on drop-frame counting.
- The **LTC in** readout shows the timecode before offset; the big display shows it after.
- The offset doesn't apply to the test generator, which starts exactly where you tell it.

Typical use: Ableton sends LTC starting at `01:00:00:00` but your Vista cues start at zero.

### Freewheel (0–120 frames, default 10)
When LTC disappears, MTC keeps counting forward on its own for this many frames before
it stops.

- **Why:** audio glitches and network hiccups can drop a few frames. Freewheel covers them,
  so Vista doesn't stutter or jump.
- **Trade-off:** LTC Bridge can't tell a glitch from you pressing stop. After a stop, MTC
  runs on for the freewheel length before stopping.

| Setting | At 24 fps | Good for |
|---|---|---|
| 0 | Stops right away | Stopping exactly when Ableton stops, but any glitch interrupts Vista |
| 10 (default) | about 0.4 s | Covers normal glitches with a short run-on after stop |
| 25–30 | about 1 to 1.25 s | An unreliable connection, with a noticeable run-on after stop |

If good LTC returns during freewheel, the output rejoins it without a jump.

### Test Generator
Sends MTC (and Art-Net, if on) from a start time you choose, with no LTC needed. Use it to
check Vista's cues or MIDI routing during setup.
1. Type a **Start at** time, e.g. `01:00:00:00`.
2. Pick a **Rate**: 24, 25, 29.97 DF or 30.
3. Click **Start Test**. The status turns blue and reads **TEST**.
4. Click **Stop Test** to stop. LTC Bridge goes back to listening for LTC.

While the test runs, incoming LTC is ignored. It still shows in **LTC in**, so you can see
it arriving. Start time and rate are remembered. A start time that isn't valid turns red.

### Open at login
Starts LTC Bridge automatically when you log in, so the show Mac comes up ready.
- If a note says **Approve in System Settings → General → Login Items**, turn LTC Bridge
  on there.
- Keep the app in **Applications**. If it's somewhere else, a note asks you to move it.

### Status light in menu bar
Shows or hides the menu bar dot (section 4). On by default. You can also hide it from its
own menu. If the window is closed and the dot is hidden, reopen the window by clicking
LTC Bridge in the Dock.

---

## 6. How it works

### Reading the LTC
LTC is a square-like audio signal carrying 80 bits per frame. LTC Bridge:
- follows the signal level automatically, so it works at any reasonable level and with
  either polarity
- works at any sample rate (44.1, 48, 96 kHz and more)
- ignores the user bits in LTC; only the time and the drop-frame flag are used.

### Frame-rate detection
No setting is needed. The rate is worked out from the timecode itself, in this order:
1. **Drop-frame flag:** if the LTC marks itself drop-frame, the rate is 29.97 DF.
2. **Where the frame count rolls over:** if the last frame number before a new second is
   23 the rate is 24 fps, if 24 it's 25 fps, if 29 it's 30 fps. This is the most reliable clue.
3. **How fast frames arrive:** until a rollover is seen, it times the gap between frames
   (41.7 ms = 24, 40 ms = 25, 33.3 ms = 30) and rules out any rate too low for the highest
   frame number seen.

Detection starts fresh when you change the device or channel. 29.97 non-drop LTC is sent
as 30 fps, which is how MTC represents it.

### Locking on
- LTC Bridge waits for **4 frames in a row** before it starts sending MTC. This stops noise
  or a single corrupted frame from triggering a false start.
- Once locked, small timing differences (up to 1.5 frames) are smoothed out, not treated as
  jumps. This absorbs uneven audio delivery from network soundcards.
- If the incoming timecode jumps (you moved Ableton's playhead), the output follows once the
  new position holds steady for 4 frames, and sends a full-frame message so the receiver
  moves immediately.
- **Loop protection:** if a "jump" lands on timecode already heard in the last second,
  LTC Bridge treats it as a stuck audio buffer replaying and ignores it.
- The big display never steps backwards because of timing smoothing, only on a real jump.

### Generating the MTC
- MTC is sent as **quarter-frame messages**, four per frame and evenly spaced, from a
  high-priority timing thread. That's what receivers like Vista expect.
- A **full-frame message** is sent whenever output starts or jumps, so receivers relocate
  right away.
- The rate code in the MTC matches the detected rate (24, 25, 29.97 DF or 30).
- Differences between the Dante clock and the Mac's clock are tracked continuously, so the
  MTC doesn't slowly drift away from the LTC over a long show.
- Art-Net timecode packets are sent from the same timing thread, one at the start of every
  frame.
- Measured accuracy in the self-test: within about 0.5 ms of the incoming LTC (one frame is 33–42 ms).

### Staying reliable
- LTC Bridge asks macOS not to throttle it or let the Mac sleep while it's running.
- Closing the window **does not stop MTC**. The app keeps running in the Dock and menu bar.
- Quitting with **⌘Q** while timecode is running asks you to confirm first, so a stray
  keystroke can't cut Vista off mid-song.

---

## 7. Status lights and what they mean

| Status | Meaning | MTC output |
|---|---|---|
| **LOCKED** (green) | Valid LTC is arriving and the output is following it. | Running |
| **FREEWHEEL** (amber) | No valid LTC for about 2½ frames; counting on its own. | Running, until the freewheel time runs out |
| **NO SIGNAL** (red) | No LTC, or freewheel ran out. | Stopped |
| **TEST** (blue) | The test generator is running; LTC is ignored. | Running from the test start time |

The same colors are used for the timecode panel, the MTC wire, the signal history and the
menu bar dot.

Ableton playing should show LOCKED all the time. Ableton stopped should show NO SIGNAL
after the freewheel time. Anything else, such as flipping between states while stopped,
is a problem; save diagnostics (section 9).

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| "Needs audio input permission" warning | Permission denied | Click **Open Settings** and turn on LTC Bridge under Microphone. |
| Level meter flat | Wrong device or channel, or Dante not routed | Check the routing in Dante Controller and the channel number. |
| Meter moves but always NO SIGNAL | Audio isn't LTC, or it's badly distorted | Check that Ableton is outputting LTC on that channel. Keep the level out of the red. |
| Wrong frame rate shown | Source rate differs from what you expect, or the sample rates don't match between machines | Check Ableton's LTC rate and that both sides of the Dante link use the same sample rate. |
| Loop warning / status flips while Ableton is stopped | The same short chunk of timecode keeps replaying | See section 11. Save diagnostics and report it. |
| Jump warning | Glitching source or noisy channel | Check cabling and routing, and try another channel. |
| Dropouts counted in Signal History | LTC briefly lost during playback | Check the Dante network, clocking and the LTC level. Raise **Freewheel** if Vista is affected. |
| Vista receives no timecode | IAC bus not ticked, or Vista listening on a different port | Check **Send to** in LTC Bridge and the MIDI timecode input in Vista are the same IAC bus. The footer of the Routing view names the port to pick. |
| Red "MTC isn't going anywhere" warning | Nothing ticked under **Send to** | Tick an IAC bus (or network session), or turn on Art-Net. |
| Vista still says "LTC Bridge" as its input after updating | Versions before 1.9 had their own port | Change Vista's timecode input to your IAC bus. |
| Is it LTC Bridge or Vista? | Not sure where the problem is | Run the **Test Generator**. If Vista follows the test, the problem is on the LTC side. |
| Vista is late or early by a fixed amount | Different start times | Use **Offset**. |
| MTC runs on after stopping | Freewheel | Lower **Freewheel**. |
| "Reconnecting…" | Device vanished or stopped | Usually a Dante Virtual Soundcard restart; it recovers by itself. |
| Art-Net device receives nothing | Wrong interface, or the device is on another subnet | Pick the interface on the lighting network, or use **Custom IP…** with the device's address. |
| Network MIDI session not in **Send to** | Session not set up or not connected | Set it up in Audio MIDI Setup on both Macs and connect them; it appears within a second. |
| Open at login doesn't stick | Needs approval, or app not in Applications | Follow the note under the toggle. |
| Window closed and can't find it | Window closed, app still running | Click the menu bar dot → **Show LTC Bridge**, or click LTC Bridge in the Dock. |

---

## 9. Diagnostics log
**Save Diagnostics** writes `LTC Bridge Log <date time>.csv` to your Desktop and shows it
in Finder. It covers the most recent ~4,000 LTC frames (a few minutes at most) plus your
current settings, the dropout count and the Art-Net target.

Columns:
- **seconds ago:** how long before the save the frame arrived.
- **ltc:** the decoded timecode.
- **drop frame:** whether the frame had the drop-frame flag.
- **action:** what LTC Bridge did with the frame:
  - `detecting rate`: still working out the frame rate
  - `waiting`: counting up to the 4 frames needed to lock
  - `lock`: started sending MTC
  - `ok`: frame matched the output
  - `ignored`: didn't match, not yet steady enough to follow
  - `jump`: followed a new position
  - `loop ignored`: repeat of recently heard timecode, ignored
  - `test running`: arrived while the test generator was on, so it was ignored
- **timing error (frames):** how far the frame was from where the output expected it.

Save the log right after a problem happens and send it along with a description of what
you saw.

---

## 10. Tips for show use
- Turn on **Open at login** so LTC Bridge starts with the Mac.
- **Send MTC to Vista over an IAC bus.** An IAC bus is part of macOS and is always there,
  so Vista stays connected to it whether LTC Bridge opens before or after Vista, and even
  if LTC Bridge restarts. One-time setup:
  1. Open **Audio MIDI Setup** (or **Send to → Set Up IAC or Network MIDI…**), choose
     **Window → Show MIDI Studio**, double-click **IAC Driver**, tick **Device is online**,
     and add a port. A dedicated port just for timecode (for example renamed *Timecode*)
     keeps it separate from other MIDI traffic.
  2. In LTC Bridge, tick that IAC port under **Send to**.
  3. In Vista, choose the same IAC port as the MIDI timecode input.
- Run only one LTC-to-MTC converter at a time.
- Keep LTC at a healthy level, roughly −20 to −6 dBFS on the meter.
- Before each show, do a quick check: play, stop, jump the playhead, and watch Vista follow.
  Glance at **Signal History** afterwards; it should say *No dropouts*.
- Switch to the **Timecode** view with **Keep on Top** so the timecode strip stays visible
  over Vista, or leave the window closed and watch the menu bar dot.

---

## 11. Limitations and known issues
- **Looping input while Ableton is stopped (under investigation):** on one Dante setup,
  LTC Bridge received the same ~0.34 s of timecode repeating while Ableton was stopped.
  Loop protection now ignores it. Whether the repeats come from LTC Bridge's own audio
  handling or from upstream is still being tested.
- LTC Bridge sets the chosen device's IO buffer to 256 samples for low latency. This
  affects other apps using the same device.
- MTC and Art-Net timecode only; no MIDI Machine Control, and no LTC output.
- User bits and the other LTC flags are ignored.
- Art-Net is IPv4 only and sends timecode only (no DMX).
- The app isn't signed by a registered Apple developer, so macOS asks for approval on first launch.
- macOS only for now. A Windows version would need its own audio, MIDI and window code,
  plus a loopback MIDI tool such as loopMIDI (the Windows equivalent of an IAC bus).

---

## 12. Building from source
Requires only Apple's Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This runs the self-test, then builds `build/LTC Bridge.app` for both Apple Silicon and Intel.
The self-test synthesizes LTC at every frame rate and sample rate, runs the engine in real
time through CoreMIDI, and checks the test generator and Art-Net output over a loopback
UDP socket.

Code layout:
- `Sources/Core/`: platform-independent logic (LTC decoder, lock/freewheel engine, MTC scheduler, timecode math)
- `Sources/App/`: macOS audio input, MIDI and Art-Net output, and window
- `Tests/main.swift`: self-test
- `Tools/DecodeFile/`: checks any LTC audio file with the app's decoder:
  `swiftc -O Sources/Core/*.swift Tools/DecodeFile/main.swift -o build/decode_file && ./build/decode_file file.wav`
- `Tools/RenderUI/`: renders the window in each status to PNGs, for design review
- `Tools/TransitionTest/`: opens the window, switches views and measures the animation
  (top edge fixed, frame timing)
