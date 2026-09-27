import AppKit
import Testing
@testable import sarari

/// 修飾キーの押下判定（Issue #78 / #115 / #120）。NSEvent を作らず flags の生値だけで組む。
struct HotKeyJudgeTests {

    private let rightOption: UInt16 = 61
    private let leftOption: UInt16 = 58
    private let leftShift: UInt16 = 56
    private let leftCommand: UInt16 = 55
    private let fn: UInt16 = 63

    // NX_DEVICE*KEYMASK。`SettingsStore` の private な定数と同じ値を独立に持ち、ズレたら落ちるようにする。
    private let leftOptionMask: UInt = 0x0000_0020
    private let rightOptionMask: UInt = 0x0000_0040

    private func flags(_ raw: UInt, _ base: NSEvent.ModifierFlags = []) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: base.rawValue | raw)
    }

    @Test("右⌥ と 左⌥ を区別する。左を押したまま右を離しても「押されている」と誤判定しない")
    func distinguishesLeftAndRight() {
        let bothDown = flags(leftOptionMask | rightOptionMask, .option)
        #expect(SettingsStore.isKeyDown(keyCode: rightOption, flags: bothDown))
        #expect(SettingsStore.isKeyDown(keyCode: leftOption, flags: bothDown))

        let onlyLeft = flags(leftOptionMask, .option)
        #expect(!SettingsStore.isKeyDown(keyCode: rightOption, flags: onlyLeft))
        #expect(SettingsStore.isKeyDown(keyCode: leftOption, flags: onlyLeft))
    }

    /// Issue #120。JoyKeyMapper 等は修飾キーを**左側の keyCode** で送るので、左右を見ると
    /// 右⌥ 設定では永遠に反応しない。合成イベントは汎用フラグで見る。
    @Test("sideAgnostic なら左ビットしか無いイベントでも右⌥として通る")
    func sideAgnosticIgnoresSide() {
        let onlyLeft = flags(leftOptionMask, .option)
        #expect(!SettingsStore.isKeyDown(keyCode: rightOption, flags: onlyLeft))
        #expect(SettingsStore.isKeyDown(keyCode: rightOption, flags: onlyLeft, sideAgnostic: true))
    }

    /// 左右ビットが 1 つも立たないイベント（一部の仮想キーボード）でも汎用フラグで拾う。
    @Test("左右ビットが無いイベントは汎用フラグで判定する")
    func fallsBackToGenericFlag() {
        #expect(SettingsStore.isKeyDown(keyCode: rightOption, flags: [.option]))
        #expect(SettingsStore.isKeyDown(keyCode: leftOption, flags: [.option]))
    }

    @Test("fn は左右が無いので通常フラグで見る")
    func fnUsesFunctionFlag() {
        #expect(SettingsStore.isKeyDown(keyCode: fn, flags: [.function]))
        #expect(!SettingsStore.isKeyDown(keyCode: fn, flags: []))
    }

    @Test("未知の keyCode は押下と判定しない")
    func unknownKeyCode() {
        #expect(!SettingsStore.isKeyDown(keyCode: 0, flags: [.option, .command]))
    }

    // MARK: - 複数修飾キー（Issue #115）

    @Test("allKeysDown は全部揃ったときだけ true")
    func allKeysDownRequiresEvery() {
        let combo = [leftShift, leftCommand]
        #expect(!SettingsStore.allKeysDown(combo, flags: [.shift]))
        #expect(SettingsStore.allKeysDown(combo, flags: [.shift, .command]))
    }

    @Test("allKeysDown は空の集合を false にする（設定が壊れても全押しにしない）")
    func allKeysDownRejectsEmpty() {
        #expect(!SettingsStore.allKeysDown([], flags: [.shift, .command]))
    }

    @Test("anyKeyDown は 1 つでも押されていれば true（「全部離した」の検出に使う）")
    func anyKeyDownDetectsRemaining() {
        let combo = [leftShift, leftCommand]
        #expect(SettingsStore.anyKeyDown(combo, flags: [.shift]))
        #expect(!SettingsStore.anyKeyDown(combo, flags: []))
    }

    /// 押した順で保存すると同じ組み合わせが別の値・別の表示になり、監視の張り直しまで起きる。
    @Test("canonicalModifiers は押した順によらず ⌃ ⌥ ⇧ ⌘ fn の並びに揃える")
    func canonicalOrder() {
        let pressedOrder = [leftCommand, leftShift]      // ⌘ → ⇧ の順に押した
        let reverseOrder = [leftShift, leftCommand]      // ⇧ → ⌘ の順に押した
        #expect(SettingsStore.canonicalModifiers(pressedOrder)
                == SettingsStore.canonicalModifiers(reverseOrder))
        #expect(SettingsStore.canonicalModifiers(pressedOrder) == [leftShift, leftCommand])
    }

    @Test("canonicalModifiers は重複と未知のキーを落とす")
    func canonicalDropsDuplicatesAndUnknown() {
        #expect(SettingsStore.canonicalModifiers([leftShift, leftShift, 0]) == [leftShift])
    }
}
