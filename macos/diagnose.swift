// diagnose.swift
// 诊断工具：在豆包输入法里按 Shift 切换中英时，记录系统层面可见的一切变化。
//   - 所有分布式通知（含豆包可能广播的私有通知）
//   - 当前输入源属性：sourceID / modeID / 图标文件哈希（20Hz 采样）
//   - Shift 键按下/抬起时序（用于对照）
//   - 豆包偏好 plist 与数据目录的文件变化
// 用法：./diagnose   （在豆包里按几次 Shift 和字母键，Ctrl+C 结束）
import Foundation
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit

var shiftDown = false

func now() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func log(_ s: String) {
    print("[\(now())] \(s)")
    fflush(stdout)
}

func property(_ src: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func iconSig(_ src: TISInputSource) -> String {
    guard let raw = TISGetInputSourceProperty(src, kTISPropertyIconImageURL as CFString) else {
        return "icon=none"
    }
    let typeID = CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue())
    let url: URL?
    if typeID == CFURLGetTypeID() {
        url = Unmanaged<CFURL>.fromOpaque(raw).takeUnretainedValue() as URL
    } else if typeID == CFStringGetTypeID() {
        url = URL(fileURLWithPath: Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
    } else {
        return "icon=unreadable"
    }
    guard let u = url else { return "icon=unreadable" }
    if let data = try? Data(contentsOf: u) {
        let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "icon=\(u.lastPathComponent) sz=\(data.count) sha=\(hash)"
    }
    return "icon=\(u.lastPathComponent) unreadable"
}

func sampleTIS(_ tag: String) {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
        log("TIS \(tag) <none>")
        return
    }
    let id = property(src, kTISPropertyInputSourceID as CFString) ?? "?"
    let mode = property(src, kTISPropertyInputModeID as CFString) ?? "-"
    let name = property(src, kTISPropertyLocalizedName as CFString) ?? "-"
    log("TIS \(tag) id=\(id) mode=\(mode) name=\(name) \(iconSig(src))")
}

// MARK: - 豆包数据文件监控

let plistPath = ("~/Library/Preferences/com.bytedance.inputmethod.doubaoime.plist" as NSString).expandingTildeInPath
var lastPlistSig = ""

func checkPlist() {
    var sig = "missing"
    if let data = FileManager.default.contents(atPath: plistPath) {
        let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        sig = "sz=\(data.count) sha=\(hash)"
    }
    if sig != lastPlistSig {
        log("PLIST changed \(sig)")
        lastPlistSig = sig
    }
}

let dataRoot = ("~/Library/Application Support/DoubaoIme" as NSString).expandingTildeInPath
var fileSig: [String: String] = [:]

func checkDataFiles() {
    let fm = FileManager.default
    let skipDirs = ["AppLog", "Crash", "Log", "ttnet", "Updates", "Parfait"]
    var seen: [String: String] = [:]
    guard let en = fm.enumerator(atPath: dataRoot) else { return }
    for case let rel as String in en {
        let comps = rel.split(separator: "/").map(String.init)
        if comps.count > 3 { continue }
        if let first = comps.first, skipDirs.contains(first) { continue }
        let full = dataRoot + "/" + rel
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
        let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
        let size = attrs[.size] as? Int ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        seen[rel] = String(format: "%.3f:%d", mtime, size)
        if fileSig[rel] != seen[rel] {
            log("FILE changed \(rel) mtime=\(mtime) size=\(size)")
        }
    }
    fileSig = seen
}

// MARK: - 主流程

func main() {
    log("诊断开始。请在豆包输入法里：按 Shift 几次（每次间隔约 1 秒）、再随便打几个字母。Ctrl+C 结束。")

    // 1. 所有分布式通知
    DistributedNotificationCenter.default().addObserver(
        forName: nil, object: nil, queue: .main
    ) { note in
        let info = note.userInfo ?? [:]
        log("NOTIF \(note.name.rawValue) obj=\(note.object ?? "nil") info=\(info)")
    }

    // 2. TIS 20Hz 采样
    var lastSig = ""
    let tisTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let id = property(src, kTISPropertyInputSourceID as CFString) ?? "?"
        let mode = property(src, kTISPropertyInputModeID as CFString) ?? "-"
        let sig = "\(id)|\(mode)|\(iconSig(src))"
        if sig != lastSig {
            lastSig = sig
            sampleTIS("changed")
        }
    }
    RunLoop.main.add(tisTimer, forMode: .default)

    // 3. Shift 键时序 50Hz（无权限要求，读 HID 状态）
    let keyTimer = Timer(timeInterval: 0.02, repeats: true) { _ in
        let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Shift))
        if down != shiftDown {
            shiftDown = down
            log("KEY   shift \(down ? "DOWN" : "UP")")
            sampleTIS("after-shift")
        }
    }
    RunLoop.main.add(keyTimer, forMode: .default)

    // 4. plist 与数据文件变化
    let fileTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
        checkPlist()
        checkDataFiles()
    }
    RunLoop.main.add(fileTimer, forMode: .default)

    RunLoop.main.run()
}

main()
