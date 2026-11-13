# skill だけでできたものは plugin で包まず、agent-skills-nix で 3 ホストへ直接配る。
# 版は flake.lock で固定し、ホストに取りに行かせない (plugin の外部参照は host ごとに
# 更新の仕方が違い、古い版が残った。gigun-dev/claude-code todo 0076)。
#
# 配り先はホストが実際に読む場所 (2026-11-13 に使い捨て skill で実測):
#   claude → ~/.claude/skills   (Claude は ~/.agents/skills を読まない)
#   agents → ~/.agents/skills   (Codex は ~/.agents/skills と ~/.codex/skills を読む。
#                                 SKILL.md 単体の symlink は読まない)
#   gemini → ~/.gemini/skills   (agy CLI はここだけ読む)
#
# Why not symlink-tree (既定): rsync --delete で配り先を丸ごと持つので、既に手で置いた
# skill (~/.claude/skills/synced、~/.gemini/skills の cloudflare 群) を消す。link は
# home-manager が skill ごとに link するので (static な dest が要る)、既存のものと並べて段階的に移せる。
{ config, skillSources, ... }:
let
  home = config.home.homeDirectory;
in
{
  programs.agent-skills = {
    enable = true;

    sources.ryoppippi = {
      path = skillSources.ryoppippi-dotfiles;
      subdir = "agents/skills";
    };

    # 移行中は plugin 版を同時に有効にしない (agy は plugin の skill に名前の区切りを
    # 付けないので、同名の skill が 2 つ並ぶ)。
    skills.enable = [ "worktree" ];

    targets = {
      claude = {
        enable = true;
        dest = "${home}/.claude/skills";
        structure = "link";
      };
      # Why not link: Codex は SKILL.md 単体の symlink を読まない (skill の
      # ディレクトリごとの symlink と実ファイルは読む。2026-11-13 実測)。link は
      # ファイル単位で張るので、ここだけ skill ごとのディレクトリ symlink になる
      # symlink-tree にする。~/.agents/skills は空なので丸ごと持っても何も消えない。
      agents.enable = true;
      gemini = {
        enable = true;
        dest = "${home}/.gemini/skills";
        structure = "link";
      };
    };
  };
}
