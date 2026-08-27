#!/usr/bin/env python3
"""Append missing shakespeare-play-explorer env keys. Does not print secret values."""
import secrets
from pathlib import Path


def existing_keys(path: Path) -> dict:
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value
    return out


def append_missing(path: Path, keys: dict) -> list:
    present = existing_keys(path)
    additions = []
    for key, value in keys.items():
        if key not in present:
            additions.append(f"{key}={value}")
    if not additions:
        return []
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    with path.open("a", encoding="utf-8") as handle:
        if text and not text.endswith("\n"):
            handle.write("\n")
        handle.write("\n# shakespeare-play-explorer runtime\n")
        handle.write("\n".join(additions) + "\n")
    return [item.split("=", 1)[0] for item in additions]


def main():
    project_env = Path("/home/darraghog/dev/cursor-projects/n8n-workflow/.env")
    local_env = Path("/home/darraghog/dev/localserver-config/envs/local.env")
    prod_env = Path("/home/darraghog/dev/localserver-config/envs/prod.env")

    current = existing_keys(project_env)
    token = current.get("EVAL_WEBHOOK_TOKEN") or secrets.token_urlsafe(24)

    project_keys = {
        "SMTP_FROM_EMAIL": current.get("SMTP_FROM_EMAIL", ""),
        "OPERATOR_EMAIL": current.get("OPERATOR_EMAIL", ""),
        "EMAIL_ALLOWLIST": current.get("EMAIL_ALLOWLIST", ""),
        "EVAL_WEBHOOK_TOKEN": token,
        "OLLAMA_BASE_URL": current.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434"),
        "OLLAMA_MODEL": current.get("OLLAMA_MODEL", "llama3.2"),
        "PROD_TARGET": current.get("PROD_TARGET", "beeblebox"),
    }
    stack_keys = {
        "SMTP_FROM_EMAIL": current.get("SMTP_FROM_EMAIL", ""),
        "OPERATOR_EMAIL": current.get("OPERATOR_EMAIL", ""),
        "EMAIL_ALLOWLIST": current.get("EMAIL_ALLOWLIST", ""),
        "EVAL_WEBHOOK_TOKEN": token,
        "OLLAMA_BASE_URL": "http://host.docker.internal:11434",
        "OLLAMA_MODEL": "llama3.2",
    }
    print("project_added", ",".join(append_missing(project_env, project_keys)) or "none")
    print("local_added", ",".join(append_missing(local_env, stack_keys)) or "none")
    print("prod_added", ",".join(append_missing(prod_env, stack_keys)) or "none")
    print("eval_token_present", "yes")


if __name__ == "__main__":
    main()
