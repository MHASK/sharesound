# SharedSound

Synchronized multi-device audio across Apple devices on the same Wi-Fi network. Turn your Macs, iPhones, and iPads into a coordinated speaker system — any device can host, any device can join, every device has its own volume control.

> Status: **early development**. Milestone 1 (peer discovery) in progress.

## Goals

- **Apple-native.** Swift, SwiftUI, Network.framework, AVAudioEngine. No Electron, no virtual audio drivers on the happy path.
- **Tight sync.** Sub-10ms skew between devices so stereo imaging survives across rooms.
- **Any-to-any.** Phone can host for Macs. Mac can host for iPads. Roles are fluid.
- **Open source.** Apache-2.0.

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
