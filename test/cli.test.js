import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

const cliPath = fileURLToPath(new URL("../bin/cli.js", import.meta.url));
const packageInfo = JSON.parse(
  await readFile(new URL("../package.json", import.meta.url), "utf8"),
);

function run(...args) {
  return spawnSync(process.execPath, [cliPath, ...args], {
    encoding: "utf8",
  });
}

test("help is generated from package metadata and lists recorder options", () => {
  const result = run("--help");

  assert.equal(result.status, 0);
  assert.match(result.stdout, new RegExp(`${packageInfo.name} ${packageInfo.version}`));
  assert.match(result.stdout, /--output <path>/);
  assert.match(result.stdout, /--no-mic/);
  assert.match(result.stdout, /--only-mic/);
  assert.match(result.stdout, /--list-mics/);
  assert.match(result.stdout, /mics/);
  assert.match(result.stdout, /permissions/);
});

test("version prints the package version", () => {
  const result = run("--version");

  assert.equal(result.status, 0);
  assert.equal(result.stdout, `${packageInfo.version}\n`);
});

test("unknown flags fail with a help hint", () => {
  const result = run("--unknown");

  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unknown option/);
  assert.match(result.stderr, /--help/);
});

test("invalid recording values fail before launching the native helper", () => {
  const result = run("--fps", "0");

  assert.equal(result.status, 1);
  assert.match(result.stderr, /--fps must be greater than 0/);
});

test("only-mic cannot be combined with no-mic", () => {
  const result = run("--only-mic", "--no-mic");

  assert.equal(result.status, 1);
  assert.match(result.stderr, /--only-mic option cannot be combined with --no-mic/);
});
