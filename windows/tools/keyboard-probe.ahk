#Requires AutoHotkey v2.0
#SingleInstance Force

; HP ENVY 13 JIS 内蔵キーボード物理配列実測ツール
;   - 低レベル InputHook で押したキーの VK / ScanCode / 拡張フラグ / KeyName をログ
;   - 保存ボタン → windows/tools/hp-envy-keymap.txt
;   - GUI にフォーカスを当ててから押すこと (他アプリに入力が飛ばないように)

keyCount := 0
logEntries := []

myGui := Gui("+AlwaysOnTop +Resize", "HP ENVY Keyboard Probe")
myGui.SetFont("s10", "Consolas")
myGui.Add("Text", "w820",
    "推奨手順: 最下段 左 → 右、下段 → 上段 の順で全キーを系統的に 1 回ずつ押す。`n"
    "ウィンドウにフォーカスを当ててから入力すること (ボタンはマウスでクリック)。")
lv := myGui.Add("ListView", "w820 h450", ["#", "VK", "SC", "Ext", "KeyName"])
lv.ModifyCol(1, 40)
lv.ModifyCol(2, 80)
lv.ModifyCol(3, 80)
lv.ModifyCol(4, 50)
lv.ModifyCol(5, 340)
myGui.Add("Button", "xm w140", "保存").OnEvent("Click", (*) => SaveLog())
myGui.Add("Button", "x+10 w140", "ログクリア").OnEvent("Click", (*) => ClearLog())
myGui.Add("Button", "x+10 w140", "終了").OnEvent("Click", (*) => ExitApp())
myGui.Show()

ih := InputHook("V")
ih.KeyOpt("{All}", "N")
ih.OnKeyDown := OnKeyDown
ih.Start()

OnKeyDown(hook, vk, sc) {
    global keyCount, logEntries, lv
    keyCount++
    extended := (sc >> 8) & 0xFF
    extStr := extended ? Format("0x{:02X}", extended) : "-"
    keyName := ""
    try keyName := GetKeyName(Format("vk{:x}sc{:x}", vk, sc))
    lv.Add(, keyCount, Format("0x{:02X}", vk), Format("0x{:04X}", sc), extStr, keyName)
    lv.Modify(keyCount, "Vis")
    logEntries.Push({ num: keyCount, vk: vk, sc: sc, ext: extended, name: keyName })
}

SaveLog() {
    global logEntries
    if (logEntries.Length = 0) {
        MsgBox("まだキーがログされていません。", "Probe", "T1")
        return
    }
    path := A_ScriptDir "\hp-envy-keymap.txt"
    content := "# HP ENVY Keyboard Probe Result`r`n"
    content .= "# Captured: " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`r`n"
    content .= "# Columns: # | VK (hex) | SC (hex, 下位byte) | Ext (E0 prefix) | KeyName`r`n`r`n"
    for entry in logEntries {
        content .= Format("{:3}`t0x{:02X}`t0x{:04X}`t{}`t{}`r`n",
            entry.num, entry.vk, entry.sc,
            entry.ext ? Format("0x{:02X}", entry.ext) : "-",
            entry.name)
    }
    try FileDelete(path)
    FileAppend(content, path)
    MsgBox("保存しました:`n" path, "Probe", "T2")
}

ClearLog() {
    global keyCount, logEntries, lv
    keyCount := 0
    logEntries := []
    lv.Delete()
}
