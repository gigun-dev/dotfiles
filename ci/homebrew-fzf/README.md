# Intel fzf bottle: staged implementation

This is an fzf-only trial, not a general Homebrew package platform. Normal mini
resolution remains Nix fzf 0.71.0; the separately validated unlinked bottle is
0.74.5. Daily detection and private artifact storage are enabled; normal host adoption is separate.

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

## Update detection and private storage

The repository remains private. `policy.json` enables builds and update PRs,
and names `gigun-dev/dotfiles` as the private Release destination.
`fzf-update.yml` runs manually and daily at 03:00 JST. The schedule was enabled
after the GitHub App and protected Environment passed live acceptance.
No relevant input change means no PR or Intel job. A changed fzf/Go/formula
creates one draft PR; the App then sends `repository_dispatch` to the trusted
default-branch workflow to start bounded build/validation.
There is no autoapproval, automerge or mini autoapply.

`update.py` resumes partial failures after branch/PR creation, does not reopen
closed PRs or automatically retry failed builds each day, and stops on API errors.
The gate rejects dispatches from actors other than the configured App bot, checks
that the candidate commit changes only `fzf.lock.json`, and reads that lock without
executing candidate-branch code. The default
workflow token remains read-only; only the updater's short-lived, one-repository
GitHub App token can write Contents and Pull requests. The App has no Actions,
Administration or Workflows permission. Build and verify stay read-only.
The repository default token permission stays read; the combined repository
Actions create/approve-PR setting is separately enabled for PR creation only.

Release lookup verifies private visibility, complete assets, manifest/key and
checksum. A missing release falls back to14-day Actions artifacts; API failures
stop. Existing releases are never overwritten. Promotion is explicit, after
review of the input and successful build; unmerged update PRs do not publish.
The already validated bottle can be saved without rebuilding:

```sh
APPROVED_PRIVATE_REPOSITORY=gigun-dev/dotfiles \
VALIDATED_DIRECTORY=/absolute/path/to/validated-artifact \
ENVIRONMENT_JSON=/absolute/path/to/environment.json \
APPROVED_COMMIT=<reviewed-source-commit> bash ci/homebrew-fzf/publish.sh
```

The manifest contains the bottle checksum and builder provenance. Release tags
are `fzf-bottle-<input-key>` and are not marked as the repository's latest release.
Existing release retries download and verify before returning. A failed partial
upload stops for inspection; no automatic overwrite/delete occurs. Existing
controller authentication suffices; no new mini credential is required.
Making this repository public also exposes its releases and remains out of scope.
Normal mini PATH and Nix copies are unchanged.

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
