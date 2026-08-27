#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CASES_PATH = path.join(ROOT, "evals", "cases.json");

function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  for (const line of fs.readFileSync(filePath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

function normPlay(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function asObject(body) {
  if (body && typeof body === "object") return body;
  if (typeof body !== "string") return null;
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
}

async function main() {
  loadDotEnv(path.join(ROOT, ".env"));

  const base =
    process.env.EVAL_WEBHOOK_URL ||
    process.env.SMOKE_WEBHOOK_URL ||
    "";
  const token = process.env.EVAL_WEBHOOK_TOKEN || "";
  if (!base) {
    console.error("FAIL: set EVAL_WEBHOOK_URL (or SMOKE_WEBHOOK_URL) to the no-email test webhook");
    process.exit(2);
  }
  if (!token) {
    console.error("FAIL: EVAL_WEBHOOK_TOKEN is required");
    process.exit(2);
  }

  const spec = JSON.parse(fs.readFileSync(CASES_PATH, "utf8"));
  const cases = spec.cases || [];
  const results = [];

  for (const testCase of cases) {
    const started = Date.now();
    let payload = null;
    let error = null;
    try {
      const res = await fetch(base, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Eval-Token": token,
        },
        body: JSON.stringify({
          play_name: testCase.play_name,
          output_type: testCase.output_type,
          email: testCase.email,
          eval_token: token,
        }),
      });
      const text = await res.text();
      payload = asObject(text);
      if (!res.ok) {
        error = `HTTP ${res.status}: ${text.slice(0, 300)}`;
      } else if (!payload) {
        error = `non-JSON response: ${text.slice(0, 300)}`;
      }
    } catch (err) {
      error = err.message;
    }

    const result = payload?.result || {};
    const schemaOk = payload?.schema_ok === true;
    const grounded =
      payload?.groundedness_ok === true &&
      normPlay(result.play) === normPlay(testCase.play_name);
    const requestTypeOk =
      !testCase.expect_requestType || result.requestType === testCase.expect_requestType;
    const pass = !error && schemaOk && grounded && requestTypeOk;

    results.push({
      id: testCase.id,
      pass,
      error,
      status: payload?.status || null,
      schema_fail: !schemaOk,
      groundedness_fail: !grounded,
      request_type_fail: !requestTypeOk,
      latency_ms: Date.now() - started,
    });
  }

  const passed = results.filter((r) => r.pass).length;
  const schemaFails = results.filter((r) => r.schema_fail).length;
  const groundedFails = results.filter((r) => r.groundedness_fail).length;
  const summary = {
    total: results.length,
    passed,
    failed: results.length - passed,
    schema_fail: schemaFails,
    groundedness_fail: groundedFails,
    results,
  };
  console.log(JSON.stringify(summary, null, 2));
  if (passed !== results.length) process.exit(1);
}

main().catch((err) => {
  console.error("FAIL:", err.message);
  process.exit(1);
});
