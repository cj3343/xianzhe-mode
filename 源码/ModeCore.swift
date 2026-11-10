import Foundation

struct PreferenceBackup: Codable, Equatable {
    let domain: String
    let key: String
    // nil means the key did not exist; closing the mode deletes it again.
    let propertyList: Data?
}

struct ModeBackup: Codable, Equatable {
    var version = 1
    var createdAt = Date()
    let dockWasHidden: Bool
    let menuBarWasHidden: Bool
    let preferences: [PreferenceBackup]
}

struct ModeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol DesktopBackend {
    func capture() throws -> ModeBackup
    func enable() throws
    func restore(_ backup: ModeBackup) throws
}

protocol RecoveryStore {
    func load() throws -> ModeBackup?
    func save(_ backup: ModeBackup) throws
    func clear() throws
}

final class FileRecoveryStore: RecoveryStore {
    let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> ModeBackup? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = try PropertyListDecoder().decode(ModeBackup.self, from: Data(contentsOf: url))
        guard backup.version == 1 else {
            throw ModeError(message: "恢复文件版本不受支持，原设置已保留在：\(url.path)")
        }
        return backup
    }

    func save(_ backup: ModeBackup) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(backup)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

final class ModeController {
    private let backend: DesktopBackend
    private let store: RecoveryStore
    private(set) var backup: ModeBackup?
    var isActive: Bool { backup != nil }

    init(backend: DesktopBackend, store: RecoveryStore) throws {
        self.backend = backend
        self.store = store
        self.backup = try store.load()
    }

    func enable() throws {
        guard backup == nil else { return }
        let captured = try backend.capture()
        // Persist first: a crash or forced quit must never lose the original settings.
        try store.save(captured)
        backup = captured
        do {
            try backend.enable()
        } catch {
            let original = error.localizedDescription
            do {
                try disable()
            } catch {
                throw ModeError(message: "开启未完成：\(original)\n\n自动恢复也未完成：\(error.localizedDescription)\n原设置仍已保存，请再次关闭贤者模式来恢复。")
            }
            throw ModeError(message: "开启未完成，已恢复原设置：\(original)")
        }
    }

    func disable() throws {
        guard let captured = backup else { return }
        try backend.restore(captured)
        try store.clear()
        backup = nil
    }
}
