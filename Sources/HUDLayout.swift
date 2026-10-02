import SwiftUI
import AppKit

// MARK: - 表示設定（Issue #35）

/// HUD を出す位置。マルチディスプレイでは「キー入力を受けている画面」の中でこの位置に出す。
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCenter: return "画面下部中央"
        case .topCenter:    return "画面上部中央"
        }
    }
}

/// HUD の大きさ。**既存の「録音中に HUD を表示」トグルはこの選択に統合してある**
/// （設定を二重に持たない）。`.hidden` でも開始音・停止音は鳴り、
/// 挿入できなかった／確認できなかった結果だけは出す（結果を失わせない）。
///
/// 以前は波形とボタンを常に並べる「通常」もあったが、最小表示の作り直し（#180〜#204）に
/// 追従しておらず古く見えたので削除した（Issue #6）。
enum HUDSize: String, CaseIterable, Identifiable {
    case minimal
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minimal: return "最小"
        case .hidden:  return "非表示"
        }
    }

    /// 保存値から読む。削除した「通常」（`normal`）は「最小」に読み替える。
    static func fromStored(_ raw: String) -> HUDSize? {
        raw == "normal" ? .minimal : HUDSize(rawValue: raw)
    }
}

/// HUD のパネルの大きさ。**ビューの frame とパネルの実サイズを 1 か所から導く**
/// （2 つがズレると、見えていない領域がクリックを食って背面アプリに届かなくなる）。
///
/// `RecordingHUDController` ではなくここに置くのは、`RecordingHUDModel` が
/// パネルの大きさを決めるのに Controller を逆参照していたため（Issue #65）。
enum HUDMetrics {
    /// 失敗・キャンセル確認のパネル（細いバーには理由が収まらない）。
    static let panelSize = CGSize(width: 340, height: 64)
    /// 最小表示（状態アイコン＋経過時間）の細いバー。
    ///
    /// 96×28 から横 1.5 倍・縦 1.2 倍にした（Issue #189）。«もう少し大きく» への対応。
    /// 角丸は高さの半分なので自動で追従する。
    static let minimalPanelSize = CGSize(width: 144, height: 34)
    /// 最小表示にマウスが乗って、停止・キャンセルが出ているときのサイズ。
    /// ボタン 2 つぶんの 60pt を足す（`minimalPanelSize` を大きくしても、ボタンの余白は変えない）。
    static let minimalHoverPanelSize = CGSize(width: 204, height: 34)
    /// 挿入結果を残しているときのサイズ（本文＋操作ボタンぶん高くする）。
    static let resultPanelSize = CGSize(width: 380, height: 160)
}
