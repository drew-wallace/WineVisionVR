// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
// See third-party/steam-native/COPYING and LICENSE-EXCEPTION.md.

import SwiftUI

struct SteamLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SteamLibraryModel
    @State private var showingSignIn = false
    @State private var selectedGame: SteamLibraryEntry?
    @State private var search = ""
    @State private var filter = LibraryFilter.all
    @State private var selectingDownloads = false
    @State private var selectedDownloadIDs: [Int] = []

    private enum LibraryFilter: String, CaseIterable {
        case all = "All games", installed = "Installed", downloads = "Downloads"
    }

    init(model: SteamLibraryModel = .shared) { self.model = model }

    private var visibleGames: [SteamLibraryEntry] {
        let entries = filter == .installed ? model.installedGames : model.games
        return entries.filter { entry in
            let matchesSearch = search.isEmpty || entry.game.name.localizedCaseInsensitiveContains(search)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .installed: matchesFilter = model.installedIDs.contains(entry.id)
            case .downloads:
                matchesFilter = model.activeDownloads.contains(entry.id) || model.queuedDownloads.contains(entry.id) || model.pausedDownloads.contains(entry.id)
                    || model.downloadErrors[entry.id] != nil
            }
            return matchesSearch && matchesFilter
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Picker("Library", selection: $filter) {
                        ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if model.isLoadingLibrary && filter != .installed { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 24)
                if !model.signedIn && filter != .installed {
                    ContentUnavailableView {
                        Label("Your Steam library", systemImage: "gamecontroller.fill")
                    } description: {
                        Text("Sign in to browse your games and download them directly to Vision Pro.")
                    } actions: {
                        Button("Sign in to Steam") { showingSignIn = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    if filter == .downloads && (!model.activeDownloads.isEmpty || !model.queuedDownloads.isEmpty) {
                        Text("Keep Vision Pro powered and on Wi-Fi. If the system pauses downloads while you are away, they resume when you return.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                            ForEach(visibleGames) { entry in
                                Button {
                                    if selectingDownloads {
                                        guard !model.installedIDs.contains(entry.id),
                                              !model.activeDownloads.contains(entry.id),
                                              !model.queuedDownloads.contains(entry.id) else { return }
                                        if selectedDownloadIDs.contains(entry.id) { selectedDownloadIDs.removeAll { $0 == entry.id } }
                                        else { selectedDownloadIDs.append(entry.id) }
                                    } else { selectedGame = entry }
                                } label: {
                                    gameCard(entry).overlay(alignment: .topTrailing) {
                                        if selectingDownloads {
                                            Image(systemName: selectedDownloadIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(.white).padding(10)
                                                .opacity(model.installedIDs.contains(entry.id) || model.activeDownloads.contains(entry.id) || model.queuedDownloads.contains(entry.id) ? 0.3 : 1)
                                        }
                                    }
                                }
                                    .buttonStyle(.plain).hoverEffect(.highlight)
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                        if visibleGames.isEmpty {
                            ContentUnavailableView(filter == .installed ? "No installed games" : (model.isLoadingLibrary ? "Loading library…" : "No games to show"),
                                systemImage: "square.grid.2x2", description: Text(filter == .installed
                                    ? "Installed games appear here directly from this headset." : "Try another filter or refresh your library."))
                        }
                    }.refreshable {
                        if filter == .installed { model.refreshInstalled() }
                        else { await model.refreshLibrary() }
                    }
                }
            }
            .background(LinearGradient(colors: [.blue.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            .navigationTitle("Steam Library")
            .searchable(text: $search, prompt: "Search your games")
            .toolbar {
                // Never tie navigation to a network request, error or runtime state.
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if selectingDownloads {
                        Button("Queue \(selectedDownloadIDs.count)", systemImage: "arrow.down.circle") {
                            for id in selectedDownloadIDs {
                                if let entry = model.games.first(where: { $0.id == id }) { model.download(entry) }
                            }
                            selectedDownloadIDs = []
                            selectingDownloads = false
                            filter = .downloads
                        }.disabled(selectedDownloadIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(selectingDownloads ? "Cancel selection" : "Select games to download", systemImage: "checkmark.circle") {
                            selectedDownloadIDs = []
                            selectingDownloads.toggle()
                        }.disabled(!model.signedIn)
                        Button("Refresh library", systemImage: "arrow.clockwise") { Task { await model.refreshLibrary() } }
                        Button(model.isPreparingValveClient ? "Preparing Valve client…" : "Prepare Valve client", systemImage: "arrow.down.circle") {
                            Task { await model.prepareValveClient() }
                        }.disabled(model.isPreparingValveClient || model.runtimeBusy)
                        if !model.signedIn {
                            Button("Sign in to Steam", systemImage: "person.crop.circle") { showingSignIn = true }
                        }
                        if model.signedIn {
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                Task { await model.signOut() }
                            }.disabled(model.servicesBusy || model.runtimeBusy)
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .safeAreaInset(edge: .bottom) { statusBanner }
            .sheet(isPresented: $showingSignIn) { SteamSignInView().frame(width: 600, height: 620) }
            .sheet(item: $selectedGame) { entry in
                SteamGameDownloadView(entry: entry, model: model) { selectedGame = nil; dismiss() }
            }
            .task { await model.refreshLibrary() }
        }
        .frame(width: 660, height: 640)
    }

    private func gameCard(_ entry: SteamLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SteamGameArtwork(game: entry.game).frame(height: 132).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.game.name).font(.headline).lineLimit(2).frame(height: 44, alignment: .topLeading)
                Label(status(entry.id), systemImage: statusIcon(entry.id)).font(.caption).foregroundStyle(.secondary)
                Text(entry.game.downloadBytes.map { "About \(ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)) download" } ?? "Download size unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                if let progress = model.progress[entry.id] { ProgressView(value: progress.fraction).tint(.cyan) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
    }

    private func status(_ id: Int) -> String {
        if model.activeDownloads.contains(id) { return "Downloading" }
        if let index = model.queuedDownloads.firstIndex(of: id) { return "Queued · \(index + 1)" }
        if model.downloadErrors[id] != nil { return "Download interrupted" }
        if model.pausedDownloads.contains(id) { return "Paused" }
        return model.installedIDs.contains(id) ? "Installed" : "Ready to download"
    }

    private func statusIcon(_ id: Int) -> String {
        if model.queuedDownloads.contains(id) { return "text.line.first.and.arrowtriangle.forward" }
        if model.downloadErrors[id] != nil { return "exclamationmark.circle" }
        return model.installedIDs.contains(id) ? "checkmark.circle" : "arrow.down.circle"
    }

    @ViewBuilder private var statusBanner: some View {
        if let status = model.valveClientPreparationStatus {
            HStack(spacing: 12) { ProgressView(); Text(status).font(.footnote) }.padding()
                .frame(maxWidth: .infinity).background(.regularMaterial)
        } else if let error = model.error {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.footnote).lineLimit(3)
                Spacer()
                Button("Retry connection", systemImage: "arrow.clockwise") {
                    Task { await model.refreshLibrary() }
                }.disabled(model.isLoadingLibrary || model.runtimeBusy || model.servicesBusy)
                Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly)
            }.padding().background(.regularMaterial)
        } else if let id = model.serviceWarnings.keys.sorted().first, let warning = model.serviceWarnings[id] {
            let name = model.games.first(where: { $0.id == id })?.game.name ?? "App \(id)"
            Label("Library loaded. Saves for \(name) need attention: \(warning)", systemImage: "icloud.slash")
                .font(.footnote).lineLimit(3).padding().frame(maxWidth: .infinity).background(.regularMaterial)
        } else if !model.queuedDownloads.isEmpty {
            Label("\(model.queuedDownloads.count) queued · One game downloads at a time\(model.runtimeBusy ? "; waiting for the game to close" : "")", systemImage: "list.bullet")
                .font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
}

private struct SteamGameDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSaveReset = false
    let entry: SteamLibraryEntry
    @ObservedObject var model: SteamLibraryModel
    let closeLibrary: () -> Void

    private var isActive: Bool { model.activeDownloads.contains(entry.id) }
    private var queuePosition: Int? { model.queuedDownloads.firstIndex(of: entry.id).map { $0 + 1 } }
    private var failure: String? { model.downloadErrors[entry.id] }
    private var isPartial: Bool {
        DepotDownloader.hasPartialDownload(appID: UInt32(entry.id), steamApps: SteamInstallPaths.steamApps(drive: MadeiraDock.drive))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SteamGameArtwork(game: entry.game).frame(height: 210).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    Text(entry.game.name).font(.title2.bold())
                    VStack(alignment: .leading, spacing: 6) {
                        Label(entry.game.downloadBytes.map { "Full download: about \(bytes($0))" } ?? "Download size unavailable", systemImage: "arrow.down.circle")
                        Label(entry.game.installedBytes.map { "Installed size: about \(bytes($0))" } ?? "Installed size unavailable", systemImage: "internaldrive")
                        Text("Estimates from Steam. Resuming or repairing may download less; installation can need extra temporary space.")
                            .font(.caption)
                    }.font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.serviceStatus[entry.id] ?? "Steam Cloud checks saves before launch and after exit", systemImage: "icloud")
                        Toggle("Upload saves", isOn: Binding(
                            get: { model.cloudPermissions(entry.id).upload },
                            set: { model.setCloudPermissions(entry.id, upload: $0) })).disabled(model.runtimeBusy || model.servicesBusy)
                        Toggle("Download saves", isOn: Binding(
                            get: { model.cloudPermissions(entry.id).download },
                            set: { model.setCloudPermissions(entry.id, download: $0) })).disabled(model.runtimeBusy || model.servicesBusy)
                        Text("These settings apply to this game, including automatic sync. Turn uploads off while checking a cloud download.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Online play uses Valve's signed-in Steam client and the game's own servers. Availability depends on the game and its services.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.installedIDs.contains(entry.id) {
                            HStack {
                                Button("Sync saves") { Task { await model.syncSaves(entry.id) } }
                                Button("Use cloud saves") { Task { await model.syncSaves(entry.id, preferCloud: true) } }
                                    .disabled(!model.cloudPermissions(entry.id).download)
                                Button("Reset saves", role: .destructive) { confirmSaveReset = true }
                            }.disabled(model.runtimeBusy || model.servicesBusy || model.isPreparingValveClient)
                            Text("Use cloud saves replaces conflicting local saves with the cloud copy. Replaced files are backed up.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.dlc[entry.id] ?? []) { item in
                            Label("\(item.name) · Owned · \(item.ready ? (item.hasDepots ? "Installed" : "Included with game") : "Update / repair required")",
                                  systemImage: item.ready ? "checkmark.seal" : "arrow.down.circle")
                        }
                    }.font(.callout)
                    if let progress = model.progress[entry.id] {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.fraction).tint(.cyan)
                            HStack {
                                Text("\(Int(progress.fraction * 100))%")
                                Spacer()
                                Text("\(bytes(progress.doneBytes)) / \(bytes(progress.totalBytes))")
                            }.font(.caption).foregroundStyle(.secondary)
                            if isActive, progress.bytesPerSecond.isFinite, progress.bytesPerSecond > 0 {
                                Text("\(bytes(UInt64(min(progress.bytesPerSecond, Double(Int64.max)))))/s").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let failure {
                        Label("Download interrupted", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(failure).font(.callout).textSelection(.enabled)
                        Text("Verified chunks are saved. Retry to continue the download.").font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        if isActive {
                            Button("Pause download", systemImage: "pause.fill") { model.pause(entry.id) }
                        } else if let queuePosition {
                            Label("Queued · \(queuePosition)", systemImage: "list.bullet")
                            Button("Remove from queue", systemImage: "xmark.circle") { model.removeQueued(entry.id) }
                        } else if model.installedIDs.contains(entry.id), !isPartial, failure == nil {
                            if !MadeiraDock.clientInstalled {
                                Button(model.isPreparingValveClient ? "Preparing Valve client…" : "Prepare Valve client", systemImage: "arrow.down.circle") {
                                    Task {
                                        await model.prepareValveClient()
                                        if model.error == nil && MadeiraDock.clientInstalled {
                                            await model.play(entry)
                                            if model.error == nil { closeLibrary() }
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.servicesBusy || model.runtimeBusy || model.isPreparingValveClient || !MadeiraDock.bundled || !model.signedIn)
                            } else {
                                let launches = model.launchOptions(for: entry)
                                let installedGame = MadeiraDock.games(drive: MadeiraDock.drive).first { $0.id == entry.id }
                                let options = installedGame.map {
                                    SteamLibraryModel.installedLaunchOptions(launches, game: $0, drive: MadeiraDock.drive)
                                } ?? []
                                Group {
                                    if launches.isEmpty {
                                        if model.loadingLaunchOptions.contains(entry.id) {
                                            ProgressView("Loading this game's launch options…").font(.footnote)
                                        } else {
                                            Button("Load launch options", systemImage: "arrow.clockwise") {
                                                Task { await model.loadInstalledLaunchOptions(entry) }
                                            }
                                            if let warning = model.serviceWarnings[entry.id] {
                                                Text(warning).font(.caption).foregroundStyle(.orange)
                                            }
                                        }
                                    } else if options.isEmpty {
                                        Label("No installed Windows executable found. Update / repair this game.", systemImage: "exclamationmark.circle")
                                            .font(.footnote).foregroundStyle(.orange)
                                    } else if options.count == 1 {
                                        selectButton("Select to launch", option: options.first?.index)
                                    } else {
                                        Menu {
                                            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                                selectButton(optionLabel(option), option: option.index ?? 0)
                                            }
                                        } label: { Label("Select to launch", systemImage: "play.fill") }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.servicesBusy || model.runtimeBusy || model.isPreparingValveClient || !MadeiraDock.bundled || !model.signedIn)
                            }
                        } else {
                            Button(model.runtimeBusy || !model.activeDownloads.isEmpty ? "Add to download queue" : (failure != nil ? "Retry download" : (isPartial || model.pausedDownloads.contains(entry.id) ? "Resume download" : "Download")), systemImage: "arrow.down.circle.fill") {
                                model.download(entry)
                            }.buttonStyle(.borderedProminent)
                        }
                        Spacer(minLength: 48)
                        if !isActive, queuePosition == nil,
                           model.installedIDs.contains(entry.id), !isPartial, failure == nil {
                            Button(model.activeDownloads.isEmpty ? "Update / repair" : "Queue update / repair") { model.download(entry) }
                                .buttonStyle(.bordered)
                        }
                    }
                    if !MadeiraDock.clientInstalled {
                        Text("The Valve launch files are required before selecting an installed game. Preparing them does not start Wine.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let stage = model.valveClientPreparationStatus {
                        HStack { ProgressView(); Text(stage).font(.footnote) }
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                    }
                    if !MadeiraDock.bundled {
                        Label("The Steam launch host is missing from this app build.", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("Selecting a game returns to the launcher. Press Play there; Windows execution requires StikDebug/JIT setup.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Add more games from your library to queue them in order. The queue is saved for this Steam account and waits while a game is running. Paused downloads stay paused until you resume them.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("You can close this view at any time. Closing it does not delete the download.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .navigationTitle("Game download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } }
            }
        }
        .confirmationDialog("Reset local saves for \(entry.game.name)?", isPresented: $confirmSaveReset, titleVisibility: .visible) {
            Button("Delete local saves and turn sync off", role: .destructive) {
                Task { await model.resetLocalSaves(entry.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this game's local Steam save files and turns Upload saves and Download saves off. Cloud saves stay unchanged; this deletion will not sync to Steam. To restore them later, turn Download saves on and choose Use cloud saves.")
        }
        .task(id: entry.id) { await model.loadInstalledLaunchOptions(entry) }
        .frame(width: 620, height: 620)
    }

    private func selectButton(_ title: String, option: UInt32?) -> some View {
        Button(title, systemImage: "play.fill") { Task { await model.play(entry, launchOption: option); if model.error == nil { closeLibrary() } } }
    }

    private func optionLabel(_ option: SteamLaunchOption) -> String {
        let executable = URL(fileURLWithPath: option.executable).lastPathComponent
        let label: String
        switch option.type.lowercased() {
        case "vr": label = "SteamVR / OpenVR · \(executable)"
        case "othervr": label = "Other VR · \(executable)"
        default: label = executable
        }
        // Windlands publishes SteamVR, Oculus and desktop entries for the same
        // executable. Include its public launch arguments to distinguish them.
        return option.arguments.isEmpty ? label : "\(label) — \(option.arguments)"
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

private struct SteamGameArtwork: View {
    let game: SteamOwnedGame
    @State private var candidate = 0

    private var urls: [URL] {
        var urls: [URL] = []
        for name in [game.headerImage, game.libraryHero, game.libraryCapsule].compactMap({ $0 }) {
            guard !name.isEmpty, name.utf8.count <= 256, !name.hasPrefix("/"), !name.contains(".."),
                  name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) else { continue }
            if let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.id)/\(name)") { urls.append(url) }
        }
        if let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.id)/header.jpg") { urls.append(url) }
        return urls
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [.blue.opacity(0.28), .indigo.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if candidate < urls.count {
                    AsyncImage(url: urls[candidate]) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .failure:
                            placeholder.task { candidate += 1 }
                        default: placeholder
                        }
                    }
                    .id(candidate)
                } else { placeholder }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityLabel("Artwork for \(game.name)")
    }

    private var placeholder: some View {
        Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.45))
    }
}
