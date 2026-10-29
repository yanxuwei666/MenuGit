# macOS 首版采用原生应用

## 状态

已确定技术方向；Finder 覆盖、系统权限、Git 环境和最低系统版本仍需验证。详细需求以 [macOS 需求规格](../Requirements-Spec-MenuGit-macOS.md) 为准，实施细节见 [开发方案](../Development-Plan-MenuGit-macOS.md)。

## 背景与决定

MenuGit 首版只面向 macOS，以 Finder 右键为主要入口，界面需贴近 macOS。主应用采用 SwiftUI / Swift，Finder 入口采用 Finder Sync 扩展，Git 操作复用系统 Git 和已有配置。

## 取舍与边界

这需要重新实现历史上的 Tauri / Vue / Rust 应用，而不是继续以它作为首版技术基线。Finder Sync 提供的目录监控和右键入口不等于自动覆盖用户可访问的所有目录，也不等于主应用已获得文件访问权限；覆盖范围和权限需要单独验证。此决策不指定最低 macOS 版本，也不表示已经实现或通过发布验收。
