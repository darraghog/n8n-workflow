# n8n Homelab Project Instructions

Standards for building n8n workflow applications deployed to a single-node **podman + podman-compose** homelab environment.

---

## 1. Overview and scope

- **Target:** n8n workflow applications on a homelab host running podman and podman-compose.
- **Assumptions:** Host is configured like `localserver-config` with n8n stack, Caddy tls-proxy, and systemd user services for lifecycle management.

---

## 2. Project layout

Use this directory structure for n8n workflow projects:

```
project-root/
├── workflows/              # Exported workflow JSON (one file per workflow)
├── compose/                # Optional: project-specific compose overlays
├── docs/                   # Runbooks, architecture notes
├── .env.example            # Documented env vars (no secrets)
└── PROJECT-INSTRUCTIONS.md # This file (or link to shared standards)
```

- **workflows/** — Export workflows as individual JSON files. Name by slug: `workflow-name.json` or `{id}-{slug}.json`.
- **compose/** — Only if you extend or override the base n8n stack. Otherwise, use the canonical compose from `localserver-config/compose/n8n/`.
- **docs/** — Runbooks, architecture decisions, troubleshooting.
- **.env.example** — List required and optional variables with brief descriptions; never include secrets.

---

## 3. Compose and deployment standards

### 3.1 Tool choice

- Use **podman-compose** (not `podman compose`) to avoid conmon-related issues.
- Install via `uv tool install podman-compose` or system package if available.

### 3.2 Compose file conventions

- **Base:** `compose.yaml` — n8n with SQLite, ports, env, healthcheck.
- **Overlay:** `compose.postgres.yaml` — Applied when `N8N_DATABASE=postgres`; adds Postgres service and DB env vars.

Example deploy command with overlay:

```bash
podman-compose -f compose.yaml -f compose.postgres.yaml up -d
```

### 3.3 Required environment variables

| Variable | Description |
|----------|-------------|
| `N8N_BASIC_AUTH_PASSWORD` | Admin password for the n8n UI |
| `N8N_ENCRYPTION_KEY` | Key for encrypting credentials; generate with `openssl rand -hex 32` |

When using Postgres overlay:

| Variable | Description |
|----------|-------------|
| `POSTGRES_PASSWORD` | Postgres password for n8n database |

### 3.4 Port mapping and volumes

- **Ports:** n8n HTTP on 5678; HTTPS via tls-proxy on 8444.
- **Volumes:** Named volumes `n8n-data` (and `postgres-data` if Postgres); create externally when needed:

```bash
podman volume create postgres-data
```

### 3.5 Healthchecks

Use the n8n health endpoint:

```yaml
healthcheck:
  test: "wget -qO- http://127.0.0.1:5678/healthz || exit 1"
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 30s
```

---

## 4. Workflow version control

### 4.1 Export format

- Export workflows as JSON from the n8n UI (three-dot menu) or via the n8n CLI.
- One file per workflow. Naming: `workflow-name.json` or `{id}-{slug}.json`.

### 4.2 Credentials in exports

- Exported JSON can contain credential references. **Strip or anonymise** sensitive data before committing.
- Document credential names and types separately (e.g. in `docs/credentials.md`) so they can be recreated on a new instance.

### 4.3 Automated backup

You can use a meta-workflow: n8n API + Git node to backup all workflows to a Git repo on a schedule. See [n8n docs on export/import](https://docs.n8n.io/workflows/export-import) and community templates for "backup workflows to GitHub".

---

## 5. Homelab integration

### 5.1 TLS and URLs

- TLS is provided by the existing Caddy tls-proxy (e.g. on 8443, 8444).
- Set these for correct webhook and editor URLs:

```bash
export N8N_HOST="$(hostname)"
export N8N_EDITOR_BASE_URL="https://${N8N_HOST}:8444"
export N8N_WEBHOOK_URL="${N8N_EDITOR_BASE_URL}/"
```

### 5.2 extra_hosts

Include host resolution so webhooks and callbacks reach the host:

```yaml
extra_hosts:
  - "${N8N_HOST:-localhost}:host-gateway"
  - "host.docker.internal:host-gateway"
```

### 5.3 Systemd

Use oneshot services that call start/stop scripts. Example pattern:

```ini
[Unit]
Description=n8n compose stack
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=__HOME__/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=__REPO_ROOT__/scripts/start-n8n.sh up
ExecStop=__REPO_ROOT__/scripts/start-n8n.sh down

[Install]
WantedBy=default.target
```

The script loads `.env`, sets `N8N_HOST` and `N8N_EDITOR_BASE_URL`, and runs `podman-compose` with the appropriate compose files.

### 5.4 Deploy flow

- **Full deploy:** `./scripts/deploy.sh` — installs base packages, podman, compose, systemd units, and brings up stacks.
- **Compose-only (updates):** `./scripts/deploy.sh --compose-only` — skips package install; use when syncing from a dev machine via SSH.

---

## 6. Secrets and credentials

- Store secrets in `.env` in the project root. Ensure `.env` is in `.gitignore`.
- Provide `.env.example` with variable names and descriptions (no values).
- **Never commit:** `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_PASSWORD`, `POSTGRES_PASSWORD`.

Example `.env.example`:

```
# Required
N8N_BASIC_AUTH_PASSWORD=      # Admin UI password
N8N_ENCRYPTION_KEY=            # Generate: openssl rand -hex 32

# Optional: use Postgres instead of SQLite
N8N_DATABASE=postgres
POSTGRES_PASSWORD=             # Only if N8N_DATABASE=postgres
```

---

## 7. Database options

| Option | When to use | Volume |
|--------|-------------|--------|
| **SQLite** | Default; single-node, low concurrency | `n8n-data` |
| **Postgres** | Homelab "production"; multiple workers, better durability | `n8n-data` + `postgres-data` (external) |

To switch to Postgres:

1. Set `N8N_DATABASE=postgres` in `.env`.
2. Set `POSTGRES_PASSWORD`.
3. Create volume: `podman volume create postgres-data`.
4. Deploy with overlay: `podman-compose -f compose.yaml -f compose.postgres.yaml up -d`.

---

## 8. Quick reference

### Ports and URLs

| Service | HTTP | HTTPS |
|---------|------|-------|
| n8n | 5678 | 8444 (via tls-proxy) |

### Scripts (typical)

| Script | Purpose |
|--------|---------|
| `scripts/deploy.sh` | Full install + deploy |
| `scripts/deploy.sh --compose-only` | Compose-only deploy (updates) |
| `scripts/start-n8n.sh up` | Start n8n stack |
| `scripts/start-n8n.sh down` | Stop n8n stack |

### n8n docs

- [Export and import workflows](https://docs.n8n.io/workflows/export-import)
- [CLI commands](https://docs.n8n.io/hosting/cli-commands)
