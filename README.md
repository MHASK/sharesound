# SharedSound

Synchronized multi-device audio across Apple devices on the same Wi-Fi network. Turn your Macs, iPhones, and iPads into a coordinated speaker system — any device can host, any device can join, every device has its own volume control.

> Status: **early development**. Milestone 1 (peer discovery) in progress.

## Goals

- **Apple-native.** Swift, SwiftUI, Network.framework, AVAudioEngine. No Electron, no virtual audio drivers on the happy path.
- **Tight sync.** Sub-10ms skew between devices so stereo imaging survives across rooms.
- **Any-to-any.** Phone can host for Macs. Mac can host for iPads. Roles are fluid.
- **Open source.** Apache-2.0.

## Mental model

SharedSound moves audio **between devices**, not directly to speakers. Each device drives its own local output however it likes — built-in speakers, AirPods, Sony XM5s, a wired DAC, whatever is already paired.

So if you want your Sony headphones and your partner's AirPods playing the same thing:

- Your headphones pair to **your Mac** → your Mac hosts.
- Their AirPods pair to **their iPhone** → their iPhone joins as a client.
- SharedSound ships audio over Wi-Fi between the two devices; each device handles its own Bluetooth link.

One device per listener. Per-device volume is independent. No fighting over one Mac's Bluetooth bandwidth.

## Platforms

- macOS 14+ (Sonoma). macOS 14.2+ required for system-audio capture via CoreAudio process taps.
- iOS / iPadOS 17+.

## Architecture (planned)

| Layer | Tech |
|---|---|
| Discovery | Bonjour via `NWListener` / `NWBrowser` |
| Control | TCP (`NWConnection`) |
| Audio transport | UDP (`NWConnection` unicast per client) |
| Codec | Opus (10ms frames, ~64kbps stereo) |
| Clock sync | PTP-lite over control channel, `mach_absolute_time` |
| Playback | `AVAudioEngine` scheduled buffers |
| System audio capture (Mac) | `CATapDescription` process tap |
| UI | SwiftUI multiplatform |

## Running it (Mac, development)

```bash
swift run SharedSoundApp
```

Run it on two Macs on the same Wi-Fi. On one:

1. Tap **Become Host**.
2. Tap **Play 440Hz Sine Wave**.

On the other:

1. Leave it in Client mode.
2. Tap **Connect** next to the discovered host.

You should hear a 440Hz tone from the client Mac's output (AirPods, XM5s, whatever is selected). First Bonjour + incoming connection on macOS will prompt for Local Network permission — allow it.

## Roadmap

- **M1** — Scaffold, Bonjour discovery, peer list UI *(current)*
- **M2** — Raw PCM transport, end-to-end Mac→iOS playback
- **M3** — Opus codec integration
- **M4** — Clock sync + scheduled playback (the hard part)
- **M5** — Multi-client fan-out, per-device volume, control messages
- **M6** — Mac system audio capture via CoreAudio tap
- **M7** — Role switching, polish, CI

## License

Apache-2.0. See [LICENSE](LICENSE).
