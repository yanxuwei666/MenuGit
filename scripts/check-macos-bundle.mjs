import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const app = path.resolve(process.argv[2] ?? "src-tauri/target/release/bundle/macos/MenuGit.app");
const installed = process.argv.includes("--installed");
function capture(command, args, input) {
  const result = spawnSync(command, args, { encoding: "utf8", input });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr || result.signal}`);
  return result.stdout;
}
function plist(filename) {
  return JSON.parse(capture("plutil", ["-convert", "json", "-o", "-", filename]));
}
const info = plist(path.join(app, "Contents", "Info.plist"));
const plugin = path.join(app, "Contents", "PlugIns", "MenuGitFinderSync.appex");
const pluginInfo = plist(path.join(plugin, "Contents", "Info.plist"));
const executable = path.join(plugin, "Contents", "MacOS", pluginInfo.CFBundleExecutable);
assert.equal(info.CFBundleIdentifier, "dev.menugit.desktop");
assert.ok(
  info.CFBundleURLTypes?.some((entry) => entry.CFBundleURLSchemes?.includes("menugit")),
  "Info.plist does not declare the menugit URL scheme"
);
assert.equal(pluginInfo.CFBundleIdentifier, `${info.CFBundleIdentifier}.findersync`);
assert.equal(pluginInfo.CFBundlePackageType, "XPC!");
assert.deepEqual(pluginInfo.CFBundleSupportedPlatforms, ["MacOSX"]);
assert.equal(pluginInfo.LSMinimumSystemVersion, "12.0");
assert.equal(pluginInfo.LSUIElement, true);
assert.equal(pluginInfo.NSExtension.NSExtensionPointIdentifier, "com.apple.FinderSync");
assert.equal(pluginInfo.NSExtension.NSExtensionPrincipalClass, "MenuGitFinderSyncExtension");
assert.ok(fs.statSync(executable).mode & 0o111, "Finder extension is not executable");
assert.match(capture("file", [executable]), /Mach-O.*executable/);
assert.match(capture("xcrun", ["vtool", "-show-build", executable]), /minos\s+12\.0\b/);
assert.match(capture("xcrun", ["otool", "-l", executable]), /LC_MAIN/);
assert.match(capture("xcrun", ["nm", "-u", executable]), /_NSExtensionMain/);
const entitlementXml = capture("codesign", ["--display", "--entitlements", "-", "--xml", plugin]);
const entitlements = JSON.parse(capture("plutil", ["-convert", "json", "-o", "-", "-"], entitlementXml));
assert.equal(entitlements["com.apple.security.app-sandbox"], true);
assert.equal(entitlements["com.apple.security.files.user-selected.read-only"], true);
for (const scope of ["/Users/", "/Volumes/", "/private/tmp/"])
  assert.ok(entitlements["com.apple.security.temporary-exception.files.absolute-path.read-only"].includes(scope), `Missing read scope: ${scope}`);
capture("codesign", ["--verify", "--deep", "--strict", app]);
const main = path.join(app, "Contents", "MacOS", info.CFBundleExecutable);
const state = JSON.parse(capture(main, ["--finder-extension-status"]));
assert.equal(state.supported, true);
assert.equal(state.bundled, true);
assert.equal(state.extensionPath, plugin);
if (installed) {
  assert.equal(state.registered, true, "Installed extension is not registered");
  assert.equal(state.enabled, true, "Installed extension is not enabled");
  const processes = capture("ps", ["-axo", "pid=,command="]);
  assert.ok(processes.split("\n").some(line => {
    const command = line.trim().replace(/^\d+\s+/, "");
    return command === executable || command.startsWith(`${executable} `);
  }), "Finder has not launched the installed extension");
}
console.log(`PASS macOS bundle: executable entry, minimum OS, sandbox permissions, signing, CLI status${installed ? ", installed registration, enablement and live Finder extension" : ""}`);
console.log(JSON.stringify(state));
