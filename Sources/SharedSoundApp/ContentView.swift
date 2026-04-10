import SwiftUI
import SharedSoundCore

struct ContentView: View {
    @EnvironmentObject var session: SessionViewModel

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                DeviceHero(name: session.localName, running: session.isRunning)
                    .padding(.top, 28)

                RolePicker(role: session.role, toggle: session.toggleRole)
                    .padding(.horizontal, 28)

                if session.role == .host {
                    HostPanel()
                } else {
                    ClientPanel()
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.06, blue: 0.14),
                Color(red: 0.11, green: 0.09, blue: 0.22),
                Color(red: 0.05, green: 0.05, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Hero

private struct DeviceHero: View {
    let name: String
    let running: Bool

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.45), .clear],
                            center: .center, startRadius: 4, endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 10)

                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 82, height: 82)
                    .overlay(
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                    )

                Image(systemName: "laptopcomputer")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
            }

            Text(name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            HStack(spacing: 6) {
                Circle()
                    .fill(running ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                    .scaleEffect(running && pulse ? 1.35 : 1.0)
                    .opacity(running && pulse ? 0.55 : 1.0)
                    .animation(
                        running
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                Text(running ? "On local network" : "Stopped")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .onAppear { pulse = true }
        }
    }
}

// MARK: - Role picker

private struct RolePicker: View {
    let role: Peer.Role
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "Host", active: role == .host)
            segment(title: "Client", active: role == .client)
        }
        .padding(4)
        .background(
            Capsule().fill(.white.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
    }

    private func segment(title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? .black : .white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(active ? Color.white : Color.clear)
            )
            .contentShape(Capsule())
            .onTapGesture {
                if !active { toggle() }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: active)
    }
}

// MARK: - Host panel

private struct HostPanel: View {
    @EnvironmentObject var session: SessionViewModel

    var body: some View {
        VStack(spacing: 20) {
            PlayButton(
                playing: session.hostIsPlaying,
                action: session.togglePlayback
            )
            .padding(.top, 4)

            Text(session.hostIsPlaying ? "Sharing system audio" : "Share System Audio")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            if let url = session.hostWebURL {
                BrowserGuestsCard(url: url)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ListenersCard(clients: session.hostConnectedClients)
                .padding(.horizontal, 20)
        }
        .animation(.easeOut(duration: 0.25), value: session.hostWebURL)
    }
}

private struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: playing
                                ? [Color.red, Color(red: 0.85, green: 0.15, blue: 0.35)]
                                : [Color.accentColor, Color.accentColor.opacity(0.75)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 92, height: 92)
                    .shadow(color: (playing ? Color.red : Color.accentColor).opacity(0.55),
                            radius: 18, y: 8)

                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: playing ? 0 : 3)  // optically center the triangle
            }
            .scaleEffect(pressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, perform: {}, onPressingChanged: { pressed = $0 })
    }
}

private struct BrowserGuestsCard: View {
    let url: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Browser guests", systemImage: "globe")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)

                HStack(alignment: .center, spacing: 14) {
                    QRTile(url: url)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan or open")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(url)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Any browser, any device on this Wi-Fi")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct QRTile: View {
    let url: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .frame(width: 92, height: 92)

            if let image = QRCode.image(for: url) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
            }
        }
    }
}

private struct ListenersCard: View {
    let clients: [String]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Listeners", systemImage: "headphones")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(clients.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }

                if clients.isEmpty {
                    Text("Waiting for someone to join…")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 8) {
                        ForEach(clients, id: \.self) { name in
                            HStack(spacing: 10) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(Color.accentColor)
                                Text(name)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.9))
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Client panel

private struct ClientPanel: View {
    @EnvironmentObject var session: SessionViewModel

    var body: some View {
        VStack(spacing: 16) {
            StatusPill(text: session.clientState)
                .padding(.top, 8)

            if session.peers.isEmpty {
                EmptyRadar()
                    .padding(.top, 20)
            } else {
                HostListCard(
                    peers: session.peers,
                    connectedID: session.connectedPeerID,
                    connect: session.connect,
                    disconnect: session.disconnect
                )
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct EmptyRadar: View {
    @State private var expand = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                        .frame(width: 40, height: 40)
                        .scaleEffect(expand ? 2.2 : 0.6)
                        .opacity(expand ? 0 : 0.8)
                        .animation(
                            .easeOut(duration: 2.4)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.8),
                            value: expand
                        )
                }
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 100, height: 100)
            .onAppear { expand = true }

            Text("Looking for hosts on your Wi-Fi")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct HostListCard: View {
    let peers: [Peer]
    let connectedID: UUID?
    let connect: (Peer) -> Void
    let disconnect: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Available hosts", systemImage: "hifispeaker.2")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)

                VStack(spacing: 8) {
                    ForEach(peers.filter { $0.role == .host }) { peer in
                        PeerRow(
                            peer: peer,
                            isConnected: connectedID == peer.id,
                            connect: { connect(peer) },
                            disconnect: disconnect
                        )
                    }
                }
            }
        }
    }
}

private struct PeerRow: View {
    let peer: Peer
    let isConnected: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 38, height: 38)
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(isConnected ? "Connected" : "Host")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(isConnected ? Color.green : .white.opacity(0.5))
            }

            Spacer()

            Button(action: isConnected ? disconnect : connect) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isConnected ? .white : .black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(
                        Capsule().fill(isConnected ? Color.white.opacity(0.15) : Color.white)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04))
        )
    }
}

// MARK: - Card container

private struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}
