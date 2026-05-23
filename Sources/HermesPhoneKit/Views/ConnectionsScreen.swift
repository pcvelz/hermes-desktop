#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct ConnectionsScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var draft = ConnectionDraft()
    @State private var isPresentingEditor = false
    @State private var editingConnectionID: UUID?
    @State private var chatTestResult: String?
    @State private var isTestingChat = false
    @State private var showsGatewayDiagnostics = false

    var body: some View {
        List {
            Section {
                activeWorkspaceSummary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            nativeChatSection

            Section("Saved Connections") {
                if store.connections.isEmpty {
                    ContentUnavailableView("No Connections", systemImage: "server.rack", description: Text("Add an SSH connection to start using Hermes on iPhone."))
                } else {
                    ForEach(store.connections) { connection in
                        connectionRow(connection)
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.removeConnection(connection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button {
                editingConnectionID = nil
                draft = ConnectionDraft()
                isPresentingEditor = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                ConnectionEditorView(draft: $draft, editingConnectionID: editingConnectionID)
                    .environmentObject(store)
            }
        }
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.refreshOverview()
            await store.nativeChatStore.refreshBootstrapStatus()
        }
    }

    private var activeWorkspaceSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active Workspace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let connection = store.activeConnection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.label)
                                .font(.title3.weight(.semibold))
                            Text(connection.displayDestination)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(connection.resolvedHermesProfileName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.16), in: Capsule())
                    }

                    if let overview = store.overview {
                        VStack(alignment: .leading, spacing: 8) {
                            workspaceMetric(label: "Remote Home", value: overview.remoteHome)
                            workspaceMetric(label: "Hermes Home", value: overview.hermesHome)
                            workspaceMetric(label: "Session Store", value: overview.sessionStore?.path ?? "Not found")
                            workspaceMetric(label: "Profiles", value: overview.availableProfiles.map(\.name).joined(separator: " · "))
                        }
                    } else {
                        Text("Pull remote workspace details from here, then spend the rest of your time in Terminal, Sessions, and Files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ContentUnavailableView("No Active Connection", systemImage: "server.rack", description: Text("Pick a saved connection to make Terminal, Sessions, and Files immediately usable."))
            }
        }
    }

    private func connectionRow(_ connection: ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.label)
                        .font(.headline)
                    Text(connection.displayDestination)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(connection.resolvedHermesProfileName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if store.activeConnectionID == connection.id {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 10) {
                Button("Use") {
                    store.activateConnection(connection)
                }
                .buttonStyle(.borderedProminent)

                Button("Edit") {
                    editingConnectionID = connection.id
                    draft = ConnectionDraft(connection: connection, credential: (try? store.credential(for: connection)) ?? SSHCredentialRecord())
                    isPresentingEditor = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func workspaceMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }

    private var nativeChatSection: some View {
        Section("Native Chat") {
            if let bootstrap = store.nativeChatStore.bootstrapStatus {
                DetailRow(label: "SSH", value: bootstrap.sshConnected ? "Connected" : "Unavailable")
                DetailRow(label: "Python", value: bootstrap.pythonAvailable ? "Available" : "Unavailable")
                DetailRow(label: "Hermes CLI", value: bootstrap.hermesCLIAvailable ? "Available" : "Unavailable")
                DetailRow(label: "TUI Gateway", value: bootstrap.tuiGatewayAvailable ? "Available" : "Unavailable")
                if let version = bootstrap.hermesVersion {
                    DetailRow(label: "Hermes Version", value: version)
                }
                if let fallbackReason = bootstrap.fallbackReason {
                    DetailRow(label: "Fallback", value: fallbackReason)
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking native chat support...")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    isTestingChat = true
                    chatTestResult = await store.nativeChatStore.runChatTest()
                    isTestingChat = false
                }
            } label: {
                HStack {
                    if isTestingChat {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isTestingChat ? "Testing Chat..." : "Test Chat")
                }
            }
            .disabled(isTestingChat || !store.nativeChatStore.canUseNativeChat)

            if let chatTestResult {
                Text(chatTestResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Diagnostics", isExpanded: $showsGatewayDiagnostics) {
                if store.nativeChatStore.rawEvents.isEmpty {
                    Text("No gateway events captured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.nativeChatStore.rawEvents.suffix(12).reversed())) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.type)
                                .font(.caption.weight(.semibold))
                            Text(event.rawLine ?? JSONValue.object(event.payload).displayString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
    }
}

#endif
