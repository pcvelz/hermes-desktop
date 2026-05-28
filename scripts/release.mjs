#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const versionArg = args.find((arg) => !arg.startsWith("--"));
const shouldPush = args.includes("--push");
const skipChecks = args.includes("--skip-checks");

if (!versionArg) {
  fail("Usage: npm run release -- <version> [--push] [--skip-checks]");
}

const version = normalizeVersion(versionArg);
const tag = `v${version}`;

assertCleanWorkingTree();
assertTagDoesNotExist(tag);

const previousTag = latestTag();
const releaseNotes = buildReleaseNotes(previousTag, tag);

updateVersions(version);

if (!skipChecks) {
  run("npm", ["run", "test:i18n"]);
  run("npm", ["run", "build"]);
  run("cargo", ["fmt", "--manifest-path", "src-tauri/Cargo.toml", "--", "--check"]);
  run("cargo", ["check", "--manifest-path", "src-tauri/Cargo.toml"]);
  run("cargo", ["test", "--manifest-path", "src-tauri/Cargo.toml"]);
}

run("git", ["add", "package.json", "package-lock.json", "src-tauri/Cargo.toml", "src-tauri/Cargo.lock", "src-tauri/tauri.conf.json"]);
run("git", ["commit", "-m", `Release ${tag}`]);
run("git", ["tag", "-a", tag, "-m", `Release ${tag}`, "-m", "Release notes:", "-m", releaseNotes]);

if (shouldPush) {
  const branch = git(["branch", "--show-current"]).trim();
  if (!branch) {
    fail("Could not determine the current branch for push.");
  }
  run("git", ["push", "origin", branch, tag]);
  console.log(`Release ${tag} pushed. GitHub Actions will build artifacts and create the release.`);
} else {
  console.log(`Release ${tag} committed and tagged locally.`);
  console.log(`Run: git push origin ${currentBranchForMessage()} ${tag}`);
}

function normalizeVersion(value) {
  const normalized = value.trim().replace(/^v/i, "");
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(normalized)) {
    fail(`Invalid version "${value}". Expected semver like 0.10.4.`);
  }
  return normalized;
}

function assertCleanWorkingTree() {
  const status = git(["status", "--porcelain"]);
  if (status.trim()) {
    fail("Working tree is not clean. Commit or stash changes before running the release script.");
  }
}

function assertTagDoesNotExist(tagName) {
  const existing = git(["tag", "--list", tagName]).trim();
  if (existing) {
    fail(`Tag ${tagName} already exists.`);
  }
}

function latestTag() {
  try {
    return git(["describe", "--tags", "--abbrev=0"]).trim();
  } catch {
    return null;
  }
}

function buildReleaseNotes(previousTag, tagName) {
  if (!previousTag) {
    return `- Initial ${tagName} release.`;
  }
  const log = git(["log", "--pretty=format:- %s", `${previousTag}..HEAD`]).trim();
  return log || `- Version bump for ${tagName}.`;
}

function updateVersions(nextVersion) {
  updateJson("package.json", (json) => {
    json.version = nextVersion;
  });
  updateJson("package-lock.json", (json) => {
    json.version = nextVersion;
    if (json.packages?.[""]) {
      json.packages[""].version = nextVersion;
    }
  });
  updateJson("src-tauri/tauri.conf.json", (json) => {
    json.version = nextVersion;
  });
  replaceInFile("src-tauri/Cargo.toml", /^version = ".*"$/m, `version = "${nextVersion}"`);
  replaceInCargoLock(nextVersion);
}

function updateJson(relativePath, updater) {
  const filePath = path.join(root, relativePath);
  const json = JSON.parse(readFileSync(filePath, "utf8"));
  updater(json);
  writeFileSync(filePath, `${JSON.stringify(json, null, 2)}\n`);
}

function replaceInFile(relativePath, pattern, replacement) {
  const filePath = path.join(root, relativePath);
  const source = readFileSync(filePath, "utf8");
  const updated = source.replace(pattern, replacement);
  if (updated === source) {
    fail(`Could not update ${relativePath}.`);
  }
  writeFileSync(filePath, updated);
}

function replaceInCargoLock(nextVersion) {
  const filePath = path.join(root, "src-tauri/Cargo.lock");
  const source = readFileSync(filePath, "utf8");
  const updated = source.replace(
    /(name = "hermes-desktop-tauri"\nversion = ")[^"]+(")/,
    `$1${nextVersion}$2`,
  );
  if (updated === source) {
    fail("Could not update src-tauri/Cargo.lock.");
  }
  writeFileSync(filePath, updated);
}

function currentBranchForMessage() {
  return git(["branch", "--show-current"]).trim() || "main";
}

function git(args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" });
}

function run(command, commandArgs) {
  const result = spawnSync(command, commandArgs, {
    cwd: root,
    stdio: "inherit",
    shell: false,
  });
  if (result.status !== 0) {
    fail(`${command} ${commandArgs.join(" ")} failed.`);
  }
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
