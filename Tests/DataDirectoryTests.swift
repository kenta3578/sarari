import Foundation
import Testing
@testable import sarari

/// 旧名の置き場 `~/koebun`（Issue #43）・`~/koemakase`（Issue #54）からの移行。辞書・履歴を失わないことを見る。
struct DataDirectoryTests {

    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarari-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    @Test("旧名の置き場だけがあれば、中身ごと新しい置き場へ移す")
    func movesLegacy() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent("koebun")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: legacy.appendingPathComponent("replacements.json"))

            DataDirectory.migrateIfNeeded(home: home)

            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            #expect(FileManager.default.fileExists(
                atPath: home.appendingPathComponent("sarari/replacements.json").path))
        }
    }

    @Test("新しい置き場が既にあれば何もしない（新しい方を正とする）")
    func keepsCurrent() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent("koebun")
            let current = home.appendingPathComponent("sarari")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

            DataDirectory.migrateIfNeeded(home: home)

            #expect(FileManager.default.fileExists(atPath: legacy.path))
            #expect(FileManager.default.fileExists(atPath: current.path))
        }
    }

    @Test("直前の名前 koemakase の置き場も移す（Issue #54）")
    func movesPreviousName() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent("koemakase")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: legacy.appendingPathComponent("replacements.json"))

            DataDirectory.migrateIfNeeded(home: home)

            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            #expect(FileManager.default.fileExists(
                atPath: home.appendingPathComponent("sarari/replacements.json").path))
        }
    }

    @Test("旧名の置き場が2つあれば新しい名前の方を移し、古い方は触らない")
    func prefersNewestLegacy() throws {
        try withHome { home in
            let older = home.appendingPathComponent("koebun")
            let newer = home.appendingPathComponent("koemakase")
            try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
            try Data("newer".utf8).write(to: newer.appendingPathComponent("marker"))

            DataDirectory.migrateIfNeeded(home: home)

            #expect(FileManager.default.fileExists(atPath: older.path))
            #expect(!FileManager.default.fileExists(atPath: newer.path))
            #expect(FileManager.default.fileExists(
                atPath: home.appendingPathComponent("sarari/marker").path))
        }
    }
}
