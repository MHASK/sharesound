import SwiftUI
import SharedSoundCore

struct ContentView: View {
    @EnvironmentObject var session: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            peerList
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.localName)
                        .font(.headline)
                    Text(session.isRunning ? "Advertising on local network" : "Stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var peerList: some View {
        Group {
            if session.registry.peers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Looking for peers on your Wi-Fi…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(session.registry.peers) { peer in
                    HStack {
                        Image(systemName: peer.role == .host ? "hifispeaker.fill" : "iphone")
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(peer.role.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}
