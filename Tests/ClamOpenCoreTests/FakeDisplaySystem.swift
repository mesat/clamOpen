import CoreGraphics
@testable import ClamOpenCore

/// 模拟的显示系统，复现真实硬件上观察到的行为：
/// - Apple Silicon：被禁用的显示器从 online 列表中消失，只能通过 CGSGetDisplayList 找回
/// - Intel：被禁用的显示器仍在 online 列表中，但不再 active
/// - 合盖：内置屏离线（但仍被 CGSGetDisplayList 列出）
final class FakeDisplaySystem: DisplaySystem {

    enum Arch { case appleSilicon, intel }

    struct Display {
        var builtin: Bool
        var connected = true
        var enabled = true
    }

    static let builtinID: CGDirectDisplayID = 1
    static let externalID: CGDirectDisplayID = 2
    static let secondExternalID: CGDirectDisplayID = 3

    var arch: Arch
    var displays: [CGDirectDisplayID: Display] = [:]
    var lidClosed = false
    var canConfigure = true
    /// CGSGetDisplayList 是否可用
    var supportsFullList = true
    /// 预设的 setEnabled 失败结果，按顺序消耗；为空时成功
    var queuedFailures: [DisplayController.Result] = []
    /// 所有 setEnabled 调用记录
    private(set) var calls: [(id: CGDirectDisplayID, enabled: Bool)] = []

    init(arch: Arch = .appleSilicon, hasBuiltin: Bool = true, externals: Int = 1) {
        self.arch = arch
        if hasBuiltin { displays[Self.builtinID] = Display(builtin: true) }
        if externals >= 1 { displays[Self.externalID] = Display(builtin: false) }
        if externals >= 2 { displays[Self.secondExternalID] = Display(builtin: false) }
    }

    // MARK: - 场景操作

    func plug(_ id: CGDirectDisplayID = externalID) {
        displays[id] = Display(builtin: false)
    }

    func unplug(_ id: CGDirectDisplayID = externalID) {
        displays[id]?.connected = false
    }

    /// Intel 偶发：系统自行把被禁用的内置屏重新点亮
    func spontaneouslyWakeBuiltin() {
        displays[Self.builtinID]?.enabled = true
    }

    /// 模拟“上次运行时关闭了内置屏”（App 重启后丢失意图）
    func setBuiltinDisabledExternally() {
        displays[Self.builtinID]?.enabled = false
    }

    var builtinEnabled: Bool { displays[Self.builtinID]?.enabled ?? false }

    func resetCalls() { calls.removeAll() }

    // MARK: - DisplaySystem

    private func isOnline(_ id: CGDirectDisplayID) -> Bool {
        guard let d = displays[id], d.connected else { return false }
        if d.builtin && lidClosed { return false }
        return arch == .intel || d.enabled
    }

    func onlineDisplays() -> [CGDirectDisplayID] {
        displays.keys.sorted().filter(isOnline)
    }

    func allDisplays() -> [CGDirectDisplayID]? {
        guard supportsFullList else { return nil }
        return displays.keys.sorted().filter { displays[$0]!.connected }
    }

    func isBuiltin(_ id: CGDirectDisplayID) -> Bool { displays[id]?.builtin ?? false }

    func isActive(_ id: CGDirectDisplayID) -> Bool {
        isOnline(id) && (displays[id]?.enabled ?? false)
    }

    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> DisplayController.Result {
        calls.append((id, enabled))
        guard canConfigure else { return .apiMissing }
        if !queuedFailures.isEmpty { return queuedFailures.removeFirst() }
        guard displays[id]?.connected == true else { return .configureFailed(1001) }
        displays[id]?.enabled = enabled
        return .ok
    }
}
