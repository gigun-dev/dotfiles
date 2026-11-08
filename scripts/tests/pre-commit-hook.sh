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
  fmt) shift; exec "$treefmt" "\$@" ;;
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

# (a)+(b) staged の整形が commit に入り、unstaged / untracked は commit 後も残る。
sed -i.bak 's/^  a = 1;$/  a=2;/' "a b.nix"; rm "a b.nix.bak"
git add "a b.nix"
# 整形済みの staged 行 + 同じファイルの離れた unstaged hunk (整形が触らなければ pop は衝突しない)。
sed -i.bak 's/^  a = 1;$/  a = 2;/' c.nix; rm c.nix.bak; git add c.nix
sed -i.bak 's/^  z = 1;$/  z = 9;/' c.nix; rm c.nix.bak
sed -i.bak 's/^one$/ONE/' notes.txt; rm notes.txt.bak; git add notes.txt
sed -i.bak 's/^ten$/TEN/' notes.txt; rm notes.txt.bak
printf 'y\n' >>other.txt                # 別ファイルの unstaged
printf 'u\n' >untracked.txt
git commit -qm change
git show HEAD:'a b.nix' | grep -qx '  a = 2;'
git show HEAD:c.nix | grep -qx '  a = 2;'
! git show HEAD:c.nix | grep -q 'z = 9'
[ "$(git show HEAD:notes.txt | head -n1)" = ONE ]
grep -qx '  z = 9;' c.nix
grep -q '^y$' other.txt
[ "$(cat untracked.txt)" = u ]
git diff --quiet HEAD -- other.txt && { echo 'FAIL: unstaged lost' >&2; exit 1; }
[ -z "$(git stash list)" ]
git checkout -q -- . && rm untracked.txt

# 同じ行を整形と unstaged 編集が両方触ると pop が衝突する。握りつぶさず失敗し、stash を残す。
git checkout -q -- .
sed -i.bak 's/^  a = 2;$/  a=5;/' "a b.nix"; rm "a b.nix.bak"; git add "a b.nix"
sed -i.bak 's/^  a=5;$/  a=6;/' "a b.nix"; rm "a b.nix.bak"
if git commit -qm conflict 2>"$scratch/err"; then echo 'FAIL: conflict ignored' >&2; exit 1; fi
grep -q 'stash@{0}' "$scratch/err"
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
[ "$(git log --oneline | wc -l | tr -d ' ')" = 2 ]
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

# untracked だけが残っている (tracked の unstaged が無い) と戻す差分が空になる。それでも通る。
printf '  # only\n' >>"a b.nix"; git add "a b.nix"
printf 'u\n' >untracked.txt
git commit -qm untracked-only
[ "$(cat untracked.txt)" = u ]
[ -z "$(git stash list)" ]
rm untracked.txt

# 何も staged でなければ hook は何もしない (nix が無くても通る)。
PATH=/usr/bin:/bin "$BASH" "$hook"
echo ok
