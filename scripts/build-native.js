#!/usr/bin/env node

import { access, copyFile, mkdir, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const projectRoot = fileURLToPath(new URL("../", import.meta.url));
const nativeDir = path.join(projectRoot, "native");
const swiftSources = (await readdir(nativeDir))
  .filter((name) => name.endsWith(".swift"))
  .map((name) => path.join(nativeDir, name))
  .sort();
const encodeSourcePath = path.join(projectRoot, "native", "mp3_encode.c");
const bridgingHeaderPath = path.join(projectRoot, "native", "record-bridging.h");
const shinePath = path.join(projectRoot, "native", "third_party", "shine");
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
const shineSources = (await readdir(shinePath))
  .filter((name) => name.endsWith(".c"))
  .map((name) => path.join(shinePath, name));
const cSources = [...shineSources, encodeSourcePath];
const temporaryObjects = [];

try {
  for (let index = 0; index < architectures.length; index += 1) {
    const architecture = architectures[index];
    const objectFiles = [];
    for (const source of cSources) {
      const objectPath = path.join(
        os.tmpdir(),
        `record-${architecture}-${path.basename(source, ".c")}-${process.pid}.o`,
      );
      temporaryObjects.push(objectPath);
      execFileSync(
        "xcrun",
        [
          "clang",
          "-c",
          "-O2",
          "-std=c99",
          "-arch",
          architecture,
          "-mmacosx-version-min=15.0",
          "-I",
          shinePath,
          "-o",
          objectPath,
          source,
        ],
        { cwd: projectRoot, stdio: "inherit" },
      );
      objectFiles.push(objectPath);
    }

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
        "-import-objc-header",
        bridgingHeaderPath,
        "-framework",
        "ScreenCaptureKit",
        "-framework",
        "AVFoundation",
        "-framework",
        "AudioToolbox",
        "-framework",
        "CoreMedia",
        "-framework",
        "CoreGraphics",
        "-framework",
        "CoreAudio",
        "-framework",
        "AppKit",
        "-framework",
        "CoreImage",
        "-o",
        temporaryOutputs[index],
        ...objectFiles,
        ...swiftSources,
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
    [...temporaryOutputs, ...temporaryObjects].map((temporaryOutput) =>
      rm(temporaryOutput, { force: true }),
    ),
  );
}
