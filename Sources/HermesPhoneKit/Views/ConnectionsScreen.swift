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
    @State private var showsConnectionGuide = true
    @State private var showsAPIDiagnostics = false

    var body: some View {
        List {
            Section {
                activeWorkspaceSummary
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            connectionGuideSection

            nativeChatSection

            Section("Hosts") {
                if store.connections.isEmpty {
                    ContentUnavailableView("No Hosts", systemImage: "server.rack", description: Text("Add your Hermes host, then add one or more profiles inside it."))
                } else {
                    ForEach(savedConnectionGroups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(group.connections.count) Hermes \(group.connections.count == 1 ? "profile" : "profiles")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.activeHostFingerprint == group.id {
                                    Text("Active Host")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                } else {
                                    Button("Use Host") {
                                        store.activateHost(group.id)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button {
                                    addProfile(to: group)
                                } label: {
                                    Label("Add Profile", systemImage: "plus")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                            }

                            ForEach(group.connections) { connection in
                                connectionRow(connection)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            store.removeConnection(connection)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                if connection.id != group.connections.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 4)
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
                Label("Add Host", systemImage: "plus")
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
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(connection.resolvedHermesProfileName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.16), in: Capsule())
                            Text(connection.displayProfileScope)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let overview = store.overview {
                        VStack(alignment: .leading, spacing: 8) {
                            workspaceMetric(label: "Remote Home", value: overview.remoteHome)
                            workspaceMetric(label: "Hermes Home", value: overview.hermesHome)
                            workspaceMetric(label: "Chat", value: connection.displayAPIServerEndpoint)
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
                    Text(connection.resolvedHermesProfileName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(chatAPIPortSummary(for: connection))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(".env: \(connection.remoteHermesHomePath)/.env")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Select") {
                    store.activateConnection(connection)
                }
                .buttonStyle(.bordered)

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

    private var connectionGuideSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsConnectionGuide) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Prima ti colleghi via SSH. Terminale e Files funzionano già. Questi passi servono solo se vuoi usare la chat direttamente dall'app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let connection = store.activeConnection {
                        ConnectionsGuideStep(title: "1. Apri il .env del profilo", detail: "\(connection.remoteHermesHomePath)/.env. Puoi modificarlo da Files o dal Terminale dell'app.")
                        connectionsCodeBlock(envSnippet(for: connection))
                        ConnectionsGuideStep(title: "2. Usa gli stessi valori nell'app", detail: "Per \(connection.resolvedHermesProfileName), salva Chat Port \(connection.resolvedAPIServerPort). Se API_SERVER_KEY è vuota, lascia vuota anche la Chat Key.")
                        ConnectionsGuideStep(title: "3. Riavvia Hermes per quel profilo", detail: restartGuidance(for: connection))
                    } else {
                        ConnectionsGuideStep(title: "1. Aggiungi un host", detail: "Inserisci host, porta SSH e utente. È abbastanza per usare Terminale e Files.")
                        ConnectionsGuideStep(title: "2. Aggiungi un profilo Hermes", detail: "Default usa ~/.hermes/.env. Un profilo chiamato work usa ~/.hermes/profiles/work/.env.")
                        connectionsCodeBlock(genericEnvSnippet)
                        ConnectionsGuideStep(title: "3. Usa gli stessi valori nell'app", detail: "Per ogni profilo con cui vuoi chattare, porta e key devono combaciare tra .env e app.")
                    }

                    Text("Sicuro: lascia API_SERVER_HOST su 127.0.0.1. La chat passa tramite SSH e non rende pubblico nulla.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Più profili attivi insieme? Dai a ciascuno una porta diversa, ad esempio 8642, 8643, 8644.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Label("Chat setup in 3 steps", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var nativeChatSection: some View {
        Section("Chat status") {
            if let bootstrap = store.nativeChatStore.bootstrapStatus {
                DetailRow(label: "SSH", value: bootstrap.sshConnected ? "Connected" : "Unavailable")
                DetailRow(label: "Chat", value: bootstrap.apiServerAvailable ? "Ready" : "Needs setup")
                DetailRow(label: "Chat Key", value: bootstrap.apiAuthenticated ? "OK" : "Check if you set one")
                DetailRow(label: "Chat Port", value: String(bootstrap.apiServerPort))
                if let fallbackReason = bootstrap.fallbackReason {
                    DetailRow(label: "What to check", value: fallbackReason)
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking chat API...")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await store.nativeChatStore.refreshBootstrapStatus(force: true)
                }
            } label: {
                Label("Refresh chat status", systemImage: "arrow.clockwise")
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
                    Text(isTestingChat ? "Testing chat..." : "Test chat")
                }
            }
            .disabled(isTestingChat || !store.nativeChatStore.canUseNativeChat)

            if let chatTestResult {
                Text(chatTestResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Diagnostics", isExpanded: $showsAPIDiagnostics) {
                if store.nativeChatStore.rawEvents.isEmpty {
                    Text("No API events captured yet.")
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

    private func chatAPIPortSummary(for connection: ConnectionProfile) -> String {
        if connection.hasExplicitAPIServerPort {
            return "Chat Port \(connection.resolvedAPIServerPort)"
        }
        return "Chat Port \(connection.resolvedAPIServerPort) (default)"
    }

    private func envSnippet(for connection: ConnectionProfile) -> String {
        """
        API_SERVER_ENABLED=true
        API_SERVER_PORT=\(connection.resolvedAPIServerPort)
        API_SERVER_HOST=127.0.0.1
        API_SERVER_KEY=
        """
    }

    private var genericEnvSnippet: String {
        """
        API_SERVER_ENABLED=true
        API_SERVER_PORT=8642
        API_SERVER_HOST=127.0.0.1
        API_SERVER_KEY=
        """
    }

    private func restartGuidance(for connection: ConnectionProfile) -> String {
        if let customHermesHomePath = connection.trimmedCustomHermesHomePath {
            return "Dopo aver salvato .env, riavvia Hermes usando la home \(customHermesHomePath)."
        }
        if let profileName = connection.trimmedHermesProfile {
            return "Dopo aver salvato .env, riavvia Hermes usando il profilo \(profileName)."
        }
        return "Dopo aver salvato .env, riavvia Hermes usando il profilo default."
    }

    private func connectionsCodeBlock(_ value: String) -> some View {
        Text(value)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var savedConnectionGroups: [ConnectionHostGroup] {
        let grouped = Dictionary(grouping: store.connections, by: \.hostConnectionFingerprint)
        return grouped.values.map { connections in
            let sortedConnections = connections.sorted {
                if $0.resolvedHermesProfileName == $1.resolvedHermesProfileName {
                    return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                }
                return $0.resolvedHermesProfileName.localizedCaseInsensitiveCompare($1.resolvedHermesProfileName) == .orderedAscending
            }
            let first = sortedConnections[0]
            return ConnectionHostGroup(
                id: first.hostConnectionFingerprint,
                title: first.displayDestination,
                connections: sortedConnections
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func addProfile(to group: ConnectionHostGroup) {
        guard let base = group.connections.first else { return }
        let credential = (try? store.credential(for: base)) ?? SSHCredentialRecord()
        editingConnectionID = nil
        draft = ConnectionDraft(profileTemplateFrom: base, credential: credential, apiServerPort: nextAPIPort(in: group))
        isPresentingEditor = true
    }

    private func nextAPIPort(in group: ConnectionHostGroup) -> Int {
        let usedPorts = Set(group.connections.compactMap { $0.hasExplicitAPIServerPort ? $0.resolvedAPIServerPort : nil })
        var candidate = 8642
        while usedPorts.contains(candidate) {
            candidate += 1
        }
        return candidate
    }
}

private struct ConnectionsGuideStep: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionHostGroup: Identifiable {
    let id: String
    let title: String
    let connections: [ConnectionProfile]
}

#endif
