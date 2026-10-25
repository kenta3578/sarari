import AppKit
import Testing
@testable import sarari

/// 挿入先の照合をやめても（Issue #116）、送ってはいけない場所へは送らないこと。
///
/// 守るのはパスワード欄・Secure Keyboard Entry（Issue #104）とアクセシビリティ権限なし。
/// どちらも ⌘V を送らずに `.failed` を返す。パスワード欄の経路だけはクリップボードにも残さない。
@MainActor
struct TextInjectorGuardTests {

    private final class Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sarari.tests.\(UUID().uuidString)"))
        var secureReason: String?
        var trusted = true
        /// ⌘V を送った回数。
        var delivered = 0

        @MainActor
        func makeInjector() -> TextInjector {
            TextInjector(environment: TextInjector.Environment(
                pasteboard: pasteboard,
                isAccessibilityTrusted: { [self] in trusted },
                secureInputReason: { [self] in secureReason },
                deliver: { [self] _ in
                    delivered += 1
                    return .succeeded
                },
                // 失敗したらクリップボードに残す設定。パスワード欄ではそれでも残さないことを見る。
                keepResultOnFailure: { true },
                restoreDelay: .zero
            ))
        }

        func copy(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        var current: String? { pasteboard.string(forType: .string) }

        deinit { pasteboard.releaseGlobally() }
    }

    @Test("パスワード欄・Secure Keyboard Entry では送らず、クリップボードにも残さない")
    func secureInputIsNotDelivered() async {
        for reason in ["パスワード欄には入力しません", "Secure Keyboard Entry が有効なため入力できません"] {
            let h = Harness()
            h.secureReason = reason
            h.copy("元のコピー")

            let outcome = await h.makeInjector().insert("口述")

            #expect(outcome == .failed(reason: reason, hint: .secureInput))
            #expect(h.delivered == 0)
            #expect(h.current == "元のコピー")
        }
    }

    @Test("アクセシビリティ権限が無ければ送らず、設定で残すなら結果をクリップボードに置く")
    func untrustedIsNotDelivered() async {
        let h = Harness()
        h.trusted = false
        h.copy("元のコピー")

        let outcome = await h.makeInjector().insert("口述")

        #expect(outcome.isFailure)
        #expect(outcome.hint == .accessibilityPermission)
        #expect(h.delivered == 0)
        #expect(h.current == "口述")
    }

    @Test("どちらにも当たらなければ、そのとき前面にある場所へ送る")
    func otherwiseDelivered() async {
        let h = Harness()

        let outcome = await h.makeInjector().insert("口述")

        #expect(outcome == .succeeded)
        #expect(h.delivered == 1)
    }
}
