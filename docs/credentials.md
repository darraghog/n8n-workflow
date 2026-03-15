# Credentials for Shakespeare Play Workflow

Create these credentials in n8n before running the workflow.

## Send Email (SMTP)

- **Type:** SMTP
- **Host:** Your SMTP server (e.g. `smtp.gmail.com`)
- **Port:** 465 (SSL) or 587 (TLS)
- **User:** Your email address
- **Password:** App password or account password
- **From Email:** Address that appears as sender

For Gmail, enable 2-step verification and generate an app password.

## Ollama

Ollama is called via HTTP Request; no n8n credential is used. Ensure:
- Ollama runs on the host (e.g. `ollama run llama3.2`)
- From n8n in Docker/podman, use `http://host.docker.internal:11434`
