import Foundation
import WebKit
import ObjectiveC

/// 議事録ペインのpreferencesだけで60Hz優先を外す。Safariや永続設定には触れない。
/// 非公開APIの廃止・名前変更・型変更はすべて未対応として扱う。KVCは使わない。
/// 正本: docs/minutes-rendering.md「画面の更新頻度」
enum MinutesRenderingPreferences {
    static let near60FPSKey = "PreferPageRenderingUpdatesNear60FPSEnabled"

    /// 戻り値は適用後の値。nilはAPIまたはfeatureがなく、何も変更しなかった場合。
    /// featuresClassとpreferencesは、APIがないOSをテストで再現するため差し替えられる。
    @discardableResult
    static func setNear60FPS(_ value: Bool, on preferences: NSObject,
                             featuresClass: AnyClass = WKPreferences.self) -> Bool? {
        accessNear60FPS(value, on: preferences, featuresClass: featuresClass)
    }

    static func near60FPS(on preferences: NSObject) -> Bool? {
        accessNear60FPS(nil, on: preferences, featuresClass: WKPreferences.self)
    }

    private static func accessNear60FPS(_ value: Bool?, on preferences: NSObject, featuresClass: AnyClass) -> Bool? {
        let listSelector = NSSelectorFromString("_features")
        let keySelector = NSSelectorFromString("key")
        let getSelector = NSSelectorFromString("_isEnabledForFeature:")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard let list = class_getClassMethod(featuresClass, listSelector),
              matches(list, returns: ["@"], arguments: []),
              let get = class_getInstanceMethod(type(of: preferences), getSelector),
              matches(get, returns: ["B", "c"], arguments: [["@"]]),
              let set = class_getInstanceMethod(type(of: preferences), setSelector),
              matches(set, returns: ["v"], arguments: [["B", "c"], ["@"]]) else { return nil }

        typealias List = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias Key = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        typealias Get = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        typealias Set = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let listFeatures = unsafeBitCast(method_getImplementation(list), to: List.self)
        guard let features = listFeatures(featuresClass, listSelector)?.takeUnretainedValue() as? [NSObject] else { return nil }
        for feature in features {
            guard let key = class_getInstanceMethod(type(of: feature), keySelector),
                  matches(key, returns: ["@"], arguments: []) else { continue }
            let readKey = unsafeBitCast(method_getImplementation(key), to: Key.self)
            guard readKey(feature, keySelector)?.takeUnretainedValue() as? String == near60FPSKey else { continue }
            let write = unsafeBitCast(method_getImplementation(set), to: Set.self)
            let read = unsafeBitCast(method_getImplementation(get), to: Get.self)
            if let value { write(preferences, setSelector, value, feature) }
            return read(preferences, getSelector, feature)
        }
        return nil
    }

    /// IMPを呼ぶ前に引数数とABIを確認する。将来同じselectorの型が変わっても呼ばない。
    private static func matches(_ method: Method, returns: Set<String>, arguments: [Set<String>]) -> Bool {
        func encoding(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
            guard let pointer else { return "" }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        guard method_getNumberOfArguments(method) == UInt32(arguments.count + 2),
              returns.contains(encoding(method_copyReturnType(method))),
              ["@", "#"].contains(encoding(method_copyArgumentType(method, 0))),
              encoding(method_copyArgumentType(method, 1)) == ":" else { return false }
        return arguments.enumerated().allSatisfy { index, allowed in
            allowed.contains(encoding(method_copyArgumentType(method, UInt32(index + 2))))
        }
    }
}
