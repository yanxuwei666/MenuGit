import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

if (process.platform !== "darwin") throw new Error("FinderSync verification requires macOS");
const app = path.resolve(process.argv[2] ?? "/Applications/MenuGit.app");
const observedIndex = process.argv.indexOf("--observed-path");
const observedPath = observedIndex >= 0 ? process.argv[observedIndex + 1] : null;
if (observedIndex >= 0 && !observedPath) throw new Error("Missing --observed-path value");
const digest = observedPath ? createHash("sha256").update(fs.realpathSync(observedPath)).digest("hex") : null;
const pluginExe = path.join(app, "Contents", "PlugIns", "MenuGitFinderSync.appex", "Contents", "MacOS", "MenuGitFinderSync");
const main = path.join(app, "Contents", "MacOS", "menugit");
function run(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || `${command}: ${result.signal}`);
  return result.stdout;
}
let log = "";
const stream = spawn("/usr/bin/log", ["stream", "--style", "compact", "--level", "info", "--predicate", 'subsystem == "dev.menugit.desktop.findersync"']);
const closed = once(stream, "close");
stream.stdout.on("data", chunk => { log += chunk.toString(); });
stream.stderr.on("data", chunk => { log += chunk.toString(); });
let state;
try {
  // 仅重新加载 MenuGit 扩展，不重启 Finder，不启动应用主窗口。
  run("/usr/bin/pluginkit", ["-e", "ignore", "-i", "dev.menugit.desktop.findersync"]);
  for (const line of run("/bin/ps", ["-axo", "pid=,command="]).split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(.+)$/);
    if (match && (match[2] === pluginExe || match[2].startsWith(`${pluginExe} `))) {
      try { process.kill(Number(match[1]), "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    }
  }
  state = JSON.parse(run(main, ["--repair-finder-extension"]));
  assert.ok(state.registered && state.enabled, "Extension registration or enablement failed");
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 8000;
    const timer = setInterval(() => {
      if (log.includes("Finder extension started") && (!digest || log.includes(`observing directory digest=${digest}`))) {
        clearInterval(timer); resolve();
      } else if (Date.now() >= deadline) {
        clearInterval(timer);
        reject(new Error(digest ? "Finder did not observe the requested directory; this check requires it to already be open in Finder" : "Finder did not initialize the extension"));
      }
    }, 100);
  });
  const checker = path.resolve("scripts/check-macos-bundle.mjs");
  console.log(run(process.execPath, [checker, app, "--installed"]).trim());
  console.log(digest ? `PASS real Finder directory routing: ${digest}` : "PASS Finder initialized installed extension");
} finally {
  // 修复失败时仍恢复扩展的启用选择。
  if (!state?.enabled) run("/usr/bin/pluginkit", ["-e", "use", "-i", "dev.menugit.desktop.findersync"]);
  stream.kill("SIGTERM");
  await closed;
  fs.mkdirSync("src-tauri/target", { recursive: true });
  fs.writeFileSync("src-tauri/target/finder-routing-check.log", `${new Date().toISOString()}\n${JSON.stringify(state)}\nexpectedDirectoryDigest=${digest ?? "not requested"}\n${log}`);
}
