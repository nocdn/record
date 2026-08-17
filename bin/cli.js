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
    await listMicrophones();
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
  setTerminalTabTitle(args.onlyMic ? "Recording Audio" : "Recording Screen");

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
  const nativeArgs = ["--output", outputPath];

  if (args.onlyMic) {
    nativeArgs.push("--only-mic");
    if (args.microphoneName) {
      nativeArgs.push("--mic", args.microphoneName);
    }
  } else {
    nativeArgs.push(
      "--display",
      String(args.display),
      "--fps",
      String(args.fps),
      "--format",
      args.format,
    );

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
  }

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
        process.stdout.write("Duration: 00:00:00\n");
        process.stdout.write("Press Ctrl+C to stop and save, or Ctrl+D to discard.\n");
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
  process.on("SIGINT", handleSignal);
  process.on("SIGTERM", handleSignal);
  if (process.stdin.isTTY) {
    process.stdin.on("end", handleStdinEnd);
    process.stdin.resume();
  }

  try {
    await exitPromise;
  } finally {
    process.removeListener("SIGINT", handleSignal);
    process.removeListener("SIGTERM", handleSignal);
    if (process.stdin.isTTY) {
      process.stdin.removeListener("end", handleStdinEnd);
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

async function listMicrophones() {
  assertMacOS();

  const executable = await nativeExecutable();
  const child = spawn(executable, ["--list-mics"], {
    stdio: ["ignore", "pipe", "inherit"],
  });

  const output = createInterface({ input: child.stdout });
  output.on("line", (line) => process.stdout.write(`${line}\n`));

  await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => {
      output.close();
      if (signal) {
        reject(new Error(`Microphone list stopped by ${signal}.`));
      } else if (code === 0) {
        resolve();
      } else {
        reject(new Error("No microphones were found."));
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

    if (arg === "--only-mic" || arg === "--mic-only" || arg === "--microphone") {
      args.onlyMic = true;
      args.microphone = true;
      args.systemAudio = false;
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

  if (args.onlyMic && !args.microphone) {
    throw new Error("The --only-mic option cannot be combined with --no-mic.");
  }

  return args;
}

function resolveOutputPath(args) {
  const extension = args.onlyMic ? ".mp3" : `.${args.format}`;
  const requestedPath = args.output
    ? path.resolve(args.output)
    : args.onlyMic
      ? path.join(process.cwd(), `${timestampFilename()}${extension}`)
      : path.join(os.homedir(), "Movies", `${timestampFilename()}${extension}`);

  if (path.extname(requestedPath)) {
    return requestedPath;
  }

  return `${requestedPath}${extension}`;
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

  return `screen${args.systemAudio ? ", system audio" : ""}${args.microphone ? ", microphone" : ""}`;
}

function helpText(info) {
  const command = info.name;
  const description = info.description || "";
  return `${command} ${info.version}
${description ? `\n${description}\n` : ""}
Usage:
  ${command} [options]
  ${command} --only-mic
  ${command} mics
  ${command} permissions

Examples:
  ${command}
  ${command} --output meeting.mp4
  ${command} --only-mic
  ${command} --mic "AirPods"
  ${command} mics
  ${command} --no-mic --no-system-audio
  ${command} permissions

Options:
  -h, --help                       Show this help text.
  -v, --version                    Show the package version.
  -o, --output <path>              Save to this path instead of the default location.
      --only-mic, --mic-only, --microphone
                                   Record only the microphone as MP3 in the current directory.
      --no-mic                     Disable microphone capture.
      --mic <name>                 Select a microphone by name (default: built-in Mac mic).
      --list-mics                  List microphones that --mic can select.
      --no-system-audio            Disable system/application audio.
      --display <number>           Capture display number (default: 1).
      --fps <number>               Capture frame rate (default: 60).
      --format <mp4|mov>           Video container (default: mp4). Audio-only default is MP3.
      --no-cursor                  Hide the mouse cursor.

Keys:
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
