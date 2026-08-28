# Shakespeare Play Explorer – Field Reference

All workflow fields use `snake_case`.

## Workflow layout

```
Form adapter                    Eval adapter
  Form / Map Form Request         Webhook / Map Eval Request
           \                            /
            \                          /
             →  Run Core (Execute Sub-workflow)  →
                        |
              Core sub-workflow
    When Executed by Another Workflow
        → Prepare Request → Ollama path → Build Result → Log Execution
                        |
         back to adapter (email or Respond to Webhook)
```

Operator errors: `Shakespeare Play Explorer – Operator Errors` (Error Trigger → Notify Operator).

## Core input (sub-workflow)

Adapters pass this to **Run Core**:

| Field | Type | Description |
|-------|------|-------------|
| `channel` | string | `form` or `eval` — controls allowlist and email |
| `request_id` | string | Optional UUID; core generates one if omitted |
| `play_name` | string | Play name from form or webhook body |
| `output_type` | string | `Key Characters` or `Human-centric Themes` |
| `email` | string | Recipient (form path); ignored for eval response |

## Canonical Prepare Request output

| Field | Type | Description |
|-------|------|-------------|
| `request_id` | string | UUID correlation id |
| `channel` | string | `form` or `eval` |
| `play_name` | string | Sanitized play name (letters, numbers, spaces, `.,'-`; max 80) |
| `play_valid` | bool | Whether the raw play name passed validation |
| `output_type` | string | "Key Characters" or "Human-centric Themes" |
| `email` | string | Submitted recipient (never returned on the test webhook) |
| `email_allowed` | bool | Recipient is on `EMAIL_ALLOWLIST` |
| `from_email` | string | `$env.SMTP_FROM_EMAIL` |
| `from_webhook` | bool | `channel === "eval"` |
| `skip_ollama` | bool | Validation or allowlist failure; do not call the model |
| `skip_email` | bool | True when `channel === "eval"` |
| `send_email` | bool | `channel === "form"` and allowlisted and `SMTP_FROM_EMAIL` set |
| `ollama_url` | string | `$env.OLLAMA_BASE_URL` + `/api/chat` |
| `ollama_body` | string | JSON-encoded chat payload (system + JSON user message) |
| `status` | string | `ok`, `validation_error`, or `email_rejected` at prepare time |

## Canonical Build Result output

| Field | Type | Description |
|-------|------|-------------|
| `request_id` | string | Correlation id |
| `play_name` | string | Play name |
| `output_type` | string | "Key Characters" or "Human-centric Themes" |
| `output_type_value` | string | `characters` or `themes` |
| `email` | string | Recipient (redacted from webhook JSON and logs) |
| `from_email` | string | SMTP from address |
| `parse_ok` | bool | Model output parsed as JSON |
| `schema_ok` | bool | `{ play, requestType, title, items[], summary }` valid |
| `groundedness_ok` | bool | `result.play` matches `play_name` |
| `item_count` | number | Length of `items` |
| `status` | string | `ok`, `validation_error`, `email_rejected`, `ollama_unavailable`, `parse_fail`, `schema_fail`, `groundedness_fail` |
| `json_content` | string | Pretty-printed result JSON for email |
| `html_email_body` | string | HTML table email (after Build HTML Email) |
| `webhook_response` | object | Public JSON for the test webhook (no email) |

## LLM result schema

```json
{
  "play": "Hamlet",
  "requestType": "characters",
  "title": "Key Characters in Hamlet",
  "items": [{ "name": "Hamlet", "description": "Prince of Denmark" }],
  "summary": "A tragedy of indecision and revenge."
}
```

`requestType` is `characters` or `themes`. Error shapes add `"error": "<status>"`.

## Triggers

| Trigger | Path | Email | Auth |
|---------|------|-------|------|
| Form | `/form/shakespeare-play-explorer` | Only if allowlisted | Recipient allowlist (fail closed) |
| Webhook | `/webhook/shakespeare-play-explorer-test` | Never | `X-Eval-Token` or body `eval_token` must match `EVAL_WEBHOOK_TOKEN` |
