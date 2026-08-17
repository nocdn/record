#!/usr/bin/env node

import { access, copyFile, mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const sourcePath = path.join(projectRoot, "native", "record-native.swift");
const plistPath = path.join(projectRoot, "native", "Info.plist");
const entitlementsPath = path.join(projectRoot, "native", "Record.entitlements");
const vendorPath = path.join(projectRoot, "vendor");
const appPath = path.join(vendorPath, "Record.app");
const contentsPath = path.join(appPath, "Contents");
const macOSPath = path.join(contentsPath, "MacOS");
const executablePath = path.join(macOSPath, "record-native");

if (process.env.RECORD_SKIP_NATIVE_BUILD === "1") {
  try {
    await access(executablePath);
  } catch {
    throw new Error(
      "RECORD_SKIP_NATIVE_BUILD=1 but vendor/Record.app is missing. Run `npm run build` first.",
    );
  }
  console.log("Skipping native build because RECORD_SKIP_NATIVE_BUILD=1.");
  process.exit(0);
}

if (os.platform() !== "darwin") {
  throw new Error("The native recorder can only be built on macOS.");
}

await rm(vendorPath, { recursive: true, force: true });
await mkdir(macOSPath, { recursive: true });

const architectures = process.env.RECORD_NATIVE_ARCH
  ? process.env.RECORD_NATIVE_ARCH.split(",").map((value) => value.trim()).filter(Boolean)
  : ["arm64", "x86_64"];
const temporaryOutputs = architectures.map((architecture) =>
  path.join(os.tmpdir(), `record-native-${architecture}-${process.pid}`),
);

try {
  for (let index = 0; index < architectures.length; index += 1) {
    const architecture = architectures[index];
    execFileSync(
      "xcrun",
      [
        "swiftc",
        "-swift-version",
        "5",
        "-parse-as-library",
        "-O",
        "-whole-module-optimization",
        "-target",
        `${architecture}-apple-macosx15.0`,
        "-framework",
        "ScreenCaptureKit",
        "-framework",
        "AVFoundation",
        "-framework",
        "CoreMedia",
        "-framework",
        "CoreGraphics",
        "-framework",
        "CoreAudio",
        "-o",
        temporaryOutputs[index],
        sourcePath,
      ],
      { cwd: projectRoot, stdio: "inherit" },
    );
  }

  if (temporaryOutputs.length === 1) {
    await copyFile(temporaryOutputs[0], executablePath);
  } else {
    execFileSync("lipo", ["-create", ...temporaryOutputs, "-output", executablePath], {
      stdio: "inherit",
    });
  }

  await copyFile(plistPath, path.join(contentsPath, "Info.plist"));

  const signingIdentity = process.env.RECORD_SIGNING_IDENTITY ?? "-";
  const signingArguments = [
    "--force",
    "--deep",
    "--sign",
    signingIdentity,
    "--entitlements",
    entitlementsPath,
  ];
  if (signingIdentity === "-") {
    signingArguments.push("--timestamp=none");
  } else {
    signingArguments.push("--options", "runtime", "--timestamp");
  }

  execFileSync(
    "codesign",
    [...signingArguments, appPath],
    { cwd: projectRoot, stdio: "inherit" },
  );

  execFileSync("codesign", ["--verify", "--deep", "--strict", appPath], {
    cwd: projectRoot,
    stdio: "inherit",
  });
  execFileSync("file", [executablePath], { stdio: "inherit" });
  console.log(`Built ${path.relative(projectRoot, appPath)}`);
} finally {
  await Promise.all(
    temporaryOutputs.map((temporaryOutput) => rm(temporaryOutput, { force: true })),
  );
}
