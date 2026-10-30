#!/bin/bash
set -euo pipefail

# macOS /bin/bash 3.2 在 UTF-8 locale 下会把 $VAR 后紧跟的非 ASCII 字符并入变量名，所以变量一律用花括号。
REPO="yanxuwei666/MenuGit"
BUNDLE_ID="dev.menugit.native.finder"

info() { printf '%s\n' "$*"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "此脚本仅支持 macOS。"

VERSION="${MENUGIT_VERSION:-}"
if [ -z "${VERSION}" ]; then
    info "正在查询最新版本…"
    LATEST_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" || true)
    VERSION="${LATEST_URL##*/}"
    case "${VERSION}" in
        v[0-9]*) ;;
        *) fail "无法获取最新版本，请检查网络，或设置 MENUGIT_VERSION=v0.1.1 后重试。" ;;
    esac
fi

DMG_URL="https://github.com/${REPO}/releases/download/${VERSION}/MenuGit-${VERSION}.dmg"
TMP=$(mktemp -d)
MOUNT="${TMP}/mnt"
mkdir -p "${MOUNT}"
cleanup() {
    hdiutil detach "${MOUNT}" >/dev/null 2>&1 || true
    rm -rf "${TMP}"
}
trap cleanup EXIT

info "下载 MenuGit ${VERSION}…"
curl -fL --progress-bar "${DMG_URL}" -o "${TMP}/MenuGit.dmg" || fail "下载失败：${DMG_URL}"
hdiutil attach "${TMP}/MenuGit.dmg" -nobrowse -readonly -mountpoint "${MOUNT}" >/dev/null || fail "无法挂载 DMG。"
[ -d "${MOUNT}/MenuGit.app" ] || fail "DMG 中未找到 MenuGit.app。"

TARGET_DIR="/Applications"
if [ ! -w "${TARGET_DIR}" ]; then
    TARGET_DIR="${HOME}/Applications"
    mkdir -p "${TARGET_DIR}"
fi
TARGET="${TARGET_DIR}/MenuGit.app"

info "安装到 ${TARGET}…"
killall MenuGit MenuGitFinder 2>/dev/null || true
sleep 1
rm -rf "${TARGET}"
ditto "${MOUNT}/MenuGit.app" "${TARGET}"
xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true

info "启动应用并注册 Finder 扩展…"
open "${TARGET}"
for _ in $(seq 1 20); do
    if pluginkit -m -A -i "${BUNDLE_ID}" 2>/dev/null | grep -q "${BUNDLE_ID}"; then
        break
    fi
    sleep 0.5
done
pluginkit -e use -i "${BUNDLE_ID}" 2>/dev/null || true

info "重启 Finder 以加载右键菜单…"
killall Finder 2>/dev/null || true

info ""
info "安装完成：MenuGit ${VERSION}"
info "在 Finder 中右键仓库里的文件或文件夹，即可看到 MenuGit 菜单。"
info "卸载：把 MenuGit.app 拖进废纸篓即可，应用会自动退出并移除右键菜单。"
