import { readFile, writeFile } from "node:fs/promises";

const args = process.argv.slice(2);
const migrate = args.includes("--migrate");
const file = args.find((arg) => !arg.startsWith("--")) ?? ".sdlc.yml";
const errors = [];
const sections = new Set([
  "labels", "branch", "implementation", "pull_request", "verification",
  "delivery", "orchestration", "reconciliation",
]);
const keys = new Map([
  ["labels", new Set(["mode", "vocabulary", "mappings"])],
  ["branch", new Set(["pattern", "default"])],
  ["implementation", new Set(["create_branch", "use_worktree", "worktree_root", "commit_reference_required"])],
  ["pull_request", new Set(["creation"])],
  ["verification", new Set(["require_tests", "require_acceptance_checks", "require_manual_evidence_when_relevant", "reject_unrelated_changes"])],
  ["delivery", new Set(["default_flavor", "flavors"])],
  ["orchestration", new Set(["automatic_lifecycle", "max_concurrency", "max_remediation_passes", "reviewers"])],
  ["reconciliation", new Set(["close_child_on_merge", "close_feature_on_complete"])],
]);
const values = new Map();

function error(line, message) { errors.push(`${file}:${line}: ${message}`); }
function scalar(raw, line) {
  const value = raw.trim();
  if (!value) return {};
  if (/^(true|false)$/.test(value)) return value === "true";
  if (/^\d+$/.test(value)) return Number(value);
  if ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("'") && value.endsWith("'"))) return value.slice(1, -1);
  if (/^[\[{]/.test(value)) {
    try { return JSON.parse(value.replaceAll("'", '"')); } catch { error(line, `expected valid inline JSON, got ${value}`); return null; }
  }
  return value;
}

let source;
try { source = await readFile(file, "utf8"); }
catch (cause) {
  console.error(`Invalid ${file}:\n- cannot read configuration: ${cause.message}\n- create it with sdlc-setup, then rerun validation`);
  process.exitCode = 1;
}
if (source === undefined) process.exit();

let section = "";
for (const [index, rawLine] of source.split(/\r?\n/).entries()) {
  const line = index + 1;
  const content = rawLine.replace(/\s+#.*$/, "").trimEnd();
  if (!content.trim()) continue;
  const top = content.match(/^([A-Za-z][\w-]*):(?:\s*(.*))?$/);
  if (top) {
    section = top[1];
    if (section !== "schema" && !sections.has(section)) error(line, `unknown top-level key ${section}`);
    if (values.has(section)) error(line, `duplicate key ${section}`);
    values.set(section, top[2] === undefined || top[2] === "" ? {} : scalar(top[2], line));
    continue;
  }
  const nested = content.match(/^\s+([A-Za-z][\w-]*):(?:\s*(.*))?$/);
  if (!nested) { error(line, "expected a top-level or indented key"); continue; }
  if (!/^\s{2}\S/.test(content)) { error(line, "nested keys must be indented by two spaces"); continue; }
  if (!sections.has(section)) { error(line, `unknown section ${section || "<none>"}`); continue; }
  const key = `${section}.${nested[1]}`;
  if (!keys.get(section).has(nested[1])) error(line, `unknown key ${key}`);
  if (values.has(key)) error(line, `duplicate key ${key}`);
  if (values.get(section) !== null && typeof values.get(section) !== "object") error(line, `${section} must be a mapping`);
  values.set(key, nested[2] === undefined || nested[2] === "" ? {} : scalar(nested[2], line));
}

function required(key, description = key) {
  if (!values.has(key) || values.get(key) === "" || values.get(key) === null) error(1, `${description} is required`);
  return values.get(key);
}
function type(key, expected) { if (values.has(key) && typeof values.get(key) !== expected) error(1, `${key} must be ${expected}`); }
function enumValue(key, allowed) { if (values.has(key) && !allowed.includes(values.get(key))) error(1, `${key} must be one of: ${allowed.join(", ")}`); }
function object(key) { if (values.has(key) && (values.get(key) === null || typeof values.get(key) !== "object" || Array.isArray(values.get(key)))) error(1, `${key} must be a mapping`); }

const schema = required("schema", "schema");
type("schema", "number");
if (schema !== 1) error(1, "schema must be 1; run sdlc-setup or use --migrate when a migration is available");
for (const name of sections) { required(name, `${name} section`); object(name); }

required("labels.mode"); type("labels.mode", "string"); enumValue("labels.mode", ["mapped", "native"]);
for (const label of ["sdlc", "sdlc-feature", "sdlc-work-item", "sdlc-requirements", "sdlc-design", "ready", "in-progress", "review", "complete", "blocked", "needs-discovery"]) {
  const vocabulary = values.get("labels.vocabulary");
  if (!vocabulary || typeof vocabulary !== "object" || Array.isArray(vocabulary) || typeof vocabulary[label] !== "string" || !vocabulary[label].trim()) error(1, `labels.vocabulary.${label} is required`);
  const mappings = values.get("labels.mappings");
  if (!mappings || typeof mappings !== "object" || Array.isArray(mappings) || typeof mappings[label] !== "string" || !mappings[label].trim()) error(1, `labels.mappings.${label} is required`);
}

const pattern = required("branch.pattern");
type("branch.pattern", "string");
if (typeof pattern === "string" && (!pattern.includes("{issue-number}") || !pattern.includes("{short-slug}"))) error(1, "branch.pattern must contain {issue-number} and {short-slug}");
if (values.has("branch.default")) { type("branch.default", "string"); if (typeof values.get("branch.default") === "string" && !values.get("branch.default").trim()) error(1, "branch.default must not be empty"); }

for (const key of ["implementation.create_branch", "implementation.commit_reference_required", "orchestration.automatic_lifecycle", "reconciliation.close_child_on_merge", "reconciliation.close_feature_on_complete", "verification.require_tests", "verification.require_acceptance_checks", "verification.require_manual_evidence_when_relevant", "verification.reject_unrelated_changes"]) { required(key); type(key, "boolean"); }
if (values.has("implementation.use_worktree")) type("implementation.use_worktree", "boolean");
if (values.has("implementation.worktree_root")) { type("implementation.worktree_root", "string"); if (typeof values.get("implementation.worktree_root") === "string" && !values.get("implementation.worktree_root").trim()) error(1, "implementation.worktree_root must not be empty"); }
required("pull_request.creation"); type("pull_request.creation", "string"); enumValue("pull_request.creation", ["never", "ask", "automatic"]);

required("delivery.default_flavor"); type("delivery.default_flavor", "string"); enumValue("delivery.default_flavor", ["thin-slice", "stepwise", "feature"]);
const flavors = required("delivery.flavors");
if (!Array.isArray(flavors) || !flavors.every((value) => ["thin-slice", "stepwise", "feature"].includes(value))) error(1, "delivery.flavors must be an array containing only thin-slice, stepwise, or feature");

required("orchestration.max_concurrency"); type("orchestration.max_concurrency", "number");
if (typeof values.get("orchestration.max_concurrency") === "number" && values.get("orchestration.max_concurrency") < 1) error(1, "orchestration.max_concurrency must be at least 1");
required("orchestration.max_remediation_passes"); type("orchestration.max_remediation_passes", "number");
if (typeof values.get("orchestration.max_remediation_passes") === "number" && values.get("orchestration.max_remediation_passes") !== 2) error(1, "orchestration.max_remediation_passes must be exactly 2");
const reviewers = required("orchestration.reviewers");
if (!Array.isArray(reviewers) || reviewers.length < 1 || !reviewers.every((value) => typeof value === "string" && value.trim())) error(1, "orchestration.reviewers must be a non-empty array of reviewer names");

if (errors.length) {
  console.error(`Invalid ${file}:\n${errors.map((item) => `- ${item}`).join("\n")}`);
  process.exitCode = 1;
} else if (migrate) {
  await writeFile(file, source.endsWith("\n") ? source : `${source}\n`);
  console.log(`Migrated ${file} to schema 1`);
} else console.log(`Valid ${file} (schema 1)`);
