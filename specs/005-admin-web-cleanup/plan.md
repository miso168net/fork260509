# Implementation Plan: admin-web-cleanup

**Branch**: `005-admin-web-cleanup` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/005-admin-web-cleanup/spec.md`

## Summary

admin-web 端清理 3 個 GAP，全部落在 admin-web 倉內：

1. **GAP-2**：刪 `admin-web/src/service/api/auth.ts` 的 `fetchCustomBackendError` 函式（grep 確認 0 callers）— ~7 行刪除
2. **GAP-3**：`admin-web/src/store/modules/route/index.ts::getIsAuthRouteExist` 的 dynamic-mode 路徑（line 306-308）由「呼叫 `fetchIsRouteExist`」改為「本地查 `authRoutes.value`（既有 shallowRef）」+ 刪 `admin-web/src/service/api/route.ts` 的 `fetchIsRouteExist` 函式 + 整理 imports — ~15 行
3. **GAP-4**：`admin-web/src/service/api/route.ts::fetchGetUserRoutes()` 的 `url: '/route/getUserRoutes'` 改 `'/auth/getUserRoutes'` — 1 行

走 constitution §V **兩段式 submodule commit**（admin-web fork inner + outer SHA pin bump）。動態驗證依 feature 6 docker stack（follow-up，與 features 2/3/4 同模式）。

## Technical Context

**Language/Version**: TypeScript 6 / Vue 3.5+（admin-web 既有，無變更）

**Primary Dependencies**（全部既有、不新增）:
- `vue 3.5+` / `vue-router 4` / `pinia` — Vue stack
- `axios`（透過 `@/service/request` wrapper） — HTTP client
- `@elegant-router/vue` + `@elegant-router/types` — route definitions
- `pnpm 10.5+` — package manager

**Storage**: admin-web `pinia` routeStore (in-memory client state)；不動 localStorage / sessionStorage

**Testing**:
- 靜態：`pnpm typecheck`、`pnpm lint`、`pnpm build` — admin-web 三大 verify
- grep：確認 `fetchCustomBackendError` / `fetchIsRouteExist` / `/route/isRouteExist` / `/route/getUserRoutes` 在 admin-web `src/` 內 0 hits（FR-502/503/504）
- 動態（依 feature 6 merge）：admin-web `pnpm dev` + 開瀏覽器 login → fetchGetUserRoutes 命中 `/auth/getUserRoutes` + DevTools Network 查 0 個 `/route/isRouteExist` request

**Target Platform**: 瀏覽器（admin-web vite build → 靜態 assets via nginx）

**Project Type**: TypeScript frontend service-layer cleanup — admin-web 倉內：
- 3 個檔修改：
  - `src/service/api/auth.ts`（GAP-2 刪 fetchCustomBackendError）
  - `src/service/api/route.ts`（GAP-3 刪 fetchIsRouteExist + GAP-4 path rename）
  - `src/store/modules/route/index.ts`（GAP-3 dynamic-mode 改本地查）
- 0 個檔新增

**Performance Goals**:
- diff ≤ 30 行（SC-507 cap，含 import 整理）
- `pnpm typecheck` PASS（SC-501）、`pnpm lint` PASS、`pnpm build` PASS
- 0 個 `/route/isRouteExist` HTTP request（SC-505）— dynamic-mode 全本地查
- 0 個 `/route/getUserRoutes` request（SC-504）— 改為 `/auth/getUserRoutes`

**Constraints**:
- 單一倉（admin-web），跨 §V 兩段式 commit
- 不動 admin-api 任何檔（FR-530）— 全部 admin-web 端解
- 不引新 dependency
- 不動 admin-web `authRouteMode='static'` 路徑（FR-535）— 既有 user 體驗無變化
- 不擴 scope 進 2-M4 login error dedupe（FR-531）

**Scale/Scope**: ~25 行 TS diff（GAP-2 -7 + GAP-3 ~15 + GAP-4 +1/-1 + import 整理）；SC-507 cap 30 行。

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 原則 | 通過 / 違反 / 不適用 | 證據 |
|---|---|---|
| **§I 同源反代優先** | N/A | 不動部署層；admin-web 透過既有 vite proxy 或 nginx 反代到 admin-api（feature 1 已 setup） |
| **§II 外部化設定** | N/A | 不動 config / env 變數 |
| **§III 最小 GAP 修補** | ✅ 通過 | spec.md Scope 顯式列 GAP-2/3/4 + 分組理由（同主題同倉，例外條款）；FR-530 ~ FR-535 六個 negative requirement 劃定範圍邊界；SC-507 鎖 ≤ 30 行；inner commits 將拆 3 個 GAP commits 保留 traceability（與 feature 3 模式同） |
| **§IV 上游驗證** | ✅ 通過 | spec Assumptions 列 4 項 §IV 待驗證項，本 plan Phase 0 R1-R4 已全部 read code 解析完成（R1 admin-api `/auth/getUserRoutes` 確認、R2 `/route/getConstantRoutes` 確認、R3 `authRoutes` cache ref 確認、R4 caller invariant 確認） |
| **§V 兩段式 submodule commit (NON-NEGOTIABLE)** | ✅ 通過（將遵守） | 本 feature 動 admin-web/ submodule，**必走兩段 commit**：第一段 admin-web/ worktree 內 + push fork branch `new-admin-base-web`；第二段 outer `chore(submodule): bump admin-web 到 <SHA>` + push outer。重用 feature 2 模式（admin-web 第二次走此流程） |
| **§VI Spec-Driven Development** | ✅ 通過 | spec → clarify（0 questions，all categories Clear）→ 本 plan → tasks → analyze → implement 流程已具現化 |
| **§VII Conventional Commits 中文** | ✅ 通過（流程內遵循） | inner: `fix(admin-web): GAP-2/3/4 ...` 各 commit；outer: `chore(submodule): bump admin-web 到 <SHA>: feature 5 admin-web cleanup` |

**附加技術棧鎖定**：admin-web 既有 Vue 3.5+ / Vite 8 / TypeScript 6 / pnpm 10.5+ — 全對齊 constitution §技術棧。本 feature 不改任何依賴版本。

**結論**：Constitution Check **PASS**，無違反、無 Complexity Tracking 需 justify。

## Project Structure

### Documentation (this feature)

```text
specs/005-admin-web-cleanup/
├── plan.md                          # 本檔
├── research.md                      # Phase 0：R1-R4 §IV 待驗證項 read code 解析 + §V 兩段式 commit 流程（admin-web 版）
├── data-model.md                    # Phase 1：3 個檔的精確 line / change + 1 個 shared helper 重用
├── quickstart.md                    # Phase 1：implementer 兩段式 + operator dynamic smoke
├── contracts/
│   └── admin-web-api-cleanup.md     # admin-web service/api 對齊 admin-api endpoints 的契約
├── checklists/
│   └── requirements.md              # 既有，全綠
└── tasks.md                         # /speckit-tasks 產出（Phase 2，本 plan 不負責）
```

### Source Code（admin-web 倉內，feature 將動）

本 feature 改動全部在 **admin-web/** worktree 內（= `fork260509-soybean-admin-base@new-admin-base-web` branch；本機透過 worktree 在 `admin-web/` 操作；外層 `new-admin-root` 透過 submodule SHA pin 追蹤）：

```text
admin-web/                                                    ← worktree（branch: new-admin-base-web）
├── src/service/api/auth.ts                                  ★ GAP-2 刪 fetchCustomBackendError 函式（line 46-48 + 註解 line 41-45）
├── src/service/api/route.ts                                 ★ GAP-3 刪 fetchIsRouteExist 函式（line 13-20） + GAP-4 改 fetchGetUserRoutes path（line 10）
└── src/store/modules/route/index.ts                         ★ GAP-3 dynamic-mode 路徑改本地查 authRoutes.value（line 306-308） + 刪 fetchIsRouteExist import（line 7）
```

**外層 `new-admin-root`** 只追蹤 admin-web submodule 的 SHA pin（gitlink）+ 本 spec/plan/tasks 文件。

**Structure Decision**: 採 constitution §V 兩段式 submodule commit 模式（與 feature 2 同流程，admin-web 第二次走）：

1. **第一段**（admin-web/ worktree 內）：建議拆 3 個 inner commits（**按 user story priority 順序**：US1 P1 GAP-4 先；US2 P2 GAP-2/GAP-3 後）：
   - inner commit 1（US1 P1）：`fix(admin-web): GAP-4 fetchGetUserRoutes path /route/getUserRoutes → /auth/getUserRoutes`（route.ts 1-line path rename — MVP）
   - inner commit 2（US2 P2）：`fix(admin-web): GAP-2 刪除 dev-only fetchCustomBackendError`（auth.ts 刪除）
   - inner commit 3（US2 P2）：`fix(admin-web): GAP-3 getIsAuthRouteExist dynamic-mode 改本地查 authRoutes`（route.ts 刪 fetchIsRouteExist + store/route/index.ts dynamic-mode 改寫 + import 整理）
   - `git push origin new-admin-base-web` 推到 fork remote

2. **第二段**（outer `new-admin-root` 倉）：
   - 1 個 outer commit：`chore(submodule): bump admin-web 到 <短SHA>: feature 5 admin-web cleanup (GAP-2/3/4)`
   - push outer

理由：

1. **§V NON-NEGOTIABLE**：違反 = outer SHA pin 與 fork HEAD 不同步
2. **3 個 inner commits**（GAP-2 / GAP-3 / GAP-4 各一）保留 GAP traceability
3. **outer 單一 commit cover 三 inner pin shifts**：跟 feature 2/3 同模式

## Phase 0: Outline & Research

**Status**: ✅ 完成（research.md 已產出）。

**Scope 摘要**（詳見 research.md）：spec 的「待驗證的上游慣例」4 項 + §V 兩段式 commit 流程具現化：

| # | 項 | 結論 |
|---|---|---|
| R1 | admin-api 是否真有 `/auth/getUserRoutes` | ✅ `init_protected_router()` line 25 註冊；GAP-4 對齊有效 |
| R2 | admin-api 是否有 `/route/getConstantRoutes` | ✅ `sys_menu_route.rs:15` 註冊；**無 GAP-4b 需求** |
| R3 | admin-web routeStore user routes cached ref | ✅ `authRoutes: shallowRef<ElegantConstRoute[]>`（line 67）；由 `addAuthRoutes()` 在 `fetchGetUserRoutes` callback populate |
| R4 | `router/guard/route.ts:139` caller invariant | ✅ 正常 flow 下 `authRoutes.value` 已 populated；edge case 回 false（保守 fallback acceptable） |
| R5 | §V 兩段式 commit 流程（admin-web 版） | reuse feature 2 模式、target submodule admin-web、branch `new-admin-base-web` |

**Output**: `research.md`（4 個 verification + 1 個 commit 流程）— 已完成。

## Phase 1: Design & Contracts

**Prerequisites**: research.md 完成 ✅。

### 1.1 Data Model

`data-model.md` 列：

- **3 個 file entity** + 各檔內動的精確 line / change：
  - `auth.ts`: line 41-48 整塊（JSDoc + 函式）刪除
  - `route.ts`: line 13-20 刪 fetchIsRouteExist；line 10 path rename
  - `store/route/index.ts`: line 7 import 整理；line 306-308 dynamic-mode 改本地查 `authRoutes.value`
- **1 個 shared helper**：`isRouteExistByRouteName(routeName, routes)` 來自 `store/modules/route/shared.ts:173`（既有，dynamic-mode 重用）
- **1 個 ref state**：`authRoutes: ShallowRef<ElegantConstRoute[]>`（既有，dynamic-mode 從此查）

無 application data model 改動（不動 entity / API contract / TS interface — 都是既有結構）。

### 1.2 Contracts

#### `contracts/admin-web-api-cleanup.md`

admin-web service/api 對齊 admin-api endpoints 的契約：

- **`POST /auth/login`** （已對齊，feature 2）— 不動
- **`GET /auth/getUserInfo`** （已對齊）— 不動
- **`POST /auth/refreshToken`** （feature 4 已加 admin-api 端）— 不動
- **`GET /auth/getUserRoutes`** （GAP-4 修補 target）— admin-web 改 path
- **`GET /route/getConstantRoutes`** （已對齊 R2 verified）— 不動
- ~~`GET /route/isRouteExist`~~（GAP-3 修補 — admin-web 不再呼叫，本地查 authRoutes）
- ~~`GET /auth/error`~~（GAP-2 修補 — admin-web 不再呼叫，函式刪除）

含 admin-web 端消費路徑 + 修補前後對照表。

### 1.3 Quickstart

`quickstart.md` 給 implementer + operator 用：

- **implementer**：
  1. admin-web/ worktree 健檢（`git status` + branch = `new-admin-base-web`）
  2. 改 3 個檔的精確 diff hint（auth.ts / route.ts / store/route/index.ts）
  3. `pnpm typecheck` + `pnpm lint` + `pnpm build` 驗證
  4. 三段 inner commits（按 GAP-2 / GAP-3 / GAP-4 拆）
  5. `git push origin new-admin-base-web`
  6. 回外層 `git add admin-web && git commit && git push`

- **operator**（依 feature 6 docker stack merge）：
  1. login 拿 token
  2. 觀察 fetchGetUserRoutes 命中 `/auth/getUserRoutes`
  3. dynamic-mode runtime 測試：navigate not-found 路徑 → DevTools 查 0 個 `/route/isRouteExist` request

### 1.4 Agent Context Update

更新 outer 倉 `CLAUDE.md` 內 `<!-- SPECKIT START -->` / `<!-- SPECKIT END -->` 區塊，把 active 從 feature 4（已 merged 為里程碑）切到 feature 5。

**Output**: `data-model.md`、`contracts/admin-web-api-cleanup.md`、`quickstart.md`、`CLAUDE.md` SPECKIT 區塊更新。

## Phase 2 (out of scope for /speckit-plan)

`/speckit-tasks` 預期粒度（與 feature 2 / 3 同模式，~9 個 task）：

- T001 (setup): admin-web/ worktree health check
- T002 [US1] (inner GAP-4): route.ts fetchGetUserRoutes path rename + `pnpm typecheck` + inner commit — MVP
- T003 [US2] (inner GAP-2): auth.ts 刪 fetchCustomBackendError + `pnpm typecheck` + inner commit
- T004 [US2] (inner GAP-3): route.ts 刪 fetchIsRouteExist + store/route/index.ts dynamic-mode 改寫 + import 整理 + `pnpm typecheck` + inner commit
- T005 (build verify): `pnpm typecheck` + `pnpm lint` + `pnpm build` 整套 PASS
- T006 (inner push): cd admin-web && git push origin new-admin-base-web
- T007 (outer SHA pin commit): outer git add admin-web && commit
- T008 (static acceptance evidence): 4 條 grep + pnpm verify evidence + commit
- T009 (push outer): user 同意後
- T010 (CHECKLIST sync): 標 feature 5 完成
- T011 (follow-up，依 feature 6): dynamic acceptance smoke

## Constitution Check — Post-Design Re-evaluation

Phase 0 + Phase 1 產出落地後回掃 7 條原則：

| 原則 | 狀態 | Phase 0/1 補強證據 |
|---|---|---|
| §I 同源反代 | N/A | 不變 |
| §II 外部化設定 | N/A | 不變 |
| §III 最小 GAP | ✅ | scope 維持 ≤ 30 行；contracts 把 admin-web ↔ admin-api endpoint 契約 normative |
| §IV 上游驗證 | ✅ | research.md R1-R4 把 4 項待驗證項全部 read code 解析（含 R2 「無 GAP-4b」結論） |
| §V 兩段式 submodule | ✅ | research.md R5 admin-web 版兩段式藍本（reuse feature 2 結構） |
| §VI Spec-Driven Development | ✅ | 流程完整、clarify 0 questions Pass |
| §VII Conventional Commits 中文 | ✅ | 3 inner / 1 outer commit message 範本鎖定 |

**結論**：Post-design Constitution Check **PASS**，與 pre-design 一致。

## Complexity Tracking

> **Constitution Check 全部通過、無違反，本表留空。**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (無) | — | — |
