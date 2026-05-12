# Feature Specification: admin-web-cleanup（admin-web 端對齊 admin-api 既有 endpoints）

**Feature Branch**: `005-admin-web-cleanup`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "feature 5 admin-web-cleanup"

## Scope（依 constitution §III）

| 項目 | 說明 |
|---|---|
| 主題 | admin-web 服務層完成對 admin-api 既有 endpoints 的最後對齊 — 移除呼叫不存在端點的 caller、修正 path 不一致、刪除生產不用的 dev-only stub。 |
| 涵蓋 GAP | **GAP-2**（`fetchCustomBackendError` 函式 → admin-api 沒 `/auth/error`）+ **GAP-3**（`/route/isRouteExist` → admin-api 沒此 endpoint，改本地 routeStore 查）+ **GAP-4**（`/route/getUserRoutes` → admin-api path 為 `/auth/getUserRoutes`） |
| 倉/層 | **admin-web**（=`fork260509-soybean-admin-base@new-admin-base-web`，本機透過 worktree 在 `admin-web/` 操作） |
| 分組理由 | 三個 GAP 都屬「admin-web 端清理 / 對齊」同主題、且全部位於 admin-web 倉內，符合 §III 例外條款（同主題同倉合併）。spec.md 開頭顯式列 GAP id；inner commits 各自帶對應 GAP scope（拆 3 個 inner commits 保留 traceability）。 |
| 不涵蓋 | admin-api 任何檔（feature 6/8 範圍）；admin-web auth/index.ts login error path dedupe（review backlog 2-M4，留作獨立 follow-up 或下個 feature；本 feature 不擴 scope 進此 ad-hoc cleanup）；admin-web Dockerfile / build args（feature 7）；admin-web env 變數調整（feature 2 已對齊、feature 7 進一步重構）；新功能 / UI 變更 |
| 規模 | ~25 行 TS diff（GAP-2 刪 ~7 行 + GAP-3 改寫 ~15 行 + GAP-4 改 1 行；含 import 整理） |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - admin-web 取得 user routes 後正常進 dashboard（Priority: P1）

當 admin-web user login 成功後，admin-web 會呼叫 `fetchGetUserRoutes()` 拿該 user 的 menu/route tree、注入 vue-router、跳轉到首頁。當前 admin-web 打 `/route/getUserRoutes` 但 admin-api 實際 endpoint 在 `/auth/getUserRoutes` — path 不一致導致 404，user routes 拿不到，dashboard 進不去。

**Why this priority**：沒這個修補 = user login 成功但卡在「載 routes」階段，UI 顯示空白/錯誤，整個 admin tool 不可用。是 admin-web 端對齊 admin-api 的最後一塊。

**Independent Test**:

1. 前置：features 1-4 已 merged、feature 6 envsubst 完成（admin-rust-api docker 容器能啟動）OR 本機 cargo run 起 admin-rust-api；admin-web `pnpm dev` 起在 vite dev server
2. 用 `Soybean / 123456` login
3. 開 DevTools Network 觀察 login 後第 2 個 API 呼叫
4. **預期**：path 是 `/auth/getUserRoutes`（不是 `/route/getUserRoutes`），response code 200，body 含 `data.routes` array、`data.home` string
5. UI 進到首頁、左側 menu 含 user 角色對應的 routes

**Acceptance Scenarios**:

1. **Given** admin-rust-api healthy + Soybean login 成功，**When** admin-web 自動呼叫 fetchGetUserRoutes，**Then** request URL 是 `/auth/getUserRoutes`（**不是** `/route/getUserRoutes`），response 200 + `data.routes`/`data.home` 非空。
2. **Given** user routes 載入成功，**When** vue-router 注入 routes 並跳首頁，**Then** UI 顯示左側 menu 含對應角色 routes（Soybean = ROLE_SUPER = 全部 menu）。
3. **Given** admin-web service/api/route.ts 內僅 `fetchGetConstantRoutes` 與 `fetchGetUserRoutes` 兩個 exports（**fetchIsRouteExist 應已被 GAP-3 刪除**），**When** lint / type-check 跑，**Then** PASS 0 error。

---

### User Story 2 - admin-web 不再呼叫不存在的 admin-api endpoints（Priority: P2）

當前 admin-web 程式中有兩個 callers 打到 admin-api 不存在的 endpoints：
- `fetchCustomBackendError` 打 `/auth/error`（dev-only 偽錯誤觸發器，admin-api 沒此 endpoint，生產不用）
- `fetchIsRouteExist` 打 `/route/isRouteExist`（admin-api 沒此 endpoint；admin-web 在 dynamic auth route mode 下 — `authRouteMode='dynamic'` — 會嘗試呼叫，造成 404）

本 feature 透過：
- **GAP-2**：直接刪 `fetchCustomBackendError`（grep 確認 0 callers）+ 對應 import / type 清理
- **GAP-3**：把 `getIsAuthRouteExist` 的 dynamic-mode 路徑改為「從 routeStore 本地 cached user routes 查」，刪 `fetchIsRouteExist` API caller

**Why this priority**：沒這修補 = admin-web 在 dynamic-route-mode + not-found 路徑 trigger 404；fetchCustomBackendError 殘留是 dead code、增加維護負擔。屬整合品質 hardening、不影響核心 login flow。

**Independent Test**:

1. 前置同 US1
2. 跑 admin-web 本機 lint / type-check：`pnpm typecheck` 與 `pnpm lint`
3. grep 確認 `fetchCustomBackendError` 與 `fetchIsRouteExist` 在 admin-web `src/` 內 0 hits
4. dynamic-route-mode runtime 測試：在 admin-web `.env` 設 `VITE_AUTH_ROUTE_MODE=dynamic` 後 reload；測試 navigate 到不存在路徑（如 `/non-existent`） — DevTools Network **不該**看到 `/route/isRouteExist` request；UI 應顯示 not-found 頁面（routeStore 本地查得 false）。

**Acceptance Scenarios**:

1. **Given** admin-web `src/` 跑完整 grep，**When** 找 `fetchCustomBackendError`，**Then** 0 命中（GAP-2 PASS）。
2. **Given** admin-web `src/` 跑完整 grep，**When** 找 `fetchIsRouteExist` 或 `/route/isRouteExist` literal，**Then** 0 命中（GAP-3 PASS）。
3. **Given** `getIsAuthRouteExist(routePath)` 被呼叫（router/guard/route.ts:139），**When** authRouteMode 是 `dynamic` 與 user routes 已 fetch，**Then** 函式從本地 cached routes 查、回 boolean，**不發任何 HTTP request**。
4. **Given** authRouteMode 是 `static`（既有路徑），**When** 同呼叫，**Then** 行為**不變**（既有 `isRouteExistByRouteName` + `createStaticRoutes()` 路徑保留）。
5. **Given** admin-web TypeScript build，**When** 跑 `pnpm typecheck` + `pnpm build`，**Then** 0 error（刪除函式後沒 dangling import / type 殘留）。

### Edge Cases

- **`authRouteMode=dynamic` 且 user routes 尚未 fetch 完成**：本 feature 假定 `getIsAuthRouteExist` 被呼叫時 user routes 已在 routeStore（router guard order：fetchUserRoutes → set route → getIsAuthRouteExist 對 navigate target 查；既有 admin-web flow 保證此順序）。若實作發現順序有 race，回 `false`（保守 — not-found 路徑安全處理）。
- **routeStore.allRoutes 為空（首次 navigate）**：依本地 cache，回 `false`（=「route 不存在於 user 權限」），fall back 到 not-found 頁面 — 比之前打 404 endpoint 更穩定。
- **fetchCustomBackendError 雖目前 0 callers，但有可能在 admin-web 文件 / 註解 中被引用**：grep `src/` + `docs/` 確認；若有文件引用，移除 reference（不在 feature 5 主 scope，但若 implement 順手發現可補）。
- **GAP-4 path rename 後與 admin-api `/auth/getUserRoutes` 對齊**：admin-api 早在 feature 1 之前就有此 endpoint（`init_protected_router` 內），feature 5 不需動 admin-api。
- **`fetchGetConstantRoutes` 仍打 `/route/getConstantRoutes`**：admin-api 是否有此 endpoint 待驗證（§IV）— 若 admin-api 真有 `/route/getConstantRoutes` 則保持；若沒有則本 feature 順帶加 GAP-4b 修補 path（保守先列為待驗證、不擴 scope）。
- **build 階段 dead code elimination**：刪除 `fetchCustomBackendError` 後 webpack/vite tree-shaking 自動處理；無需手動清 chunk。

## Requirements *(mandatory)*

### Functional Requirements

#### admin-web `src/service/api/auth.ts`（GAP-2）

- **FR-501 (GAP-2)**: MUST 刪除 `export function fetchCustomBackendError(code: string, msg: string) { ... }` 函式（連同其 JSDoc 註解區塊）。整個函式宣告（含 JSDoc + 函式體 + 上方空行）= 約 8-9 行刪除。
- **FR-502 (GAP-2 hygiene)**: 函式刪除後 MUST 跑 grep 確認 admin-web `src/` 內 0 處引用 `fetchCustomBackendError`；若有殘留 import 或 type reference 同步清理。

#### admin-web `src/service/api/route.ts`（GAP-3 + GAP-4）

- **FR-510 (GAP-3 API removal)**: MUST 刪除 `export function fetchIsRouteExist(routeName: string) { ... }` 函式（line 13-20，含 JSDoc 註解區塊 + 函式體）。
- **FR-511 (GAP-4)**: MUST 把 `fetchGetUserRoutes()` 內 `url: '/route/getUserRoutes'` 改為 `url: '/auth/getUserRoutes'`，對齊 admin-api `init_protected_router()` 內既有 `/auth/getUserRoutes` 註冊。

#### admin-web `src/store/modules/route/index.ts`（GAP-3 routeStore 邏輯）

- **FR-520 (GAP-3 dynamic mode)**: `getIsAuthRouteExist(routePath)` 函式 MUST 把 dynamic-mode 路徑（line 306-308：`const { data } = await fetchIsRouteExist(routeName); return data;`）改為「從本地 routeStore cached user routes 查 routeName 是否存在 + 是否屬該 user 已 fetch 的權限 routes」。具體：
  - 用既有 `isRouteExistByRouteName(routeName, <local-cached-user-routes>)` helper 查
  - `<local-cached-user-routes>` 為 routeStore 內已存的 user routes ref（如 `allRoutes` 或對應 ref；implementer 在 plan 階段 read code 對應）
  - 函式 signature 不變、return type 仍 `Promise<boolean>`（保持與既有 caller 介面相容）
- **FR-521 (GAP-3 import cleanup)**: 刪除 `fetchIsRouteExist` 從 service/api/route 的 import（既有 import 在 routeStore 文件頂端某行）；保留 `isRouteExistByRouteName` import（既有，static 路徑仍用）。

#### 範圍邊界（負面 requirement）

- **FR-530**: 本 feature MUST NOT 動 admin-api 任何檔（GAP-2/3/4 全部走 admin-web 端解 — INTEGRATION-PLAN §4 各 GAP 推薦方案 A 都是 admin-web 改）。
- **FR-531**: 本 feature MUST NOT 改 admin-web `auth/index.ts` 內 login error path dedupe（review backlog 2-M4，獨立 follow-up）。
- **FR-532**: 本 feature MUST NOT 改 admin-web `.env*` 系列（feature 2 已對齊、feature 7 重構）。
- **FR-533**: 本 feature MUST NOT 改 admin-web Dockerfile / build config（feature 7）。
- **FR-534**: 本 feature MUST NOT 新增 admin-web 功能 / UI / 元件。
- **FR-535**: 本 feature MUST NOT 動 admin-web 既有 `authRouteMode='static'` 路徑（GAP-3 只改 dynamic 分支；static 行為保留 — 既有 user 用 static mode 體驗無變化）。

### Key Entities

- **`admin-web/src/service/api/auth.ts`**：admin-web auth service 層。本 feature 刪除 `fetchCustomBackendError`（GAP-2）。是 admin-web 倉內既有檔。
- **`admin-web/src/service/api/route.ts`**：admin-web route service 層。本 feature 刪 `fetchIsRouteExist`（GAP-3 API removal）+ 改 `fetchGetUserRoutes` path（GAP-4）。
- **`admin-web/src/store/modules/route/index.ts`**：admin-web route store（Pinia）。本 feature 改 `getIsAuthRouteExist` 的 dynamic-mode 分支（GAP-3 routeStore 邏輯）。
- **`admin-web/src/store/modules/route/shared.ts`**：含 `isRouteExistByRouteName` helper（既有），dynamic-mode 將重用此 helper 對 local cached user routes 查 — 無需修改 helper 自身。
- **`admin-web/src/router/guard/route.ts:139`**：`getIsAuthRouteExist` 唯一 caller。本 feature 不動此檔（函式 signature 不變、caller 介面相容）。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-501**: admin-web `pnpm typecheck` PASS（無 type error）+ `pnpm lint` PASS（無 lint error）+ `pnpm build` PASS（production build 成功）。
- **SC-502**: grep `fetchCustomBackendError` 在 admin-web `src/` 內 0 hits（GAP-2 cleanup 完成）。
- **SC-503**: grep `fetchIsRouteExist` 與 `/route/isRouteExist` literal 在 admin-web `src/` 內 0 hits（GAP-3 cleanup 完成）。
- **SC-504**: grep `'/route/getUserRoutes'` 在 admin-web `src/` 內 0 hits（GAP-4 path rename 完成）；grep `'/auth/getUserRoutes'` ≥ 1 hits（新 path 註冊）。
- **SC-505**: dynamic-mode runtime 測試：navigate 到不存在路徑 + DevTools Network 觀察 — 0 個 `/route/isRouteExist` request 發出（依賴 features 1-4 + 6 完成；feature 6 前用靜態驗證代替）。
- **SC-506**: admin-web login 成功後 fetchGetUserRoutes 命中 `/auth/getUserRoutes`（**不是** `/route/getUserRoutes`），response code 200 + 載入 dashboard（依賴 features 1-4 + 6 完成；feature 6 前靜態驗證代替）。
- **SC-507**: 本 feature 的 diff 行數 ≤ **30 行**（含 import 整理）— 對齊 CHECKLIST 估算「~25 行」+ 一點 buffer。

## Assumptions

### 設計假設（自我決策、無需 clarify）

- 採 INTEGRATION-PLAN §4 各 GAP 推薦方案 A（admin-web 端解、不改 admin-api）— 成本低、risk 集中於 admin-web、不違反 §III 跨倉禁制。
- GAP-3 `getIsAuthRouteExist` dynamic-mode 路徑用「本地 cached user routes」查 — 假定 user routes 在 caller 呼叫前已 `fetchGetUserRoutes` 載入（既有 admin-web router guard order 保證此前提）。
- GAP-2 `fetchCustomBackendError` 刪除是「真 0 caller」— 已 grep src/ 確認；不會 break 任何既有功能。
- GAP-4 改 admin-web path（不改 admin-api alias） — admin-api 既有 `/auth/getUserRoutes` 端點不動。
- `fetchGetConstantRoutes` 仍打 `/route/getConstantRoutes`，**本 feature 不動** — 屬獨立 endpoint，admin-api 是否有對應註冊待驗證（§IV）；若有 path 不一致為 GAP-4b 獨立 follow-up，不擴本 feature scope。

### 對其他 feature 的依賴（明列以利 plan 階段排序）

- **依賴 feature 2（已 merged）**：admin-web wire-level codes 已對齊（200/401/空/空 + login body identifier）。本 feature 假定 admin-web 攔截器既有行為正確。
- **依賴 feature 3（已 merged）**：admin-api response camelCase 已對齊。本 feature 不依賴 admin-api response struct。
- **依賴 feature 4（已 merged）**：admin-api refresh handler 已實作；本 feature 不直接依賴，但完整 dynamic acceptance 需 refresh flow 走得通。
- **依賴 feature 6（dockerfile-envsubst，未開）**：admin-rust-api docker 容器要能成功啟動才能跑端到端 acceptance（curl + browser dev）。本 feature 自身可跑**靜態 verification**（grep + typecheck + lint + build PASS）— 動態 docker 驗證等 feature 6 merge 後補（與 feature 2/3/4 同 follow-up 模式）。
- **不依賴 feature 7**：admin-web Dockerfile 變動屬 feature 7、本 feature 純 source code cleanup。
- **不依賴 feature 8**：TZ-skew schema 修補屬 admin-api 範圍。

### 待驗證的上游慣例（依 constitution §IV）

- [ ] **admin-api 是否真有 `/auth/getUserRoutes`** endpoint（GAP-4 修補對齊的目標）— 看 `admin-api/server/router/src/admin/sys_authentication_route.rs::init_protected_router()` 確認；implementation 階段順帶 read。
- [ ] **admin-api 是否有 `/route/getConstantRoutes`** endpoint（admin-web `fetchGetConstantRoutes` 打的 path）— 看 `admin-api/server/router/src/admin/sys_menu_route.rs` 或對應 router；若 admin-api 是 `/route/getConstantRoutes` 則無需處理；若不同需 GAP-4b 補（**out of feature 5 scope**，但驗到後 evaluate 是否擴 scope 或開 follow-up）。
- [ ] **admin-web routeStore 內 user routes 的 cached ref 名稱**（FR-520 用 `<local-cached-user-routes>` 占位）— 看 `admin-web/src/store/modules/route/index.ts` 內 user routes state ref（可能名為 `allRoutes` / `routes` / `userRoutes` — implementer plan 階段對應）。
- [ ] **admin-web `getIsAuthRouteExist` 唯一 caller `router/guard/route.ts:139` 的 call site invariant**（router guard order 保證 user routes 已 fetched） — implementer plan 階段 read code 確認。

### 不在範圍

- admin-api 任何檔變更（feature 6 envsubst、feature 8 TZ-skew 各自處理）。
- admin-web `auth/index.ts` login error path dedupe（review backlog 2-M4；屬獨立 cleanup，**可由 user 透過 /speckit-clarify 或 new feature 啟動**）。
- admin-web Dockerfile / build args 接合（feature 7）。
- admin-web `.env*` 系列重構（feature 7）。
- admin-web 既有 `authRouteMode='static'` 邏輯（GAP-3 只動 dynamic 分支）。
- admin-web 新功能 / UI / 元件變更。
- `fetchGetConstantRoutes` path 對齊（待 §IV 驗證 admin-api 端 — 若不一致為 GAP-4b 獨立 follow-up）。
- E2E 自動化測試（屬 admin-web 倉自身 CI 範圍）。
- 跨瀏覽器 / 響應式 / a11y 測試。
