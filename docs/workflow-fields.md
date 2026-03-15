# Shakespeare Play Explorer – Field Reference

All workflow fields use `snake_case`. Workflow stages: Form → Ollama + Merge → Build Result → Send Email.

## Canonical Output Object (Build Result → Send Email)

| Field | Type | Description |
|-------|------|-------------|
| `play_name` | string | Shakespeare play name |
| `output_type` | string | "Key Characters" or "Human-centric Themes" |
| `output_type_value` | string | "characters" or "themes" |
| `email` | string | Recipient email |
| `json_content` | string | Formatted LLM response JSON |

## Data Flow

```
Form                    → play_name, output_type, email
  ├→ Ollama             ← play_name, output_type (prompt)
  └→ Merge (input 1)    ← play_name, output_type, email
       ↑
Ollama                  → message.content (API response)
       └→ Merge (input 2)
            ↓
Merge (append)          → [form, ollama]
            ↓
Build Result            → play_name, output_type, output_type_value, email, json_content
            ↓
Send Email              ← email, output_type, play_name, json_content
```
