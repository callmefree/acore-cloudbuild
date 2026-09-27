# Gauntlet 简体中文 Implementation Plan

> **For agentic workers:** Inline execution in the current task. Steps use checkbox syntax for tracking.

**Goal:** 在现有云编译流程中交付完整的 Gauntlet 简体中文玩家文本。

**Architecture:** 云编译仓库保存对上游模块的可重放补丁；工作流先克隆模块，再应用兼容与汉化补丁，构建服务端并打包产物。客户端中文词缀库与服务端协议保持同版。

**Tech Stack:** C++、Lua 5.1、Git patch、GitHub Actions Windows、PowerShell。

## Global Constraints

- 不修改 `mod-gauntlet` 协议版本 16、命令关键字、状态键或词缀 ID。
- 保留现有 `mod-gauntlet__no-bot-api-and-near-macro.patch`。
- 本次仅云编译，不部署 `D:\AzerothCore-Server`。

---

### Task 1: 建立文本清单与汉化实现

**Files:**
- Create: `ci/patches/mod-gauntlet__zhcn.patch`
- Modify: upstream module source in an isolated local clone while generating the patch

- [ ] 列出三选一、已携带词缀与普通玩家聊天路径的英文输出。
- [ ] 用现有中文词缀库校对名称、说明和动态数值；翻译常规玩家提示。
- [ ] 生成对上游原始提交可应用的补丁，并验证与兼容补丁同时应用。

### Task 2: 客户端与打包

**Files:**
- Modify: `.github/workflows/windows-build.yml` if an updated client addon must be shipped
- Create: `ci/client/GauntletUI/*` if an updated addon is required

- [ ] 核对客户端 `ADESC`、`ODESC` 与服务端中文的拼接及 UTF-8 处理。
- [ ] 在产物中包含需要更新的客户端文件，并确认版本匹配。

### Task 3: 验证与云编译

**Files:**
- Modify: `ci/modules.list` only if documentation must reflect the new localization patch

- [ ] 运行补丁应用检查和可用的模块测试。
- [ ] 提交构建仓库变更并触发 `windows-build`。
- [ ] 等待运行结束，核对结论、产物及发布位置。
