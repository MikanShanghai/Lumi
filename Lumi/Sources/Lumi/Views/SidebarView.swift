import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 34)
                .padding(.bottom, 16)
            sectionLabel("媒体库")
            navItem(.library)
            sectionLabel("来源")
            navItem(.netdisk)
            Spacer(minLength: 12)
            navItem(.settings)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: Theme.sidebarWidth, alignment: .leading)
        .background(VisualEffectView(material: .sidebar, blending: .behindWindow))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255),
                                 Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 5, y: 2)
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            Text("Lumi")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func navItem(_ route: Route) -> some View {
        Button {
            withAnimation(.lumiStandard) { app.route = route }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: route.symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .foregroundStyle(app.route == route ? Theme.accent : Color.secondary)
                Text(route == .netdisk ? "百度网盘" : route.rawValue)
                    .font(.system(size: 13, weight: app.route == route ? .semibold : .regular))
                Spacer()
                if route == .netdisk && app.baidu.loginState == .connected {
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: Theme.green.opacity(0.8), radius: 3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(app.route == route ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(app.route == route ? .primary : .secondary)
    }
}
