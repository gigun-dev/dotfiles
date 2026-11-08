#!/usr/bin/env bash
# 使い捨て repo だけで git/hooks/pre-commit を検証する。実 checkout / ユーザー設定には書き込まない。
# nix は偽物を PATH 先頭に置き、`nix fmt` と `nix run .#gitleaks` だけを実物の
# treefmt / gitleaks へ振る (fixture に flake が無いため)。
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
hook=$root/git/hooks/pre-commit
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

system=$(nix eval --impure --raw --expr builtins.currentSystem)
treefmt=$(nix build --no-link --print-out-paths "$root#formatter.$system")/bin/treefmt
gitleaks=$(nix eval --raw "$root#apps.$system.gitleaks.program")
nix-store --realise "${gitleaks%/bin/gitleaks}" >/dev/null
mkdir "$scratch/bin"
cat >"$scratch/bin/nix" <<EOF
#!/usr/bin/env bash
case "\$1" in
  fmt)
    shift
    # FOREIGN_WT があれば、整形中に別 worktree が stash を積む (同時 commit の再現)。
    if [ -n "\${FOREIGN_WT:-}" ]; then
      printf 'foreign\\n' >>"\$FOREIGN_WT/notes.txt"
      # hook の中は git commit の GIT_INDEX_FILE などを継ぐので、別プロセスの commit に見えるよう外す。
      env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX \\
        git -C "\$FOREIGN_WT" stash push --quiet --message foreign
    fi
    exec "$treefmt" "\$@" ;;
  run) shift 3; exec "$gitleaks" "\$@" ;;
esac
exit 1
EOF
chmod +x "$scratch/bin/nix"
export PATH="$scratch/bin:$PATH"

repo="$scratch/repo with space"
git init -q -b main "$repo"
cd "$repo"
git config core.hooksPath "$root/git/hooks"
printf '{ }\n' >flake.nix
body='{\n  a = 1;\n  p = 1;\n  q = 1;\n  r = 1;\n  s = 1;\n  t = 1;\n  z = 1;\n}\n'
printf "$body" >"a b.nix"; printf "$body" >c.nix
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' >notes.txt
printf 'x\n' >other.txt
git add .
git -c core.hooksPath=/dev/null commit -qm initial

# (a) unstaged が無ければ退避は起きず、staged の整形がそのまま commit に入る。
sed -i.bak 's/^  a = 1;$/  a=2;/' "a b.nix"; rm "a b.nix.bak"
git add "a b.nix"
git commit -qm format
git show HEAD:'a b.nix' | grep -qx '  a = 2;'
[ -z "$(git stash list)" ]

# (b) 整形済みの staged と、同じファイルの離れた unstaged hunk・別ファイルの unstaged・
# untracked は、pop で commit 後も残る。
sed -i.bak 's/^  a = 1;$/  a = 2;/' c.nix; rm c.nix.bak; git add c.nix
sed -i.bak 's/^  z = 1;$/  z = 9;/' c.nix; rm c.nix.bak
sed -i.bak 's/^one$/ONE/' notes.txt; rm notes.txt.bak; git add notes.txt
sed -i.bak 's/^ten$/TEN/' notes.txt; rm notes.txt.bak
printf 'y\n' >>other.txt                # 別ファイルの unstaged
printf 'u\n' >untracked.txt
git commit -qm change
git show HEAD:c.nix | grep -qx '  a = 2;'
! git show HEAD:c.nix | grep -q 'z = 9'
[ "$(git show HEAD:notes.txt | head -n1)" = ONE ]
grep -qx '  z = 9;' c.nix
grep -q '^y$' other.txt
[ "$(cat untracked.txt)" = u ]
git diff --quiet HEAD -- other.txt && { echo 'FAIL: unstaged lost' >&2; exit 1; }
[ -z "$(git stash list)" ]
git checkout -q -- . && rm untracked.txt

# 整形が staged を書き換え、退避中に unstaged があると pop が衝突する (ryoppippi 方式の既知の制約)。
# 黙って通さず失敗し、stash を残す。
git checkout -q -- .
sed -i.bak 's/^  a = 2;$/  a=5;/' "a b.nix"; rm "a b.nix.bak"; git add "a b.nix"
sed -i.bak 's/^  a=5;$/  a=6;/' "a b.nix"; rm "a b.nix.bak"
if git commit -qm conflict 2>"$scratch/err"; then echo 'FAIL: conflict ignored' >&2; exit 1; fi
grep -q 'stash (pre-commit' "$scratch/err"
[ -n "$(git stash list)" ]
git reset -q --hard; git stash drop -q

# (c) 秘密を staged すると止まり、作業ツリーは元に戻る。
printf 'keep\n' >>other.txt
printf 'u\n' >untracked.txt
key="AKIA$(printf 'IOSFODNN7EXAMPLE')"
printf 'aws_access_key_id = "%s"\naws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzZ3xAmPLeKEy9"\n' "$key" >creds.txt # gitleaks:allow (テスト用のダミー)
git add creds.txt
if git commit -qm leak 2>"$scratch/err"; then echo 'FAIL: leak committed' >&2; exit 1; fi
grep -q 'gitleaks' "$scratch/err"
[ "$(git log --oneline | wc -l | tr -d ' ')" = 3 ]
git diff --cached --name-only | grep -qx creds.txt
grep -q '^keep$' other.txt
[ "$(cat untracked.txt)" = u ]
[ -z "$(git stash list)" ]
git reset -q; rm creds.txt; git checkout -q -- .; rm untracked.txt

# (d) 整形失敗 (構文エラー) で止まり、unstaged は残る。
printf '{ broken = ;\n' >"a b.nix"; git add "a b.nix"
printf 'keep\n' >>other.txt
if git commit -qm broken 2>"$scratch/err"; then echo 'FAIL: bad nix committed' >&2; exit 1; fi
grep -q 'treefmt' "$scratch/err"
grep -q '^keep$' other.txt
[ -z "$(git stash list)" ]
git reset -q; git checkout -q -- .
# untracked だけを退避したときも pop で戻る。
# untracked だけが残っている (tracked の unstaged が無い) と戻す差分が空になる。それでも通る。
printf 'only\n' >>notes.txt; git add notes.txt
printf 'u\n' >untracked.txt
git commit -qm untracked-only
[ "$(cat untracked.txt)" = u ]
[ -z "$(git stash list)" ]
rm untracked.txt

# 整形中に別 worktree が stash を積んでも、自分の退避だけを pop し、相手の stash は残す。
git worktree add -q "$scratch/other" -b other
printf 'mine\n' >>other.txt
printf 'race\n' >>notes.txt; git add notes.txt
FOREIGN_WT="$scratch/other" git commit -qm race
grep -q '^mine$' other.txt
[ "$(git stash list --format=%gs)" = "On other: foreign" ]
! grep -q foreign notes.txt
git stash drop -q; git checkout -q -- other.txt
git worktree remove --force "$scratch/other"

# 何も staged でなければ hook は何もしない (nix が無くても通る)。
PATH=/usr/bin:/bin "$BASH" "$hook"
echo ok
