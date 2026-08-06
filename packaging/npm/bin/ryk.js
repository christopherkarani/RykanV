#!/usr/bin/env node
"use strict";

const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const childProcess = require("child_process");

const packageRoot = path.resolve(__dirname, "..");
const packageJson = require(path.join(packageRoot, "package.json"));
const binDir = path.join(packageRoot, "vendor");
const resourceDir = path.join(binDir, "resources");
const binaryName = process.platform === "win32" ? "ryk.exe" : "ryk";
const installedBinary = path.join(binDir, binaryName);
const maxDownloadBytes = 512 * 1024 * 1024;

function metaBlock() {
  return packageJson.ryk || {};
}

function platformName() {
  if (process.platform === "darwin") return "darwin";
  if (process.platform === "linux") return "linux";
  if (process.platform === "win32") return "windows";
  throw new Error(`unsupported operating system: ${process.platform}`);
}

function archName() {
  if (process.arch === "x64") return "amd64";
  if (process.arch === "arm64") return "arm64";
  throw new Error(`unsupported architecture: ${process.arch}`);
}

function sha256(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function artifactName(platform, arch) {
  const ext = platform === "windows" ? "zip" : "tar.gz";
  return `ryk-v${packageJson.version}-${platform}-${arch}.${ext}`;
}

function supportedTargets() {
  const meta = metaBlock();
  return meta.supportedTargets || Object.keys(meta.checksums || {});
}

function download(url, outputPath, redirects = 0) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, (response) => {
      if (
        response.statusCode >= 300 &&
        response.statusCode < 400 &&
        response.headers.location &&
        redirects < 5
      ) {
        response.resume();
        download(new URL(response.headers.location, url).toString(), outputPath, redirects + 1).then(resolve, reject);
        return;
      }
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`download failed: HTTP ${response.statusCode} for ${url}`));
        return;
      }
      const contentLength = Number(response.headers["content-length"] || "0");
      if (contentLength > maxDownloadBytes) {
        response.resume();
        reject(new Error(`download too large: ${contentLength} bytes`));
        return;
      }
      const file = fs.createWriteStream(outputPath, { mode: 0o600 });
      let received = 0;
      response.on("data", (chunk) => {
        received += chunk.length;
        if (received > maxDownloadBytes) {
          request.destroy(new Error("download exceeded maximum size"));
          return;
        }
        file.write(chunk);
      });
      response.on("end", () => file.end());
      response.on("error", reject);
      file.on("finish", () => file.close(resolve));
      file.on("error", reject);
    });
    request.setTimeout(120000, () => request.destroy(new Error("download timed out")));
    request.on("error", reject);
  });
}

function runChecked(command, args, options = {}) {
  const result = childProcess.spawnSync(command, args, { stdio: "inherit", ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} exited with status ${result.status}`);
  }
}

function extractArchive(archive, destination, platform) {
  fs.mkdirSync(destination, { recursive: true });
  if (platform === "windows") {
    runChecked("powershell", [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-Command",
      "Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force",
      archive,
      destination,
    ]);
  } else {
    runChecked("tar", ["-xzf", archive, "-C", destination]);
  }
}

function installReleasePayload(extractDir, platform, arch) {
  const top = path.join(extractDir, `ryk-v${packageJson.version}-${platform}-${arch}`);
  if (!fs.existsSync(top) || !fs.statSync(top).isDirectory()) {
    throw new Error(`archive did not contain expected release root for ${platform}-${arch}`);
  }
  const source = path.join(top, "bin", binaryName);
  if (!fs.existsSync(source)) {
    throw new Error(`archive did not contain expected binary: ${source}`);
  }
  fs.rmSync(binDir, { recursive: true, force: true });
  fs.mkdirSync(binDir, { recursive: true });
  fs.copyFileSync(source, installedBinary);
  if (platform !== "windows") fs.chmodSync(installedBinary, 0o755);
  fs.mkdirSync(resourceDir, { recursive: true });
  for (const dir of ["docs", "examples", "fixtures", "integrations", "ryk-dashboard-ui", "policies", "schemas"]) {
    const sourceDir = path.join(top, dir);
    if (fs.existsSync(sourceDir)) {
      fs.cpSync(sourceDir, path.join(resourceDir, dir), { recursive: true });
    }
  }
}

async function install() {
  const platform = platformName();
  const arch = archName();
  const key = `${platform}-${arch}`;
  const targets = supportedTargets();
  if (!targets.includes(key)) {
    throw new Error(`unsupported ryk npm target: ${key}; supported targets: ${targets.join(", ")}`);
  }
  const meta = metaBlock();
  const expected = meta.checksums && meta.checksums[key];
  if (!expected || expected.startsWith("PLACEHOLDER_")) {
    throw new Error("ryk npm package is missing release checksums; publish only after release automation injects verified checksums.");
  }

  const name = artifactName(platform, arch);
  const baseUrl = meta.artifactBaseUrl;
  const url = `${baseUrl}/${name}`;
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "ryk-npm-"));
  try {
    const archive = path.join(tmpRoot, name);
    const extractDir = path.join(tmpRoot, "extract");
    await download(url, archive);
    const actual = sha256(archive);
    if (actual !== expected) {
      throw new Error(`checksum mismatch for ${name}: expected ${expected}, got ${actual}`);
    }
    extractArchive(archive, extractDir, platform);
    installReleasePayload(extractDir, platform, arch);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
}

if (process.argv.includes("--install")) {
  install().then(
    () => process.exit(0),
    (error) => {
      console.error(error.message);
      process.exit(1);
    },
  );
  return;
}

if (!fs.existsSync(installedBinary)) {
  console.error("ryk binary is not installed. Reinstall after release automation replaces checksum placeholders.");
  process.exit(1);
}

const env = { ...process.env };
if (fs.existsSync(resourceDir)) {
  env.RYK_RESOURCE_ROOT = resourceDir;
}
const result = childProcess.spawnSync(installedBinary, process.argv.slice(2), { stdio: "inherit", env });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
