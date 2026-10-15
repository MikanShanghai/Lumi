import SwiftUI
import AetherEngine

struct PlayerView: View {
    @ObservedObject var session: PlaybackSession
    @EnvironmentObject var app: AppModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(engine: session.engine)
                .ignoresSafeArea()

            if !session.statusText.isEmpty {
                Text(session.statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(spacing: 0) {
                if showControls {
                    topBar.transition(.opacity)
                }
                Spacer(minLength: 0)
                if showControls {
                    ControlBar(
                        session: session,
                        onClose: { app.closePlayer() },
                        onFullScreen: { app.toggleFullScreen() }
                    )
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                        .transition(.opacity)
                        // 鼠标停在控制层上时保持可见（否则想点按钮时会自己消失）
                        .onContinuousHover { phase in
                            switch phase {
                            case .active: keepControlsVisible()
                            case .ended: scheduleHide()
                            }
                        }
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onAppear { revealControls() }
        .onDisappear { hideTask?.cancel() }
        .background(
            Group {
                Button("") { app.closePlayer() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("") { session.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { session.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { session.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { app.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                app.closePlayer()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                    Text("返回")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)

            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Spacer()

            Text("Esc 退出 · 空格 播放/暂停")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    private func revealControls() {
        if !showControls {
            withAnimation(.lumiStandard) { showControls = true }
        }
        scheduleHide()
    }

    /// 悬停在控制层上：保持可见，取消隐藏计时。
    private func keepControlsVisible() {
        if !showControls {
            withAnimation(.lumiStandard) { showControls = true }
        }
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showControls = false }
        }
    }
}

// MARK: - 控制层

struct ControlBar: View {
    @ObservedObject var session: PlaybackSession
    var onClose: () -> Void
    var onFullScreen: () -> Void

    private let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 4) {
            ScrubberView(session: session)
            HStack(spacing: 12) {
                iconButton("gobackward.10") { session.skip(by: -10) }

                Button(action: { session.togglePlay() }) {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white))
                }
                .buttonStyle(.plain)

                iconButton("goforward.10") { session.skip(by: 10) }

                Text(session.timeText)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.88))

                Spacer()

                if !session.sourceLabel.isEmpty {
                    Text(session.sourceLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }

                rateMenu

                if !session.subtitleTracks.isEmpty { subtitleMenu }
                if session.audioTracks.count > 1 { audioMenu }

                iconButton("arrow.up.left.and.arrow.down.right") { onFullScreen() }
                iconButton("xmark") { onClose() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    // MARK: 小组件

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(0.12)))
    }

    private func rateLabel(_ rate: Float) -> String {
        String(format: rate == rate.rounded() ? "%.0f×" : "%.2f×", rate)
    }

    private var rateMenu: some View {
        Menu {
            ForEach(rates, id: \.self) { value in
                Button {
                    session.setRate(value)
                } label: {
                    if abs(session.rate - value) < 0.01 {
                        Label(rateLabel(value), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(value))
                    }
                }
            }
        } label: {
            pill(rateLabel(session.rate))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var subtitlePillText: String {
        guard let index = session.activeSubtitleIndex,
              let track = session.subtitleTracks.first(where: { $0.id == index }) else {
            return "字幕"
        }
        if let language = track.language, !language.isEmpty { return "字幕 · \(language)" }
        return "字幕 ✓"
    }

    private var subtitleMenu: some View {
        Menu {
            Button("关闭字幕") { session.clearSubtitle() }
            Divider()
            ForEach(Array(session.subtitleTracks.enumerated()), id: \.element.id) { offset, track in
                Button {
                    session.selectSubtitle(track.id)
                } label: {
                    if session.activeSubtitleIndex == track.id {
                        Label(trackLabel(track, fallback: offset), systemImage: "checkmark")
                    } else {
                        Text(trackLabel(track, fallback: offset))
                    }
                }
            }
        } label: {
            pill(subtitlePillText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var audioMenu: some View {
        Menu {
            ForEach(Array(session.audioTracks.enumerated()), id: \.element.id) { offset, track in
                Button {
                    session.selectAudio(track.id)
                } label: {
                    if session.activeAudioIndex == track.id {
                        Label(trackLabel(track, fallback: offset), systemImage: "checkmark")
                    } else {
                        Text(trackLabel(track, fallback: offset))
                    }
                }
            }
        } label: {
            pill("音轨")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func trackLabel(_ track: TrackInfo, fallback: Int) -> String {
        var parts: [String] = []
        if !track.name.isEmpty, track.name != "?" { parts.append(track.name) }
        if let language = track.language, !language.isEmpty { parts.append(language) }
        if parts.isEmpty { parts.append("轨道 \(fallback + 1)") }
        if !track.codec.isEmpty { parts.append(track.codec.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

/// 进度条：拖动即 1:1 跟手，松手提交 seek；悬停时轨道变粗、出现白色圆点。
/// 悬停/拖动时在上方弹出画面预览（按 5 秒分桶缓存，220ms 防抖）。
struct ScrubberView: View {
    @ObservedObject var session: PlaybackSession
    @State private var hovering = false
    @State private var hoverRatio: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let display = session.isScrubbing ? session.scrubTime : session.currentTime
            let ratio = session.duration > 0 ? min(max(display / session.duration, 0), 1) : 0
            let barHeight: CGFloat = (hovering || session.isScrubbing) ? 6 : 4
            let previewRatio = session.isScrubbing ? ratio : hoverRatio
            let previewSeconds = previewRatio * session.duration

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.20))
                    .frame(height: barHeight)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * ratio, height: barHeight)
                if hovering || session.isScrubbing {
                    Circle()
                        .fill(.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: width * ratio - 6.5)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard session.duration > 0 else { return }
                        session.isScrubbing = true
                        let target = min(max(value.location.x / width, 0), 1) * session.duration
                        session.scrubTime = target
                        session.requestPreview(at: target)
                    }
                    .onEnded { value in
                        guard session.duration > 0 else { return }
                        let target = min(max(value.location.x / width, 0), 1) * session.duration
                        session.seek(to: target)
                        session.isScrubbing = false
                    }
            )
            // 预览浮窗放在 overlay 里：offset 只影响绘制，不参与布局，
            // 不会像放进 ZStack 那样把进度条整体撑开推下去。
            .overlay(alignment: .topLeading) {
                if (hovering || session.isScrubbing), session.duration > 0 {
                    scrubPreview(seconds: previewSeconds)
                        .offset(
                            x: min(max(width * previewRatio - 86, 0), max(width - 172, 0)),
                            y: -118
                        )
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = true
                    let ratio = min(max(location.x / width, 0), 1)
                    hoverRatio = ratio
                    if session.duration > 0, !session.isScrubbing {
                        session.requestPreview(at: ratio * session.duration)
                    }
                case .ended: hovering = false
                    session.clearPreview()
                }
            }
        }
        .frame(height: 22)
    }

    private func scrubPreview(seconds: Double) -> some View {
        VStack(spacing: 3) {
            ZStack {
                if let image = session.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if session.previewUnavailable {
                    Rectangle().fill(.black.opacity(0.5))
                    Text("无预览")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Rectangle().fill(.black.opacity(0.5))
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(PlaybackSession.format(seconds))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(6)
        .frame(width: 172)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .allowsHitTesting(false)
    }
}

