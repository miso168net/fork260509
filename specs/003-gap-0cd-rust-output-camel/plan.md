# Implementation Plan: gap-0cd-rust-output-camel

**Branch**: `003-gap-0cd-rust-output-camel` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-gap-0cd-rust-output-camel/spec.md`

## Summary

修補 admin-api response struct serialize 對齊 admin-web 端期望（GAP-0c + 0d）：在 `admin-api/server/model/src/admin/output/sys_authentication.rs` 給 `AuthOutput` 加 `#[serde(rename_all = "camelCase")]` derive attribute（讓 `refresh_token` → `refreshToken`）+ 給 `UserInfoOutput` 加 `pub buttons: Vec<String>` field；在 `admin-api/server/api/src/admin/sys_authentication_api.rs` 的 `get_user_info` handler 內初始化 `buttons: vec![]`。總 ≤ 5 行 Rust diff、單一倉（admin-api）、走 constitution §V 兩段式 submodule commit（與 feature 2 同模式）。

技術路線：直接 edit + `cargo build` + `cargo check` 靜態驗證；動態 wire-level 驗證等 feature 6 (dockerfile-envsubst) merge 後跑 curl smoke。

## Technical Context

**Language/Version**: Rust 1.86+（admin-api 既有）
**Primary Dependencies**: serde / serde_derive（admin-api 既有依賴）、axum 0.8、Sea-ORM 1.1 — 都不引新 crate
**Storage**: 不適用（純 struct attribute + handler init）
**Testing**:
- 靜態：`cargo build --release -p model` + `cargo build --release -p api`、`cargo check`、grep `#[serde(rename_all = "camelCase")]` + grep `pub buttons: Vec<String>` + grep `buttons: vec![]`
- 動態（依 feature 6 merge）：curl `/api/auth/login` jq `.data | keys` 看到 `refreshToken`；curl `/api/auth/getUserInfo` jq `.data.buttons | type` = `array`
**Target Platform**: Linux x86_64（admin-api docker image runtime）
**Project Type**: Rust backend struct + handler patch（admin-api 倉內 2 檔修改）
**Performance Goals**:
- diff ≤ 5 行（SC-304 hard cap）
- cargo build PASS、無 new warnings（SC-301）
- jq 命中 100%（SC-302/303）
**Constraints**:
- 單一倉（admin-api），跨 §V 兩段式 commit
- 不動 admin-rust-api 啟動相關（envsubst / Dockerfile，屬 feature 6）
- 不動 admin-web 任何檔（屬 features 2/5，feature 2 已 merged）
- 假定 admin-web 是唯一 consumer（FR-321）
**Scale/Scope**: ≤ 5 行 Rust diff、2 個檔（model/sys_authentication.rs + api/sys_authentication_api.rs）

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 原則 | 通過 / 違反 / 不適用 | 證據 |
|---|---|---|
| **§I 同源反代優先** | N/A | 不動部署層；nginx 反代由 feature 1（已 merged）負責 |
| **§II 外部化設定** | N/A | 不動 config（envsubst 屬 feature 6） |
| **§III 最小 GAP 修補** | ✅ 通過 | spec.md Scope 顯式列 GAP-0c/0d + 分組理由（同主題同倉，例外條款）；FR-320 ~ FR-323 四個 negative requirement 劃定範圍邊界；SC-304 鎖 ≤ 5 行；commits 將拆 GAP-0c / GAP-0d 兩個 inner commits 保留 traceability |
| **§IV 上游驗證** | ✅ 通過 | spec Assumptions 列 4 項 §IV 待驗證項（Res::new_data 包 data field、cargo build PASS、wire shape、admin-web 端對齊）；Phase 0 research 將具現化 verify 指令 |
| **§V 兩段式 submodule commit (NON-NEGOTIABLE)** | ✅ 通過（將遵守） | 本 feature 動 admin-api/ submodule，**必走兩段 commit**：第一段 admin-api/ worktree 內 + push fork branch；第二段 outer `chore(submodule): bump admin-api 到 <SHA>` + push outer。**這是第一次動 admin-api submodule**（feature 2 動的是 admin-web）— 兩段式藍本 reuse feature 2 research.md R5 但目標 submodule 改為 admin-api。 |
| **§VI Spec-Driven Development** | ✅ 通過 | spec → clarify（0 finding gracefully exit）→ 本 plan → tasks → analyze → implement |
| **§VII Conventional Commits 中文** | ✅ 通過（流程內遵循） | inner: `fix(admin-api): GAP-0c/0d ...`；outer: `chore(submodule): bump admin-api ...` |

**附加技術棧鎖定**：admin-api 既有 Rust 1.86 / axum 0.8 / Sea-ORM 1.1 — 全對齊 constitution §技術棧。本 feature 不改任何依賴版本。

**結論**：Constitution Check **PASS**，無違反、無 Complexity Tracking 需 justify。

## Project Structure

### Documentation (this feature)

```text
specs/003-gap-0cd-rust-output-camel/
├── plan.md              # 本檔
├── research.md          # Phase 0：3 個 §IV verify 指令具現化 + admin-api 兩段式 commit 流程
├── data-model.md        # Phase 1：2 file entity + 2 wire contract（簡）
├── quickstart.md        # Phase 1：implementer 兩段式 + operator dynamic smoke（依 feature 6）
├── contracts/
│   ├── auth-output.md         # AuthOutput response 序列化契約（駝峰）
│   └── user-info-output.md    # UserInfoOutput response 結構契約（含 buttons）
├── checklists/
│   └── requirements.md  # 既有，全綠
└── tasks.md             # /speckit-tasks 產出
```

### Source Code（admin-api 倉內，feature 將動）

本 feature 改動全部在 **admin-api/** worktree 內（= `fork260509-soybean-admin-rust@new-admin-rust-api` branch；本機透過 worktree 在 `admin-api/` 操作；外層 `new-admin-root` 透過 submodule SHA pin 追蹤）：

```text
admin-api/                                                              ← worktree（branch: new-admin-rust-api）
├── server/model/src/admin/output/sys_authentication.rs                ★ AuthOutput 加 derive + UserInfoOutput 加 buttons field（GAP-0c + 0d struct）
└── server/api/src/admin/sys_authentication_api.rs                     ★ get_user_info handler 加 buttons: vec![]（GAP-0d handler）
```

**外層 `new-admin-root`** 只追蹤 admin-api submodule 的 SHA pin（gitlink）。

**Structure Decision**: 採 constitution §V 兩段式 submodule commit 模式（與 feature 2 同流程，目標 submodule 改為 admin-api）：

1. **第一段**（admin-api/ worktree 內）：
   - inner commit 1：`fix(admin-api): GAP-0c AuthOutput camelCase`（model/sys_authentication.rs 加 1 行 derive）
   - inner commit 2：`fix(admin-api): GAP-0d UserInfoOutput buttons placeholder`（model 加 1 行 field + api 加 1 行 init = 2 處改動但同 GAP，合 1 commit）
   - `git push origin new-admin-rust-api` 推到 fork remote

2. **第二段**（outer `new-admin-root` 倉）：
   - 1 個 outer commit：`chore(submodule): bump admin-api 到 <短SHA>: feature 3 GAP-0cd`
   - push outer

理由：

1. **§V NON-NEGOTIABLE**：違反 = outer SHA pin 與 fork HEAD 不同步
2. **2 個 inner commits**（GAP-0c + GAP-0d 各一）保留 GAP traceability；GAP-0d 涉及 2 處（model + api）但同 GAP，合 1 commit 合理
3. **outer 單一 commit cover 兩 inner pin shifts**：跟 feature 2 同模式

## Phase 0: Outline & Research

**Status**: 將執行（在本 plan commit 後產出 `research.md`）。

**Scope**：

由於 spec 已通過 `/speckit-clarify`（0 finding），剩餘 unknown 為「§IV 上游驗證指令具現化」+「§V 兩段式 commit 流程具現化（admin-api 倉視角）」+「`Res::new_data` 包 data field 確認」：

1. **`Res::new_data` 行為驗證**：read `admin-api/server/model/src/admin/types/mod.rs` 或對應 Res impl，確認 `Res::new_data(data)` 把 data 包進 `data` field（spec assumption #1）
2. **GAP-0c 動態驗證**（依 feature 6）：curl /api/auth/login → jq `.data | keys` 應含 `refreshToken`、不含 `refresh_token`
3. **GAP-0d 動態驗證**（依 feature 6）：curl /api/auth/getUserInfo → jq `.data | keys` 應含 `buttons`、`buttons` 為 array type
4. **cargo build 驗證**：`cd admin-api && cargo build --release` PASS（無 compile error / new warning）
5. **§V 兩段式 commit 流程具現化（admin-api 版）**：與 feature 2 R5 同結構，但目標 submodule 改為 admin-api、branch 名為 `new-admin-rust-api`、fork remote 為 `fork260509-soybean-admin-rust`。

**Output**: `research.md`（5 個 verification + 1 個 commit 流程）

## Phase 1: Design & Contracts

**Prerequisites**: research.md 完成。

### 1.1 Data Model（極簡）

`data-model.md` 列：
- 2 個 file entity（`model/sys_authentication.rs`、`api/sys_authentication_api.rs`）+ 各檔內動的精確 line / change
- 2 個 wire contract（AuthOutput response、UserInfoOutput response）
- 「為何 UserInfoOutput 不換成 struct-level rename_all」rationale 補充

無 application data model 改動（不動 DB schema、不動 sys_user / sys_token 等表）。

### 1.2 Contracts

#### `contracts/auth-output.md`

POST `/api/auth/login` response 的 `data` 物件序列化契約：
- `token` (string)
- `refreshToken` (string，**駝峰**，由本 feature 透過 `#[serde(rename_all = "camelCase")]` 達成；修補前 admin-rust-api 送 `refresh_token`）

完整 wire-level shape + admin-web 消費路徑。

#### `contracts/user-info-output.md`

GET `/api/auth/getUserInfo` response 的 `data` 物件序列化契約：
- `userId` (string，既有 per-field rename)
- `userName` (string，既有 per-field rename)
- `roles` (string array)
- `buttons` (string array，**本 feature 加**，目前永空 placeholder)

含「未來 button 級權限實作會替換填值邏輯、但 field 與 schema 不變」的變更政策。

### 1.3 Quickstart

`quickstart.md` 給 implementer + operator 用：

- **implementer**：在 admin-api/ worktree 內改 ≤ 5 行 + cargo build 驗 + 兩段式 commit 流程（reuse feature 2 模式）
- **operator**（依 feature 6 merge）：dev 模式 curl smoke 觀察 wire-level shape

不含 admin-api 一般 dev 流程（cargo run / sea-orm migrate / Casbin 設定）— 屬 admin-api 倉自身 README 範圍。

### 1.4 Agent Context Update

更新 outer 倉 `CLAUDE.md` 內 `<!-- SPECKIT START -->` / `<!-- SPECKIT END -->` 區塊，把 active 從 feature 2（已 merged 為里程碑）切到 feature 3。

**Output**: `data-model.md`、`contracts/{auth-output,user-info-output}.md`、`quickstart.md`、`CLAUDE.md` SPECKIT 區塊更新。

## Phase 2 (out of scope for /speckit-plan)

`/speckit-tasks` 預期粒度（與 feature 2 同模式，~6 個 task）：

- T001 (setup): admin-api/ worktree health check
- T002 (inner): admin-api/server/model/.../sys_authentication.rs 改 2 處（AuthOutput derive + UserInfoOutput buttons field）+ inner commits（拆 GAP-0c / GAP-0d 兩個 commits 或合一個依紀律）
- T003 (inner): admin-api/server/api/.../sys_authentication_api.rs 改 1 行（buttons init）+ inner commit
- T004 (cargo build): cargo build PASS 驗證
- T005 (inner push): cd admin-api && git push origin new-admin-rust-api
- T006 (outer): outer git add admin-api && chore(submodule): bump admin-api ...
- T007 (static accept): grep + git submodule status evidence + commit
- T008 (push outer): user 同意後
- T009 (CHECKLIST sync): 標 feature 3 完成
- T010 (follow-up): 依 feature 6 merge — 動態 wire smoke + buttons array 確認

## Constitution Check — Post-Design Re-evaluation

Phase 0 + Phase 1 產出落地後回掃 7 條原則：

| 原則 | 狀態 | Phase 0/1 補強證據 |
|---|---|---|
| §I 同源反代 | N/A | 不變 |
| §II 外部化設定 | N/A | 不變 |
| §III 最小 GAP | ✅ | scope 維持 ≤ 5 行；contracts 把 wire shape normative |
| §IV 上游驗證 | ✅ | research.md R1-R4 把 verify 指令具現化（cargo build + jq） |
| §V 兩段式 submodule | ✅ | research.md R5 admin-api 版兩段式藍本（reuse feature 2 結構） |
| §VI Spec-Driven Development | ✅ | 流程完整 |
| §VII Conventional Commits 中文 | ✅ | inner / outer commit 範本鎖定 |

**結論**：Post-design Constitution Check **PASS**，與 pre-design 一致。

## Complexity Tracking

> **Constitution Check 全部通過、無違反，本表留空。**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (無) | — | — |
