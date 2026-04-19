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
; F13 / F14 単体押下は明示的に吸収 (race condition 防止、最重要)。

F13::return
F14::return

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
F13 & 1::SendCmd("1")
F13 & 2::SendCmd("2")
F13 & 3::SendCmd("3")
F13 & 4::SendCmd("4")
F13 & 5::SendCmd("5")
F13 & 6::SendCmd("6")
F13 & 7::SendCmd("7")
F13 & 8::SendCmd("8")
F13 & 9::SendCmd("9")
F13 & Backspace::SendInput "{Delete}"

; F14 = 右 Cmd (物理 カタカナひらがな)
F14 & c::SendCmd("c")
F14 & v::SendCmd("v")
F14 & x::SendCmd("x")
F14 & a::SendCmd("a")
F14 & z::SendCmd("z")
F14 & y::SendCmd("y")
F14 & s::SendCmd("s")
F14 & f::SendCmd("f")
F14 & t::SendCmd("t")
F14 & w::SendCmd("w")
F14 & d::HandleCmdD()
F14 & k::SendCmd("k")
F14 & n::SendCmd("n")
F14 & p::SendCmd("p")
F14 & o::SendCmd("o")
F14 & r::SendCmd("r")
F14 & q::SendCmd("q")
F14 & j::SendCmd("j")
F14 & l::SendCmd("l")
F14 & 1::SendCmd("1")
F14 & 2::SendCmd("2")
F14 & 3::SendCmd("3")
F14 & 4::SendCmd("4")
F14 & 5::SendCmd("5")
F14 & 6::SendCmd("6")
F14 & 7::SendCmd("7")
F14 & 8::SendCmd("8")
F14 & 9::SendCmd("9")
F14 & Backspace::SendInput "{Delete}"

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

; IME 切替時の視覚フィードバック
;   実制御は MS IME の設定 (無変換→IME-オフ / 変換→IME-オン) に委譲。
;   AHK は `~` prefix でキーを pass-through してオーバーレイ表示のみ担当。
~vk1D::ShowImeIndicator("A")
~vk1C::ShowImeIndicator("あ")

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
