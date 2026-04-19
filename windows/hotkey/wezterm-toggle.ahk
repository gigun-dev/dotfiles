#Requires AutoHotkey v2.0
#SingleInstance Force
;
; WezTerm トグル hotkey (iTerm2 Hotkey Window 風)
;
; 操作:
;   Ctrl+` (バッククォート) で WezTerm の前面/非表示トグル
;   - 起動していなければ起動
;   - 前面表示中なら最小化
;   - 最小化/背面なら前面へ
;

global WEZTERM_EXE := "wezterm-gui.exe"

ToggleWezTerm() {
    if WinExist("ahk_exe " . WEZTERM_EXE) {
        if WinActive("ahk_exe " . WEZTERM_EXE) {
            ; フォアグラウンドにあるなら隠す (タスクバーから消える)
            WinHide("ahk_exe " . WEZTERM_EXE)
        } else {
            ; 存在するが背面/最小化/非表示 → 前面に全画面で表示
            WinShow("ahk_exe " . WEZTERM_EXE)
            WinRestore("ahk_exe " . WEZTERM_EXE)
            WinMaximize("ahk_exe " . WEZTERM_EXE)
            WinActivate("ahk_exe " . WEZTERM_EXE)
        }
    } else {
        ; 起動していない → 新規起動 (最大化)
        Run(WEZTERM_EXE, , "Max")
    }
}

; Ctrl+` (^`) でトグル
^`::ToggleWezTerm()

; オプション: Alt+Space でも同じ動作 (iTerm2 派の saku)
; !Space::ToggleWezTerm()
