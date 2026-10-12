import Testing

/// NSApplication・WindowServer・MainActorを共有するアプリ側のテスト。
/// MainActorはawait中に別テストを始められるため、個々のSuiteの.serializedだけでは
/// シートの同期アニメーションやWebKitの描画とAIの非同期処理が競合する。
/// 共通の親で実行順を決め、各ケースの時間制限が始まる前に順番を待つ。
/// Core・CLI・音声処理など、この親に属さないテストは既定どおり並列に実行する。
@Suite(.serialized) struct AppKitTests {}
