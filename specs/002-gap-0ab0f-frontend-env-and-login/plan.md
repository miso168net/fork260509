# Implementation Plan: gap-0ab0f-frontend-env-and-login

**Branch**: `002-gap-0ab0f-frontend-env-and-login` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-gap-0ab0f-frontend-env-and-login/spec.md`

## Summary

修補 admin-web 端對接 admin-rust-api 的 wire-level 不對齊（GAP-0a / 0b / 0f）：admin-web `.env` 內 4 行 value 改齊（success_code 0000→200、清空 fake logout codes、expired_token_codes 對齊 401）+ admin-web `src/service/api/auth.ts` 內 1 行 data field rename（`userName` → `identifier`）。總 ≤ 5 行 diff、單一倉（admin-web）、走 constitution §V 兩段式 submodule commit。

技術路線：直接 edit + manual smoke verify。靜態 verification（grep / read diff）可在本 feature 自身完成；動態 login flow acceptance 等 feature 6 (dockerfile-envsubst) merge 後跑。

## Technical Context

**Language/Version**: 不適用（純 env value 改 + .ts 1 行 data rename）。前端框架是 admin-web 既有 stack（Vue 3.5+ / TypeScript 6 / Vite 8 / pnpm 10.5+）— 由 admin-web 倉自身維護，本 feature 不動。
**Primary Dependencies**: admin-web 既有依賴；本 feature 不引入新 npm package
**Storage**: N/A
**Testing**:
- 靜態：`grep` / `git diff` 比對 `.env` 與 `auth.ts`
- 動態（依賴 feature 6 merge）：dev compose stack + admin-web `pnpm dev` + 瀏覽器 manual smoke login
**Target Platform**: 主流瀏覽器（admin-web 既有 vite config 決定）
**Project Type**: web frontend config patch（admin-web 倉內 .env value 對齊 + 1 處 data field rename）
**Performance Goals**: SC-201 onboarding ≤ 5 分鐘 / SC-202 200 識別率 100% / SC-203 0 fake-code 誤觸 / SC-204 diff ≤ 5 行
**Constraints**: 單一倉（admin-web）+ §V 兩段式 commit；不動 .env.dev / .env.prod / .env.test（feature 7）；不動 admin-rust-api（features 3/4/6）；不動 admin-web auth/index.ts 邏輯（features 4/5）
**Scale/Scope**: ≤ 5 行 diff、2 個檔（`admin-web/.env` + `admin-web/src/service/api/auth.ts`）

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 原則 | 通過 / 違反 / 不適用 | 證據 |
|---|---|---|
| **§I 同源反代優先** | N/A | 不動部署層；admin-web request 走 vite proxy（dev）/ nginx（prod，feature 1）到 admin-rust-api `:10001` |
| **§II 外部化設定** | ✅ 通過 | 本 feature 改的就是 env-driven config，完全符合「設定外部化」精神；不在 source code hardcode codes |
| **§III 最小 GAP 修補** | ✅ 通過 | spec.md Scope 顯式列 GAP-0a/0b/0f + 分組理由（同主題同倉，例外條款）；FR-220/221/222 三個 negative requirement 劃定範圍邊界；SC-204 鎖 ≤ 5 行 |
| **§IV 上游驗證** | ✅ 通過 | spec Assumptions 列 4 項 §IV 待驗證；本 feature 是「Soybean@123. 預設密碼」首次驗證機會；Phase 0 research 將具現化 verify 指令 |
| **§V 兩段式 submodule commit (NON-NEGOTIABLE)** | ✅ 通過（將遵守） | 本 feature 動 admin-web/ submodule，**必走兩段 commit**：第一段 admin-web/ worktree 內 + push fork branch；第二段 outer `chore(submodule): bump admin-web 到 <SHA>` + push outer。tasks.md 將精確展開兩段。 |
| **§VI Spec-Driven Development** | ✅ 通過 | spec → clarify（0 finding）→ 本 plan → tasks → implement |
| **§VII Conventional Commits 中文** | ✅ 通過（流程內遵循） | inner: `fix(admin-web): GAP-0a/0b/0f ...`；outer: `chore(submodule): bump admin-web ...` |

**附加技術棧鎖定**：本 feature 不改技術棧（admin-web 既有 Vue 3.5 / Vite 8 / TypeScript 6 / pnpm 10.5）— 全對齊 constitution §技術棧。

**結論**：Constitution Check **PASS**，無違反、無 Complexity Tracking 需 justify。

## Project Structure

### Documentation (this feature)

```text
specs/002-gap-0ab0f-frontend-env-and-login/
├── plan.md              # 本檔
├── research.md          # Phase 0：5 個 §IV verify 指令具現化 + 兩段式 commit 流程
├── data-model.md        # Phase 1：file entity + wire contract（簡）
├── quickstart.md        # Phase 1：implementer 兩段式 + operator dev acceptance
├── contracts/
│   ├── env-codes.md     # admin-web .env 內 4 codes 變數 contract
│   └── login-body.md    # POST /auth/login wire-level 雙向 contract
├── checklists/
│   └── requirements.md  # 既有，全綠
└── tasks.md             # /speckit-tasks 產出
```

### Source Code（admin-web 倉內，feature 將動）

本 feature 改動全部在 **admin-web/** worktree 內（= `fork260509-soybean-admin@new-admin-base-web` branch；本機透過 worktree 在 `admin-web/` 操作；外層 `new-admin-root` 透過 submodule SHA pin 追蹤）：

```text
admin-web/                                   ← worktree（branch: new-admin-base-web）
├── .env                                     ★ 動 4 行 value（GAP-0a + 0b）
└── src/service/api/auth.ts                  ★ 動 1 行 data field rename（GAP-0f）
```

**外層 `new-admin-root`** 只追蹤 admin-web submodule 的 SHA pin（gitlink），檔案 diff 不在外層 git 內可見。

**Structure Decision**: 採 constitution §V 兩段式 submodule commit 模式：

1. **第一段**（admin-web/ worktree 內）：3 個 inner commits（GAP-0a / GAP-0b / GAP-0f 各一）→ `git push origin new-admin-base-web` 推到 fork remote
2. **第二段**（outer `new-admin-root` 倉）：1 個 `chore(submodule): bump admin-web 到 <短 SHA>: feature 2 GAP-0ab0f` outer commit → push outer

理由：

1. **§V NON-NEGOTIABLE**：違反 = outer SHA pin 與 fork HEAD 不同步、別人 clone 拿到舊版檔案
2. **單一 outer commit + 多個 inner commit 比一一對應好**：3 GAP 同主題、合一個 outer pin commit 更乾淨；inner 仍 1 GAP 1 commit 保留 diff traceability
3. **outer 不做檔案 diff**（git submodule 模型本來就只記 SHA pin）

## Phase 0: Outline & Research

**Status**: 將執行（在本 plan commit 後產出 `research.md`）。

**Scope**：

由於 spec 已通過 `/speckit-clarify`（0 finding），剩餘 unknown 為「§IV 上游驗證指令具現化」+「§V 兩段式 commit 流程具現化」：

1. **GAP-0a 上游慣例驗證**：admin-rust-api 對 200 response 確實送 `{"code": 200, ...}` — curl `/api/auth/login` 看實際 response body
2. **GAP-0b 上游慣例驗證**：admin-rust-api 對 unauthorized 確實回 401 — curl 無 token 訪問需授權 endpoint
3. **GAP-0f 上游慣例驗證**：admin-rust-api `LoginInput.identifier` field — INTEGRATION-PLAN §4 已確認、本 feature 補 curl 驗證
4. **預設密碼驗證**：login `Soybean / Soybean@123.` 真能拿到 token（CLAUDE.md §5 待驗證項）
5. **§V 兩段式 commit 流程具現化**：本 feature 第一個動 submodule，research 給 tasks 用的精確指令序列：
   - inner: `cd admin-web && git status` 確認在 `new-admin-base-web` branch / `git add ... && git commit -m "..."` / `git push origin new-admin-base-web`
   - outer: `cd .. && git status` 確認 `modified: admin-web (new commits)` / `git add admin-web && git commit -m "chore(submodule): bump admin-web 到 <短 SHA>: ..."` / `git push origin <feature-branch>`

**Output**: `research.md`（5 個 verification + 1 個 commit 流程）

## Phase 1: Design & Contracts

**Prerequisites**: research.md 完成。

### 1.1 Data Model（極簡）

`data-model.md` 列：
- 2 個 file entity（`admin-web/.env`、`admin-web/src/service/api/auth.ts`）+ 各檔內動的精確 line / value
- 2 個 wire contract（admin-web → admin-rust-api request body / admin-rust-api → admin-web response code）

無 application data model（本 feature 不動 schema）。

### 1.2 Contracts

#### `contracts/env-codes.md`

4 個 admin-web `.env` 內變數的 contract，每個含 admin-web service 層消費邏輯 + admin-rust-api 對應行為：

| Var | 值 | admin-web 消費 | admin-rust-api 行為 |
|---|---|---|---|
| `VITE_SERVICE_SUCCESS_CODE` | `200` | service 層判 response code === 200 為成功 | `Res::new_data` 永遠 code = 200 |
| `VITE_SERVICE_LOGOUT_CODES` | （空） | 空 → 不會觸發 logout | 不送業務 logout codes |
| `VITE_SERVICE_MODAL_LOGOUT_CODES` | （空） | 空 → 不會觸發 modal logout | 不送業務 modal codes |
| `VITE_SERVICE_EXPIRED_TOKEN_CODES` | `401` | code === 401 觸發 refresh flow | unauthorized → HTTP 401 |

#### `contracts/login-body.md`

POST `/api/auth/login` 雙向 wire contract：

- **request**: `{"identifier": string, "password": string}`
- **response (200 OK)**: `{"code": 200, "data": {"token": string, "refreshToken": string}, "msg": string}`
- **response (401 Unauthorized)**: `{"code": 401, "msg": string}`

注意：response `refreshToken` 駝峰由 feature 3 (gap-0cd-rust-output-camel) 修補；本 contract 描述「修完後的應然狀態」，本 feature 2 完成但 feature 3 未完成時該 field 仍是 `refresh_token`（snake）— Assumptions 已說明。

### 1.3 Quickstart

`quickstart.md` 給 implementer + operator 用：

- **implementer**：在 admin-web/ worktree 內改 5 行的精確指令序列 + 兩段式 commit 流程具現化
- **operator**：dev 模式 manual smoke login 流程（依賴 features 1+6）

不含 admin-web 一般 dev 流程（pnpm install / lint / build）— 屬 admin-web 倉自身 README 範圍。

### 1.4 Agent Context Update

更新 outer 倉 `CLAUDE.md` 內 `<!-- SPECKIT START -->` / `<!-- SPECKIT END -->` 區塊，把 active 從 feature 1 切到 feature 2。

**Output**: `data-model.md`、`contracts/{env-codes,login-body}.md`、`quickstart.md`、`CLAUDE.md` SPECKIT 區塊更新。

## Phase 2 (out of scope for /speckit-plan)

`/speckit-tasks` 預期粒度（精簡版，~6 個 task）：

- T001 (inner): admin-web/ worktree 內改 `.env` 4 行（GAP-0a + 0b）+ inner commit
- T002 (inner): admin-web/ worktree 內改 `src/service/api/auth.ts` 1 行（GAP-0f）+ inner commit
- T003 (inner push): `git push origin new-admin-base-web` 推 fork branch
- T004 (outer): outer `git add admin-web && git commit chore(submodule): bump admin-web ...` + push outer
- T005 (static acceptance): grep / diff 驗證 evidence
- T006 (dynamic acceptance, follow-up): 依賴 feature 6 merge — login smoke + 預設密碼驗證 + 回填 spec §IV 勾選

T001 與 T002 邏輯獨立可分 commit，但都必走 §V 兩段式（一個 outer commit cover 所有 inner pin shift）。

## Constitution Check — Post-Design Re-evaluation

Phase 0 + Phase 1 產出落地後回掃 7 條原則：

| 原則 | 狀態 | Phase 0/1 補強證據 |
|---|---|---|
| §I 同源反代 | N/A | 不變 |
| §II 外部化設定 | ✅ 通過 | contracts/env-codes.md 把 4 codes normative |
| §III 最小 GAP | ✅ 通過 | scope 維持 5 行 diff；3 GAP 同主題同倉合併符合例外 |
| §IV 上游驗證 | ✅ 通過 | research.md R1-R4 把 verify 指令具現化（含預設密碼） |
| §V 兩段式 submodule | ✅ 通過 | research.md R5 把兩段式 commit 流程具現化、tasks 將精確展開 |
| §VI Spec-Driven Development | ✅ 通過 | 流程完整 |
| §VII Conventional Commits 中文 | ✅ 通過 | inner / outer commit 範本鎖定 |

**結論**：Post-design Constitution Check **PASS**，與 pre-design 一致。

## Complexity Tracking

> **Constitution Check 全部通過、無違反，本表留空。**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (無) | — | — |
