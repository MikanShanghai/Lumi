import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(VisualEffectView(material: .underWindowBackground, blending: .behindWindow))

            if let session = app.playback {
                PlayerView(session: session)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { app.lastError != nil },
            set: { if !$0 { app.lastError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(app.lastError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.route {
        case .library: LibraryView()
        case .netdisk: NetdiskView()
        case .settings: SettingsView()
        }
    }
}
