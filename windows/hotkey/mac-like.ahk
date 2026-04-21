#Requires AutoHotkey v2.0
#SingleInstance Force
#WinActivateForce

; Foreground lock を確実に無効化 (WinActivate 成功率を上げる)
DllCall("SystemParametersInfo", "UInt", 0x2001, "UInt", 0, "Ptr", 0, "UInt", 0)

; Mac-like keyboard translator (Windows 側で Mac の Cmd+X 体験を再現)
;
; 前提 (Scancode Map で変換済):
;   物理 LWin       → F13
;   物理 カタカナ    → F14
;   物理 LCtrl (2)  → LWin  (本物の Win キーは左端に残る)
;   物理 Caps       → LCtrl (既存 swap、小指 Ctrl)
;
; このスクリプトは F13 / F14 + 文字キー を Ctrl + 文字 に変換する。
; F13 単体押下は明示的に吸収 (race condition 防止、最重要)。
; F14 は未使用 (カタカナキーの Scancode Map remap を撤廃済、JIS VK 崩壊回避のため)。

F13::return

; Cmd+key → Ctrl+key (一般 GUI) / Ctrl+Shift+key (WezTerm 内、タブ操作等のため)
SendCmd(key) {
    mods := WinActive("ahk_exe wezterm-gui.exe") ? "^+" : "^"
    SendInput mods . key
}

; Cmd+D は Shift 有無で挙動を分岐 (iTerm2 準拠):
;   Cmd+D       → WezTerm 左右分割 (Ctrl+Shift+D)  / 他 Ctrl+D
;   Cmd+Shift+D → WezTerm 上下分割 (Ctrl+Shift+Alt+D) / 他 Ctrl+Shift+D
HandleCmdD() {
    inWezTerm := WinActive("ahk_exe wezterm-gui.exe")
    if GetKeyState("Shift", "P")
        SendInput inWezTerm ? "^+!d" : "^+d"
    else
        SendInput inWezTerm ? "^+d" : "^d"
}

; F13 = 左 Cmd (物理 LWin)
F13 & c::SendCmd("c")
F13 & v::SendCmd("v")
F13 & x::SendCmd("x")
F13 & a::SendCmd("a")
F13 & z::SendCmd("z")
F13 & y::SendCmd("y")
F13 & s::SendCmd("s")
F13 & f::SendCmd("f")
F13 & t::SendCmd("t")   ; WezTerm: 新タブ / 他: Ctrl+T
F13 & w::SendCmd("w")   ; WezTerm: タブ閉じる / 他: Ctrl+W
F13 & d::HandleCmdD()   ; WezTerm: 左右分割 (+Shift で上下) / 他: Ctrl+D
F13 & k::SendCmd("k")   ; WezTerm: Clear Scrollback
F13 & n::SendCmd("n")
F13 & p::SendCmd("p")
F13 & o::SendCmd("o")
F13 & r::SendCmd("r")
F13 & q::SendCmd("q")
F13 & j::SendCmd("j")   ; Zed: terminal panel toggle (Cursor-like)
F13 & l::SendCmd("l")   ; Zed: agent (chat) panel toggle (Cursor-like)
F13 & u::SendCmd("u")   ; WezTerm: transparency toggle (iTerm2 Cmd+U 風)
F13 & 1::SendCmd("1")
F13 & 2::SendCmd("2")
F13 & 3::SendCmd("3")
F13 & 4::{                  ; Cmd+4 / Cmd+Shift+4 = Rapture (Mac スクショ)
    if GetKeyState("Shift", "P")
        Run '"C:\Users\81809\rapture-2.4.1\rapture.exe"', "C:\Users\81809\rapture-2.4.1"
    else
        SendCmd("4")
}
F13 & 5::SendCmd("5")
F13 & 6::SendCmd("6")
F13 & 7::SendCmd("7")
F13 & 8::SendCmd("8")
F13 & 9::SendCmd("9")
F13 & Backspace::SendInput "{Delete}"

; Caps+V (= Ctrl+V) = ペースト (WezTerm 内: 画像があれば WSL パス貼り付け、なければ通常ペースト)
; $ prefix でフック使用 (自身の SendInput ^v を再 trigger しない)
$^v::{
    if WinActive("ahk_exe wezterm-gui.exe") {
        if PasteClipboardImage()
            return
        SendInput "^+v"  ; WezTerm のペーストは Ctrl+Shift+V
    } else {
        SendInput "^v"
    }
}

PasteClipboardImage() {
    static counter := 0
    stamp := FormatTime(, "yyyyMMddHHmmss") . "_" . (++counter)
    winPath := "C:\tmp\clip_" . stamp . ".png"
    wslPath := "/mnt/c/tmp/clip_" . stamp . ".png"

    DirCreate "C:\tmp"

    ; ImageMagick でクリップボード画像を PNG 保存 (非ゼロ exit = 画像なし)
    ; DSC が C:\tools\imagemagick → 実体ディレクトリに symlink
    RunWait('"C:\tools\imagemagick\magick.exe" clipboard: "' . winPath . '"', "C:\tmp", "Hide")
    if !FileExist(winPath)
        return false

    ; WSL パスをクリップボード経由で一括ペースト
    A_Clipboard := wslPath
    ClipWait 1
    SendInput "^+v"
    return true
}

; WezTerm Hotkey Window (iTerm2 風)
;   物理 LWin+Space (= F13+Space) でトグル。Mac の Cmd+Space 感覚。
;   表示時: Show + Restore + Maximize + Activate で前面全画面
;   隠す時: WinHide でタスクバーからも消える
global WEZTERM_EXE := "wezterm-gui.exe"

F13 & Space::ToggleWezTerm()

ToggleWezTerm() {
    ; hidden window も検出するために DetectHiddenWindows true
    DetectHiddenWindows true
    hwnd := WinExist("ahk_exe " . WEZTERM_EXE)
    DetectHiddenWindows false

    if !hwnd {
        Run(WEZTERM_EXE, , "Max")
        return
    }

    if WinActive("ahk_id " . hwnd) {
        ; iTerm2 Hotkey Window 方式: Minimize ではなく Hide (タスクバーからも消える)
        ; Hide したウィンドウは Show 時に foreground lock を迂回できるため再呼出しが確実
        WinHide("ahk_id " . hwnd)
        Send "{Blind}!{Esc}"  ; 前のウィンドウにフォーカスを返す
    } else {
        KeyWait "Space"
        WinShow("ahk_id " . hwnd)
        WinMaximize("ahk_id " . hwnd)
        WinActivate("ahk_id " . hwnd)
        if !WinActive("ahk_id " . hwnd) {
            ForceActivate(hwnd)
            if !WinActive("ahk_id " . hwnd)
                DllCall("SwitchToThisWindow", "Ptr", hwnd, "Int", 1)
        }
    }
}

ForceActivate(hwnd) {
    foreHwnd := DllCall("GetForegroundWindow", "ptr")
    foreTid  := DllCall("GetWindowThreadProcessId", "ptr", foreHwnd, "ptr*", 0)
    myTid    := DllCall("GetCurrentThreadId")
    DllCall("AttachThreadInput", "uint", myTid, "uint", foreTid, "int", 1)
    DllCall("SetForegroundWindow", "ptr", hwnd)
    DllCall("SetActiveWindow", "ptr", hwnd)
    DllCall("AttachThreadInput", "uint", myTid, "uint", foreTid, "int", 0)
}

; Mac 風 IME 変換 (Caps = Ctrl 経由、IME 入力中のみ発動)
;   Ctrl+J → F6 (ひらがな)
;   Ctrl+K → F7 (カタカナ)
;   Ctrl+L → F8 (半角カタカナ)
;   IME オフの時は通常の Ctrl+J/K/L を透過 (Zed/Chrome 等の機能維持)
;   LAlt (= F13) + J/L は別ハンドラ (F13 & j / F13 & l) で Zed 用なので競合しない。
IsImeOn() {
    hwnd := WinExist("A")
    if !hwnd
        return false
    hime := DllCall("imm32\ImmGetDefaultIMEWnd", "ptr", hwnd, "ptr")
    if !hime
        return false
    return DllCall("user32\SendMessage", "ptr", hime, "uint", 0x283, "ptr", 0x005, "ptr", 0)
}

; IME に未確定文字 (composition) があるか判定
;   GCS_COMPSTR = 0x0008, ImmGetCompositionString の戻り値 > 0 なら未確定あり
IsComposing() {
    hwnd := WinExist("A")
    if !hwnd
        return false
    tid := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr*", 0, "uint")
    himc := DllCall("imm32\ImmGetContext", "ptr", hwnd, "ptr")
    if !himc
        return false
    len := DllCall("imm32\ImmGetCompositionString", "ptr", himc, "uint", 0x0008, "ptr", 0, "uint", 0, "int")
    DllCall("imm32\ImmReleaseContext", "ptr", hwnd, "ptr", himc)
    return len > 0
}

; $ prefix で Use Hook → AHK が送った ^j を自分で再 trigger しないようにする
$^j::Send IsImeOn() ? "{F6}" : "^j"
$^k::Send IsImeOn() ? "{F7}" : "^k"
$^l::Send IsImeOn() ? "{F8}" : "^l"

; IME 切替時の視覚フィードバック
;   実制御は MS IME の設定 (無変換→IME-オフ / 変換→IME-オン) に委譲。
;   AHK は `~` prefix でキーを pass-through してオーバーレイ表示のみ担当。
;   注意: Scancode Map で JIS キー (カタカナ等) を remap すると変換/無変換の
;   VK コードが崩壊して MS IME KeyAssignment が効かなくなる (既知問題)。
~vk1D::ShowImeIndicator("A")

; 変換キー: 未確定文字がなければ IME ON として pass-through + インジケータ表示
; 未確定文字があるときは抑制 (カタカナ変換を防止、Mac 風の挙動)
; $ prefix (Use Hook) で SendInput による自己再発火を防止
$vk1C::{
    if IsComposing()
        return
    SendInput "{vk1C}"
    ShowImeIndicator("あ")
}

ShowImeIndicator(text) {
    static g := ""
    try {
        if IsObject(g)
            g.Destroy()
    }
    w := 110, h := 110
    MonitorGetWorkArea(, &L, &T, &R, &B)
    x := L + (R - L - w) // 2
    y := T + (B - T - h) // 2
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20", "ime-indicator")
    g.BackColor := "202020"
    g.MarginX := 0
    g.MarginY := 0
    g.SetFont("s44 cFFFFFF Bold", "Meiryo UI")
    ; x0 y0 で margin 無視、Center = SS_CENTER (水平中央)、+0x200 = SS_CENTERIMAGE (縦中央)
    g.Add("Text", Format("x0 y0 w{} h{} Center +0x200", w, h), text)
    g.Show(Format("NoActivate x{} y{} w{} h{}", x, y, w, h))
    WinSetTransparent(170, g.Hwnd)
    SetTimer((*) => (IsObject(g) ? g.Destroy() : 0), -500)
}
