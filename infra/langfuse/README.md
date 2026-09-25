# Langfuse on mini-vm

Langfuse v4 runs as the upstream Docker Compose stack inside the existing NixOS
Lima guest. NixOS owns Docker, secrets, lifecycle, health checks, and unattended
updates; Compose owns the application topology.

The initial deployment keeps blob storage in the local MinIO container so actual
CPU, memory, disk, and object-operation volume can be measured. The S3 settings
are isolated in `compose.yaml`; moving to R2 only requires replacing those
settings and removing the MinIO dependency and service.

Persistent data lives in Docker named volumes. List them with:

```sh
docker volume ls --filter name=langfuse
```

The browser UI is available at `https://langfuse.097969.xyz` through the
existing named tunnel and Cloudflare Access. The direct UI remains available
over the tailnet at `http://mini-vm:3000` for recovery.

OTLP ingestion uses a separate public tunnel hostname without interactive
Cloudflare Access. The origin proxy only accepts the OTLP path; Langfuse project
keys provide HTTP Basic authentication. The endpoint is:

```text
https://langfuse-otel.097969.xyz/api/public/otel/v1/traces
```

Use Basic authentication with the project public and secret keys stored in
`secrets/langfuse-env.age`, and send `x-langfuse-ingestion-version: 4`.

## Client endpoints

The REST API base and OTLP ingestion URL are intentionally separate:

- `LANGFUSE_BASE_URL=http://mini-vm:3000` is used for API reads and CLI access.
- `LANGFUSE_OTLP_ENDPOINT=https://langfuse-otel.097969.xyz/api/public/otel/v1/traces` is used to send OTLP traces.

Dotfiles declares these non-secret values in `claude/langfuse-endpoints.env`.
Client project keys remain in the local, git-ignored
`~/.config/claude-code/langfuse.env` file.

Open the encrypted file in an editor when the login password or project keys
are needed:

```sh
cd secrets
nix run github:ryantm/agenix -- -e langfuse-env.age
```

`LANGFUSE_INIT_USER_*` only bootstraps the first database user. After the first
startup, users, organizations, projects, and password changes are managed in
Langfuse/Postgres through the UI; editing those init values does not update an
existing user.

## Operations

```sh
systemctl status langfuse
journalctl -u langfuse -f
docker-compose -p langfuse -f /etc/langfuse/compose.yaml ps
curl -fsS http://127.0.0.1:3000/api/public/ready
```

Do not run `docker-compose down -v`; `-v` deletes all persistent data.

Non-major Langfuse updates are proposed by `langfuse-update-propose.timer` after
the release has aged seven days. The timer pins the new Web and Worker image
digests, builds the NixOS configuration, opens or refreshes a PR, and enables
GitHub auto-merge. Major releases are ignored and require a migration decision.

## Model pricing sync

Langfuse computes `totalCost` on a `GENERATION` observation only when its
`generation.model` string matches some registered model's `matchPattern`
(built-in models cover most public models, but not always the newest ones).
Without a match, `usageDetails` (token counts) still show up, but `totalCost`
stays `null` — that is what staleness looks like here, not an error anywhere.

`infra/langfuse/scripts/sync-model-pricing.py` fills that gap by reading prices
from litellm's canonical price sheet
(`https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`,
fetched at run time, not pinned or committed — see the script's module
docstring for why) and creating any model that's missing from Langfuse but
present in an explicit `TARGET_MODELS` list in the script. It never overwrites
an existing model; if litellm's numbers drift from an already-registered
model, it reports the drift and stops instead of silently fixing it. A model
absent from litellm's price sheet is reported as absent — the script does not
fill in a zero price.

```sh
# Requires ~/.config/claude-code/langfuse-endpoints.env and langfuse.env
# (same files the Claude Code OTLP hook uses). Default is --check: never writes.
python3 infra/langfuse/scripts/sync-model-pricing.py
python3 infra/langfuse/scripts/sync-model-pricing.py --write   # actually POSTs missing models
```

Before adding a model to `TARGET_MODELS`, confirm it is actually being used:

```sh
curl -sS -H "Authorization: Basic $(printf '%s:%s' "$LANGFUSE_PUBLIC_KEY" "$LANGFUSE_SECRET_KEY" | base64)" \
  "$LANGFUSE_BASE_URL/api/public/v2/observations?type=GENERATION&fields=core,basic,model&limit=200" \
  | python3 -c 'import json,sys,collections; print(collections.Counter(o["model"] for o in json.load(sys.stdin)["data"]))'
```

Costs are computed at ingestion time from whatever models exist at that
moment; registering a model does not retroactively backfill `totalCost` on
observations ingested before the model existed
([verified 2026-09-25] after registering `claude-opus-5-5`, generations
ingested *after* registration got `totalCost`, but ones ingested a minute
earlier stayed `null` even after the model existed). If pricing looks missing
for a model that is already registered, check whether the affected
observations predate the model's `createdAt`, not the `matchPattern`.
