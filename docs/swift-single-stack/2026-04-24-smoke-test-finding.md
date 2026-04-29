# v3 Smoke-Test Finding —— `~/.engram` 已存在时 Service 启动失败

**日期:** 2026-04-24
**触发 commit:** 88d5e01 后的 Release 部署到 `/Applications/Engram.app`
**严重性:** High(所有从 Node 版本升级的老用户必遇 —— 用户最常见路径)

## 复现步骤

1. `xcodebuild -scheme Engram -configuration Release build`
2. `codesign --force --deep --sign - /Applications/Engram.app`(ad-hoc 签名,因为本地无 Developer ID)
3. 运行 `/Applications/Engram.app/Contents/MacOS/Engram`
4. 观察 `log show --predicate 'processImagePath CONTAINS "Engram"'`

## 观察到的错误

```
Engram: [com.engram.app:daemon] EngramService stderr:
EngramService failed: serviceUnavailable(message: "Service Root Directory must be mode 0700")
```

Launcher 健康检查 5s 打一次失败,累计 3 次后 Service 进入 `.degraded` 状态 —— 所有写工具(save_insight / setFavorite / generateSummary / export / linkSessions 等)永久 fail-closed,UI 菜单栏徽章也无法更新。

## Root Cause

**文件:** `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:98-124`(`secureRuntimeDirectory`)

```swift
static func secureRuntimeDirectory(...) throws -> URL {
    let rootDirectory = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
    ...
    if !fileManager.fileExists(atPath: rootDirectory.path) {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try validateRuntimeDirectory(rootDirectory, label: "service root directory")
    ...
}
```

**问题:** 只在目录**不存在**时才创建为 0700。对**已存在**的旧 `~/.engram`(Node 版本创建,系统 umask 默认 0755),代码直接跳过创建步骤,然后 `validateRuntimeDirectory` 检查 `(info.st_mode & 0o077) == 0` 失败。

**影响范围:** 任何从 Phase C(Node daemon)升级到 Swift single-stack 的用户。`~/.engram` 是 Node 版本就存在的目录(里面有 `index.sqlite` / `settings.json` / `mcp-events.json` 等),mode 一直是 0755。新用户(干净系统)走 `createDirectory(..., 0o700)` 分支所以没问题 —— 这就是为什么 CI/测试从没抓到。

## 推荐修复

在 `secureRuntimeDirectory` 里,对**已存在但 mode 不对**的目录做 chmod 修复,而不是直接 validate 失败:

```swift
static func secureRuntimeDirectory(...) throws -> URL {
    let rootDirectory = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
    let runDirectory = rootDirectory.appendingPathComponent("run", isDirectory: true)
    let fileManager = FileManager.default

    try ensureSecureDirectory(rootDirectory, label: "service root directory")
    try ensureSecureDirectory(runDirectory, label: "service runtime directory")
    return runDirectory
}

private static func ensureSecureDirectory(_ directory: URL, label: String) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.path) {
        // 已存在 -> stat 检查 + 必要时 chmod 修复
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat \(label)")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw EngramServiceError.serviceUnavailable(message: "\(label.capitalized) path is not a directory")
        }
        guard info.st_uid == geteuid() else {
            throw EngramServiceError.serviceUnavailable(message: "\(label.capitalized) is owned by another user")
        }
        if (info.st_mode & 0o077) != 0 {
            // 原先模式太宽松(如 Node 时代的 0755),修复为 0700
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    } else {
        // 不存在 -> 用 0700 创建
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try validateRuntimeDirectory(directory, label: label)  // 最终兜底校验
}
```

**安全性考虑:** `setAttributes` 收紧权限(0755 → 0700),不放宽,不是敏感操作。且前置已验证 owner = geteuid(),即使目录存在也是当前用户所有。

## 临时绕过(对现有用户)

```
chmod 0700 ~/.engram
```

## 验收标准

1. 新增测试 `EngramServiceIPCTests.testSecureRuntimeDirectoryRepairsLegacyPermissions`:
   - 预先 `mkdir ~/.engram -m 0755`
   - 调 `secureRuntimeDirectory()`
   - 断言返回 OK,且 stat 后 mode 为 0700
2. 回归测试 `testSecureRuntimeDirectoryCreatesFreshWith0700`(干净场景):仍通过
3. 手动 smoke:`chmod 0755 ~/.engram && open /Applications/Engram.app` → Service 启动成功,`~/.engram/run/engram-service.sock` 出现

## 其他 smoke-test 观察(无需修复)

- **Release 本地未签名**:`codesign --force --deep --sign -` ad-hoc 即可启动;真发布时需 Developer ID + notarize(这是 ship 流程问题,不是代码 bug)
- **App bundle 仍含 Node**:`Contents/Resources/node/daemon.js` + `node_modules` 还在(689M app 大部分是这些)。Stage 5 清理计划内,非 blocker
- **`Resources/node/` 不再被启动**:smoke 过程中只观察到 Engram 主进程 + 1 个 EngramService helper,没有任何 `node daemon.js` 进程;Unix socket 正常建立并被 Service 监听 ✅

---

**这是唯一 blocker bug。修复后,v3 可以安心 ship。** 验证过程:`xcodebuild build` ✅ / `check-swift-schema-compat.ts` ✅ / `MigrationRunnerTests + IndexerParityTests + StartupBackfillTests 17/17` ✅ / Release build + 部署 + 启动(chmod 绕过后)✅。
