import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var keyField = ""
    @State private var secretField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 12) {
                Text("百度网盘凭证")
                    .font(.system(size: 14, weight: .semibold))
                Text("保存于 ~/Library/Application Support/Lumi/config.json（仅本机，权限 600）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("新的 AppKey（留空则不变）", text: $keyField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                SecureField("新的 SecretKey（留空则不变）", text: $secretField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button("保存") {
                        guard !keyField.isEmpty, !secretField.isEmpty else { return }
                        app.baidu.saveCredentials(appKey: keyField, appSecret: secretField)
                        keyField = ""; secretField = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    Button("断开网盘连接") { app.baidu.disconnect() }
                        .buttonStyle(.bordered)
                }
                Divider().padding(.vertical, 6).frame(maxWidth: 420)
                Text("播放内核：探路版使用系统 AVPlayer；下一步切换 AetherEngine（HDR / 杜比视界 / ASS 字幕 / 全格式）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
