// probe-popup.swift
// 探针：在豆包输入法按 Shift 弹出「中/英」小窗时，抓取该窗口的一切元数据。
// 判断能否通过 CGWindowList（无需权限）读到小窗标题/文字。
// 用法：./probe-popup   （在豆包里按几次 Shift，Ctrl+C 结束）
import Foundation
import CoreGraphics

func now() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func log(_ s: String) {
    print("[\(now())] \(s)")
    fflush(stdout)
}

// 按键轮询：字母 A-Z(0-25)、回车(36)、空格(49)、Shift(56/60)
let keyCodes: [CGKeyCode] = [56, 60, 36, 49] + (0...25).map(CGKeyCode.init)
var keyState: [CGKeyCode: Bool] = [:]

func pollKeys() {
    for code in keyCodes {
        let down = CGEventSource.keyState(.combinedSessionState, key: code)
        if keyState[code] != down {
            keyState[code] = down
            if code <= 25 || code == 36 || code == 49 {
                let ch = code == 49 ? "space" : code == 36 ? "return" : String(Character(UnicodeScalar(65 + Int(code))!))
                log("KEY   \(ch) \(down ? "DOWN" : "UP")")
            } else {
                log("KEY   shift\(code == 56 ? "L" : "R") \(down ? "DOWN" : "UP")")
            }
        }
    }
}

func mousePos() -> CGPoint {
    let e = CGEvent(source: nil)
    return e?.location ?? .zero
}

var lastSig: [CGWindowID: String] = [:]

func poll() {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
    let mouse = mousePos()
    var seen: Set<CGWindowID> = []
    for w in list {
        guard let num = w[kCGWindowNumber as String] as? CGWindowID else { continue }
        seen.insert(num)
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let title = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
        let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = CGFloat(b["X"] as? Double ?? 0), y = CGFloat(b["Y"] as? Double ?? 0)
        let wd = CGFloat(b["Width"] as? Double ?? 0), ht = CGFloat(b["Height"] as? Double ?? 0)
        let sig = "\(title)|\(on)|\(layer)|\(alpha)|\(Int(x)),\(Int(y)),\(Int(wd)),\(Int(ht))"
        if lastSig[num] != sig {
            lastSig[num] = sig
            let nearMouse = mouse.x >= x - 40 && mouse.x <= x + wd + 40 && mouse.y >= y - 40 && mouse.y <= y + ht + 40
            log("WIN#\(num) owner=\(owner) title=«\(title)» on=\(on) layer=\(layer) alpha=\(alpha) xywh=\(Int(x)),\(Int(y)),\(Int(wd)),\(Int(ht)) nearMouse=\(nearMouse) mouse=\(Int(mouse.x)),\(Int(mouse.y))")
        }
    }
    // 窗口消失也记录
    for num in lastSig.keys where !seen.contains(num) {
        log("WIN#\(num) GONE")
        lastSig.removeValue(forKey: num)
    }
}

func main() {
    log("探针开始。请在豆包输入法里按 Shift 4~5 次（每次间隔 1 秒，等小窗弹出消失），完成后 Ctrl+C。")
    let t = Timer(timeInterval: 0.02, repeats: true) { _ in poll() }
    RunLoop.main.add(t, forMode: .default)
    let k = Timer(timeInterval: 0.02, repeats: true) { _ in pollKeys() }
    RunLoop.main.add(k, forMode: .default)
    poll()
    RunLoop.main.run()
}

main()
