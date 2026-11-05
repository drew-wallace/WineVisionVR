// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
import Foundation

/// Retry transient transport failures once before asking the player to act.
/// Cancellation, account refusals and save conflicts retain their own handling.
@MainActor
enum SteamConnectionRecovery {
    static func isConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.networkConnectionLost, .notConnectedToInternet, .timedOut,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        guard let error = error as? SteamError else { return false }
        switch error {
        case .disconnected, .connectionTimeout, .connectionFailed, .noServersAvailable: return true
        default: return false
        }
    }

    static func retry<T>(operation: () async throws -> T,
                         beforeRetry: () async throws -> Void) async throws -> T {
        do { return try await operation() }
        catch {
            try Task.checkCancellation()
            guard isConnectionFailure(error) else { throw error }
            try await beforeRetry()
            try Task.checkCancellation()
            return try await operation()
        }
    }
}

/// Optional per-game work cannot turn a successful owned-library refresh into
/// a failure, or prevent the download queue from being restored.
@MainActor
enum SteamLibraryMaintenance {
    static func run(_ appIDs: [Int], canContinue: () -> Bool,
                    operation: (Int) async throws -> Void, onFailure: (Int, Error) -> Void) async {
        for id in appIDs {
            guard canContinue(), !Task.isCancelled else { return }
            do { try await operation(id) }
            catch is CancellationError { return }
            catch {
                guard canContinue() else { return }
                onFailure(id, error)
            }
        }
    }
}
