# Intel fzf bottle: staged implementation

This is an fzf-only trial, not a general Homebrew package platform. Normal mini
resolution remains Nix fzf 0.71.0; the separately validated unlinked bottle is
0.74.5. Nothing here activates host adoption, a schedule, or publication.

## One recipe, two execution locations

`bash ci/homebrew-fzf/recipe.sh preflight` only reports the target, pinned core,
installed Go and existing fzf. It does not tap, fetch, install, unlink, clean up,
or change persistent PATH. Intel macOS 15 with `/usr/local` is required.

For a deliberately prepared local builder, use `build --work ABSOLUTE_DIR
--execute`. The builder must already have clean core at the lock revision, the
specified Go, and no installed fzf. Build installs fzf on that builder through
ordinary Homebrew. Use a separate clean builder for `verify --work ABSOLUTE_DIR
--artifact BUILD_DIRECTORY --execute`; it pours with `--skip-link`, verifies
Homebrew's poured receipt, architecture, version, filter, formula test and
unchanged Go receipt. No removal is automated. Do not run these mutation modes
on the operational mini, where the isolated fzf is already installed.

Only a disposable GitHub-hosted runner can use `prepare-ci --execute
--disposable-runner` or automatically prepare Go. The same build/verify code is
used locally and in Actions. No build sandbox is disabled. `brew unpack` checks
the pinned source hash; `go mod download` and `go mod verify` populate Homebrew's
standard Go cache before its network-denied source build.

## Reuse and compatibility

The key includes source/formula build hashes, versions/revisions, the bounded
Go dependency, recipe, macOS major, architecture and prefix. Unrelated core
commits and bottle publication metadata do not force rebuilds. A changed source,
Go or recipe does. A new dependency graph fails for review instead of silently
installing arbitrary additional tools. SDK, clang and Brew versions are recorded
in provenance, not imposed on a consumer. This establishes target compatibility,
not bit-for-bit reproducibility across compiler images.

`reuse --work DIR` accepts only a matching validated manifest and checksum.
Actions reuse searches retained artifacts from successful manual runs of this
workflow in this repository; expired, failed and unvalidated builds are not hits.
Corrupt hits stop. Artifacts are retained 14 days; expiration can require another
build. A cache is not a signature or a guarantee against repository compromise.
The original successful trial predates this manifest format and is not silently
promoted into a new cache entry.

## Disabled automation and durable storage

`policy.json` keeps heavy builds and update PRs disabled, with no durable
destination. The active heavy workflow has only a manual trigger and read-only
permissions. An explicit manual `bounded_trial=true` dispatch permits one bounded
validation while the default remains disabled; pushing this PR runs only lightweight recipe checks plus existing
repository checks. Nix required checks remain unchanged; code lives outside
`scripts/**` so this fzf-only PR does not request unrelated Nix builds.

`state.py detect --output /tmp/fzf-candidate.json` reads official immutable core
sources and writes a candidate only when relevant inputs change. The inert
`staged/update.yml.disabled` demonstrates deterministic branch deduplication and
draft PR creation with partial-failure resumption. Existing closed PRs are not
reopened; existing runs for the same head (including failures) are not dispatched
again automatically. API errors stop. It has no schedule and is not an active workflow. GITHUB_TOKEN
PR creation does not trigger pull_request checks: the inert template explicitly dispatches the bounded build on its new
deterministic branch and declares the future `actions: write` requirement. No new credential is proposed. Approval is needed before enabling
that write permission, schedule/cadence and build usage. No auto-merge or host
adoption is included.

Recommended durable destination is a private Release in this existing repository,
with immutable key-based tag and checksum/validation manifest. `state.py
archive-plan --environment FILE --directory DIR` prints a plan only.
`staged/publish.sh.disabled` is inert and refuses a missing approved destination;
it never clobbers an existing release. Before activation, approve destination and
publication scope and verify release access through existing controller authentication.
The read-only Release backend is implemented and mock-tested: when configured it
validates private visibility, complete assets, manifest/key/checksum before returning
a hit. Missing releases fall back to Actions artifacts; API failures stop. Existing
release publication retries download and verify the release instead of overwriting it. No release has
been created. Making the repository public would also expose these assets and is
a separate decision.

## Evidence and limits

The earlier live trial successfully built with Go 1.27.3, poured fzf 0.74.5 on a
fresh Intel runner without rebuilding Go, and validated it unlinked on mini.
Run 40391238749 reused the build from 40389694444; source build phase 416 seconds,
bottle 2348 KiB. SHA256:
`a47f1156d5781a7539bf3ff7c654581e9908adb35bafae74e882d17cbba19ad8`.
The new common recipe was live-built at commit `f03ba93` in run
[40397272398](https://github.com/gigun-dev/dotfiles/actions/runs/40397272398):
build job 9m10s (source-build/bottle phase492s), separate fresh-runner pour and
validation1m54s. fzf0.74.5 and Go1.27.3; macOS15/x86_64, SDK15.5,
Apple clang17.0.0, Homebrew6.0.18. Bottle2402197bytes, SHA256
`45957f1abe8b2c450629c09c3ed9afa31feb8bc16935417949b387f53249e689`.
The Go receipt/provenance check and poured-from-bottle receipt check passed.
Actual artifact tampering and a wrong key were rejected locally. Unit tests also
cover expiry, failed-run exclusion and update detection no-op/change outputs.
The previous preflight failures were caused by an untracked runner formula;
`prepare-ci` now preserves untracked files in its disposable-runner stash.
A second run [40399031167](https://github.com/gigun-dev/dotfiles/actions/runs/40399031167)
reused the validated artifact in22s, skipping build and verify jobs' mutation steps.
No claim is made that all shell CLI dependencies are solved. Usage allowance was not independently verified; no paid-overage authority
or new heavy run is assumed.

Run local checks:

```sh
bash -n ci/homebrew-fzf/recipe.sh
python3 -m unittest discover -s ci/homebrew-fzf/tests -v
```

## Activation permission boundary

Repository default token permissions remain read-only. The inert updater grants
contents:write, pull-requests:write and actions:write only to its update job.
The last permission is solely for explicit workflow dispatch; no token or registry
is added. The dispatched build gate runs lightweight tests before any Intel job.
No approve/merge/apply command is present. The repository's combined
“Allow GitHub Actions to create and approve pull requests” setting was observed
OFF; it must be approved separately before bot PR creation. Templates and policy
remain disabled until activation is authorized. No Release has been uploaded.
