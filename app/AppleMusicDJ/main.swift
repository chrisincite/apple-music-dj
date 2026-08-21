import AppKit
import SwiftUI

// MARK: - 介面狀態

@MainActor
final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var tab = 0            // 0 = 接下來, 1 = 剛剛播過
    @Published var vibeDraft = ""
    @Published var flash: String?

    func showFlash(_ s: String) {
        flash = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.flash == s { self?.flash = nil }
        }
    }
}

// MARK: - 元件

struct FeedbackButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 46, height: 30)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(hover ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct PanelView: View {
    @ObservedObject var e: Engine
    @ObservedObject var ui: UIState
    @FocusState private var vibeFocused: Bool

    private var t: Track? { e.track }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            if ui.expanded { expandedSection }
        }
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            if let f = ui.flash {
                Text(f)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .foregroundStyle(.white)
                    .padding(.bottom, 9)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: ui.flash)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 11) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(t?.name ?? "沒有在播")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(t?.artist ?? (e.enabled ? "等待 DJ 排歌…" : "還沒設定氛圍"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                progress
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                iconButton("xmark", 9) { NSApp.terminate(nil) }
                iconButton(ui.expanded ? "chevron.up" : "chevron.down", 9) {
                    if ui.expanded { vibeFocused = false }
                    withAnimation(.easeOut(duration: 0.16)) { ui.expanded.toggle() }
                }
            }
        }
        .padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 10)
    }

    private var controls: some View {
        HStack(spacing: 7) {
            FeedbackButton(symbol: "hand.thumbsup", help: "更多這種") {
                e.thumbsUp(); ui.showFlash("👍 之後多排這種"); returnFocus()
            }
            FeedbackButton(symbol: "hand.thumbsdown", help: "不要這首，並少排這類") {
                e.thumbsDown(); ui.showFlash("👎 已封鎖並跳過"); returnFocus()
            }
            FeedbackButton(symbol: "plus", help: "存進「🎧 DJ 精選」") {
                e.keep(); ui.showFlash("＋ 已存入精選"); returnFocus()
            }
            FeedbackButton(symbol: "forward.end", help: "跳過") {
                e.skip(); ui.showFlash("⏭ 跳過"); returnFocus()
            }
            Spacer()
            Circle().fill(e.enabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(e.vibe.isEmpty ? "未設定氛圍" : e.vibe)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 13).padding(.bottom, ui.expanded ? 10 : 12)
    }

    private var artwork: some View {
        Group {
            if let a = e.artwork {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.2))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var progress: some View {
        GeometryReader { g in
            let frac = (t?.duration ?? 0) > 0 ? min(1, (t!.position) / t!.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13))
                Capsule().fill(Color.primary.opacity(0.55)).frame(width: g.size.width * frac)
            }
        }
        .frame(height: 3).padding(.top, 2)
    }

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("換個氛圍…例如「深夜寫程式」", text: $ui.vibeDraft)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .focused($vibeFocused)
                    .onSubmit { submitVibe() }
                    // 這個面板平常刻意不搶焦點（按 👍 不會打斷你手上的工作），
                    // 但不搶焦點的 app 建立不了 text input context，中文輸入法會直接壞掉。
                    // 所以只在輸入框真的拿到焦點時才啟用 app，離開就還回去。
                    .onChange(of: vibeFocused) { focused in
                        // accessory app 不會因為點擊自動變成作用中，
                        // 不作用中就沒有 text input context，輸入法接不上。
                        if focused { NSApp.activate(ignoringOtherApps: true) }
                        else { NSApp.deactivate() }
                    }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))

            Picker("", selection: $ui.tab) {
                Text("接下來").tag(0)
                Text("剛剛播過").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if ui.tab == 0 {
                        if e.queue.isEmpty { emptyNote("佇列還空著") }
                        ForEach(Array(e.queue.enumerated()), id: \.offset) { i, q in
                            row(index: "\(i + 1)", name: q.name, artist: q.artist, trailing: nil)
                        }
                    } else {
                        if e.recent.isEmpty { emptyNote("還沒有播過的記錄") }
                        ForEach(Array(e.recent.enumerated()), id: \.offset) { _, r in
                            row(index: "↺", name: r.name, artist: r.artist, trailing: ago(r.at))
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 13).padding(.bottom, 12)
    }

    /// 按回饋鈕不該打斷手上的工作：做完就把作用中狀態還給原本那個 app。
    private func returnFocus() {
        guard !vibeFocused else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.deactivate() }
    }

    private func submitVibe() {
        let v = ui.vibeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        vibeFocused = false
        guard !v.isEmpty else { return }
        e.setVibe(v)
        ui.vibeDraft = ""
        ui.showFlash("氛圍已更新：\(v)")
    }

    private func row(index: String, name: String, artist: String,
                     trailing: String?) -> some View {
        HStack(spacing: 7) {
            Text(index).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 13, alignment: .trailing)
            Text(name).font(.system(size: 11)).lineLimit(1)
            Text(artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if let t = trailing {
                Spacer(minLength: 4)
                Text(t).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private func emptyNote(_ s: String) -> some View {
        Text(s).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.vertical, 6)
    }

    /// 把時間戳變成「3 分前」
    private func ago(_ at: Double) -> String {
        guard at > 0 else { return "" }
        let m = Int((Date().timeIntervalSince1970 - at) / 60)
        if m < 1 { return "剛剛" }
        if m < 60 { return "\(m) 分前" }
        return "\(m / 60) 小時前"
    }

    private func iconButton(_ s: String, _ size: CGFloat,
                            _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: s).font(.system(size: size, weight: .bold))
                .foregroundStyle(.secondary).frame(width: 16, height: 14)
        }.buttonStyle(.plain)
    }
}

// MARK: - 視窗

/// borderless NSPanel 預設 canBecomeKey = false，SwiftUI 的按鈕就收不到點擊。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 讓第一下點擊就直接作用；另外把視窗高度貼合 SwiftUI 內容，
/// 否則展開的清單會被固定高度裁掉。
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        guard let w = window else { return }
        let target = fittingSize
        guard target.height > 1, target.width > 1 else { return }
        let f = w.frame
        guard abs(f.height - target.height) > 0.5 || abs(f.width - target.width) > 0.5 else { return }
        // Cocoa 原點在左下，改高度要同步移原點，左上角才會待在原地
        var nf = f
        nf.origin.y += f.height - target.height
        nf.size = target
        w.setFrame(nf, display: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    let engine = Engine()
    let ui = UIState()

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = FirstMouseHostingView(rootView: PanelView(e: engine, ui: ui))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 108)

        // 不能用 .nonactivatingPanel：那樣點擊不會讓 app 變成作用中，
        // 鍵盤事件與輸入法都到不了輸入框。改用一般面板 + 按鈕按完主動還焦點。
        panel = FloatingPanel(contentRect: host.frame,
                              styleMask: [.borderless, .utilityWindow],
                              backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        // NSPanel 的 .utilityWindow 預設 hidesOnDeactivate = true：app 一失去
        // 作用中狀態面板就自己隱藏，配上「最後一個視窗關閉就結束」等於自動退出。
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 350, y: f.maxY - 130))
        }
        panel.orderFrontRegardless()

        // 第一次啟動、還沒設過氛圍 → 直接展開讓使用者輸入
        if engine.vibe.isEmpty { ui.expanded = true }
    }

    // 只有面板上的 ✕ 才結束 app；視窗被隱藏不該等於離開。
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

@main
struct DJPanelApp {
    static func main() {
        // main() 本來就在主執行緒；delegate 是 weak，必須有人持有它
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

private nonisolated(unsafe) var delegateKey: UInt8 = 0
