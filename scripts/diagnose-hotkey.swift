#!/usr/bin/env swift
import AppKit
import Carbon

let help = """
macOSのグローバルホットキー診断（設定変更・アプリ終了なし）
  swift scripts/diagnose-hotkey.swift [--key-code 49] [--modifiers option] [--seconds 60]
  swift scripts/diagnose-hotkey.swift --check [--key-code 49] [--modifiers option]

--modifiers: control+option+shift+command の組み合わせ（指定するキーだけを列挙）
--check: 一時的な排他登録で競合を検査し、直後に解除する。入力監視権限は不要。
通常モード: 実キー押下とhotkey通知の送信先PIDを受動観測する。入力監視権限が必要。
終了コード: 0=観測完了/登録可能、1=登録済み、2=引数/権限/APIエラー。
"""

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(2)
}

var keyCode: UInt32 = 49
var carbonModifiers = UInt32(optionKey)
var eventModifiers = CGEventFlags.maskAlternate.rawValue
var seconds: Double = 60
var checkOnly = false
let modifierOptions: [String: (UInt32, UInt64)] = [
    "control": (UInt32(controlKey), CGEventFlags.maskControl.rawValue),
    "option": (UInt32(optionKey), CGEventFlags.maskAlternate.rawValue),
    "shift": (UInt32(shiftKey), CGEventFlags.maskShift.rawValue),
    "command": (UInt32(cmdKey), CGEventFlags.maskCommand.rawValue),
]
var arguments = Array(CommandLine.arguments.dropFirst())[...]
while let argument = arguments.popFirst() {
    switch argument {
    case "--help", "-h": print(help); exit(0)
    case "--check": checkOnly = true
    case "--key-code":
        guard let raw = arguments.popFirst(), let value = UInt32(raw), value <= 127 else {
            fail("--key-codeには0〜127のキーコードを指定してください。")
        }
        keyCode = value
    case "--seconds":
        guard let raw = arguments.popFirst(), let value = Double(raw), value >= 1, value <= 300 else {
            fail("--secondsには1〜300秒を指定してください。")
        }
        seconds = value
    case "--modifiers":
        guard let raw = arguments.popFirst(), !raw.isEmpty else { fail("--modifiersの値が必要です。") }
        carbonModifiers = 0
        eventModifiers = 0
        for name in raw.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            guard let masks = modifierOptions[String(name)] else { fail("未対応の修飾キー: \(name)") }
            carbonModifiers |= masks.0
            eventModifiers |= masks.1
        }
    default: fail("不明な引数: \(argument)\n\(help)")
    }
}

if checkOnly {
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
        keyCode, carbonModifiers, EventHotKeyID(signature: 0x4446484b, id: 1),
        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference
    )
    if let reference {
        let cleanup = UnregisterEventHotKey(reference)
        guard cleanup == noErr else { fail("一時登録の解除失敗: OSStatus=\(cleanup)") }
    }
    switch status {
    case noErr: print("AVAILABLE: 排他登録成功・解除済み。非排他登録・システム予約・event tapの有無は別途確認。")
    case OSStatus(eventHotKeyExistsErr): print("REGISTERED: 同じ組み合わせの排他登録あり（OSStatus=\(status)）。PIDはこの検査では分かりません。"); exit(1)
    default: fail("登録検査失敗: OSStatus=\(status)")
    }
    exit(0)
}

guard CGPreflightListenEventAccess() else {
    fail("入力監視権限がありません。実行元アプリの権限を本人が確認し、必要な場合だけ許可して再実行してください。")
}

final class Observation {
    let keyCode: UInt32
    let modifiers: UInt64
    var lastMatch: CGEventTimestamp?
    var recipients = 0
    init(keyCode: UInt32, modifiers: UInt64) { self.keyCode = keyCode; self.modifiers = modifiers }
    func receive(type: CGEventType, event: CGEvent) {
        let relevantMask = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode),
           event.flags.rawValue & relevantMask == modifiers {
            lastMatch = event.timestamp
            print("MATCH: 指定キーの実入力を観測しました。")
        } else if type.rawValue == 14,
                  let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 6,
                  let previous = lastMatch, event.timestamp >= previous,
                  event.timestamp - previous <= 1_000_000_000 {
            let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            guard pid > 0, pid != getpid() else { return }
            let app = NSRunningApplication(processIdentifier: pid)
            print("RECIPIENT: pid=\(pid) app=\(app?.localizedName ?? "unknown") bundle=\(app?.bundleIdentifier ?? "unknown")")
            recipients += 1
        }
        fflush(stdout)
    }
}

let observation = Observation(keyCode: keyCode, modifiers: eventModifiers)
let callback: CGEventTapCallBack = { _, type, event, context in
    if let context {
        Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue().receive(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
var taps: [CFMachPort] = []
var sources: [CFRunLoopSource] = []
let configurations: [(CGEventTapLocation, CGEventMask)] = [
    (.cgSessionEventTap, 1 << 10),
    (.cgAnnotatedSessionEventTap, 1 << 14),
]
for (location, mask) in configurations {
    guard let tap = CGEvent.tapCreate(
        tap: location, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: callback,
        userInfo: Unmanaged.passUnretained(observation).toOpaque()
    ) else {
        for existing in taps { CFMachPortInvalidate(existing) }
        fail("受動監視の作成失敗。実行元の権限を確認してください。location=\(location.rawValue)")
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    taps.append(tap)
    sources.append(source)
}
print("READY: \(Int(seconds))秒間観測します。調べたい実キーを押してください。入力画面の切り替えは不要です。")
fflush(stdout)
CFRunLoopRunInMode(.defaultMode, seconds, false)
for tap in taps { CFMachPortInvalidate(tap) }
print("DONE: 送信先通知=\(observation.recipients)件。0件でも競合なしとは判断できません。")
