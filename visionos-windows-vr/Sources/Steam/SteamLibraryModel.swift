// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
// Adapted from SwiftSteam at 48f976429c189f8396e23d251d8a82f43c705922.
// See third-party/steam-native/COPYING and LICENSE-EXCEPTION.md.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SteamLibraryEntry: Identifiable, Sendable {
    let game: SteamOwnedGame
    var id: Int { game.id }
}

@MainActor
final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()

    @Published private(set) var signedIn = SteamSignIn.isSignedIn
    @Published private(set) var accountName = SteamSignIn.accountName
    @Published private(set) var games: [SteamLibraryEntry] = []
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var installedIDs: Set<Int> = []
    @Published private(set) var installedGames: [SteamLibraryEntry] = []
    @Published private(set) var loadingLaunchOptions: Set<Int> = []
    private var installedMetadata: [Int: SteamOwnedGame] = [:]
    @Published private(set) var progress: [Int: SteamDownloadProgress] = [:]
    @Published private(set) var activeDownloads: Set<Int> = []
    @Published private(set) var pausedDownloads: Set<Int> = []
    /// Waiting app IDs in the order selected; the single active install is separate.
    @Published private(set) var queuedDownloads: [Int] = []
    @Published private(set) var downloadErrors: [Int: String] = [:]
    @Published private(set) var isPreparingValveClient = false
    @Published private(set) var valveClientPreparationStatus: String?
    /// Set by the app while a Wine/runtime launch or accepted session is active.
    @Published var runtimeBusy = false {
        didSet {
            guard runtimeBusy != oldValue else { return }
            if runtimeBusy {
                Task { @MainActor in
                    guard self.runtimeBusy, !self.servicesBusy, !self.sessionReservedForLaunch else { return }
                    await self.prepareForLaunch()
                }
            } else if !sessionReservedForLaunch {
                resumeAfterLaunchFailure()
            }
        }
    }
    @Published var error: String?

    /// The app launcher receives a validated installed record after the CM
    /// session has logged off and its socket has closed.
    var onPlaySelected: ((DockGame, UInt32) -> Void)?

    @Published private(set) var onlineStatus = "Steam connects when the game starts"
    @Published private(set) var servicesBusy = false
    @Published private(set) var serviceStatus: [Int: String] = [:]
    @Published private(set) var serviceWarnings: [Int: String] = [:]
    @Published private(set) var cloudSettings: [Int: SteamCloudPermissions] = [:]
    @Published private(set) var dlc: [Int: [SteamDLCStatus]] = [:]
    private let session = SteamSession()
    private lazy var gameServices = SteamGameServices(session: session)
    private var serviceAppID: Int?

    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private var downloadTasks: [Int: Task<Void, Never>] = [:]
    private var downloadTokens: [Int: UUID] = [:]
    private var sessionReservedForLaunch = false
    private var accountGeneration = 0
    private var suspendingDownloads = 0
    private var resumeWhenDownloadsStop = false
    private var reloadLibraryWhenIdle = false
    private var queueAccount: String?
    private var repairDownloads: Set<Int> = []
    private var applicationIsActive = true
    private var backgroundRecoveryCandidates: Set<Int> = []
    private var waitingForForeground: Set<Int> = []
    #if canImport(UIKit)
    private var downloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Background URLSession owns the network transfers. This short execution
    /// allowance lets chunk verification/journaling finish when the scene leaves
    /// the foreground; it does not promise unlimited background CPU time.
    private func updateDownloadBackgroundExecution() {
        #if canImport(UIKit)
        if activeDownloads.isEmpty {
            endDownloadBackgroundExecution()
        } else if downloadBackgroundTask == .invalid {
            downloadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Steam download checkpoint") { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.persistDownloadQueue()
                    // Do not cancel system-owned transfers at expiration. Their
                    // encrypted results remain available for the next wake.
                    self.endDownloadBackgroundExecution()
                }
            }
        }
        #endif
    }

    private func endDownloadBackgroundExecution() {
        #if canImport(UIKit)
        guard downloadBackgroundTask != .invalid else { return }
        let identifier = downloadBackgroundTask
        downloadBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
        #endif
    }

    func applicationActivityChanged(_ isActive: Bool) {
        guard isActive != applicationIsActive else { return }
        applicationIsActive = isActive
        if !isActive {
            backgroundRecoveryCandidates.formUnion(activeDownloads)
            persistDownloadQueue()
        } else {
            // A single suspension-related retry keeps its position in the FIFO.
            // Normal errors and explicitly paused games are never auto-resumed.
            waitingForForeground.removeAll()
            startNextDownload()
        }
    }

    private static func isSuspensionConnectionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.networkConnectionLost, .notConnectedToInternet, .timedOut,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(urlError.code)
        }
        guard let steamError = error as? SteamError else { return false }
        switch steamError {
        case .disconnected, .connectionTimeout, .connectionFailed, .noServersAvailable: return true
        default: return false
        }
    }

    private struct SavedDownloadQueue: Codable {
        let pending: [Int]
        let paused: [Int]
        let repairs: [Int]
    }

    private static func queueKey(_ account: String) -> String {
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "SteamLibrary.downloadQueue.v1." + Data(normalized.utf8).base64EncodedString()
    }

    private func persistDownloadQueue() {
        guard let account = queueAccount else { return }
        // Only app IDs are saved. Authentication stays in Steam's Keychain store.
        let active = activeDownloads.sorted().filter { !pausedDownloads.contains($0) }
        let pending = (active + queuedDownloads).reduce(into: [Int]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let saved = SavedDownloadQueue(pending: pending, paused: pausedDownloads.sorted(), repairs: repairDownloads.sorted())
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.queueKey(account))
        }
    }

    private func restoreDownloadQueue(account: String) {
        guard queueAccount != account else { return }
        queueAccount = account
        let owned = Set(games.map(\.id))
        guard let data = UserDefaults.standard.data(forKey: Self.queueKey(account)),
              let saved = try? JSONDecoder().decode(SavedDownloadQueue.self, from: data) else {
            persistDownloadQueue()
            return
        }
        pausedDownloads = Set(saved.paused).intersection(owned)
        repairDownloads = Set(saved.repairs).intersection(owned)
        queuedDownloads = saved.pending.reduce(into: [Int]()) { result, id in
            guard id > 0, owned.contains(id), !pausedDownloads.contains(id), !result.contains(id) else { return }
            // A process may have closed after writing the complete appmanifest.
            // Explicit update/repair requests must still run for installed games.
            let partial = DepotDownloader.hasPartialDownload(appID: UInt32(id), steamApps: SteamInstallPaths.steamApps(drive: MadeiraDock.drive))
            if !installedIDs.contains(id) || partial || repairDownloads.contains(id) { result.append(id) }
        }
        repairDownloads.formIntersection(Set(queuedDownloads).union(pausedDownloads))
        persistDownloadQueue()
    }
    private var signInObserver: NSObjectProtocol?

    private init() {
        signInObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.signInStateChanged() }
        }
        refreshInstalled()
        if signedIn { Task { await connectAndLoad() } }
    }

    func refreshInstalled() {
        let records = MadeiraDock.games(drive: MadeiraDock.drive)
        installedIDs = Set(records.filter(\.installed).map(\.id))
        installedMetadata = installedMetadata.filter { installedIDs.contains($0.key) }
        installedGames = SteamInstalledLibrary.games(records: records,
            metadata: games.map(\.game) + Array(installedMetadata.values)).map { SteamLibraryEntry(game: $0) }
        SteamLog.event("[steam-library] local-installed games=\(installedGames.count) remote-refresh=\(isLoadingLibrary ? 1 : 0)")
    }

    /// Prefer refreshed local-card details, then the client's disk cache. This
    /// remains available before a catalog refresh has produced any game cards.
    func launchOptions(for entry: SteamLibraryEntry) -> [SteamLaunchOption] {
        for options in [installedGames.first(where: { $0.id == entry.id })?.game.launches,
                        entry.game.launches, games.first(where: { $0.id == entry.id })?.game.launches] {
            if let options, !options.isEmpty { return options }
        }
        guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == entry.id }) else { return [] }
        return SteamLocalAppInfo.launchOptions(appID: entry.id, game: game, drive: MadeiraDock.drive) ?? []
    }

    /// If this game has never been launched, the guest cache may not exist.
    /// Fetch only its launch metadata, independently of the full catalog task.
    func loadInstalledLaunchOptions(_ entry: SteamLibraryEntry) async {
        guard signedIn, !runtimeBusy, !servicesBusy, installedIDs.contains(entry.id),
              launchOptions(for: entry).isEmpty, !loadingLaunchOptions.contains(entry.id) else { return }
        if sessionReservedForLaunch { resumeAfterLaunchFailure() }
        let generation = accountGeneration
        let loader = fetcher
        loadingLaunchOptions.insert(entry.id)
        defer { if generation == accountGeneration { loadingLaunchOptions.remove(entry.id) } }
        do {
            guard let info = try await loader.fetchAppInfo(appID: UInt32(entry.id)), !info.launches.isEmpty else {
                throw DockError.message("Steam did not return launch options for this game. You can retry from its panel.")
            }
            guard generation == accountGeneration, !runtimeBusy, !sessionReservedForLaunch else { return }
            installedMetadata[entry.id] = SteamOwnedGame(info)
            refreshInstalled()
            serviceWarnings.removeValue(forKey: entry.id)
        } catch {
            guard generation == accountGeneration, !runtimeBusy, !sessionReservedForLaunch else { return }
            serviceWarnings[entry.id] = error.localizedDescription
        }
    }

    func refreshLibrary() async {
        refreshInstalled()
        guard signedIn else { return }
        await connectAndLoad()
    }

    private func signInStateChanged() async {
        persistDownloadQueue()
        accountGeneration &+= 1
        let generation = accountGeneration
        signedIn = SteamSignIn.isSignedIn
        accountName = SteamSignIn.accountName
        await stopConnectionAndDownloads()
        guard generation == accountGeneration else { return }
        clearAccountDownloadState()
        // Depot keys and owned-depot licenses belong to the old account.
        fetcher = SteamLibraryFetcher(session: session)
        downloader = DepotDownloader(session: session)
        if signedIn {
            session.resume()
            await connectAndLoad()
        }
    }

    private func clearAccountDownloadState() {
        queueAccount = nil
        games = []
        dlc = [:]
        serviceStatus = [:]
        serviceWarnings = [:]
        cloudSettings = [:]
        installedMetadata = [:]
        loadingLaunchOptions = []
        refreshInstalled()
        progress = [:]
        activeDownloads = []
        pausedDownloads = []
        queuedDownloads = []
        repairDownloads = []
        backgroundRecoveryCandidates = []
        waitingForForeground = []
        endDownloadBackgroundExecution()
        downloadErrors = [:]
        if isPreparingValveClient && !runtimeBusy { sessionReservedForLaunch = false }
        isPreparingValveClient = false
        valveClientPreparationStatus = nil
    }

    private func connectAndLoad() async {
        guard !servicesBusy, !sessionReservedForLaunch, !runtimeBusy, suspendingDownloads == 0 else { return }
        guard !isLoadingLibrary else {
            reloadLibraryWhenIdle = true
            return
        }
        isLoadingLibrary = true
        defer {
            isLoadingLibrary = false
            if reloadLibraryWhenIdle {
                reloadLibraryWhenIdle = false
                Task { await connectAndLoad() }
            } else {
                startNextDownload()
            }
        }
        let generation = accountGeneration
        let libraryFetcher = fetcher
        let account = SteamSignIn.accountName
        guard signedIn, account != nil else { return }
        do {
            try await session.connectAndLogin()
            guard generation == accountGeneration, signedIn, account == SteamSignIn.accountName,
                  !runtimeBusy, !sessionReservedForLaunch else { return }
            let result = try await libraryFetcher.fetchOwnedApps()
            guard generation == accountGeneration, signedIn,
                  account == SteamSignIn.accountName, !sessionReservedForLaunch else { return }
            games = result.map { SteamLibraryEntry(game: SteamOwnedGame($0)) }
                .sorted { $0.game.name.localizedCaseInsensitiveCompare($1.game.name) == .orderedAscending }
            refreshInstalled()
            restoreDownloadQueue(account: account!)
            refreshCloudSettings()
            error = nil
            SteamLog.event("[steam-library] loaded games=\(games.count) installed=\(installedIDs.count)")
            let canContinue = { generation == self.accountGeneration && !self.sessionReservedForLaunch && !self.runtimeBusy }
            await SteamLibraryMaintenance.run(result.map { Int($0.appID) }.filter { installedIDs.contains($0) },
                canContinue: canContinue, operation: { id in
                    if let info = try await libraryFetcher.fetchInstallInfo(appID: UInt32(id)) {
                        guard canContinue() else { throw CancellationError() }
                        self.dlc[id] = SteamDLCStatus.inspect(info: info, owned: libraryFetcher.ownedDLC, drive: MadeiraDock.drive)
                    }
                }, onFailure: { id, failure in self.serviceWarnings[id] = failure.localizedDescription })
            // A failed save retry stays attached to that game. The library and
            // restored download queue remain usable, including after uninstall.
            do {
                let pending = try gameServices.pendingApps()
                await SteamLibraryMaintenance.run(pending, canContinue: canContinue,
                    operation: { id in
                        guard libraryFetcher.ownedApps.contains(UInt32(id)) else {
                            throw DockError.message("Save upload remains pending because Steam has not confirmed ownership of app \(id).")
                        }
                        try await self.syncServices(id)
                        self.serviceWarnings.removeValue(forKey: id)
                    }, onFailure: { id, failure in
                        self.serviceWarnings[id] = failure.localizedDescription
                        self.serviceStatus[id] = failure.localizedDescription
                        SteamLog.event("[steam-library] save-retry-held app=\(id)")
                    })
            } catch {
                SteamLog.event("[steam-library] save-retry-journal-unavailable")
            }
        } catch {
            if generation == accountGeneration, signedIn { self.error = SteamSignIn.message(error) }
        }
    }

    /// Adds another owned game to the FIFO, including while a game is running.
    func download(_ entry: SteamLibraryEntry) {
        guard signedIn, queueAccount == SteamSignIn.accountName,
              games.contains(where: { $0.id == entry.id }), !queuedDownloads.contains(entry.id),
              !activeDownloads.contains(entry.id) || pausedDownloads.contains(entry.id) else { return }
        let appID = entry.id
        downloadErrors.removeValue(forKey: appID)
        pausedDownloads.remove(appID)
        if installedIDs.contains(appID) { repairDownloads.insert(appID) }
        queuedDownloads.append(appID)
        persistDownloadQueue()
        error = nil
        startNextDownload()
    }

    func removeQueued(_ id: Int) {
        queuedDownloads.removeAll { $0 == id }
        repairDownloads.remove(id)
        waitingForForeground.remove(id)
        backgroundRecoveryCandidates.remove(id)
        persistDownloadQueue()
        startNextDownload()
    }

    private func startNextDownload() {
        guard signedIn, !servicesBusy, !runtimeBusy, !sessionReservedForLaunch,
              !isPreparingValveClient, !isLoadingLibrary, suspendingDownloads == 0,
              downloadTasks.isEmpty, let appID = queuedDownloads.first,
              !waitingForForeground.contains(appID) else { return }
        queuedDownloads.removeFirst()
        activeDownloads.insert(appID)
        if !applicationIsActive { backgroundRecoveryCandidates.insert(appID) }
        updateDownloadBackgroundExecution()
        persistDownloadQueue()
        let generation = accountGeneration
        let token = UUID()
        downloadTokens[appID] = token
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await session.ensureConnected()
                try Task.checkCancellation()
                guard generation == accountGeneration else { throw CancellationError() }
                guard let app = try await fetcher.fetchInstallInfo(appID: UInt32(appID)) else {
                    throw SteamError.depotNotFound(UInt32(appID))
                }
                try Task.checkCancellation()
                guard generation == accountGeneration else { throw CancellationError() }
                let ownedDepots = try await fetcher.ownedDepotIDs()
                try Task.checkCancellation()
                guard generation == accountGeneration else { throw CancellationError() }
                _ = try await downloader.install(app, steamApps: SteamInstallPaths.steamApps(drive: MadeiraDock.drive),
                    ownedDepots: { ownedDepots }) { [weak self] value in
                        Task { @MainActor in
                            guard let self, generation == self.accountGeneration,
                                  self.downloadTokens[appID] == token, self.downloadTasks[appID]?.isCancelled == false,
                                  self.activeDownloads.contains(appID), !self.pausedDownloads.contains(appID) else { return }
                            self.progress[appID] = value
                        }
                    }
                guard generation == accountGeneration else { return }
                refreshInstalled()
                let content = SteamDLCStatus.inspect(info: app, owned: fetcher.ownedDLC, drive: MadeiraDock.drive)
                dlc[appID] = content
                guard content.allSatisfy(\.ready) else {
                    throw DockError.message("Owned DLC did not finish installing. Retry Update / repair to complete it.")
                }
                if appID == RiskOfRain2HealthBarRepair.appID {
                    guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == appID }) else {
                        throw DockError.message("Risk of Rain 2's installed folder could not be found for the health-bar repair.")
                    }
                    try await RiskOfRain2HealthBarRepair.prepare(game: game, drive: MadeiraDock.drive)
                    guard generation == accountGeneration else { return }
                }
                error = nil
                queuedDownloads.removeAll { $0 == appID }
                repairDownloads.remove(appID)
                backgroundRecoveryCandidates.remove(appID)
                waitingForForeground.remove(appID)
            } catch is CancellationError {
                // Explicit pauses stay paused; launch suspension already requeued its active ID.
            } catch {
                guard generation == accountGeneration else { return }
                if !Task.isCancelled {
                    if backgroundRecoveryCandidates.remove(appID) != nil,
                       Self.isSuspensionConnectionError(error), !pausedDownloads.contains(appID) {
                        queuedDownloads.removeAll { $0 == appID }
                        queuedDownloads.insert(appID, at: 0)
                        if !applicationIsActive { waitingForForeground.insert(appID) }
                        downloadErrors.removeValue(forKey: appID)
                    } else {
                        let message = SteamSignIn.message(error)
                        downloadErrors[appID] = message
                        self.error = message
                    }
                }
            }
            guard generation == accountGeneration, downloadTokens[appID] == token else { return }
            activeDownloads.remove(appID)
            if downloadErrors[appID] == nil && !pausedDownloads.contains(appID) {
                progress.removeValue(forKey: appID)
            }
            downloadTasks.removeValue(forKey: appID)
            downloadTokens.removeValue(forKey: appID)
            persistDownloadQueue()
            startNextDownload()
            updateDownloadBackgroundExecution()
        }
        downloadTasks[appID] = task
    }

    func pause(_ id: Int) {
        guard let task = downloadTasks[id] else { return }
        pausedDownloads.insert(id)
        waitingForForeground.remove(id)
        backgroundRecoveryCandidates.remove(id)
        queuedDownloads.removeAll { $0 == id }
        persistDownloadQueue()
        task.cancel()
    }

    func resume(_ entry: SteamLibraryEntry) { download(entry) }

    private func requeueActiveDownloads() {
        let interrupted = activeDownloads.sorted().filter { !pausedDownloads.contains($0) }
        queuedDownloads = interrupted + queuedDownloads.filter { !interrupted.contains($0) }
        persistDownloadQueue()
    }

    func prepareValveClient() async {
        guard !servicesBusy, !isPreparingValveClient, !runtimeBusy else { return }
        let preserveLaunchReservation = sessionReservedForLaunch
        isPreparingValveClient = true
        sessionReservedForLaunch = true
        let generation = accountGeneration
        defer {
            if generation == accountGeneration {
                isPreparingValveClient = false
                startNextDownload()
            }
        }
        requeueActiveDownloads()
        await stopConnectionAndDownloads()
        guard generation == accountGeneration else { return }

        // The prefix seeder must not race a native Steam install creating its
        // first steamapps directory. Keep the account disconnected throughout.
        if runtimeBusy {
            error = "Close the active game session before preparing the Valve client."
        } else {
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { [weak self] stage in
                    await MainActor.run {
                        guard let self, generation == self.accountGeneration else { return }
                        self.valveClientPreparationStatus = stage
                    }
                }
                guard generation == accountGeneration else { return }
                valveClientPreparationStatus = nil
                error = nil
            } catch {
                guard generation == accountGeneration else { return }
                valveClientPreparationStatus = nil
                self.error = error.localizedDescription
            }
        }
        sessionReservedForLaunch = preserveLaunchReservation
        if signedIn, !runtimeBusy, !preserveLaunchReservation {
            session.resume()
            await connectAndLoad()
        }
    }

    /// Whether the program a launch option names is really in the game's install folder.
    /// Steam lists every platform's and build type's entry (Moss II VR has a Test build at option 0
    /// that is not installed), and starting a missing program fails with Steam's "could not find
    /// the game's executable" refusal.
    nonisolated static func isInstalled(_ option: SteamLaunchOption, game: DockGame, drive: URL) -> Bool {
        SteamInstalledExecutable.resolve(option.executable, game: game, drive: drive) != nil
    }

    /// Hide metadata entries for other platforms or programs absent from this install.
    nonisolated static func installedLaunchOptions(_ options: [SteamLaunchOption], game: DockGame, drive: URL) -> [SteamLaunchOption] {
        options.filter {
            ($0.oslist.isEmpty || $0.oslist.lowercased().contains("windows")) &&
                isInstalled($0, game: game, drive: drive)
        }
    }

    /// OpenComposite supplies SteamVR/OpenVR. Prefer that route over another VR
    /// runtime (for example Oculus), even when both entries name the same file.
    nonisolated static func preferredVRLaunchOption(_ options: [SteamLaunchOption]) -> SteamLaunchOption? {
        options.first(where: { $0.type.lowercased() == "vr" })
            ?? options.first(where: { $0.type.lowercased() == "othervr" })
    }

    /// The launch option to start by default: installed Windows entries, with
    /// SteamVR first. Returns nil when no Windows executable can be found.
    nonisolated static func preferredLaunchOption(_ options: [SteamLaunchOption], game: DockGame, drive: URL) -> SteamLaunchOption? {
        let present = installedLaunchOptions(options, game: game, drive: drive)
        return preferredVRLaunchOption(present)
            ?? present.first(where: { $0.type.isEmpty || $0.type == "default" })
            ?? present.first
    }

    func play(_ entry: SteamLibraryEntry, launchOption: UInt32? = nil) async {
        guard !servicesBusy, !runtimeBusy, signedIn else { return }
        guard !activeDownloads.contains(entry.id),
              !DepotDownloader.hasPartialDownload(appID: UInt32(entry.id), steamApps: SteamInstallPaths.steamApps(drive: MadeiraDock.drive)) else {
            error = "Finish or resume this game's download before selecting it to play."
            return
        }
        await prepareForLaunch()
        refreshInstalled()
        guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == entry.id }) else {
            error = "Steam has not finished installing this game yet."
            resumeAfterLaunchFailure()
            return
        }
        do {
            try MadeiraDock.validate(game, drive: MadeiraDock.drive)
            error = nil
            let launches = launchOptions(for: entry)
            guard !launches.isEmpty else {
                error = "Launch information is unavailable. Refresh the library and try again."
                resumeAfterLaunchFailure()
                return
            }
            let options = Self.installedLaunchOptions(launches, game: game, drive: MadeiraDock.drive)
            let selected = launchOption.flatMap { index in options.first { $0.index == index } }
                ?? (launchOption == nil ? Self.preferredLaunchOption(options, game: game, drive: MadeiraDock.drive) : nil)
            guard let index = selected?.index else {
                error = "No installed Windows executable was found for this launch option. Update / repair the game and try again."
                resumeAfterLaunchFailure()
                return
            }
            guard let onPlaySelected else {
                error = "The WineVision VR launcher is not ready yet."
                resumeAfterLaunchFailure()
                return
            }
            onPlaySelected(game, index)
        } catch {
            self.error = error.localizedDescription
            resumeAfterLaunchFailure()
        }
    }

    func signOut() async {
        guard !servicesBusy, !runtimeBusy else { return }
        persistDownloadQueue()
        accountGeneration &+= 1
        let generation = accountGeneration
        signedIn = false
        accountName = nil
        await stopConnectionAndDownloads()
        guard generation == accountGeneration else { return }
        clearAccountDownloadState()
        SteamSignIn.signOut()
    }

    private var cloudSettingsAccount: UInt64? {
        if session.steamID != 0 { return session.steamID }
        guard let token = SteamSignIn.credentialsForDock()?.refreshToken else { return nil }
        return try? MadeiraDock.subject(token)
    }

    func cloudPermissions(_ appID: Int) -> SteamCloudPermissions {
        guard let account = cloudSettingsAccount else { return .init(upload: false, download: false) }
        return cloudSettings[appID] ?? ((try? gameServices.permissions(appID, account: account)) ?? .init(upload: false, download: false))
    }

    private func refreshCloudSettings() {
        guard let account = cloudSettingsAccount else { cloudSettings = [:]; return }
        cloudSettings = Dictionary(uniqueKeysWithValues: installedIDs.map { id in
            (id, (try? gameServices.permissions(id, account: account)) ?? .init(upload: false, download: false))
        })
    }

    func setCloudPermissions(_ appID: Int, upload: Bool? = nil, download: Bool? = nil) {
        guard !runtimeBusy, !servicesBusy, let account = cloudSettingsAccount else { return }
        do {
            try gameServices.setPermissions(appID, account: account, upload: upload, download: download)
            serviceWarnings.removeValue(forKey: appID)
            serviceStatus[appID] = "Cloud settings saved; applies to Sync saves and the next launch"
        } catch { serviceWarnings[appID] = error.localizedDescription }
        // A setting persisted before a client-config failure still stays off.
        refreshCloudSettings()
    }

    func updateOnlineStatus(_ report: MadeiraDock.Report) {
        let status: String
        if DockOffline.networkDown { status = "Network unavailable; online play needs an internet connection" }
        else if report.fields["session-offline-requested"] == "1" { status = "Steam started in offline mode" }
        else if report.fields["session-authenticated-online"] == "1" {
            switch report.fields["session-social-persona-state"].flatMap(Int.init) {
            case 1:
                if report.fields["session-friend-subscription-result"] == "1" {
                    status = "Steam online · Friends connected"
                } else if report.fields["session-friend-subscription-ready"] == "0" ||
                            report.fields["session-friend-subscription-sent"] == "0" ||
                            report.fields["session-friend-subscription-timeout"] == "1" ||
                            report.fields["session-friend-subscription-result"] != nil {
                    status = "Steam online · Live friends unavailable"
                } else {
                    status = "Steam online · Connecting friends"
                }
            case 2: status = "Steam online · Busy status"
            case 3, 4: status = "Steam signed in · Away status"
            case 7: status = "Steam signed in · Invisible status"
            default: status = "Valve confirmed Steam online sign-in"
            }
        }
        else { status = "Waiting for Steam online sign-in" }
        if onlineStatus != status { onlineStatus = status }
    }

    /// Runs at actual launch, including launches restored from saved profiles.
    /// runtimeBusy may already be true while the launcher prepares presentation.
    func prepareGameServices(appID: Int, option: UInt32) async throws {
        guard !servicesBusy else { throw DockError.message("Steam is already synchronizing saves.") }
        servicesBusy = true
        defer { servicesBusy = false }
        await prepareForLaunch()
        session.resume()
        do {
            try await session.ensureConnected()
            _ = try await fetcher.fetchOwnedApps() // fresh ownership, including purchases/refunds
            guard fetcher.ownedApps.contains(UInt32(appID)) else { throw DockError.message("Steam did not confirm ownership of this game.") }
            try await syncServices(appID, launchOption: option)
            serviceAppID = appID
            await session.suspend()
        } catch {
            serviceStatus[appID] = error.localizedDescription
            await session.suspend()
            throw error
        }
    }

    private func syncServices(_ appID: Int, launchOption: UInt32? = nil, preferCloud: Bool = false) async throws {
        guard let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == appID }) else {
            throw DockError.message("Steam app \(appID) is no longer installed. Its local saves are kept and its upload remains pending.")
        }
        guard let info = try await fetcher.fetchInstallInfo(appID: UInt32(appID)) else {
            throw DockError.message("Steam did not return product information for \(game.name) (\(appID)). Saves remain on this device; retry Sync saves later.")
        }
        let content = SteamDLCStatus.inspect(info: info, owned: fetcher.ownedDLC, drive: MadeiraDock.drive)
        dlc[appID] = content
        if launchOption != nil, content.contains(where: { !$0.ready }) {
            throw DockError.message("Owned DLC is missing or outdated. Update / repair this game before playing.")
        }
        if let launchOption, let option = info.launches.first(where: { $0.index == launchOption }),
           let requirement = option.requiredDLC, !requirement.isEmpty, requirement != "0" {
            guard let id = UInt32(requirement), fetcher.ownedApps.contains(id) else {
                throw DockError.message("Steam did not confirm ownership of the DLC required by this launch option.")
            }
        }
        if launchOption != nil { try gameServices.prepareClientSettings(appID) }
        if info.cloudEnabled {
            serviceStatus[appID] = "Synchronizing Steam Cloud…"
            serviceStatus[appID] = try await gameServices.sync(game: game, info: info, preferCloud: preferCloud)
            if launchOption != nil { try gameServices.markPending(appID) }
        } else { serviceStatus[appID] = "This game does not advertise Steam Cloud support" }
    }

    func syncSaves(_ appID: Int, preferCloud: Bool = false) async {
        guard !runtimeBusy, !servicesBusy else { return }
        servicesBusy = true
        defer { servicesBusy = false; resumeAfterLaunchFailure() }
        await prepareForLaunch()
        session.resume()
        do {
            try await session.ensureConnected()
            _ = try await fetcher.fetchOwnedApps()
            guard fetcher.ownedApps.contains(UInt32(appID)) else { throw DockError.message("Steam did not confirm ownership of this game.") }
            try await syncServices(appID, preferCloud: preferCloud)
            serviceWarnings.removeValue(forKey: appID)
            error = nil
        } catch { serviceStatus[appID] = error.localizedDescription; serviceWarnings[appID] = error.localizedDescription }
    }

    /// The view calls this only after a destructive-action confirmation.
    func resetLocalSaves(_ appID: Int) async {
        guard !runtimeBusy, !servicesBusy, !isPreparingValveClient, signedIn,
              let account = cloudSettingsAccount else { return }
        servicesBusy = true
        defer { refreshCloudSettings(); servicesBusy = false; resumeAfterLaunchFailure() }
        await prepareForLaunch()
        session.resume()
        do {
            // Even a failed connection or metadata lookup must leave sync off.
            try gameServices.setPermissions(appID, account: account, upload: false, download: false)
            refreshCloudSettings()
            try await session.ensureConnected()
            _ = try await fetcher.fetchOwnedApps()
            guard fetcher.ownedApps.contains(UInt32(appID)),
                  let game = MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == appID }),
                  let info = try await fetcher.fetchInstallInfo(appID: UInt32(appID)) else {
                throw DockError.message("Steam could not identify this game's save folders. No saves were removed.")
            }
            let count = try await gameServices.resetLocalSaves(game: game, info: info)
            serviceStatus[appID] = "Local saves reset (\(count) files). Uploads and downloads are off. Cloud saves are unchanged."
            serviceWarnings.removeValue(forKey: appID)
            error = nil
        } catch {
            serviceStatus[appID] = "Reset did not finish: \(error.localizedDescription)"
            serviceWarnings[appID] = serviceStatus[appID]
        }
    }

    /// Called only after the native runtime confirms stop. A pending journal
    /// remains if Wine services are still exiting or the network is unavailable.
    func finishGameServices() async {
        guard let appID = serviceAppID, !servicesBusy else { return }
        serviceAppID = nil
        servicesBusy = true
        defer { servicesBusy = false }
        session.resume()
        do {
            for _ in 0..<40 {
                if wine_process_is_running() == 0 && wineserver_is_running() == 0 { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
                throw DockError.message("Saves are waiting for Wine to close; sync will retry next app start.")
            }
            try await session.ensureConnected()
            _ = try await fetcher.fetchOwnedApps()
            guard fetcher.ownedApps.contains(UInt32(appID)) else { throw DockError.message("Steam did not confirm ownership of this game.") }
            try await syncServices(appID)
        } catch { serviceStatus[appID] = error.localizedDescription; serviceWarnings[appID] = error.localizedDescription }
        await session.suspend()
    }

    /// Releases the authenticated Steam connection before WineVision VR starts its
    /// Wine session. Waiting downloads and the interrupted active install survive.
    func prepareForLaunch() async {
        sessionReservedForLaunch = true
        requeueActiveDownloads()
        await stopConnectionAndDownloads()
    }

    /// Reconnects after a launch fails or a game session ends.
    func resumeAfterLaunchFailure() {
        guard !servicesBusy, !runtimeBusy, !isPreparingValveClient else { return }
        sessionReservedForLaunch = false
        guard suspendingDownloads == 0 else {
            resumeWhenDownloadsStop = true
            return
        }
        session.resume()
        if signedIn { Task { await connectAndLoad(); startNextDownload() } }
    }

    private func stopConnectionAndDownloads() async {
        suspendingDownloads += 1
        defer {
            suspendingDownloads -= 1
            if suspendingDownloads == 0 && resumeWhenDownloadsStop {
                resumeWhenDownloadsStop = false
                resumeAfterLaunchFailure()
            }
        }
        let tasks = Array(downloadTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        downloadTasks.removeAll()
        downloadTokens.removeAll()
        activeDownloads.removeAll()
        endDownloadBackgroundExecution()
        await session.suspend()
    }
}
