import AppKit

/// E2E テストの挿入先（Issue #126）。sarari 本体には入らない、テスト専用の小さなアプリ。
///
/// 起動引数:
///   `--field text`      … 複数行のテキスト欄（NSTextView）にフォーカスを置く
///   `--field password`  … パスワード欄（NSSecureTextField。AX では AXSecureTextField）に置く
///   `--out <path>`      … 欄の中身が変わるたびにこのファイルへ書き出す（テストはこれを読む）
///
/// 挿入は ⌘V で届くので、sarari とは別のプロセスにして最前面に出す。同じプロセスに窓を持つと、
/// sarari が挿入先を AX で読むときに自分自身へ問い合わせることになり、メインスレッドで固まる。
final class HostDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let outURL: URL
    private let usesPassword: Bool

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        usesPassword = value(after: "--field") == "password"
        outURL = URL(fileURLWithPath: value(after: "--out") ?? NSTemporaryDirectory() + "sarari-e2e-out.txt")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "sarari E2E"
        write("")

        if usesPassword {
            let field = NSSecureTextField(frame: NSRect(x: 20, y: 80, width: 440, height: 24))
            field.delegate = self
            window.contentView?.addSubview(field)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
        } else {
            let textView = NSTextView(frame: NSRect(x: 20, y: 20, width: 440, height: 160))
            textView.delegate = self
            textView.isRichText = false
            window.contentView?.addSubview(textView)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        write(textView.string)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        write(field.stringValue)
    }

    private func write(_ text: String) {
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
let delegate = HostDelegate(arguments: CommandLine.arguments)
app.delegate = delegate

// ⌘V はメニューの「ペースト」を通って欄に届く。メニューが無いと何も起きない。
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editItem.submenu = editMenu
mainMenu.addItem(NSMenuItem())
mainMenu.addItem(editItem)
app.mainMenu = mainMenu
app.setActivationPolicy(.regular)
app.run()
