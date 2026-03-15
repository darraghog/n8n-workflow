#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const ROOT = path.resolve(
  process.argv[2] || "/home/darraghog/dev/cursor-projects/n8n-workflow",
);
const WORKFLOW_PATH = path.join(
  ROOT,
  "workflows",
  "shakespeare-play-explorer.json",
);

function readWorkflow() {
  const raw = fs.readFileSync(WORKFLOW_PATH, "utf8");
  return JSON.parse(raw);
}

function getNode(workflow, name) {
  const node = workflow.nodes.find((n) => n.name === name);
  assert(node, `Missing node: ${name}`);
  return node;
}

function runCodeNode(jsCode, inputJsonItems) {
  const context = {
    $input: {
      all: () => inputJsonItems.map((json) => ({ json })),
    },
  };

  const script = new vm.Script(`(function(){\n${jsCode}\n})()`, {
    filename: "BuildResult.inline.js",
  });

  return script.runInNewContext(context, { timeout: 1000 });
}

function testStructure(workflow) {
  assert.equal(workflow.name, "Shakespeare Play Explorer");

  // Required nodes/stages
  const form = getNode(workflow, "Form");
  const ollama = getNode(workflow, "Ollama");
  const merge = getNode(workflow, "Merge");
  const build = getNode(workflow, "Build Result");
  const buildHtml = getNode(workflow, "Build HTML Email");
  const email = getNode(workflow, "Send Email");

  assert.equal(form.type, "n8n-nodes-base.formTrigger");
  assert.equal(ollama.type, "n8n-nodes-base.httpRequest");
  assert.equal(merge.type, "n8n-nodes-base.merge");
  assert.equal(build.type, "n8n-nodes-base.code");
  assert.equal(buildHtml.type, "n8n-nodes-base.code");
  assert.equal(email.type, "n8n-nodes-base.emailSend");

  // Form fields are canonical snake_case names
  const fields = form.parameters.formFields.values.map((f) => f.fieldName);
  assert.deepEqual(fields, ["play_name", "output_type", "email"]);

  // Connection topology
  const c = workflow.connections;
  assert(c.Form?.main?.[0], "Missing Form connections");
  assert(c.Ollama?.main?.[0], "Missing Ollama connections");
  assert(c.Merge?.main?.[0], "Missing Merge connections");
  assert(c["Build Result"]?.main?.[0], "Missing Build Result connections");
  assert(c["Build HTML Email"]?.main?.[0], "Missing Build HTML Email connections");

  const formTargets = c.Form.main[0].map((x) => x.node).sort();
  assert.deepEqual(formTargets, ["Merge", "Ollama"]);
  assert.equal(c.Ollama.main[0][0].node, "Merge");
  assert.equal(c.Merge.main[0][0].node, "Build Result");
  assert.equal(c["Build Result"].main[0][0].node, "Build HTML Email");
  assert.equal(c["Build HTML Email"].main[0][0].node, "Send Email");
}

function testOutputFieldReferences(workflow) {
  const emailNode = getNode(workflow, "Send Email");
  const text = emailNode.parameters.text;
  const html = emailNode.parameters.html;
  assert(
    text.includes("{{ $json.json_content }}"),
    "Send Email should reference json_content",
  );
  assert.equal(
    emailNode.parameters.emailFormat,
    "both",
    "Send Email should send both text and HTML formats",
  );
  assert(
    html.includes("{{ $json.html_email_body }}"),
    "Send Email HTML should reference html_email_body",
  );
  assert(
    !text.includes("jsonContent"),
    "Legacy field jsonContent should not be used",
  );
}

function testBuildResultCodeNode(workflow) {
  const build = getNode(workflow, "Build Result");
  const jsCode = build.parameters.jsCode;
  assert(jsCode.includes("output_type_value"), "Build Result should output output_type_value");
  assert(jsCode.includes("json_content"), "Build Result should output json_content");

  // Case 1: valid JSON from Ollama text
  const form = {
    play_name: "Hamlet",
    output_type: "Key Characters",
    email: "user@example.com",
  };
  const ollama = {
    message: {
      content:
        '{"play":"Hamlet","requestType":"characters","title":"Key Characters in Hamlet","items":[{"name":"Hamlet","description":"Prince of Denmark"}],"summary":"A tragedy of indecision and revenge."}',
    },
  };

  const out1 = runCodeNode(jsCode, [form, ollama]);
  assert(out1?.json, "Build Result should return object with json");
  assert.equal(out1.json.play_name, "Hamlet");
  assert.equal(out1.json.output_type, "Key Characters");
  assert.equal(out1.json.output_type_value, "characters");
  assert.equal(out1.json.email, "user@example.com");
  assert.equal(typeof out1.json.json_content, "string");
  const parsed1 = JSON.parse(out1.json.json_content);
  assert.equal(parsed1.play, "Hamlet");

  // Case 1b: reversed merge order should still work
  const out1b = runCodeNode(jsCode, [ollama, form]);
  assert(out1b?.json, "Build Result should return object with json (reversed order)");
  assert.equal(out1b.json.play_name, "Hamlet");
  assert.equal(out1b.json.output_type, "Key Characters");
  assert.equal(out1b.json.output_type_value, "characters");
  assert.equal(out1b.json.email, "user@example.com");
  const parsed1b = JSON.parse(out1b.json.json_content);
  assert.equal(parsed1b.play, "Hamlet");

  // Case 2: non-JSON Ollama text should still produce usable json_content
  const out2 = runCodeNode(jsCode, [
    { ...form, output_type: "Human-centric Themes" },
    { response: "Themes include ambition, guilt, and moral conflict." },
  ]);
  assert.equal(out2.json.output_type_value, "themes");
  const parsed2 = JSON.parse(out2.json.json_content);
  assert.equal(parsed2.play, "Hamlet");
  assert.equal(parsed2.requestType, "themes");

  // Case 3: legacy Form Trigger keys (label-based) should still map correctly
  const out3 = runCodeNode(jsCode, [
    {
      "Shakespeare Play": "Macbeth",
      "What would you like?": "Key Characters",
      "Your email address": "legacy@example.com",
    },
    {
      response:
        '{"play":"Macbeth","requestType":"characters","title":"Key Characters in Macbeth","items":[{"name":"Macbeth","description":"Scottish nobleman"}],"summary":"Ambition and consequence."}',
    },
  ]);
  assert.equal(out3.json.play_name, "Macbeth");
  assert.equal(out3.json.output_type, "Key Characters");
  assert.equal(out3.json.email, "legacy@example.com");
}

function testBuildHtmlEmailCodeNode(workflow) {
  const buildHtml = getNode(workflow, "Build HTML Email");
  const jsCode = buildHtml.parameters.jsCode;
  assert(jsCode.includes("html_email_body"), "Build HTML Email should output html_email_body");

  const out = runCodeNode(jsCode, [
    {
      play_name: "Hamlet",
      output_type: "Key Characters",
      email: "user@example.com",
      json_content: JSON.stringify({
        play: "Hamlet",
        requestType: "characters",
        title: "Key Characters in Hamlet",
        items: [{ name: "Hamlet", description: "Prince of Denmark" }],
        summary: "A tragedy of revenge.",
      }),
    },
  ]);

  assert.equal(out?.json?.email, "user@example.com");
  assert.equal(typeof out?.json?.html_email_body, "string");
  assert(
    out.json.html_email_body.includes("<table"),
    "html_email_body should include a table",
  );
  assert(
    out.json.html_email_body.includes("Key Characters in Hamlet"),
    "html_email_body should include parsed title",
  );
}

function main() {
  const workflow = readWorkflow();
  testStructure(workflow);
  testOutputFieldReferences(workflow);
  testBuildResultCodeNode(workflow);
  testBuildHtmlEmailCodeNode(workflow);
  console.log("PASS: workflow structure and dataflow checks succeeded");
}

try {
  main();
} catch (err) {
  console.error("FAIL:", err.message);
  process.exit(1);
}
