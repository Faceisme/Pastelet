import Foundation

/// 面板内部键盘导航通知（控制器 → 视图，解耦 SwiftUI 焦点系统的限制）
extension Notification.Name {
    static let pasteletNavLeft   = Notification.Name("pastelet.nav.left")
    static let pasteletNavRight  = Notification.Name("pastelet.nav.right")
    static let pasteletNavDelete = Notification.Name("pastelet.nav.delete")
    static let pasteletNavUndoDelete = Notification.Name("pastelet.nav.undoDelete")
    static let pasteletNavSelect = Notification.Name("pastelet.nav.select")
    static let pasteletNavEscape = Notification.Name("pastelet.nav.escape")
    static let pasteletNavScroll = Notification.Name("pastelet.nav.scroll")
    static let pasteletNavStartSearch = Notification.Name("pastelet.nav.startSearch")
    static let pasteletNavTypeSearch = Notification.Name("pastelet.nav.typeSearch")
    static let pasteletNavCancelSearch = Notification.Name("pastelet.nav.cancelSearch")
    static let pasteletPanelResetState = Notification.Name("pastelet.panel.resetState")
}
