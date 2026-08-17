#!/usr/bin/env node

import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync, spawnSync } from "node:child_process";

const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const appPath = path.join(projectRoot, "vendor", "Record.app");

if (os.platform() !== "darwin") {
  throw new Error("The native recorder can only be notarized on macOS.");
}

const details = codesignDetails(appPath);
if (!/Authority=Developer ID Application:/.test(details)) {
  throw new Error(
    "vendor/Record.app must be signed with a Developer ID Application identity before notarization. Set RECORD_SIGNING_IDENTITY and run `npm run build`.",
  );
}
if (!/flags=0x[0-9a-f]*\(.*runtime/.test(details)) {
  throw new Error(
    "vendor/Record.app must be signed with the Hardened Runtime before notarization.",
  );
}

const credentials = notaryCredentials();
const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "record-notarize-"));
const zipPath = path.join(temporaryDirectory, "Record.zip");
let keyPath;

try {
  if (credentials.kind === "api-key") {
    keyPath = path.join(temporaryDirectory, `AuthKey_${credentials.keyId}.p8`);
    await writeFile(keyPath, credentials.key, { mode: 0o600 });
  }

  execFileSync("ditto", ["-c", "-k", "--keepParent", appPath, zipPath], {
    stdio: "inherit",
  });

  const submitArguments = [
    "notarytool",
    "submit",
    zipPath,
    "--wait",
    "--timeout",
    "30m",
    "--no-progress",
    "--output-format",
    "json",
    ...credentialArguments(credentials, keyPath),
  ];

  console.log("Submitting vendor/Record.app to Apple's notary service…");
  const submission = runJson("xcrun", submitArguments);
  const status = submission.status || submission.Status;
  const submissionId = submission.id || submission.RequestUUID;

  if (status !== "Accepted") {
    if (submissionId) {
      try {
        execFileSync(
          "xcrun",
          [
            "notarytool",
            "log",
            submissionId,
            ...credentialArguments(credentials, keyPath),
          ],
          { stdio: "inherit" },
        );
      } catch {
        // The status error below is the one that matters.
      }
    }
    throw new Error(
      `Notarization did not succeed (status: ${status ?? "unknown"}).`,
    );
  }

  console.log(`Notarization accepted (${submissionId ?? "no id"}). Stapling ticket…`);
  execFileSync("xcrun", ["stapler", "staple", "-v", appPath], { stdio: "inherit" });
  execFileSync("xcrun", ["stapler", "validate", "-v", appPath], { stdio: "inherit" });
  execFileSync("codesign", ["--verify", "--deep", "--strict", appPath], {
    stdio: "inherit",
  });

  const stapledDetails = codesignDetails(appPath);
  if (!/Notarization Ticket=stapled/.test(stapledDetails)) {
    throw new Error("The notarization ticket was not stapled to vendor/Record.app.");
  }

  console.log("Notarized and stapled vendor/Record.app");
} finally {
  await rm(temporaryDirectory, { recursive: true, force: true });
}

function codesignDetails(target) {
  const result = spawnSync("codesign", ["-dv", "--verbose=4", target], {
    encoding: "utf8",
  });
  return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

function notaryCredentials() {
  const key =
    process.env.APPLE_API_KEY ??
    process.env.APPLE_API_PRIVATE_KEY ??
    process.env.APPSTORE_API_PRIVATE_KEY;
  const keyId = process.env.APPLE_API_KEY_ID ?? process.env.APPSTORE_API_KEY_ID;
  const issuer = process.env.APPLE_API_ISSUER ?? process.env.APPSTORE_ISSUER_ID;

  if (key && keyId) {
    return { kind: "api-key", key, keyId, issuer };
  }

  const appleId = process.env.APPLE_ID;
  const password =
    process.env.APPLE_APP_SPECIFIC_PASSWORD ?? process.env.APPLE_PASSWORD;
  const teamId = process.env.APPLE_TEAM_ID;

  if (appleId && password && teamId) {
    return { kind: "apple-id", appleId, password, teamId };
  }

  throw new Error(
    "Missing Apple notary credentials. Set APPLE_API_KEY, APPLE_API_KEY_ID, and APPLE_API_ISSUER (team keys), or APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID.",
  );
}

function credentialArguments(credentials, keyPath) {
  if (credentials.kind === "api-key") {
    const arguments_ = ["--key", keyPath, "--key-id", credentials.keyId];
    if (credentials.issuer) {
      arguments_.push("--issuer", credentials.issuer);
    }
    return arguments_;
  }

  return [
    "--apple-id",
    credentials.appleId,
    "--password",
    credentials.password,
    "--team-id",
    credentials.teamId,
  ];
}

function runJson(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    throw new Error(output || `${command} ${args[0]} failed.`);
  }

  const stdout = (result.stdout ?? "").trim();
  if (!stdout) {
    throw new Error(`${command} ${args[0]} produced no JSON output.`);
  }

  try {
    return JSON.parse(stdout);
  } catch {
    throw new Error(`Could not parse notarytool JSON:\n${stdout}`);
  }
}
