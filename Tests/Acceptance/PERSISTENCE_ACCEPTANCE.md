# 1.3.0 代码单框草稿持久化 · 独立验收规范

**版本目标**：1.3.0 / build 5（`Info.plist` 已升）
**bundle id**：`com.visero.devkit`（正式），`com.visero.devkit.preview`（预览，独立草稿位置）
**范围**：只有「代码格式化」单框的内容落盘。Diff / Unix 时间戳 / UTC 时钟 / 下班倒计时一律不落盘。

---

## 0. 路径与权限约定（独立验收侧固定）

| 项 | 正式 | 预览 |
|---|---|---|
| 草稿目录 | `~/Library/Application Support/com.visero.devkit/` | `~/Library/Application Support/com.visero.devkit.preview/` |
| 草稿文件 | `CodeDraft.json` | `CodeDraft.json` |
| 期望权限 | `0600`（`-rw-------`） | `0600` |
| 所有者 | 当前用户 | 当前用户 |

**硬规则**：
- 预览运行时**不得**写正式 bundle id 的目录。验收时跑 preview 后，正式草稿文件 mtime 必须不变。
- 旧正式 DevKit（运行中那个）的 JSON 与偏好**不动**。验收只在 preview 或新解压的 build 上做。
- 草稿是「代码格式化」单框的输入，不是输出、不是设置、不是 Diff 两侧。

---

## 1. 七个必过验收点

### P1 重启恢复
1. 启动 preview 版 DevKit。
2. 在「代码格式化」单框粘贴一段已知文本（带 SHA-256 标记）。
3. 完全退出（Cmd+Q，不是关窗）。
4. 重新启动 preview。
5. **判据**：单框内容 == 第 2 步粘贴的字节（严格 UTF-8 相等）。

### P2 成功格式化后恢复的是格式化结果
1. 粘贴一段未格式化 JSON。
2. 点「格式化」，确认输出与输入不同。
3. 完全退出。
4. 重启。
5. **判据**：单框内容 == 第 2 步格式化后的字节（不是原始未格式化版本）。

### P3 清空后重开为空
1. 粘贴一段文本。
2. 点「清空」。
3. 完全退出。
4. 重启。
5. **判据**：单框为空字符串。草稿文件要么不存在、要么内容是空字符串/带 `{"text":""}` 版本号。

### P4 失败保留原文
1. 粘贴一段坏代码（用 `Tests/Acceptance/Samples/error/*.ext` 之一，例如 `json.trailing.json`）。
2. 点「格式化」，确认 UI 报错、单框内容不变。
3. 完全退出。
4. 重启。
5. **判据**：单框内容 == 第 1 步原始坏代码字节（不是空、不是部分格式化产物）。

### P5 并发过期 write 与 format 不盖新
这是竞态保护的核心。UI 实现：输入防抖 + 格式化完成后写盘，两者都要带「代际/版本号」。

**独立复现路径**（等 UI 实现后由 runner 跑，不用手动）：
1. 输入 `A`。
2. 防抖 timer 待发时，立刻输入 `B`（A 的写盘请求过期）。
3. 点「格式化」对 `B` 做格式化，得到 `B'`。
4. 在 `B'` 到达编辑器**之前**，让 A 的过期写盘请求强行 flush。
5. 等 `B'` 到达。
6. **判据**：
   - 编辑器最终显示 `B'`。
   - 草稿文件内容 == `B'`（A 不能盖 B，B 不能盖 B'）。
   - 用 UI 侧暴露的 session/generation 计数器；过期 write 拿到的代际 < 当前代际时必须丢弃，不写盘。

### P6 读失败不丢现内容
1. 启动 app，正常加载草稿。
2. 外部把草稿文件改成损坏 JSON / chmod 000 / 删除。
3. 触发一次重新读（或重启）。
4. **判据**：
   - 编辑器当前内容**不被清空**（如果是重启场景：启动时读失败 → 单框为空，但此时不能再写回一个空草稿覆盖用户正在输入的内容；UI 应该 silent 回退，错误只记日志）。
   - 读失败后，用户输入 `C`，退出，重启 → 能恢复 `C`（损坏草稿被新内容替换）。

### P7 权限 0600
1. 触发一次写盘。
2. `ls -l ~/Library/Application Support/<bundle>/CodeDraft.json`。
3. **判据**：权限位是 `-rw-------`（`0600`），不是 `-rw-r--r--`（`0644`）或 group/world 可写。
4. `stat -f %Sp` 输出 `crw-------` 或 `-rw-------`。

---

## 2. 附加边界验收

### B1 预览不撞正式
1. 先记录正式草稿文件 mtime（如果存在）。
2. 启动 `com.visero.devkit.preview`。
3. 在预览单框输入 `PREVIEW_ONLY`。
4. 退出预览。
5. **判据**：
   - `~/Library/Application Support/com.visero.devkit.preview/CodeDraft.json` 内容含 `PREVIEW_ONLY`。
   - `~/Library/Application Support/com.visero.devkit/CodeDraft.json` mtime 未变（或不存在）。
   - 运行中的旧正式 DevKit 窗口内容未变（没被刷新、没被清空）。

### B2 别的工具不落盘
1. 在 Diff 左侧贴 `DIFF_LEFT_MARKER`、右侧贴 `DIFF_RIGHT_MARKER`。
2. 在 Unix 时间戳框输入 `EPOCH_MARKER`。
3. 切到 UTC 时钟、下班倒计时页（这些有自己的设置持久化，是例外）。
4. 退出重启。
5. **判据**：Diff 两侧、Unix 输入框都回到空。**不**期望这些内容被恢复。

### B3 原子写
1. 触发一次写盘，同时 `kill -9` app 在写盘中途。
2. 检查草稿文件：要么是旧版本完整 JSON，要么是新版本完整 JSON，**不能是半截 JSON**。
3. **判据**：UI 用 `Data.write(to:options:.atomic)` 或 tmp+rename。

### B4 大小上限
草稿 > 2 MB 时不写盘（与格式化输入上限一致），UI 不崩。

---

## 3. 我已准备的独立测试入口

- `Tests/Acceptance/PersistenceRunner.swift.tmpl` — 等 UI 暴露 `CodeDraftStore` 后填充。
- 现有样本 `Tests/Acceptance/Samples/error/*.ext` 直接用于 P4。
- P1/P2/P3/P4 的判据由 runner 自动对比 SHA-256。

## 4. 当前状态（独立观察）

- Sources 里**尚未出现**任何 `Application Support` / atomic write / `0600` 草稿代码。grep 到的 `draft` 都是 UTC 偏移与下班时间的临时输入 state。
- 旧正式 DevKit 仍在运行，我没碰。
- 等 UI agent 实现后，我重跑本规范全部 P1–P7 + B1–B4。
