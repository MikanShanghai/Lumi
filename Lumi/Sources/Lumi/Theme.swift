import SwiftUI

enum Theme {
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    static let sidebarWidth: CGFloat = 236
}

extension Animation {
    /// 默认弹簧：无过冲（damping 1.0 / response 0.4，Apple「移动/重定位」参数）
    static let lumiStandard = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// 带动量的浮层/面板（damping 0.8 / response 0.3，Apple「抽屉/表单」参数）
    static let lumiSheet = Animation.spring(response: 0.3, dampingFraction: 0.8)
}
