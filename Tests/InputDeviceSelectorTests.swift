import Testing
@testable import sarari

/// 録音に使うマイクの選び方（Issue #94）。
struct InputDeviceSelectorTests {

    @Test("既定が Bluetooth なら内蔵マイクで録る（ヘッドホンを通話モードに入れない）")
    func bluetoothUsesBuiltIn() {
        #expect(InputDeviceSelector.shouldUseBuiltIn(defaultTransport: .bluetooth, builtInAvailable: true, lidClosed: false))
    }

    @Test("既定が Bluetooth 以外なら、既定のマイクのまま")
    func otherKeepsDefault() {
        #expect(!InputDeviceSelector.shouldUseBuiltIn(defaultTransport: .other, builtInAvailable: true, lidClosed: false))
    }

    @Test("蓋を閉じていると内蔵マイクは無音なので、Bluetooth でも差し替えない")
    func lidClosedKeepsDefault() {
        #expect(!InputDeviceSelector.shouldUseBuiltIn(defaultTransport: .bluetooth, builtInAvailable: true, lidClosed: true))
    }

    @Test("内蔵マイクが無い Mac では差し替えない")
    func noBuiltInKeepsDefault() {
        #expect(!InputDeviceSelector.shouldUseBuiltIn(defaultTransport: .bluetooth, builtInAvailable: false, lidClosed: false))
    }
}
