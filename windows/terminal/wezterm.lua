-- WezTerm 設定 (Windows)
-- 配置先: %USERPROFILE%\.wezterm.lua (DSC がシンボリックリンク)
--
-- iTerm2 のキーバインドを Windows 慣習にマッピング:
--   Windows 内蔵キーボード (現状): CTRL|SHIFT が Cmd 相当
--   Anker + Kanata 将来構成: Kanata で Anker LWin+key を CTRL+SHIFT+key に変換
--     することで同じバインドで Mac 感と Win 感両対応（未実装）
--
-- 備考: SUPER (Win) キーは Windows が Win+D 等を OS レベルで横取りするため
-- WezTerm では基本使わない。

local wezterm = require('wezterm')
local act = wezterm.action
local config = wezterm.config_builder()

-- ============================================================================
-- フォント
-- ============================================================================
config.font = wezterm.font_with_fallback({
  { family = 'JetBrainsMono Nerd Font Mono', weight = 'Regular' },
  'Segoe UI Emoji',
  'Yu Gothic UI',
})
config.font_size = 13.0
config.line_height = 1.1
config.cell_width = 1.0

-- ============================================================================
-- レンダリング / パフォーマンス (極限チューニング)
-- ============================================================================
-- GPU レンダラ
-- WezTerm GitHub #4502 #5790 #6265 #6359: WebGpu + NVIDIA dual-GPU + Windows 11 で
-- window_background_opacity が効かない既知 regression。公式ワークアラウンドは
-- front_end = 'OpenGL' + prefer_egl = true (ANGLE 経由で DX11 を掴む)。
config.front_end = 'OpenGL'
config.prefer_egl = true

-- フレームレート
config.max_fps = 240          -- ディスプレイ再描画上限 (高 Hz モニタ対応)
config.animation_fps = 0      -- アニメ 0fps = アニメ完全無効 (入力優先)

-- バックグラウンド処理削減
config.automatically_reload_config = false        -- ファイル監視 OFF
config.check_for_updates = false                  -- 更新チェック OFF
config.adjust_window_size_when_changing_font_size = false

-- 描画要素削減
config.enable_scroll_bar = false
config.enable_kitty_graphics = false              -- Kitty graphics protocol OFF (使ってない)
config.enable_csi_u_key_encoding = false
config.enable_wayland = false                     -- Windows なので無関係
config.anti_alias_custom_block_glyphs = true
config.warn_about_missing_glyphs = false

-- 入力処理
config.use_dead_keys = false                       -- dead key 処理 OFF
config.use_ime = false                             -- ターミナル内 IME OFF (速度↑、日本語入力したいなら true)

-- ベル
config.audible_bell = 'Disabled'
config.visual_bell = { fade_in_duration_ms = 0, fade_out_duration_ms = 0, target = 'CursorColor' }

-- カーソル: 点滅無効
config.cursor_blink_ease_in  = 'Constant'
config.cursor_blink_ease_out = 'Constant'
config.default_cursor_style = 'SteadyBlock'

-- パディング最小化
config.window_padding = { left = 4, right = 4, top = 2, bottom = 2 }

-- タブバー軽量化
config.show_new_tab_button_in_tab_bar = false

-- ============================================================================
-- テーマ / 外観
-- ============================================================================
config.color_scheme = 'Tokyo Night'
-- Tokyo Night の青みがかった背景を純粋な黒に override (foreground 色はそのまま)
config.colors = {
  background = '#000000',
}
-- Win11 統合ボタン (タブバー右端に最小/最大/閉じるが乗る)
config.window_decorations = 'INTEGRATED_BUTTONS|RESIZE'
-- 透過 (default 25% 透過、Cmd+U で 1.0 と toggle 可能)
config.window_background_opacity = 0.75
config.initial_cols = 120
config.initial_rows = 36

-- INTEGRATED_BUTTONS を常に表示したいので 1 タブ時もタブバー非表示にしない
config.hide_tab_bar_if_only_one_tab = false
config.use_fancy_tab_bar = false
config.tab_max_width = 32
config.tab_bar_at_bottom = false

config.default_cursor_style = 'SteadyBlock'
config.cursor_blink_rate = 0

config.scrollback_lines = 10000

-- ============================================================================
-- デフォルトシェル: WSL2 Ubuntu (なければ PowerShell 7)
-- WSL domain の default_cwd を WSL home に固定 — 新 tab/pane は cwd 引き継がず
-- 常に ~/ で開く方針 (ssh / mini path 引継ぎ事故ゼロ、シンプル優先)
-- ============================================================================
local wsl_domains = wezterm.default_wsl_domains()
local wsl_present = false
for _, d in ipairs(wsl_domains) do
  if d.name == 'WSL:Ubuntu' then
    wsl_present = true
    d.default_cwd = '/home/gigun'
    break
  end
end
config.wsl_domains = wsl_domains
if wsl_present then
  config.default_domain = 'WSL:Ubuntu'
else
  config.default_prog = { 'pwsh.exe', '-NoLogo' }
end

-- ============================================================================
-- キーバインド (iTerm2 風、Windows 慣習で CTRL|SHIFT を Cmd 相当に)
-- ============================================================================
config.disable_default_key_bindings = false

config.keys = {
  -- Tab / Pane: cwd を /home/gigun にハードコード (空 spec だと pane.cwd を補完されるため)
  -- 新 tab/pane は常に WSL home で開く、ssh 中の remote path / 連打 race 等の事故ゼロ
  { key = 't', mods = 'CTRL|SHIFT',       action = act.SpawnCommandInNewTab({ cwd = '/home/gigun' }) }, -- Cmd+T
  { key = 'w', mods = 'CTRL|SHIFT',       action = act.CloseCurrentPane({ confirm = false }) }, -- Cmd+W

  -- Pane split (iTerm2 準拠) — cwd 明示で引き継ぎ無効
  { key = 'd', mods = 'CTRL|SHIFT',       action = act.SplitPane({ direction = 'Right', size = { Percent = 50 }, command = { cwd = '/home/gigun' } }) }, -- Cmd+D (左右)
  { key = 'd', mods = 'CTRL|SHIFT|ALT',   action = act.SplitPane({ direction = 'Down',  size = { Percent = 50 }, command = { cwd = '/home/gigun' } }) }, -- Cmd+Shift+D (上下)

  -- Tab navigation
  { key = ']', mods = 'CTRL|SHIFT',       action = act.ActivateTabRelative(1) },         -- Cmd+]
  { key = '[', mods = 'CTRL|SHIFT',       action = act.ActivateTabRelative(-1) },        -- Cmd+[
  { key = 'Tab', mods = 'CTRL',           action = act.ActivateTabRelative(1) },
  { key = 'Tab', mods = 'CTRL|SHIFT',     action = act.ActivateTabRelative(-1) },

  -- Pane navigation (Cmd+Opt+Arrow)
  { key = 'LeftArrow',  mods = 'CTRL|SHIFT|ALT', action = act.ActivatePaneDirection('Left') },
  { key = 'RightArrow', mods = 'CTRL|SHIFT|ALT', action = act.ActivatePaneDirection('Right') },
  { key = 'UpArrow',    mods = 'CTRL|SHIFT|ALT', action = act.ActivatePaneDirection('Up') },
  { key = 'DownArrow',  mods = 'CTRL|SHIFT|ALT', action = act.ActivatePaneDirection('Down') },

  -- Font size (Cmd+/-/=)
  { key = '=', mods = 'CTRL|SHIFT',       action = act.IncreaseFontSize },
  { key = '-', mods = 'CTRL|SHIFT',       action = act.DecreaseFontSize },
  { key = '0', mods = 'CTRL|SHIFT',       action = act.ResetFontSize },

  -- Clear scrollback (Cmd+K)
  { key = 'k', mods = 'CTRL|SHIFT',       action = act.ClearScrollback('ScrollbackAndViewport') },

  -- Fullscreen (Cmd+Shift+F 相当)
  { key = 'f', mods = 'CTRL|SHIFT|ALT',   action = act.ToggleFullScreen },

  -- Transparency toggle (iTerm2 Cmd+U 風、opaque ↔ 0.75 で切替)
  { key = 'u', mods = 'CTRL|SHIFT', action = wezterm.action_callback(function(window, _)
      local o = window:get_config_overrides() or {}
      if o.window_background_opacity == 1.0 then
        o.window_background_opacity = 0.75
      else
        o.window_background_opacity = 1.0
      end
      window:set_config_overrides(o)
    end) },
}

-- Tab navigation by number (iTerm2 風 Cmd+1..9 → ActivateTab)
-- phys:Digit1..9 で物理キー指定 (JIS/US の Shift+数字 symbol 違いを回避)
for i = 1, 9 do
  table.insert(config.keys, { key = 'phys:' .. tostring(i), mods = 'CTRL|SHIFT', action = act.ActivateTab(i - 1) })
end

return config
