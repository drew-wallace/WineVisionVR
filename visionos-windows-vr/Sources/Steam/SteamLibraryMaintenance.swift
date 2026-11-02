// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
import Foundation

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
