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

The UI and OTLP endpoint are available over the tailnet at
`http://mini-vm:3000`. The trace endpoint is:

```text
http://mini-vm:3000/api/public/otel/v1/traces
```

Use Basic authentication with the project public and secret keys stored in
`secrets/langfuse-env.age`, and send `x-langfuse-ingestion-version: 4`.

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
