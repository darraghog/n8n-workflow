# Credentials for Shakespeare Play Workflow

Create these credentials in n8n before running the workflow. Workflow JSON must not contain secrets.

## Send Email (SMTP)

- **Type:** SMTP
- **Host:** Your SMTP server (e.g. `smtp.gmail.com`)
- **Port:** 465 (SSL) or 587 (TLS)
- **User:** Your email address
- **Password:** App password or account password
- Bind at import with `N8N_SMTP_CREDENTIAL_ID` or `N8N_SMTP_CREDENTIAL_NAME` (required in every environment).

## n8n container environment

These must be available inside the n8n process (`$env` in Code/Email nodes). `compose/n8n/compose.yaml` in localserver-config passes them through from the stack `.env`.

| Variable | Purpose |
|----------|---------|
| `SMTP_FROM_EMAIL` | From address (not hardcoded in the workflow) |
| `OPERATOR_EMAIL` | Only recipient for the Error Trigger workflow |
| `EMAIL_ALLOWLIST` | Form recipients: exact emails and/or `@domain.com`. Empty denies all. `*` allows all (unsafe). |
| `EVAL_WEBHOOK_TOKEN` | Shared token for `POST /webhook/shakespeare-play-explorer-test` (`X-Eval-Token` or JSON `eval_token`) |
| `OLLAMA_BASE_URL` | Default `http://host.docker.internal:11434` |
| `OLLAMA_MODEL` | Default `llama3.2` |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | Must be `false` so Code/Email nodes can read `$env` |

The test webhook never sends email. Form submissions send only when the address is allowlisted.

## Ollama

Ollama is called via HTTP Request using `$env.OLLAMA_BASE_URL`. No n8n credential is used. Ensure Ollama is running on the host with the configured model pulled.
