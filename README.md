# izovr Steam Frame on a Linux host (openSUSE Tumbleweed)

Silly scripts that make wireless PCVR streaming to a Steam Frame work on (my) desktop.

## How every script works

```bash
./scripts/<name>             check the current state, change nothing
./scripts/<name> --apply     make the change
./scripts/<name> --restore   undo it
./scripts/<name> --help      what it is and why it exists
```

```bash
./izovr            state of everything, grouped
./izovr session    what to switch before and after playing
./izovr --brief    same, without the probe lines
```

Every check prints the command or path it read (`reads: ...`) above its verdict
and then shows the current value next to the wanted one:

```
[ ok ] domain               now: PL              want: any country, not 00
[ -- ] force-quantum        now: 0 (unset)       want: 2048
```

So nothing has to be taken on trust. Verdicts come from effective state wherever
one can be observed — `ulimit -r`, `iw reg get`, `pkcheck`, the live interface
state — not from the presence of a file this repo happens to create.

Exactly one reading needs privileges: the firewall port list. firewalld answers it
only over D-Bus behind polkit and keeps `/etc/firewalld` root-only, so there is no
unprivileged path to it. That check asks for your password, because a prompt from a
command you just typed is more useful than a verdict of "unreadable". It stays quiet
when no terminal is attached, and `sudo -v` once up front silences it for the rest of
the sudo timeout.

## Known-good configuration (27.09.2026, 1.5 h of Half-Life: Alyx, no crashes)

```
Alyx compat tool     none, the native Linux build
Alyx launch options  PIPEWIRE_LATENCY=1024/48000 PIPEWIRE_RATE=1/48000 %command%
driver_vrlink        {"10bit": false}
steam.app.546560     {"resolutionScale": 154}
PipeWire             clock.force-quantum 2048, clock.force-rate 44100
                     (runtime only, re-apply each session)
WireGuard tunnel     stopped
SteamVR              started by hand, before the game
```

Start SteamVR first, wait for the headset to connect, then launch the game.
Reproduce the session settings with `./izovr session`.

Two crashes that nothing in this repo causes or can fix:

- Alyx asserts in `GetBitRange()` (`networksystem/serializedentity.h`) when loading
  certain saves. Others report the same as a save-load crash specific to the Vulkan
  renderer, on Windows as well:
  [#482](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/482). The
  window-minimise workaround from that issue does NOT work here: with the window
  minimised the game never reaches the headset (KDE on Wayland, NVIDIA).
- `vrcompositor` SIGSEGV during Alyx level loads on driver 595.99.02, a regression in
  SteamVR 2.17.9 that is absent in 2.16.7:
  [#944](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/944) reports it on
  the same driver and Vulkan version. Downgrading is not obviously safe, since Frame
  support arrived in 2.17.8.

## Upstream, as of 28.09.2026

| issue | state |
|---|---|
| **SteamVR 2.18.1 beta**, 24.09 | Linux fixes: GPU selection on hosts that have both a discrete and an integrated GPU, async reprojection on AMD, systems without systemd. Steam Link: video corruption and checkerboarding. The GPU one matters here — this host is an RTX 5080 beside a Raphael iGPU, the case [#967](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/967) describes. |
| [#962](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/962) SteamVR never auto-starts | **closed as completed**, 27.09, by a Valve developer. |
| [#965](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/965) encoder reset storms | open. Reproduced on NVIDIA and AMD, discrete and integrated. One reporter measures 5.2-10.2 resets/min on 2.18.1 against 36.9-44.9 on 2.17.10 — but their 2.17.10 baseline is 6-7x worse than what this host already reaches with `rt-priority`, so that gain probably does not transfer. |
| [#944](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/944) Alyx level-load SIGSEGV | open, no Valve response, no workaround. |
| [#959](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/959) "2.18.1 forces linux32" | closed — and its premise is wrong, see below. |

### #959 does not mean what its title says

Its title — *"v2.18.1 forces linux32 drivers (breaking VR Link), even after
downgrade"* — was read here as a reason to stay off the beta. It does not hold:

- `arch=linux32` is written by the 32-bit Steam client and appears on **stable** as
  well. On this host, on 2.17.10, `vrclient_steam.txt` logs `arch=linux32` while every
  other component — games, `vrcompositor`, `vrstartup`, the webhelpers — logs
  `arch=linux64`. `drivers/vrlink/bin/` ships `linux64` only, on both branches.
- The reporter's actual breakage was SizeOSC, a third-party driver that needed to hook
  the interface versions new in 2.18.1. They established that themselves and accepted
  the closure.

What that title mistook for a beta regression is the real and separate bug in #962:
the 32-bit client cannot load a `linux64`-only driver.

One thing from that thread still deserves respect: a downgrade did not undo the beta's
persistent configuration state, and only a full Steam wipe did. Back up
`config/steamvr.vrsettings`, `config/config.vdf` and
`steamapps/appmanifest_250820.acf` before switching branches.

## Permanent — set once, never think about it again

| script | what it does |
|---|---|
| `rt-priority` | Grants the user an RT scheduling ceiling so the encoder threads are not preempted. Without it `vrlink` logs `Failed to set thread priority` and the compositor times out waiting for frames. Needs a re-login. |
| `regdomain` | Sets the wireless regulatory domain. In domain `00` the kernel forbids 6 GHz entirely and the dedicated link cannot associate at all. |
| `firewall-ports` | Opens `27031-27036/udp`, `27036-27037/tcp` and `10400-10401/udp`. The last range is the actual vrlink transport and is not in Valve's documented port list. |
| `gpu-isolation` | Checks that SteamVR's Vulkan loader is pinned to NVIDIA and prints the launch option to paste. Steam owns this setting, so the script never writes it. |
| `dongle-powersave` | Keeps the dongle radio awake on both layers: an NM dispatcher for the host side, a module parameter for the card firmware. The NM connection profile cannot be used — Steam rewrites it. An upstream measurement of a ~18% reset reduction from this was later **retracted by its own author** ([#965](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/965)): session-to-session variance exceeded the effect. The reasoning stands, the measured benefit does not. |
| `polkit-network` | One narrow polkit rule that stops the root password prompt Steam triggers roughly once a minute. |

## Permanent, with one catch

| script | catch |
|---|---|
| `vrlink-encoder` | Drops the stream to 8-bit. **Tested and rejected:** it changes the format but leaves the reset rate unchanged, does not silence the P010 log noise, and makes the image visibly brighter with washed-out blacks. Kept only as a documented dead end. |
| `vrlink-single-link` | Fallback only. Multi-link is better turned off **in the headset**: while connected to the PC, SteamVR -> VR settings -> Steam Link -> turn off multilink. That panel is only reachable during an active stream. This script sets an undocumented driver key instead, and exists for the case where the toggle is missing. |
| `idle-wifi-card` | Marks the unused built-in Wi-Fi card unmanaged so it stops scanning the same 6 GHz band. Undo it the day you need Wi-Fi on this machine. Bluetooth is unaffected. |

## Per session — on before, off after

| script | why |
|---|---|
| `vpn-tunnel` | `vrlink` binds every interface at startup, the WireGuard tunnel included, and a hiccup there kills the whole session. Restart SteamVR after switching. |
| `dongle-lowlatency` | The part of Valve's low-latency mode that works without kernel debugfs: A-MSDU off, MCS capped, host power save off. |
| `pipewire-resample` | Clears the crackle heard only in the headset, caused by a forced 44.1 -> 48 kHz resample. Two PipeWire levers, both needed. Per-game launch options do NOT replace it: `PIPEWIRE_RATE` changes the node's scheduling rate, not the format the game produces, so the resample stays. Check the FORMAT column of `pw-top`, not RATE. |

## Diagnostics — read-only

| script | what it shows |
|---|---|
| `vr-verify` | Install, OpenXR runtime, drivers, link state, recent error counts. |
| `measure [seconds]` | Samples GPU, encoder, load and radio during a live session, then counts stream resets, audio dropouts and compositor timeouts. |
| `dump-stats` | Writes the raw state of kernel, radio, network, GPU, audio and SteamVR to `stats/` with no interpretation, for pasting into bug reports. `stats/` is gitignored. |

## Two things the scripts cannot fix

- **Steam may no longer need to be helped along.** Steam did not auto-start SteamVR
  for a VR stream on Linux, and Proton titles cannot start it themselves, so SteamVR
  had to be launched by hand.
  [#962](https://github.com/ValveSoftware/SteamVR-for-Linux/issues/962) was closed as
  completed on 27.09.2026 — retest by launching a VR title from the headset with
  SteamVR down. Until that is confirmed here, keep starting it by hand.
- **Four of Valve's seven low-latency toggles need kernel debugfs** (`CONFIG_MAC80211_DEBUGFS` and `CONFIG_RTW89_DEBUGFS`) that openSUSE
  does not build, including the EDCA timing Valve applies on Windows.