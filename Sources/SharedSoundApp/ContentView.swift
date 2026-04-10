import SwiftUI
import SharedSoundCore

struct ContentView: View {
    @EnvironmentObject var session: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.role == .host {
                hostView
            } else {
                clientView
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.localName).font(.headline)
                    Text(session.isRunning ? "Advertising on local network" : "Stopped")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                roleBadge
            }
            Button(action: session.toggleRole) {
                Label(
                    session.role == .host ? "Switch to Client" : "Become Host",
                    systemImage: session.role == .host ? "person.2.fill" : "dot.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var roleBadge: some View {
        Text(session.role.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(session.role == .host ? Color.accentColor : Color.gray.opacity(0.3))
            .foregroundStyle(session.role == .host ? Color.white : Color.primary)
            .clipShape(Capsule())
    }

    // MARK: - Host view

    private var hostView: some View {
        VStack(spacing: 16) {
            Button {
                session.togglePlayback()
            } label: {
                Label(
                    session.hostIsPlaying ? "Stop Sharing System Audio" : "Share System Audio",
                    systemImage: session.hostIsPlaying ? "stop.fill" : "hifispeaker.and.homepod.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.hostIsPlaying ? .red : .accentColor)

            if let url = session.hostWebURL {
                GroupBox("Browser guests") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Any device on this Wi-Fi can open:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Connected clients (\(session.hostConnectedClients.count))") {
                if session.hostConnectedClients.isEmpty {
                    Text("Waiting for clients to join…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(session.hostConnectedClients, id: \.self) { name in
                            Label(name, systemImage: "iphone")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Client view

    private var clientView: some View {
        VStack(spacing: 0) {
            Text(session.clientState)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)

            if session.peers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Looking for hosts on your Wi-Fi…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(session.peers) { peer in
                    HStack {
                        Image(systemName: peer.role == .host ? "hifispeaker.fill" : "iphone")
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(peer.role.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.connectedPeerID == peer.id {
                            Button("Disconnect", action: session.disconnect)
                                .buttonStyle(.bordered)
                        } else if peer.role == .host {
                            Button("Connect") { session.connect(to: peer) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }
}
