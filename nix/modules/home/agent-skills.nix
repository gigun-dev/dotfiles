# skill だけでできたものは plugin で包まず、agent-skills-nix で 3 ホストへ直接配る。
# 版は flake.lock で固定し、ホストに取りに行かせない (plugin の外部参照は host ごとに
# 更新の仕方が違い、古い版が残った。gigun-dev/claude-code ADR 0006)。
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
{
  config,
  lib,
  skillSources,
  ...
}:
let
  home = config.home.homeDirectory;

  # gigun-dev/claude-code の git-workflow plugin が上流の commit skill に当てていた置換。
  # コミットメッセージを日本語にし、Conventional Commits の type と scope だけ英語に残す。
  # 上流の文が変わったら黙って素通りさせず評価で止める。
  commitFrom = "Write the message in English with UK spelling:";
  commitTo = "Write the message in Japanese, keeping the Conventional Commits type and scope in English:";
  japaneseCommit =
    { original, ... }:
    if lib.hasInfix commitFrom original then
      builtins.replaceStrings [ commitFrom ] [ commitTo ] original
    else
      throw "agent-skills: ryoppippi の commit skill に置換元の文が無い。上流の変更を見て nix/modules/home/agent-skills.nix の commitFrom を直す";

  source = path: subdir: { inherit path subdir; };
in
{
  programs.agent-skills = {
    enable = true;

    sources = {
      ryoppippi = source skillSources.ryoppippi-dotfiles "agents/skills";
      # gigun-dev/claude-code が正本を持つ skill (pre-push・japanese-tech-writing)。
      gigun = source skillSources.gigun-plugins "skills";
      emil = source skillSources.emil-skills "skills";
      unslop = source skillSources.unslop "skills";
      hallmark = source skillSources.hallmark "skills";
      langfuse = source skillSources.langfuse-skills "skills";
      modern-web-guidance = source skillSources.modern-web-guidance "skills";
      yomiyasu = source skillSources.yomiyasu "skills";
      # twostraws の Swift skill は repo 直下の <name>/SKILL.md が本体。<name>/skills/ の下にも
      # 同じ SKILL.md の複製があるので、直下の子だけを探す。
      swift-concurrency = source skillSources.swift-concurrency-skill "." // {
        filter.maxDepth = 1;
      };
      swift-testing = source skillSources.swift-testing-skill "." // {
        filter.maxDepth = 1;
      };
      swiftui = source skillSources.swiftui-skill "." // {
        filter.maxDepth = 1;
      };
    };

    # plugin 版を同時に有効にしない (agy は plugin の skill に名前の区切りを付けないので、
    # 同名の skill が 2 つ並ぶ)。移した plugin は claude-code の marketplace から外してある。
    skills.enable = [
      "worktree"
      "ask-other-agent"
      "review-loop"
      "edit-skills"
    ];
    # ryoppippi の残りの skill (tdd・vitest など) は選んでいないので配らない。
    skills.enableAll = [
      "gigun"
      "emil"
      "unslop"
      "hallmark"
      "langfuse"
      "modern-web-guidance"
      "yomiyasu"
      "swift-concurrency"
      "swift-testing"
      "swiftui"
    ];
    skills.explicit.commit = {
      from = "ryoppippi";
      transform = japaneseCommit;
    };

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
