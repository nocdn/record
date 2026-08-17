import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, spawnSync } from "node:child_process";
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
  assert.match(result.stdout, /default: 60/);
  assert.match(result.stdout, /MP3/);
  assert.match(result.stdout, /Ctrl\+D/);
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

test("SIGINT tells a fake helper to stop and save", async () => {
  const helper = await writeFakeHelper();
  const output = path.join(os.tmpdir(), `record-save-${process.pid}.mp3`);
  const child = spawn(process.execPath, [cliPath, "--only-mic", "-o", output], {
    env: { ...process.env, RECORD_NATIVE: helper },
    stdio: ["ignore", "pipe", "pipe"],
  });

  const stdout = await waitForOutput(child, "Press Ctrl+C");
  child.kill("SIGINT");
  const [code, rest] = await waitForClose(child);

  assert.equal(code, 0);
  assert.match(stdout + rest, /Saved:/);
  assert.doesNotMatch(stdout + rest, /Discarded/);
});

async function writeFakeHelper() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "record-fake-"));
  const helperPath = path.join(directory, "fake-native.js");
  await writeFile(
    helperPath,
    `#!/usr/bin/env node
import { createInterface } from "node:readline";

const output = process.argv[process.argv.indexOf("--output") + 1];
process.stdout.write(JSON.stringify({ event: "started", path: output }) + "\\n");

const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  if (line.includes('"discard"')) {
    process.stdout.write(JSON.stringify({ event: "discarded", path: output }) + "\\n");
    process.exit(0);
  }
  if (line.includes('"stop"')) {
    process.stdout.write(JSON.stringify({ event: "saved", path: output }) + "\\n");
    process.exit(0);
  }
});
`,
  );
  await chmod(helperPath, 0o755);
  return helperPath;
}

function waitForOutput(child, snippet) {
  return new Promise((resolve, reject) => {
    let stdout = "";
    const onData = (chunk) => {
      stdout += chunk.toString();
      if (stdout.includes(snippet)) {
        child.stdout.off("data", onData);
        resolve(stdout);
      }
    };
    child.stdout.on("data", onData);
    child.once("error", reject);
    child.once("close", (code) => {
      reject(new Error(`helper exited before ${snippet}: ${code}\n${stdout}`));
    });
  });
}

function waitForClose(child) {
  return new Promise((resolve, reject) => {
    let rest = "";
    child.stdout.on("data", (chunk) => {
      rest += chunk.toString();
    });
    child.once("error", reject);
    child.once("close", (code) => resolve([code, rest]));
  });
}
