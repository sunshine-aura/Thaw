<!-- cSpell:ignore cghid xcodeproj pbxproj -->

# 本地补丁说明（1.2.0 → 1.2.0-local-thaw）

仅供本机使用。这是把 upstream 2.x 上的两条修复针对 1.2.0 基线手工移植的最小补丁。
当前分支是 `1.2.0-local-thaw`，从 `1.2.0` tag 拉出。

## 修了什么

`1.2.0` 在 macOS 15 上点击 IceBar 隐藏项时，Thaw 图标会抖动/弹一下、菜单打不开、光标往左上角跑。
原因是 2.x 上 `f972f37e` 和 `61048701` 这两条修复没回移到 1.x。

### 1. f972f37e（冰吧隐藏项点击稳定）

- `Thaw/MenuBar/IceBar/IceBar.swift`
  - `leftClickAction` / `rightClickAction`：把 25 ms `Task.sleep` 换成基于 `panel.isVisible` 的轮询（10 ms 一次，最多 200 ms）。
  - 新增 `waitForPanelClosed(_:timeout:)`。
- `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`
  - `waitForItemPositionToSettle(item:previousOrigin:)` 加两段式：先等 origin 离开旧位置（≤150 ms），再走原 settle（≤250 ms）。
  - `temporarilyShow`：在 move 前抓 `preMoveOrigin`，并把它传进 settle。

### 2. 61048701（合成点击光标恢复 + 热角防护）

- `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`
  - `postMoveEvents`：`hideCursor()` 之前先 `warpCursor(to: targetPoints.start)`。
  - `postClickEvents`：`hideCursor()` 之前先 `warpCursor(to: clickPoint)`，然后 sleep 10 ms 让 Window Server 把 warp 同步完。
- `Thaw/Utilities/MouseHelpers.swift`
  - `warpCursor` 失败时改 `warning` 级别日志，并 fallback 用 `CGEvent mouseMoved` 经 `.cghidEventTap` 投递。

> 这份补丁**不包含** upstream 2.x 上为 macOS 26 引入的额外修复（Electron/Chromium 走 AX、按面板的 stuck-context 退避，等等）。
> 这里的范围只是"图标抖 + 菜单点不开"那两个症状。

## 部署目标

`Thaw.xcodeproj/project.pbxproj` 已保持 `MACOSX_DEPLOYMENT_TARGET = 14.0`，未改。在 macOS 14/15 上都能 build & run。

## 构建

本仓库用的是 Xcode 工程，需要 macOS + Xcode：

```sh
xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Debug build
```

或在 Xcode GUI 里直接打开 `Thaw.xcodeproj`，选 `Thaw` scheme，build & run。

## 没做的事

- 没有改 `1.2.0..HEAD` 之间的 100+ 个其它 commit（其中含 macOS 26-only API）。
- 没有写单测。upstream 没有 `MenuBarItemManager.temp + show` 这条路径的覆盖测试。
- 没有做完整 `xcodebuild` 验证（本机只有 CommandLineTools，没有 Xcode.app）。
  已在修改前/后分别对三个文件做 `swift -frontend -typecheck` 对比，**误差计数完全一致**（130 / 610 / 2），全部由单文件 typecheck 看不到工程其它源文件所导致的 `cannot find X in scope` 类预期错误，**没有引入新错误**。最终编译与运行验证需要在你的 macOS 15 上完成。

## 回退

```sh
git checkout 1.2.0 -- Thaw/MenuBar/IceBar/IceBar.swift \
                    Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift \
                    Thaw/Utilities/MouseHelpers.swift
# 或者
git checkout 1.2.0
git branch -D 1.2.0-local-thaw
```
