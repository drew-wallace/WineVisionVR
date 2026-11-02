import Foundation
// Platform boundaries only; the sync, protocol, metadata and manifest code
// compiled by run.py are the production sources.
enum SteamLog { static func trace(_ text: String) {}; static func event(_ text: String) {} }
struct DockGame {
    var id: Int; var name: String; var installDir: String; var library: String; var installed = true
}
enum MadeiraDock { static let drive = FileManager.default.temporaryDirectory }
enum SteamRuntimeFiles { static let relativeRoot = "Program Files (x86)/Steam" }
enum SteamInstallPaths {
    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamapps") }
}
func wine_process_is_running() -> Int { 0 }
func wineserver_is_running() -> Int { 0 }

enum SteamInstallFiles { static func safeFolderName(_ value: String) -> String { fatalError("Not used by the local-catalog tests") } }
