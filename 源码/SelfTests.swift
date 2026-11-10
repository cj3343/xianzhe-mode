import Foundation

private final class MemoryStore: RecoveryStore {
    var value: ModeBackup?
    var failSave = false
    var failClear = false
    func load() throws -> ModeBackup? { value }
    func save(_ backup: ModeBackup) throws {
        if failSave { throw ModeError(message: "save failed") }
        value = backup
    }
    func clear() throws {
        if failClear { throw ModeError(message: "clear failed") }
        value = nil
    }
}

private final class FakeDesktop: DesktopBackend {
    var captureCount = 0
    var applyCount = 0
    var restores: [ModeBackup] = []
    var failApply = false
    var failRestore = false
    var beforeApply: (() throws -> Void)?
    let original: ModeBackup
    init(dock: Bool = false, menu: Bool = false) {
        original = ModeBackup(dockWasHidden: dock, menuBarWasHidden: menu, preferences: [
            PreferenceBackup(domain: "com.apple.finder", key: "CreateDesktop", propertyList: nil)
        ])
    }
    func capture() throws -> ModeBackup { captureCount += 1; return original }
    func enable() throws {
        applyCount += 1
        try beforeApply?()
        if failApply { throw ModeError(message: "apply failed") }
    }
    func restore(_ backup: ModeBackup) throws {
        restores.append(backup)
        if failRestore { throw ModeError(message: "restore failed") }
    }
}

func runSelfTests() throws {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ModeError(message: message) }
        count += 1
    }
    for dock in [false, true] {
        for menu in [false, true] {
            let backend = FakeDesktop(dock: dock, menu: menu), store = MemoryStore()
            backend.beforeApply = { try check(store.value == backend.original, "backup must precede mutation") }
            let controller = try ModeController(backend: backend, store: store)
            try controller.enable()
            try check(controller.isActive, "enable state")
            try controller.enable()
            try check(backend.captureCount == 1 && backend.applyCount == 1, "duplicate enable must preserve original")
            try controller.disable()
            try check(backend.restores == [backend.original], "restore exact previous visibility")
            try check(!controller.isActive && store.value == nil, "clear after restore")
            try controller.disable()
            try check(backend.restores.count == 1, "duplicate disable")
        }
    }
    do {
        let backend = FakeDesktop(), store = MemoryStore()
        backend.failApply = true
        let controller = try ModeController(backend: backend, store: store)
        do { try controller.enable(); throw ModeError(message: "expected apply failure") }
        catch { try check(error.localizedDescription.contains("apply failed"), "report apply failure") }
        try check(!controller.isActive && store.value == nil && backend.restores.count == 1, "rollback on partial failure")
    }
    do {
        let backend = FakeDesktop(), store = MemoryStore()
        backend.failApply = true; backend.failRestore = true
        let controller = try ModeController(backend: backend, store: store)
        do { try controller.enable() } catch {}
        try check(controller.isActive && store.value == backend.original, "keep journal when rollback fails")
        backend.failRestore = false
        try controller.disable()
        try check(!controller.isActive && store.value == nil, "retry recovery")
    }
    do {
        let backend = FakeDesktop(), store = MemoryStore()
        store.failSave = true
        let controller = try ModeController(backend: backend, store: store)
        do { try controller.enable() } catch {}
        try check(backend.applyCount == 0 && !controller.isActive, "failed journal prevents mutation")
    }
    do {
        let backend = FakeDesktop(), store = MemoryStore()
        store.value = backend.original
        let restarted = try ModeController(backend: backend, store: store)
        try check(restarted.isActive, "detect interrupted session")
        try restarted.disable()
        try check(backend.captureCount == 0 && backend.restores == [backend.original], "recover without overwriting original")
    }
    do {
        let backend = FakeDesktop(), store = MemoryStore()
        let controller = try ModeController(backend: backend, store: store)
        try controller.enable()
        store.failClear = true
        do { try controller.disable() } catch {}
        try check(controller.isActive && store.value != nil, "keep journal if cleanup fails")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = FileRecoveryStore(url: folder.appendingPathComponent("original.plist"))
    let original = FakeDesktop(dock: true, menu: false).original
    try file.save(original)
    let loaded = try file.load()
    try check(loaded == original, "binary property-list round trip including absent key")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private recovery file")
    try file.clear()
    let cleared = try file.load()
    try check(cleared == nil, "remove recovery file")
    print("PASS: \(count) checks (visibility combinations, rollback, crash recovery, exact backup, disk errors)")
}
