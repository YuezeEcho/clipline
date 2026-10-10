import SwiftUI

struct ClipboardView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var history: ClipboardHistory
    let gust: Int

    var body: some View {
        GeometryReader { geo in
            if history.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 24, weight: .light))
                    Text(history.isTracking ? C("Copy text or an image to hang it here", "复制文字或图片，就会挂在这里")
                         : C("Clipboard recording is paused", "剪贴板记录已暂停"))
                        .font(.system(size: 13))
                    Text(C("Up to 100 items · cleared when you quit", "最近 100 条 · 退出后清空"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 24) {
                            ForEach(history.entries) { entry in
                                HangingCard(screenWidth: geo.size.width) {
                                    ClipboardCard(entry: entry, history: history, gust: gust)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, Layout.ropeTop - Layout.pinAbove)
                        .frame(minWidth: geo.size.width, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: history.entries.first?.id) { _, id in
                        if let id {
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .leading) }
                        }
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ClipboardViewportKey.self,
                                           value: g.frame(in: .named("line")))
                })
            }
        }
        .onPreferenceChange(ClipboardViewportKey.self) { rect in
            MainActor.assumeIsolated { history.interactionRect = rect }
        }
        .onPreferenceChange(ClipboardHitRectsKey.self) { rects in
            MainActor.assumeIsolated { history.hitRects = rects }
        }
    }
}

private struct ClipboardCard: View {
    @ObservedObject private var language = AppLanguage.shared
    let entry: ClipboardHistory.Entry
    @ObservedObject var history: ClipboardHistory
    let gust: Int
    @State private var hovering = false
    @State private var swing: Double = 0
    @State private var arrived = false
    private var copied: Bool { history.copiedID == entry.id }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin().zIndex(1)
            ZStack(alignment: .topTrailing) {
                Button {
                    if !history.copy(entry.id) { NSSound.beep() }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        preview.frame(height: 68, alignment: .topLeading)
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : symbol)
                            Text(copied ? C("Copied", "已复制") : sourceName)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Color.accentColor : Color.secondary)
                    }
                    .padding(12)
                    .frame(width: 150, height: 116, alignment: .topLeading)
                    .glassFrame(cornerRadius: 16)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint(C("Copy this item to the clipboard", "将此条目复制到剪贴板"))
                .contextMenu {
                    Button(C("Copy", "复制")) { history.copy(entry.id) }
                    Button(C("Remove from history", "从历史中移除")) { history.remove(entry.id) }
                }
                if hovering {
                    Button { history.remove(entry.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 20, height: 20)
                            .glassFrame(circle: true)
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help(C("Remove from history", "从历史中移除"))
                    .accessibilityLabel(C("Remove from history", "从历史中移除"))
                }
            }
            .shadow(color: .black.opacity(0.16), radius: hovering ? 12 : 7, y: 5)
            .scaleEffect(hovering ? 1.025 : 1, anchor: .top)
            .onHover { hovering = $0 }
            .background(GeometryReader { g in
                Color.clear.preference(key: ClipboardHitRectsKey.self,
                                       value: [entry.id: g.frame(in: .named("line"))])
            })
        }
        .rotationEffect(.degrees(entry.tilt + swing), anchor: .top)
        .offset(y: arrived ? 0 : -28)
        .opacity(arrived ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
        .onAppear {
            swing = 12
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { arrived = true }
            withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
        }
        .onChange(of: gust) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0...0.35)) {
                nudge(Double.random(in: 1.6...3.4))
            }
        }
        .onChange(of: copied) { _, value in
            if value { nudge(3) }
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }

    @ViewBuilder private var preview: some View {
        switch entry.content {
        case .text(let text):
            Text(String(text.prefix(400)))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        case .image(_, let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var symbol: String {
        switch entry.content {
        case .text: return "text.alignleft"
        case .image: return "photo"
        }
    }

    private var sourceName: String {
        entry.source.isEmpty || entry.source == "Clipboard" ? C("Clipboard", "剪贴板", "剪貼簿") : entry.source
    }

    private var accessibilitySummary: String {
        switch entry.content {
        case .text(let text): return String(text.prefix(200))
        case .image: return C("Image from ", "图片，来源：") + sourceName
        }
    }
}

private struct ClipboardViewportKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct ClipboardHitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
