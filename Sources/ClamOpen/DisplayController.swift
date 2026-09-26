import CoreGraphics
import Foundation

/// 封装对内置 / 外接显示器的启用、禁用与查询。
///
/// 通过 CoreGraphics 私有符号 `CGSConfigureDisplayEnabled` 真正关闭内置面板
/// （停止渲染 + 关闭背光），效果等同合盖（clamshell），但盖子保持打开。
final class DisplayController {

    /// CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
    typealias ConfigureDisplayEnabledFn =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// CGError CGSGetDisplayList(uint32_t max, CGDirectDisplayID *list, uint32_t *count)
    /// 与 CGGetOnlineDisplayList 不同，它也会列出被禁用的显示器
    typealias GetDisplayListFn =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private let configureEnabled: ConfigureDisplayEnabledFn?
    private let getDisplayList: GetDisplayListFn?

    /// 最近一次见到的内置屏 ID（兜底：禁用后枚举不到时仍能恢复）
    private var lastBuiltinID: CGDirectDisplayID?

    init() {
        // RTLD_DEFAULT (== -2)：符号随 CoreGraphics 已载入本进程，直接取即可
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(rtldDefault, "CGSConfigureDisplayEnabled") {
            configureEnabled = unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
        } else {
            configureEnabled = nil
        }
        getDisplayList = dlsym(rtldDefault, "CGSGetDisplayList")
            .map { unsafeBitCast($0, to: GetDisplayListFn.self) }
    }

    /// 私有 API 是否可用（理论上所有现代 macOS 都可用）
    var isAPIAvailable: Bool { configureEnabled != nil }

    // MARK: - 查询

    func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 所有显示器，包括被 CGSConfigureDisplayEnabled 禁用的。
    /// Apple Silicon 上内置屏被禁用后会从 online 列表中消失，只能从这里找回。
    func allDisplays() -> [CGDirectDisplayID] {
        guard let getDisplayList else { return onlineDisplays() }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else { return onlineDisplays() }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayList(count, &ids, &count) == .success else { return onlineDisplays() }
        return Array(ids.prefix(Int(count)))
    }

    /// 在线的内置屏（可被关闭的那个）
    func builtinDisplay() -> CGDirectDisplayID? {
        let id = onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
        if let id { lastBuiltinID = id }
        return id
    }

    /// 内置屏 ID，即使当前已被禁用（用于恢复）
    private func builtinDisplayIncludingDisabled() -> CGDirectDisplayID? {
        if let id = builtinDisplay() { return id }
        if let id = allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            lastBuiltinID = id
            return id
        }
        return lastBuiltinID
    }

    /// 在线的外接显示器（非内置）
    func externalDisplays() -> [CGDirectDisplayID] {
        onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
    }

    func hasExternalDisplay() -> Bool { !externalDisplays().isEmpty }

    /// 内置屏当前是否处于活动（渲染）状态
    func isBuiltinActive() -> Bool {
        guard let b = builtinDisplay() else { return false }
        return CGDisplayIsActive(b) != 0
    }

    // MARK: - 操作结果

    enum Result: Equatable {
        case ok
        case apiMissing
        case noBuiltin
        case noExternal           // 安全拦截：没有外接显示器，拒绝关闭内置（否则全黑无法操作）
        case beginFailed(Int32)
        case configureFailed(Int32)
        case completeFailed(Int32)

        var isSuccess: Bool { self == .ok }

        var message: String {
            switch self {
            case .ok:                   return tr("Success", "成功")
            case .apiMissing:           return tr("This API is not supported on this system", "当前系统不支持该接口")
            case .noBuiltin:            return tr("No internal display found", "未找到内置显示器")
            case .noExternal:           return tr("No external display — refused (the screen would go black)", "没有外接显示器，已拒绝（否则会全黑）")
            case .beginFailed(let e):   return tr("Failed to begin configuration (CGError \(e))", "开始配置失败 (CGError \(e))")
            case .configureFailed(let e): return tr("Failed to configure display (CGError \(e))", "设置失败 (CGError \(e))")
            case .completeFailed(let e):  return tr("Failed to apply configuration (CGError \(e))", "应用配置失败 (CGError \(e))")
            }
        }
    }

    // MARK: - 操作

    /// 关闭内置屏。**仅当存在在线外接显示器时**才会执行，否则返回 `.noExternal`。
    @discardableResult
    func disableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        guard let builtin = builtinDisplay() else { return .noBuiltin }
        guard hasExternalDisplay() else { return .noExternal }
        return apply(fn, display: builtin, enabled: false)
    }

    /// 恢复内置屏（也能找回已被禁用、不在 online 列表中的内置屏）
    @discardableResult
    func enableBuiltin() -> Result {
        guard let fn = configureEnabled else { return .apiMissing }
        if isBuiltinActive() { return .ok }
        guard let builtin = builtinDisplayIncludingDisabled() else { return .noBuiltin }
        return apply(fn, display: builtin, enabled: true)
    }

    private func apply(_ fn: ConfigureDisplayEnabledFn,
                       display: CGDirectDisplayID,
                       enabled: Bool) -> Result {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin != .success { return .beginFailed(begin.rawValue) }

        let e = fn(config, display, enabled)
        if e != .success {
            CGCancelDisplayConfiguration(config)
            return .configureFailed(e.rawValue)
        }

        // .forSession：当前登录会话内持久（App 退出后仍生效），注销/重启自动恢复 —— 最安全
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        if complete != .success { return .completeFailed(complete.rawValue) }
        return .ok
    }
}
