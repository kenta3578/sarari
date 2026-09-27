import Foundation
import Testing
@testable import sarari

/// 同梱の sarari の音（Issue #2）。テストはアプリをホストに走るので `Bundle.main` がアプリ本体。
@MainActor
struct SoundPlayerTests {

    @Test("bundledSounds の名前がすべてアプリに入っている")
    func everyBundledSoundIsShipped() {
        for name in SoundPlayer.bundledSounds {
            #expect(SoundPlayer.bundledFileURL(for: name) != nil, "\(name).wav が Resources/Sounds にない")
            #expect(SoundPlayer.isAvailable(name))
        }
    }

    @Test("Resources/Sounds に bundledSounds 以外の音がない（make-sounds.py の BUNDLED と揃っている）")
    func noStrayBundledFiles() throws {
        let dir = try #require(Bundle.main.resourceURL?.appendingPathComponent("Sounds"))
        let shipped = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".wav") }
            .map { String($0.dropLast(4)) }
        #expect(Set(shipped) == Set(SoundPlayer.bundledSounds))
    }

    @Test("選択肢は なし → sarari の音 → 自分の音 → システム音 の順で、名前が重ならない")
    func choicesAreGroupedWithoutDuplicates() {
        let choices = SoundPlayer.choices()
        #expect(choices.first == SoundPlayer.none)
        #expect(Array(choices.dropFirst().prefix(SoundPlayer.bundledSounds.count)) == SoundPlayer.bundledSounds)
        #expect(Array(choices.suffix(SoundPlayer.systemSounds.count)) == SoundPlayer.systemSounds)
        #expect(Set(choices).count == choices.count)
    }

    @Test("sarari の音はシステム音と名前が被らない")
    func bundledNamesDoNotShadowSystemSounds() {
        #expect(Set(SoundPlayer.bundledSounds).isDisjoint(with: SoundPlayer.systemSounds))
    }
}
