import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
import fs from "node:fs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tauri = path.join(root, "node_modules", ".bin", "tauri");
const release = path.join(root, "src-tauri", "target", "release", "bundle");
const app = path.join(release, "macos", "MenuGit.app");
const dmgDir = path.join(release, "dmg");
const staging = path.join(dmgDir, "MenuGit-dmg-root");
const version = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).version;
const arch = process.arch === "arm64" ? "aarch64" : "x86_64";
const dmg = path.join(dmgDir, `MenuGit_${version}_${arch}.dmg`);
const cargoBin = path.join(homedir(), ".cargo", "bin");
const env = { ...process.env, PATH: `${cargoBin}:${process.env.PATH ?? ""}` };

if (process.platform !== "darwin") {
  throw new Error("macOS app and FinderSync packaging must run on macOS");
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, env, stdio: "inherit", ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

// Tauri 先生成 .app。DMG 由 hdiutil 直接制作，不调用默认脚本中的 Finder AppleScript。
run(tauri, ["build", "--bundles", "app"]);
if (!fs.existsSync(app)) throw new Error(`Tauri 未生成应用包：${app}`);

const signingIdentity = process.env.APPLE_SIGNING_IDENTITY || "-";
const signArgs = ["--force", "--sign", signingIdentity];
if (signingIdentity === "-") signArgs.push("--timestamp=none");
else signArgs.push("--options", "runtime", "--timestamp");
// 先签扩展，再签外层；--deep 重签会丢失扩展自身的沙盒权限。
run("codesign", [...signArgs, "--entitlements", path.join(root, "extensions", "macos", "MenuGitFinderSync.entitlements"), path.join(app, "Contents", "PlugIns", "MenuGitFinderSync.appex")]);
run("codesign", [...signArgs, app]);
run("codesign", ["--verify", "--deep", "--strict", app]);
run(process.execPath, [path.join(root, "scripts", "check-macos-bundle.mjs"), app]);

fs.rmSync(staging, { recursive: true, force: true });
fs.mkdirSync(staging, { recursive: true });
fs.symlinkSync("/Applications", path.join(staging, "Applications"));
fs.cpSync(app, path.join(staging, "MenuGit.app"), { recursive: true, dereference: false });
run("hdiutil", ["create", "-ov", "-volname", "MenuGit", "-srcfolder", staging, "-format", "UDZO", dmg]);
run("hdiutil", ["verify", dmg]);
console.log(`Created ${dmg}`);
