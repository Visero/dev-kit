# DevKit 独立验收记录规范

> 本文件是**独立验收方**的工作手册。引擎/UI 侧的自检结果**不能**当作独立验收结论。
> 任何结论都要在本文件或 `Reports/` 下的机器报告里留下可复现证据。

## 0. 边界与红线

- 本目录 (`Tests/Acceptance/`) 与独立验收方自己的 artifacts 目录之外**只读**。
- 不修改：`Sources/`、`test.sh`、`build.sh`、`README.md`、`Resources/`（含未来的 `Resources/Formatters/`）。
- 不操作正在运行的旧正式 DevKit：不退出、不注入输入、不改它的偏好。
- 不跑用户代码、不联网、不读除样本以外的用户文件。
- 不把生成器/引擎自检的输出当作独立结论；每条结论都要附复现命令或截图。

## 1. 验收单元

固定 14 个语言单元（C 与 C++ **分开**）：

`json` `js` `ts` `html` `css` `python` `go` `swift` `java` `c` `cpp` `sql` `shell` `rust`

每个语言单元至少跑三类样本（见 `Samples/`）：

1. **positive** — 规范正样本，应被正确识别 + 格式化。
2. **dangerous** — 语义危险样本（JS ASI/正则、Python 缩进/三引号、C 宏/字符串拼接、C++ 模板/原始串、Shell heredoc、SQL 方言/引号、JSON 大整数/重复键、Swift 嵌套注释/原始串、Rust 生命周期/原始串 等）。
3. **error** — 语法损坏样本，**输出必须等于输入字节**（失败保留原文）。
4. **ambiguous** — 识别压力样本（看起来像别的语言，例如 `{x:1}` 是 JS 不是 JSON）。

## 2. 每条样本必须记录的字段

runner 已自动产出，字段对应 `Reports/report.json` 中的一项：

| 字段 | 含义 | 通过判据 |
|---|---|---|
| `sample` | 相对 `Samples/` 的路径 | 存在且可读 |
| `category` | positive / dangerous / error / ambiguous | 与 manifest 一致 |
| `expectedLanguage` | manifest 声明的语言 id | — |
| `inputSHA256` | 输入字节 SHA-256 | 复现时必须一致 |
| `detectedLanguage` | 独立识别结果 | == expectedLanguage（ambiguous 另看 `mustNotDetectAs`） |
| `detectionConfidence` | 验收侧打分（非引擎自报） | 见 §3 |
| `detectionRule` | 命中的识别规则名 | 能解释为什么 |
| `engine` | 实际跑的格式化引擎名/版本 | 与 `Resources/Formatters/` 清单一致 |
| `formatterStatus` | `ok` / `not-integrated` / `error` / `retained-original` / `changed-error-input` | error 类样本必须是 `retained-original` 或 `error` |
| `outputSHA256` | 输出字节 SHA-256 | 与复跑一致 |
| `idempotent` | 二次格式化输出是否等于一次 | true |
| `tokenPreservation` | manifest 声明的关键 token 是否原样出现在输出里 | 全 true |
| `retainedOriginalBytes` | 错误类样本输出是否等于输入 | true |
| `notes` | 复现线索 / 失败原因 | 非空时必须给出复现命令 |

## 3. 置信度打分（独立验收侧）

- `0.95`：shebang 或 JSON 括号+引号等高置信规则直接命中。
- `0.85`：JSON 明确形态。
- `0.60`：常规关键字/包声明启发式命中。
- `0.45`：粗桶命中（如 JS/TS 不分、Java/C/C++ 不分）——即使识别"对"也要在 notes 里写明桶粒度。
- `0.00`：兜底到 plain / 未识别。

**粗桶命中即视为覆盖缺口**，即使结果恰好等于 expectedLanguage。

## 4. 必查的全局不变量

这些不是单条样本，是对整个 build 的检查（由 `audit.sh` + 手动 GUI 复核）：

1. **离线自包含**：grep 不到 `URLSession` / `URL(string:http…)` / 网络库。
2. **不执行用户代码**：grep 不到 `Process()` / `launchPath` / `popen` / `system(`。
3. **无第三方依赖**：`import` 只能是 `Foundation` / `SwiftUI` / `AppKit` / `CryptoKit` / `Combine` 等系统库。
4. **ad-hoc 签名 + 严格校验**：`codesign --verify --strict --deep build/DevKit.app` 通过。
5. **解压后 codesign 校验**：把 `DevKit-*.zip` 解压到**新目录**（不是覆盖运行中的 app），再跑一次 codesign 校验。
6. **窗口尺寸 1440×960 默认值**：回归不得改 `WindowSizing.width/height`。
7. **Diff / 时钟倒计时 / Assets.car 不回归**：现有 `CoreTests` 必须全绿。
8. **ToolPage JSON ID 保留**：侧栏工具排序/ID 不变。
9. **单框原位输出 + 撤销**：GUI 手动验证——格式化一次后 Cmd+Z 能完整还原到输入字节。
10. **失败保留**：把 error 类样本贴进输入框，点格式化后输出应**等于**输入；UI 报错误但不改写文本。

## 5. 端到端 GUI 验收步骤（收到集成完成信号后执行）

> 此时由独立验收方统一操作 GUI；引擎/UI 侧不操作 GUI 避免冲突。

1. `bash Tests/Acceptance/audit.sh` —— 静态检查落盘。
2. `bash Tests/Acceptance/run.sh` —— Stub 模式先跑一次，确认 runner 自身可用。
3. 等 `Sources/CodeFormatting.swift` + `Resources/Formatters/` 清单就位后：
   - 把 `Hooks/RealBackend.swift.tmpl` 复制为 `Hooks/RealBackend.swift` 并填好 TODO。
   - `DEVKIT_REAL_BACKEND=1 bash Tests/Acceptance/run.sh`。
4. 解压最新 zip 到一个**新临时目录**（不能动正在跑的旧 app）：
   `unzip -q DevKit-<版本>-macOS-arm64.zip -d /tmp/devkit-accept-XXXX`
   对解压出的 `DevKit.app` 跑 `codesign --verify --strict --deep`。
5. 用 `open /tmp/devkit-accept-XXXX/DevKit.app` 启动新包；**不**退出旧 app。
6. 逐语言把 14 个 positive + dangerous 样本粘进输入框，截图保存到 `Reports/screenshots/`。
7. 验证 Cmd+Z 撤销、错误样本保留、窗口默认 1440×960。
8. 把 `Reports/report.json` + `report.txt` + 截图 + 本文件的勾选项归档到独立验收 artifacts。

## 6. 签字位

| 阶段 | 结论 | 日期 | 复现入口 |
|---|---|---|---|
| 准备阶段（本文件 + 语料 + runner） | 已完成 | 2026-11-03 | `Tests/Acceptance/run.sh`（stub 模式） |
| CodeFormatting 集成后端到端 | 待集成完成信号 | — | — |
| GUI 14 语言实机 | 待集成完成信号 | — | — |
| 最终签字 | — | — | — |
