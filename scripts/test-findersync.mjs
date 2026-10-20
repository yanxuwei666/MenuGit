import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
if (process.platform !== "darwin") throw new Error("FinderSync tests require macOS");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "menugit-finder-tests-"));
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit", ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} exited with ${result.status ?? result.signal}`);
  return result;
}
function write(relative, value) {
  const target = path.join(temporary, "fixtures", relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, value);
}
try {
  for (const dir of ["plain", "repo/sub", "merging", "worktree", "detached", "malformed"])
    fs.mkdirSync(path.join(temporary, "fixtures", dir), { recursive: true });
  write("repo/.git/HEAD", "ref: refs/heads/feature/menu-fix\n");
  write("repo/sub/测试 file.txt", "sample\n");
  write("merging/.git/HEAD", "ref: refs/heads/main\n");
  write("merging/.git/MERGE_HEAD", "1234567890\n");
  write("worktree/.git", "gitdir: ../worktree-metadata\n");
  write("worktree-metadata/HEAD", "ref: refs/heads/worktree-test\n");
  write("detached/.git/HEAD", "1234567890abcdef1234567890abcdef12345678\n");
  write("malformed/.git", "not a git directory\n");
  run("bash", ["scripts/build-findersync.sh"]);
  const testApp = path.join(temporary, "FinderMenuTests.app");
  const binary = path.join(testApp, "Contents", "MacOS", "FinderMenuTests");
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  fs.writeFileSync(path.join(testApp, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.menugit.desktop.findersync.tests</string>
<key>CFBundleExecutable</key><string>FinderMenuTests</string>
<key>CFBundleName</key><string>FinderMenuTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSBackgroundOnly</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>`);
  const target = `${os.arch() === "arm64" ? "arm64" : "x86_64"}-apple-macosx12.0`;
  const nativeProbe = path.join(temporary, "FinderFrameworkProbe.o");
  run("xcrun", ["clang", "-fobjc-arc", "-target", target, "-c", "extensions/macos/tests/FinderFrameworkProbe.m", "-o", nativeProbe]);
  run("xcrun", ["swiftc", "-parse-as-library", "-target", target, "-framework", "Cocoa", "-framework", "FinderSync", "-import-objc-header", "extensions/macos/tests/FinderFrameworkProbe.h", nativeProbe, "-o", binary,
    "extensions/macos/FinderSyncExtension.swift", "extensions/macos/MenuGitFinderMenu.swift", "extensions/macos/tests/FinderMenuTests.swift"]);
  run("codesign", ["--force", "--sign", "-", "--entitlements", "extensions/macos/MenuGitFinderSync.entitlements", "--timestamp=none", testApp]);
  run(binary, [path.join(temporary, "fixtures")]);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
