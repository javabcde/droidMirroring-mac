# CLAUDE.md

## Build & Release

### CI Workflow Match

**本地编译必须和 GitHub Actions workflow 编译方式一致**，这样可以先在本地发现并修复问题，避免反复推送 tag 触发 CI。

### CI 编译命令（来自 `.github/workflows/release.yml`）

```bash
# 1. Generate Xcode project (if using xcodegen)
xcodegen generate

# 2. Build with exact CI flags
xcodebuild -project DroidMirroring.xcodeproj \
  -scheme DroidMirroring \
  -configuration Release \
  -derivedDataPath build \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=off \
  build
```

### 关键点

- `ARCHS="arm64 x86_64"` — Universal Binary（双架构）
- `ONLY_ACTIVE_ARCH=NO` — 必须编译所有架构
- `CODE_SIGN_IDENTITY="-"` — 使用 ad-hoc 签名
- `SWIFT_STRICT_CONCURRENCY=off` — 关闭严格并发检查（CI 用 Xcode 16）
- CI runner: `macos-15` with `Xcode_16.app`

### Release 流程

1. 本地编译确认通过
2. `git commit` 提交修复
3. `git push origin main`
4. 删除旧 tag（如有）：`git push origin --delete vX.X.X && git tag -d vX.X.X`
5. 打新 tag：`git tag vX.X.X && git push origin vX.X.X`
6. 监控：`gh run list` / `gh run watch <run-id>`

### Release Workflow 说明

- 仅发布到当前仓库（`matyle/droidMirroring-mac`）
- 不需要 `CROSS_REPO` secret
- 触发条件：push tag（`v*`）或手动 workflow_dispatch
