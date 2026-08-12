// FloatingIM.swift
// macOS 版「中/英」浮动指示器：跟随鼠标、输入时隐藏、可盖过全屏应用。
//
// 与 X11/fcitx5 版（src/fcitx5-floating-indicator.py）的对应关系：
//   - 读 Fcitx5 中英状态         -> TISCopyCurrentKeyboardInputSource() 读当前输入源
//   - dbus-monitor 窃听按键事件  -> NSEvent 全局按键监听 + HID 按键轮询
//   - GTK override-redirect 窗口 -> 无边框 NSPanel（nonactivating + 全屏辅助）
//   - xdotool 跟随鼠标           -> 轮询 NSEvent.mouseLocation（无需权限）
//
// 豆包输入法（及其它不暴露内部状态的输入法）的中英检测：
//   豆包内部 Shift 切换不改变系统输入源，也不广播通知。但它会在切换时
//   于文本光标旁弹出 26×26 的「中/英」小窗（约 1.3 秒淡出），且切换到
//   中文模式后打字时会出现 494×64 的状态条/候选条。因此用以下状态机推断：
//     1. Shift 单击 + 小窗出现      = 确实发生了一次切换
//     2. 小窗出现后 1.6 秒内状态条出现（且位置在小窗附近）= 新状态是中文
//     3. 小窗出现后状态条未出现      = 新状态是英文
//     4. 状态条跟随光标移动（正在组词）= 中文（持续修正信号）
//   全部信号来自 CGWindowList 与 HID 按键状态轮询，无需任何系统权限。

import Cocoa
import Carbon.HIToolbox
import CoreGraphics
import Vision

private let blueColor = NSColor(calibratedRed: 32.0 / 255.0, green: 106.0 / 255.0, blue: 190.0 / 255.0, alpha: 0.94)
private let grayColor = NSColor(calibratedWhite: 119.0 / 255.0, alpha: 0.94)
private let indicatorSize = NSSize(width: 40, height: 26)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum ImeMode {
        case chinese
        case english
        case unknown
    }

    // MARK: - UI

    private var panel: NSPanel!
    private var indicatorView: NSView!
    private var label: NSTextField!
    private var statusItem: NSStatusItem!
    private var permMenuItem: NSMenuItem!

    private var visible = false
    private var suppressed = false
    private var idleWorkItem: DispatchWorkItem?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    // MARK: - 输入源层状态

    private var currentSourceIsIME = false
    private var currentSourceIsDoubao = false
    private var currentSourceIsSquirrel = false
    private var squirrelAscii: Bool?
    private var lastDisplayed: ImeMode = .chinese

    // MARK: - 豆包状态机

    private var doubaoMode: ImeMode = .unknown
    private var shiftDown = false
    private var shiftDownAt: Date?
    private var shiftTapCandidate = false
    private var tapCandidateDeadline: Date?
    private var knownPopups = Set<CGWindowID>()
    private var toggleSerial = 0
    private var barAlive = false
    private var barX: CGFloat = 0
    private var lastBarX: CGFloat = 0
    private var barMoved = false
    private var doubaoUIAlive = false
    private var screenMenuItem: NSMenuItem!
    private var calibrateMenuItem: NSMenuItem!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupIndicatorPanel()
        setupStatusItem()
        setupStateObservers()
        installKeyMonitorIfPermitted()
        if !CommandLine.arguments.contains("--no-permission-request") {
            requestPermission()
            requestScreenPermission()
        }

        let follow = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
        RunLoop.main.add(follow, forMode: .common)

        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(poll, forMode: .common)

        // 豆包状态机拆成两个定时器：按键 5ms 高频轮询（捕捉极快的击键），窗口 20ms
        let keys = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            self?.tickShiftKey()
        }
        RunLoop.main.add(keys, forMode: .common)

        let track = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.tickDoubaoWindows()
        }
        RunLoop.main.add(track, forMode: .common)

        refreshState()
        show()
        NSLog("FloatingIM 启动")
    }

    func applicationWillTerminate(_ notification: Notification) {
        for token in observers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - 指示窗口

    private func setupIndicatorPanel() {
        indicatorView = NSView(frame: NSRect(origin: .zero, size: indicatorSize))
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = 6
        indicatorView.layer?.backgroundColor = blueColor.cgColor

        label = NSTextField(labelWithString: "中")
        label.font = NSFont.boldSystemFont(ofSize: 13)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: indicatorView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: indicatorView.centerYAnchor),
        ])

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: indicatorSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.contentView = indicatorView
    }

    private func updatePosition() {
        guard visible else { return }
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - 16 - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 2), vf.maxX - size.width - 2)
            origin.y = min(max(origin.y, vf.minY + 2), vf.maxY - size.height - 2)
        }
        panel.setFrameOrigin(origin)
    }

    private func show() {
        guard !suppressed, !visible else { return }
        visible = true
        panel.orderFrontRegardless()
        updatePosition()
    }

    private func hide() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
    }

    private func scheduleShow(after delay: TimeInterval) {
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.show()
        }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - 豆包窗口/按键状态机

    /// 高频轮询 Shift 键（5ms）：捕捉极短促的击键
    private func tickShiftKey() {
        let now = Date()
        let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Shift))
        if down != shiftDown {
            shiftDown = down
            if down {
                shiftDownAt = now
            } else {
                if let t = shiftDownAt, now.timeIntervalSince(t) < 0.5 {
                    if !knownPopups.isEmpty {
                        // 小窗还在展示：豆包不弹新窗，但状态已经切换（静默切换）
                        toggleSerial += 1
                        flipDoubaoMode(reason: "静默切换（连按）")
                    } else {
                        // 无小窗：可能是切换，也可能是 Shift+字母组合键；等小窗确认
                        shiftTapCandidate = true
                        tapCandidateDeadline = now.addingTimeInterval(0.7)
                    }
                }
                shiftDownAt = nil
            }
        }
        if let d = tapCandidateDeadline, now > d {
            // 0.7 秒内没有小窗出现：是 Shift+字母之类的组合键，不是切换
            shiftTapCandidate = false
            tapCandidateDeadline = nil
        }
    }

    /// 豆包窗口扫描与切换判定（20ms）
    private func tickDoubaoWindows() {
        let now = Date()

        // --- 豆包窗口扫描 ---
        // 豆包每次切换会创建一个新的 26×26 小窗；连按时旧窗还没消失新窗就会出现，
        // 因此按窗口 ID 集合差分检测，不漏掉重叠的小窗。
        let (smallIDs, barOn, barX) = scanDoubaoWindows()
        let newIDs = smallIDs.subtracting(knownPopups)
        knownPopups = smallIDs
        barAlive = barOn
        self.barX = barX

        // 新小窗出现 = 状态切换确实发生（Shift 触发或鼠标点击豆包按钮触发）
        if !newIDs.isEmpty {
            if shiftTapCandidate {
                NSLog("豆包：Shift 切换确认")
            } else {
                NSLog("豆包：检测到切换（非 Shift，可能是鼠标点击）")
            }
            shiftTapCandidate = false
            tapCandidateDeadline = nil
            // 状态已确认的情况下直接翻转，不需要等 OCR
            toggleSerial += 1
            flipDoubaoMode(reason: shiftTapCandidate ? "Shift 翻转" : "切换翻转")
            // OCR 异步验证/纠偏（过期结果丢弃）
            if let wid = newIDs.first {
                let wID = wid
                let serial = toggleSerial
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self, let text = self.ocrPopup(wID) else { return }
                    DispatchQueue.main.async {
                        guard serial == self.toggleSerial else { return }
                        self.setDoubaoMode(text == "中" ? .chinese : .english, reason: "OCR 读小窗: \(text)")
                    }
                }
            }
        }

        // 状态条移动检测（跟随光标组词）
        if barOn {
            if abs(barX - lastBarX) > 25 {
                barMoved = true
            }
            lastBarX = barX
            // 持续修正：状态条跟随光标移动 = 正在输中文
            if barMoved && currentSourceIsDoubao && doubaoMode != .chinese {
                setDoubaoMode(.chinese, reason: "状态条跟随光标")
            }
        } else {
            lastBarX = 0
            barMoved = false
        }

        // 豆包自己的 UI（小窗/状态条）可见时，隐藏我们的指示器避免重叠
        let uiAlive = !smallIDs.isEmpty || barAlive
        if uiAlive && !doubaoUIAlive {
            doubaoUIAlive = true
            suppressed = true
            hide()
        } else if !uiAlive && doubaoUIAlive {
            doubaoUIAlive = false
            suppressed = false
            scheduleShow(after: 0.4)
        }
    }

    private func flipDoubaoMode(reason: String) {
        // unknown 显示为「中」，因此首次翻转应变为「英」
        if doubaoMode == .english {
            setDoubaoMode(.chinese, reason: reason)
        } else {
            setDoubaoMode(.english, reason: reason)
        }
    }

    /// 返回 (小窗 ID 集合, 状态条on, 状态条x)
    private func scanDoubaoWindows() -> (Set<CGWindowID>, Bool, CGFloat) {
        var smallIDs = Set<CGWindowID>()
        var barOn = false
        var barX: CGFloat = 0
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return ([], false, 0)
        }
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner.contains("豆包") else { continue }
            guard let on = w[kCGWindowIsOnscreen as String] as? Bool, on else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let wd = CGFloat(b["Width"] as? Double ?? 0)
            let ht = CGFloat(b["Height"] as? Double ?? 0)
            let x = CGFloat(b["X"] as? Double ?? 0)
            if wd >= 15 && wd <= 60 && ht >= 15 && ht <= 60 {
                if let id = w[kCGWindowNumber as String] as? CGWindowID {
                    smallIDs.insert(id)
                }
            }
            if wd >= 300 && ht >= 40 {
                barOn = true
                barX = x
            }
        }
        return (smallIDs, barOn, barX)
    }

    // MARK: - 屏幕录制 + OCR 读小窗文字

    private func requestScreenPermission() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        NSLog("FloatingIM 未获得「屏幕录制」授权（OCR 校准层）；豆包中英跟踪不依赖它，如需授权请点菜单栏图标。")
    }

    @objc private func requestScreenPermissionAction() {
        requestScreenPermission()
    }

    private func capturePopupImage(_ windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming]
        )
    }

    private func upscaled(_ image: CGImage, factor: CGFloat = 3) -> CGImage? {
        let w = CGFloat(image.width) * factor
        let h = CGFloat(image.height) * factor
        guard let ctx = CGContext(
            data: nil, width: Int(w), height: Int(h),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 截取小窗图像并用 Vision OCR 识别「中/英」。（后台线程调用）
    /// 注：不依赖 CGPreflightScreenCaptureAccess（部分系统上预检会谎报），直接尝试截图。
    private func ocrPopup(_ windowID: CGWindowID) -> String? {
        // 小窗可能刚出现还没渲染完，带重试截屏
        var img: CGImage?
        for _ in 0..<5 {
            img = capturePopupImage(windowID)
            if img != nil { break }
            Thread.sleep(forTimeInterval: 0.06)
        }
        guard let captured = img else {
            NSLog("豆包小窗截图失败（屏幕录制权限可能未生效；不影响主流程）")
            return nil
        }
        let target = upscaled(captured) ?? captured
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: target, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let results = request.results else { return nil }
        for obs in results {
            guard let textObs = obs as? VNRecognizedTextObservation else { continue }
            guard let cand = textObs.topCandidates(1).first else { continue }
            let s = cand.string
            NSLog("豆包小窗 OCR: %@ (confidence %.2f)", s, cand.confidence)
            if s.contains("中") { return "中" }
            if s.contains("英") { return "英" }
        }
        return nil
    }

    // MARK: - 手动校准

    @objc private func calibrateAction() {
        if doubaoMode == .chinese {
            setDoubaoMode(.english, reason: "手动校准")
        } else {
            setDoubaoMode(.chinese, reason: "手动校准")
        }
    }

    private func setDoubaoMode(_ mode: ImeMode, reason: String) {
        guard doubaoMode != mode else { return }
        doubaoMode = mode
        NSLog("豆包状态 -> %@（%@）", mode == .chinese ? "中" : "英", reason)
        refreshState()
    }

    // MARK: - 状态读取

    private func currentInputSourceInfo() -> (id: String, mode: String?, bundle: String?)? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        func prop(_ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        guard let id = prop(kTISPropertyInputSourceID as CFString), !id.isEmpty else {
            return nil
        }
        return (
            id,
            prop(kTISPropertyInputModeID as CFString),
            prop(kTISPropertyBundleID as CFString)
        )
    }

    private func refreshState() {
        let info = currentInputSourceInfo()
        currentSourceIsIME = false
        currentSourceIsDoubao = false
        currentSourceIsSquirrel = false
        if let info = info {
            if let mode = info.mode, !mode.isEmpty {
                currentSourceIsIME = true
            }
            if info.bundle == "com.bytedance.inputmethod.doubaoime"
                || info.id.contains("doubao") {
                currentSourceIsDoubao = true
                currentSourceIsIME = true
            }
            if info.id.contains("Squirrel") || (info.bundle?.contains("rime") ?? false) {
                currentSourceIsSquirrel = true
            }
        }

        let mode = displayMode()
        guard mode != lastDisplayed else { return }
        lastDisplayed = mode
        let text = mode == .chinese ? "中" : "英"
        label.stringValue = text
        statusItem.button?.title = text
        indicatorView.layer?.backgroundColor = (mode == .chinese ? blueColor : grayColor).cgColor
        if visible { updatePosition() }
        NSLog("显示 -> %@", text)
    }

    private func displayMode() -> ImeMode {
        if !currentSourceIsIME { return .english }
        if currentSourceIsSquirrel, let ascii = squirrelAscii {
            return ascii ? .english : .chinese
        }
        if currentSourceIsDoubao {
            // 未知时默认中文（豆包默认中文模式，首次切换后自动校准）
            return doubaoMode == .english ? .english : .chinese
        }
        return .chinese
    }

    // MARK: - 状态变化通知（鼠须管等）

    private func setupStateObservers() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.inputSourceChanged()
        })
        // 鼠须管在中英切换时广播的分布式通知（Input Source Pro 等工具同款机制）
        observers.append(center.addObserver(
            forName: NSNotification.Name("SquirrelStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.squirrelStateChanged(note)
        })
    }

    private func inputSourceChanged() {
        squirrelAscii = nil
        refreshState()
    }

    private func squirrelStateChanged(_ note: Notification) {
        if let n = note.userInfo?["asciiMode"] as? NSNumber {
            squirrelAscii = n.boolValue
        } else if let b = note.userInfo?["asciiMode"] as? Bool {
            squirrelAscii = b
        }
        refreshState()
    }

    // MARK: - 打字检测（对应 dbus-monitor 窃听 ProcessKeyEvent）
    // 注意：豆包会吞掉字母键事件，NSEvent 全局监听可能收不到；
    // 豆包场景下的隐藏主要由状态条/小窗可见性驱动，见 tickDoubaoTracker。

    private func installKeyMonitorIfPermitted() {
        guard CGPreflightListenEventAccess(), keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleGlobalEvent(event)
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            hide()
            scheduleShow(after: 0.8)
        case .flagsChanged:
            if event.modifierFlags.contains(.shift) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.refreshState()
                }
            }
        default:
            break
        }
    }

    // MARK: - 输入监控权限

    private func requestPermission() {
        guard !CGPreflightListenEventAccess() else { return }
        CGRequestListenEventAccess()
        NSLog("FloatingIM 申请「输入监控」权限（打字隐藏的辅助手段，非必需）。")
    }

    @objc private func requestPermissionAction() {
        CGRequestListenEventAccess()
        installKeyMonitorIfPermitted()
    }

    // MARK: - 菜单栏图标（用于退出）

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "中"

        let menu = NSMenu()
        permMenuItem = NSMenuItem(title: "", action: #selector(requestPermissionAction), keyEquivalent: "")
        permMenuItem.target = self
        menu.addItem(permMenuItem)
        screenMenuItem = NSMenuItem(title: "", action: #selector(requestScreenPermissionAction), keyEquivalent: "")
        screenMenuItem.target = self
        menu.addItem(screenMenuItem)
        calibrateMenuItem = NSMenuItem(title: "", action: #selector(calibrateAction), keyEquivalent: "")
        calibrateMenuItem.target = self
        menu.addItem(calibrateMenuItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 FloatingIM", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if CGPreflightListenEventAccess() {
            permMenuItem.title = "输入监控：已授权"
            permMenuItem.isEnabled = false
        } else {
            permMenuItem.title = "输入监控：未授权（点击申请）"
            permMenuItem.isEnabled = true
        }
        if CGPreflightScreenCaptureAccess() {
            screenMenuItem.title = "屏幕录制：已授权（豆包小窗 OCR 识别）"
            screenMenuItem.isEnabled = false
        } else {
            screenMenuItem.title = "屏幕录制：未授权（点击申请，授权后需重启）"
            screenMenuItem.isEnabled = true
        }
        let current = doubaoMode == .chinese ? "中" : "英"
        calibrateMenuItem.title = "校准豆包状态：当前\(current)（点击切换）"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
