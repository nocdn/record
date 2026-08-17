#!/usr/bin/env node

import { access, mkdir, readFile, unlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";

const packageInfo = await readPackageInfo();

try {
  const args = parseArgs(process.argv.slice(2), packageInfo);

  if (args.help) {
    process.stdout.write(helpText(packageInfo));
  } else if (args.version) {
    process.stdout.write(`${packageInfo.version}\n`);
  } else if (args.command === "permissions") {
    await reportPermissions();
  } else if (args.command === "mics") {
    await runNativeList(["--list-mics"], "No microphones were found.");
  } else if (args.command === "windows") {
    await runNativeList(["--list-windows"], "No windows were found.");
  } else if (args.command === "cameras") {
    await runNativeList(["--list-cameras"], "No cameras were found.");
  } else {
    await record(args);
  }
} catch (error) {
  process.stderr.write(`Error: ${error.message}\n`);
  process.exitCode = 1;
}

async function record(args) {
  assertMacOS();
  const previousTitle = process.title;
  setTerminalTabTitle(recordingTabTitle(args));

  try {
    await runRecording(args);
  } finally {
    restoreTerminalTabTitle(previousTitle);
  }
}

async function runRecording(args) {
  const executable = await nativeExecutable();
  const outputPath = resolveOutputPath(args);
  await prepareOutputPath(outputPath);
  const nativeArgs = nativeRecordingArgs(args, outputPath);

  const child = spawn(executable, nativeArgs, {
    detached: true,
    stdio: ["pipe", "pipe", "inherit"],
  });

  let stopping = false;
  let discarding = false;
  let finished = false;
  let sawSavedEvent = false;
  let sawDiscardedEvent = false;
  let started = false;
  let lastSignalAt = 0;
  let resolveExit;
  let rejectExit;
  const exitPromise = new Promise((resolve, reject) => {
    resolveExit = resolve;
    rejectExit = reject;
  });

  const output = createInterface({ input: child.stdout });
  output.on("line", (line) => {
    if (!line.trim()) {
      return;
    }

    let event;
    try {
      event = JSON.parse(line);
    } catch {
      process.stderr.write(`Recorder output: ${line}\n`);
      return;
    }

    switch (event.event) {
      case "started":
        started = true;
        process.stdout.write(`●  Recording ${recordingSummary(args)}\n`);
        process.stdout.write(`Output: ${event.path}\n`);
        if (event.microphone) {
          process.stdout.write(`Microphone: ${event.microphone}\n`);
        }
        if (event.camera) {
          process.stdout.write(`Camera: ${event.camera}\n`);
        }
        if (event.window) {
          process.stdout.write(`Window: ${event.window}\n`);
        }
        if (event.region) {
          process.stdout.write(`Region: ${event.region}\n`);
        }
        process.stdout.write("Duration: 00:00:00\n");
        process.stdout.write("Press Enter or Ctrl+C to stop and save, or Ctrl+D to discard.\n");
        break;
      case "countdown":
        process.stdout.write(`Starting in ${event.remaining}…\n`);
        break;
      case "region-prompt":
        process.stdout.write("Drag a rectangle on the display, then release. Esc cancels.\n");
        break;
      case "progress":
        if (started && !stopping) {
          process.stdout.write(`\rDuration: ${formatDuration(event.duration)} `);
        }
        break;
      case "finalizing":
        stopping = true;
        process.stdout.write("\nFinalizing recording…\n");
        break;
      case "discarding":
        stopping = true;
        discarding = true;
        process.stdout.write("\nDiscarding recording…\n");
        break;
      case "saved":
        sawSavedEvent = true;
        finished = true;
        process.stdout.write(`Saved: ${event.path}\n`);
        break;
      case "discarded":
        sawDiscardedEvent = true;
        finished = true;
        process.stdout.write("Discarded.\n");
        break;
      case "permission-required":
        process.stderr.write(`${event.message}\n`);
        break;
      case "error":
        process.stderr.write(`Recorder error: ${event.message}\n`);
        break;
      default:
        process.stderr.write(`Recorder event: ${line}\n`);
    }
  });

  child.on("error", (error) => {
    rejectExit(error);
  });

  child.on("close", (code, signal) => {
    output.close();

    if (sawSavedEvent || sawDiscardedEvent) {
      resolveExit();
      return;
    }

    if (signal) {
      rejectExit(new Error(`Recorder stopped by ${signal}.`));
      return;
    }

    rejectExit(
      new Error(
        code === 2
          ? "Recording permissions are required. Grant them in System Settings, then run the command again."
          : `Recorder exited with code ${code ?? "unknown"}.`,
      ),
    );
  });

  let forceQuitArmed = false;

  const stop = () => {
    if (stopping) {
      return;
    }
    stopping = true;
    child.stdin.write('{"command":"stop"}\n');
  };

  const discard = () => {
    if (stopping || finished) {
      return;
    }
    discarding = true;
    stopping = true;
    child.stdin.write('{"command":"discard"}\n');
  };

  const handleSignal = () => {
    const now = Date.now();
    if (now - lastSignalAt < 500) {
      return;
    }
    lastSignalAt = now;
    if (!stopping) {
      stop();
      return;
    }
    if (!forceQuitArmed) {
      forceQuitArmed = true;
      process.stderr.write("Press Ctrl+C again to force quit.\n");
      return;
    }
    child.kill("SIGKILL");
  };
  const handleStdinEnd = () => {
    if (stopping || finished) {
      return;
    }
    discard();
  };
  const handleStdinData = (chunk) => {
    if (stopping || finished) {
      return;
    }
    const text = chunk.toString();
    if (text.includes("\n") || text.includes("\r")) {
      stop();
    }
  };
  process.on("SIGINT", handleSignal);
  process.on("SIGTERM", handleSignal);
  if (process.stdin.isTTY) {
    process.stdin.on("end", handleStdinEnd);
    process.stdin.on("data", handleStdinData);
    process.stdin.resume();
  }

  try {
    await exitPromise;
  } finally {
    process.removeListener("SIGINT", handleSignal);
    process.removeListener("SIGTERM", handleSignal);
    if (process.stdin.isTTY) {
      process.stdin.removeListener("end", handleStdinEnd);
      process.stdin.removeListener("data", handleStdinData);
      process.stdin.pause();
    }
    child.stdin.end();
    if (discarding || sawDiscardedEvent) {
      await removeIfExists(outputPath);
    }
    if (!finished && !sawSavedEvent && !sawDiscardedEvent) {
      output.close();
    }
  }
}

async function runNativeList(nativeArgs, emptyMessage) {
  assertMacOS();

  const executable = await nativeExecutable();
  const child = spawn(executable, nativeArgs, {
    stdio: ["ignore", "pipe", "inherit"],
  });

  const output = createInterface({ input: child.stdout });
  output.on("line", (line) => process.stdout.write(`${line}\n`));

  await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => {
      output.close();
      if (signal) {
        reject(new Error(`List stopped by ${signal}.`));
      } else if (code === 0) {
        resolve();
      } else {
        reject(new Error(emptyMessage));
      }
    });
  });
}

async function reportPermissions() {
  assertMacOS();

  const executable = await nativeExecutable();
  const child = spawn(executable, ["--permissions"], {
    stdio: ["ignore", "pipe", "inherit"],
  });

  const output = createInterface({ input: child.stdout });
  output.on("line", (line) => process.stdout.write(`${line}\n`));

  await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => {
      output.close();
      if (signal) {
        reject(new Error(`Permission check stopped by ${signal}.`));
      } else if (code === 0) {
        resolve();
      } else {
        reject(new Error("One or more recording permissions are not granted."));
      }
    });
  });
}

function parseArgs(argv, info) {
  const args = {
    command: null,
    help: false,
    version: false,
    output: null,
    microphone: true,
    microphoneName: null,
    systemAudio: true,
    cursor: true,
    display: 1,
    fps: 60,
    format: "mp4",
    onlyMic: false,
    onlySystemAudio: false,
    onlyCamera: false,
    camera: false,
    cameraName: null,
    cameraSize: null,
    cameraPosition: null,
    windowName: null,
    region: null,
    forSeconds: null,
    inSeconds: null,
    hevc: false,
    codec: null,
    quality: null,
    scale: null,
    videoBitrate: null,
    audioBitrate: null,
    here: false,
    location: null,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    if (arg === "permissions" && args.command === null) {
      args.command = "permissions";
      continue;
    }

    if (
      (arg === "mics" || arg === "microphones") &&
      args.command === null
    ) {
      args.command = "mics";
      continue;
    }

    if ((arg === "windows" || arg === "--list-windows") && args.command === null) {
      args.command = "windows";
      continue;
    }

    if ((arg === "cameras" || arg === "--list-cameras") && args.command === null) {
      args.command = "cameras";
      continue;
    }

    if (arg === "--list-mics") {
      args.command = "mics";
      continue;
    }

    if (arg === "-h" || arg === "--help") {
      args.help = true;
      continue;
    }

    if (arg === "-v" || arg === "--version") {
      args.version = true;
      continue;
    }

    if (arg === "--output" || arg === "-o") {
      args.output = requiredValue(argv, ++index, arg);
      continue;
    }

    if (arg === "--here") {
      args.here = true;
      continue;
    }

    if (arg === "--location") {
      args.location = requiredValue(argv, ++index, arg);
      continue;
    }

    if (arg === "--only-mic" || arg === "--mic-only" || arg === "--microphone") {
      args.onlyMic = true;
      args.microphone = true;
      args.systemAudio = false;
      continue;
    }

    if (
      arg === "--only-system-audio" ||
      arg === "--system-audio-only" ||
      arg === "--internal" ||
      arg === "--internal-only"
    ) {
      args.onlySystemAudio = true;
      args.microphone = false;
      args.systemAudio = true;
      continue;
    }

    if (arg === "--only-camera" || arg === "--camera-only") {
      args.onlyCamera = true;
      args.camera = true;
      args.microphone = false;
      args.systemAudio = false;
      continue;
    }

    if (arg === "--camera") {
      args.camera = true;
      const next = argv[index + 1];
      if (next && !next.startsWith("-")) {
        args.cameraName = next;
        index += 1;
      }
      continue;
    }

    if (arg === "--camera-size") {
      args.cameraSize = unitInterval(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--camera-position") {
      args.cameraPosition = requiredValue(argv, ++index, arg).toLowerCase();
      if (!["bottom-right", "bottom-left", "top-right", "top-left"].includes(args.cameraPosition)) {
        throw new Error(
          'The camera position must be "bottom-right", "bottom-left", "top-right", or "top-left".',
        );
      }
      continue;
    }

    if (arg === "--window" || arg === "--app") {
      args.windowName = requiredValue(argv, ++index, arg);
      continue;
    }

    if (arg === "--region") {
      const next = argv[index + 1];
      if (next && !next.startsWith("-")) {
        args.region = parseRegion(next, arg);
        index += 1;
      } else {
        args.region = "interactive";
      }
      continue;
    }

    if (arg === "--for" || arg === "--duration") {
      args.forSeconds = parseDuration(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--in" || arg === "--delay") {
      args.inSeconds = parseDuration(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--hevc") {
      args.hevc = true;
      args.codec = args.codec ?? "hevc";
      continue;
    }

    if (arg === "--codec") {
      args.codec = requiredValue(argv, ++index, arg).toLowerCase();
      if (args.codec !== "h264" && args.codec !== "hevc") {
        throw new Error('The codec must be "h264" or "hevc".');
      }
      args.hevc = args.codec === "hevc";
      continue;
    }

    if (arg === "--quality") {
      args.quality = requiredValue(argv, ++index, arg).toLowerCase();
      if (args.quality !== "low" && args.quality !== "high") {
        throw new Error('The quality must be "low" or "high".');
      }
      continue;
    }

    if (arg === "--scale") {
      args.scale = parseScale(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--video-bitrate") {
      args.videoBitrate = parseBitrate(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--audio-bitrate") {
      args.audioBitrate = parseBitrate(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--no-mic") {
      args.microphone = false;
      continue;
    }

    if (arg === "--no-system-audio") {
      args.systemAudio = false;
      continue;
    }

    if (arg === "--no-cursor") {
      args.cursor = false;
      continue;
    }

    if (arg === "--display") {
      args.display = positiveInteger(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--mic") {
      args.microphoneName = requiredValue(argv, ++index, arg);
      args.microphone = true;
      continue;
    }

    if (arg === "--fps") {
      args.fps = positiveNumber(requiredValue(argv, ++index, arg), arg);
      continue;
    }

    if (arg === "--format") {
      args.format = requiredValue(argv, ++index, arg).toLowerCase();
      if (args.format !== "mp4" && args.format !== "mov") {
        throw new Error('The format must be "mp4" or "mov".');
      }
      continue;
    }

    if (arg.startsWith("-")) {
      throw new Error(
        `Unknown option "${arg}". Run ${info.name} --help for usage.`,
      );
    }

    throw new Error(
      `Unexpected argument "${arg}". Run ${info.name} --help for usage.`,
    );
  }

  if (args.help && args.version) {
    throw new Error("Choose either --help or --version.");
  }

  if (args.command && (args.help || args.version)) {
    throw new Error(
      `The ${args.command} command cannot be combined with a flag.`,
    );
  }

  const onlyModes = [args.onlyMic, args.onlySystemAudio, args.onlyCamera].filter(Boolean);
  if (onlyModes.length > 1) {
    throw new Error("Choose only one of --only-mic, --only-system-audio, or --only-camera.");
  }

  if (args.onlyMic && !args.microphone) {
    throw new Error("The --only-mic option cannot be combined with --no-mic.");
  }

  if (args.onlySystemAudio && !args.systemAudio) {
    throw new Error(
      "The --only-system-audio option cannot be combined with --no-system-audio.",
    );
  }

  if ((args.onlyMic || args.onlySystemAudio) && args.camera) {
    throw new Error("Audio-only recording cannot be combined with --camera.");
  }

  if (args.windowName && args.region) {
    throw new Error("Choose either --window or --region.");
  }

  if ((args.onlyMic || args.onlySystemAudio || args.onlyCamera) && (args.windowName || args.region)) {
    throw new Error("Window and region capture cannot be combined with an audio-only or camera-only recording.");
  }

  if (args.codec === "h264") {
    args.hevc = false;
  }

  const destinations = [args.output !== null, args.here, args.location !== null].filter(Boolean);
  if (destinations.length > 1) {
    throw new Error("Choose only one of --output, --location, or --here.");
  }

  return args;
}

function resolveOutputPath(args) {
  const audioOnly = args.onlyMic || args.onlySystemAudio;
  const extension = audioOnly ? ".mp3" : `.${args.format}`;
  const defaultDirectory = args.here
    ? process.cwd()
    : args.location
      ? resolveUserPath(args.location)
      : path.join(os.homedir(), "Downloads");
  const requestedPath = args.output
    ? resolveUserPath(args.output)
    : path.join(defaultDirectory, `${timestampFilename()}${extension}`);

  if (path.extname(requestedPath)) {
    return requestedPath;
  }

  return `${requestedPath}${extension}`;
}

function resolveUserPath(value) {
  if (value === "~") {
    return os.homedir();
  }
  if (value.startsWith("~/") || value.startsWith("~\\")) {
    return path.join(os.homedir(), value.slice(2));
  }
  return path.resolve(value);
}

async function removeIfExists(filePath) {
  try {
    await unlink(filePath);
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw error;
    }
  }
}

async function prepareOutputPath(outputPath) {
  await mkdir(path.dirname(outputPath), { recursive: true });
  try {
    await access(outputPath);
    throw new Error(`The output file already exists: ${outputPath}`);
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw error;
    }
  }
}

async function nativeExecutable() {
  if (process.env.RECORD_NATIVE) {
    return process.env.RECORD_NATIVE;
  }

  const executable = fileURLToPath(
    new URL("../vendor/Record.app/Contents/MacOS/record-native", import.meta.url),
  );

  try {
    await access(executable);
  } catch {
    throw new Error(
      "The native recorder is not built. Run `npm run build` and try again.",
    );
  }

  return executable;
}

function assertMacOS() {
  if (process.platform !== "darwin") {
    throw new Error("@nocdn/record currently supports macOS only.");
  }
}

function requiredValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("-")) {
    throw new Error(`Option ${flag} requires a value.`);
  }
  return value;
}

function positiveInteger(value, flag) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1) {
    throw new Error(`Option ${flag} must be a positive integer.`);
  }
  return number;
}

function positiveNumber(value, flag) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0 || number > 120) {
    throw new Error(`Option ${flag} must be greater than 0 and no more than 120.`);
  }
  return number;
}

function unitInterval(value, flag) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0 || number > 1) {
    throw new Error(`Option ${flag} must be greater than 0 and no more than 1.`);
  }
  return number;
}

function parseScale(value, flag) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) {
    throw new Error(`Option ${flag} must be greater than 0.`);
  }
  if (number > 1 && number <= 100) {
    return number / 100;
  }
  if (number > 1) {
    throw new Error(`Option ${flag} must be between 0 and 1, or a percent up to 100.`);
  }
  return number;
}

function parseDuration(value, flag) {
  const raw = String(value).trim().toLowerCase();
  if (/^\d+(\.\d+)?$/.test(raw)) {
    const seconds = Number(raw);
    if (seconds <= 0) {
      throw new Error(`Option ${flag} must be greater than 0.`);
    }
    return seconds;
  }

  const match = raw.match(/^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$/);
  if (!match || (!match[1] && !match[2] && !match[3])) {
    throw new Error(`Option ${flag} must look like 30, 30s, 1m, or 1m30s.`);
  }

  const seconds =
    Number(match[1] || 0) * 3600 + Number(match[2] || 0) * 60 + Number(match[3] || 0);
  if (seconds <= 0) {
    throw new Error(`Option ${flag} must be greater than 0.`);
  }
  return seconds;
}

function parseRegion(value, flag) {
  const parts = String(value).split(",").map((part) => Number(part.trim()));
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part))) {
    throw new Error(`Option ${flag} must look like x,y,w,h in display points.`);
  }
  const [x, y, width, height] = parts;
  if (width <= 0 || height <= 0) {
    throw new Error(`Option ${flag} width and height must be greater than 0.`);
  }
  return { x, y, width, height };
}

function parseBitrate(value, flag) {
  const raw = String(value).trim().toLowerCase();
  let multiplier = 1;
  let numberPart = raw;
  if (raw.endsWith("mbps") || raw.endsWith("m")) {
    multiplier = 1_000_000;
    numberPart = raw.replace(/mbps$|m$/, "");
  } else if (raw.endsWith("kbps") || raw.endsWith("k")) {
    multiplier = 1_000;
    numberPart = raw.replace(/kbps$|k$/, "");
  }
  const number = Number(numberPart);
  if (!Number.isFinite(number) || number <= 0) {
    throw new Error(`Option ${flag} must be a bitrate such as 8m, 8000k, or 8000000.`);
  }
  return Math.round(number * multiplier);
}

function nativeRecordingArgs(args, outputPath) {
  const nativeArgs = ["--output", outputPath];

  if (args.display !== 1) {
    nativeArgs.push("--display", String(args.display));
  } else if (args.onlySystemAudio || !args.onlyMic && !args.onlyCamera) {
    nativeArgs.push("--display", String(args.display));
  }

  if (args.forSeconds != null) {
    nativeArgs.push("--for", String(args.forSeconds));
  }
  if (args.inSeconds != null) {
    nativeArgs.push("--in", String(args.inSeconds));
  }

  if (args.onlyMic) {
    nativeArgs.push("--only-mic");
    if (args.microphoneName) {
      nativeArgs.push("--mic", args.microphoneName);
    }
    return nativeArgs;
  }

  if (args.onlySystemAudio) {
    nativeArgs.push("--only-system-audio");
    return nativeArgs;
  }

  if (args.onlyCamera) {
    nativeArgs.push("--only-camera", "--fps", String(args.fps), "--format", args.format);
    appendCameraArgs(nativeArgs, args);
    appendQualityArgs(nativeArgs, args);
    return nativeArgs;
  }

  nativeArgs.push("--fps", String(args.fps), "--format", args.format);

  if (!args.microphone) {
    nativeArgs.push("--no-mic");
  }
  if (!args.systemAudio) {
    nativeArgs.push("--no-system-audio");
  }
  if (args.microphoneName) {
    nativeArgs.push("--mic", args.microphoneName);
  }
  if (!args.cursor) {
    nativeArgs.push("--no-cursor");
  }
  if (args.windowName) {
    nativeArgs.push("--window", args.windowName);
  }
  if (args.region === "interactive") {
    nativeArgs.push("--region", "interactive");
  } else if (args.region) {
    nativeArgs.push(
      "--region",
      `${args.region.x},${args.region.y},${args.region.width},${args.region.height}`,
    );
  }
  if (args.camera) {
    nativeArgs.push("--camera");
    appendCameraArgs(nativeArgs, args);
  }
  appendQualityArgs(nativeArgs, args);
  return nativeArgs;
}

function appendCameraArgs(nativeArgs, args) {
  if (args.cameraName) {
    nativeArgs.push("--camera-name", args.cameraName);
  }
  if (args.cameraSize != null) {
    nativeArgs.push("--camera-size", String(args.cameraSize));
  }
  if (args.cameraPosition) {
    nativeArgs.push("--camera-position", args.cameraPosition);
  }
}

function appendQualityArgs(nativeArgs, args) {
  if (args.hevc || args.codec === "hevc") {
    nativeArgs.push("--hevc");
  }
  if (args.codec === "h264") {
    nativeArgs.push("--codec", "h264");
  }
  if (args.quality) {
    nativeArgs.push("--quality", args.quality);
  }
  if (args.scale != null) {
    nativeArgs.push("--scale", String(args.scale));
  }
  if (args.videoBitrate != null) {
    nativeArgs.push("--video-bitrate", String(args.videoBitrate));
  }
  if (args.audioBitrate != null) {
    nativeArgs.push("--audio-bitrate", String(args.audioBitrate));
  }
}

function formatDuration(seconds) {
  const totalSeconds = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const remainder = totalSeconds % 60;
  return [hours, minutes, remainder]
    .map((value) => String(value).padStart(2, "0"))
    .join(":");
}

function timestampFilename(date = new Date()) {
  const parts = [
    date.getFullYear(),
    date.getMonth() + 1,
    date.getDate(),
    date.getHours(),
    date.getMinutes(),
    date.getSeconds(),
  ].map((value) => String(value).padStart(2, "0"));

  return `recording-${parts.slice(0, 3).join("-")}-${parts.slice(3).join("")}`;
}

async function readPackageInfo() {
  const packageJsonUrl = new URL("../package.json", import.meta.url);
  const rawPackageJson = await readFile(packageJsonUrl, "utf8");
  return JSON.parse(rawPackageJson);
}

function recordingSummary(args) {
  if (args.onlyMic) {
    return "microphone";
  }
  if (args.onlySystemAudio) {
    return "system audio";
  }
  if (args.onlyCamera) {
    return "camera";
  }

  const source = args.windowName
    ? `window "${args.windowName}"`
    : args.region
      ? "region"
      : "screen";
  return `${source}${args.systemAudio ? ", system audio" : ""}${args.microphone ? ", microphone" : ""}${args.camera ? ", camera" : ""}`;
}

function recordingTabTitle(args) {
  if (args.onlyMic || args.onlySystemAudio) {
    return "Recording Audio";
  }
  if (args.onlyCamera) {
    return "Recording Camera";
  }
  return "Recording Screen";
}

function helpText(info) {
  const command = info.name;
  const description = info.description || "";
  return `${command} ${info.version}
${description ? `\n${description}\n` : ""}
Usage:
  ${command} [options]
  ${command} --only-mic
  ${command} --internal
  ${command} --only-camera
  ${command} mics | windows | cameras
  ${command} permissions

Examples:
  ${command}
  ${command} --window Safari
  ${command} --region
  ${command} --region 120,80,1280,720
  ${command} --for 30s --in 3
  ${command} --only-mic
  ${command} --internal
  ${command} --camera --hevc --quality high
  ${command} --codec hevc --video-bitrate 12m --audio-bitrate 192k --scale 0.75

Options:
  -h, --help                       Show this help text.
  -v, --version                    Show the package version.
  -o, --output <path>              Save to this exact path instead of the default location.
      --location <dir>             Save into this directory with a timestamped name.
      --here                       Save into the current directory (same as --location .).
      --only-mic, --mic-only, --microphone
                                   Record only the microphone as MP3.
      --only-system-audio, --system-audio-only, --internal, --internal-only
                                   Record only system/application audio as MP3.
      --only-camera, --camera-only Record only the camera.
      --no-mic                     Disable microphone capture.
      --mic <name>                 Select a microphone by name (default: built-in Mac mic).
      --list-mics                  List microphones that --mic can select.
      --no-system-audio            Disable system/application audio.
      --window, --app <name>       Capture a window by app or title instead of the display.
      --region [x,y,w,h]           Capture a rectangle; omit the value to click-drag one.
      --camera [name]              Overlay a face cam in the recording.
      --camera-size <0-1>          Face-cam width as a fraction of the video (default: 0.22).
      --camera-position <pos>      bottom-right, bottom-left, top-right, or top-left.
      --for, --duration <duration> Stop and save after this long, for example 30s or 1m30s.
      --in, --delay <duration>     Wait this long before recording starts.
      --hevc                       Encode video with HEVC instead of H.264.
      --codec <h264|hevc>          Video codec (default: h264).
      --quality <low|high>         Simple quality preset; fine flags below override it.
      --scale <n>                  Scale video (0-1, or a percent such as 50).
      --video-bitrate <rate>       Video bitrate, for example 8m or 8000k.
      --audio-bitrate <rate>       Audio bitrate, for example 192k.
      --display <number>           Capture display number (default: 1).
      --fps <number>               Capture frame rate (default: 60).
      --format <mp4|mov>           Video container (default: mp4). Audio-only default is MP3.
      --no-cursor                  Hide the mouse cursor.

Recordings save to ~/Downloads with a timestamped name unless --output, --location, or --here is given.

Keys:
  Enter                            Stop and save.
  Ctrl+C                           Stop and save.
  Ctrl+D                           Discard the recording.
`;
}

function setTerminalTabTitle(title) {
  if (!process.stdout.isTTY) {
    return;
  }
  process.title = title;
  process.stdout.write(`\x1b]0;${title}\x07`);
  process.stdout.write(`\x1b]1;${title}\x07`);
}

function restoreTerminalTabTitle(previousTitle) {
  if (!process.stdout.isTTY) {
    return;
  }
  const title = previousTitle || "record";
  process.title = title;
  process.stdout.write(`\x1b]0;${title}\x07`);
  process.stdout.write(`\x1b]1;${title}\x07`);
}
