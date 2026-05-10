# Feature Specification: gap-0ab0f-frontend-env-and-login（admin-web env 對齊 + login body field）

**Feature Branch**: `002-gap-0ab0f-frontend-env-and-login`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "gap-0ab0f-frontend-env-and-login"

## Scope（依 constitution §III）

| 項目 | 說明 |
|---|---|
| 主題 | admin-web 對接 admin-rust-api 的初步 wire-level 對齊（HTTP code 識別 + login body field） |
| 涵蓋 GAP | **GAP-0a**（success code）+ **GAP-0b**（error code 類別）+ **GAP-0f**（login body field） |
| 倉/層 | **admin-web**（=`fork260509-soybean-admin@new-admin-base-web`，本機透過 worktree 在 `admin-web/` 操作） |
| 分組理由 | 三個 GAP 都屬「admin-web ↔ admin-rust-api wire-level 對齊」同主題、且全部位於 admin-web 倉內，符合 §III 例外條款（同主題同倉合併）。spec.md 開頭顯式列 GAP id，commits 各自帶對應 GAP scope。 |
| 不涵蓋 | admin-web/.env.dev / .env.prod / .env.test 重構與 Dockerfile build args 接合（屬 feature 7 admin-web-dockerfile）；GAP-0c/0d（admin-api response camelCase，feature 3）；GAP-1 refresh handler（feature 4）；GAP-2/3/4 admin-web cleanup（feature 5）；feature 6 envsubst 改造 |
| 規模 | ≤ 5 行（4 行 .env value 改 + 1 行 .ts data field rename） |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator 用 admin-web 對 admin-rust-api 完成 login (Priority: P1)

新 operator 在 dev 模式下（feature 1 deploy infra 已 ready）跑 `pnpm dev`、瀏覽 vite dev server，輸入 `Soybean / Soybean@123.` 點 login，**API 呼叫送出與接收都對齊 admin-rust-api**：送出的 body field 是 `identifier`、收到的 200 OK 被識別為成功、token + refreshToken 存進 admin-web store、跳轉到首頁（home / dashboard）路由。

**Why this priority**：login 是 admin tool 一切操作的入口。GAP-0a/0b/0f 任一未修就無法 login 進系統。本 feature 是 admin-web 對齊 admin-rust-api 的**最低門檻**。

**Independent Test**:
1. 前置：feature 1 `deploy-infra` 已 merge、dev compose stack（postgres + redis + migration + admin-rust-api）已 running、admin-rust-api `/health` 200（**注意：admin-rust-api 啟動依賴 feature 6 envsubst；本 feature 2 acceptance 在 feature 6 完成後跑**）
2. host 端 `cd admin-web && pnpm install && pnpm dev`
3. 瀏覽器 → vite dev server URL（預設 :9527）
4. 輸入 `Soybean / Soybean@123.` 點 login
5. **預期**：
   - DevTools Network 看到 POST `/proxy-default/auth/login`、request body 含 `{"identifier":"Soybean","password":"Soybean@123."}`（**不是** `userName`）
   - response 200、body 含 `code:200, data:{token,refreshToken}`（注意 refreshToken 駝峰 — 屬 feature 3 解，本 feature 不負責）
   - admin-web 識別 200 為成功（不會跳「成功被當失敗」的 toast）
   - 進入首頁、URL 變 `/home`（或 admin-web `VITE_ROUTE_HOME` 指定的 route）

**Acceptance Scenarios**:

1. **Given** dev stack running + Soybean 帳號存在，**When** 在 admin-web login 頁送出 `Soybean / Soybean@123.`，**Then** request body 是 `{"identifier":"Soybean","password":"Soybean@123."}`（GAP-0f 對齊）。
2. **Given** admin-rust-api 回 `{"code":200, "data":{...}}`，**When** admin-web service 層處理 response，**Then** 識別為成功（不觸發失敗分支、不跳錯誤 toast）— 對應 GAP-0a。
3. **Given** admin-rust-api 在某 endpoint 回 `{"code":401,"msg":"Unauthorized"}`，**When** admin-web 收到，**Then** 識別為「token 過期」並觸發 refresh flow（依賴 feature 4 完成 refresh handler 才能完整跑通；本 feature 只驗 code 識別、不驗 refresh 結果）— 對應 GAP-0b 部分。
4. **Given** admin-rust-api 從不回 7777/8888/9999/3333 等 fake codes，**When** 任何 API 流程，**Then** admin-web 不會被這些 fake codes 觸發 logout 或 modal logout（清空 LOGOUT_CODES / MODAL_LOGOUT_CODES）— 對應 GAP-0b 補強。
5. **Given** login 成功，**When** admin-web 跳轉首頁，**Then** URL 對應 admin-web `VITE_ROUTE_HOME` 設定的 route（即「首頁切換完成」）。**注意**：dashboard 的 getUserRoutes / isRouteExist 完整載入屬 feature 5 範圍，本 feature 不驗。

### Edge Cases

- **未啟動 admin-rust-api 即跑 admin-web pnpm dev**：vite proxy 會回 502 / 連線失敗 — admin-web 應在 login 嘗試時顯示「網路錯誤」 toast 而非靜默卡住。屬 admin-web 既有錯誤處理範圍，本 feature 不改。
- **送出錯誤密碼**：admin-rust-api 應回 401 + `Invalid credentials` 之類 message。admin-web 識別後（依 GAP-0b 修補後 401 對應 expired token，**但 401 在 login context 不該觸發 refresh 而是顯示密碼錯誤**）— 此邏輯衝突屬 feature 5 admin-web-cleanup 處理（admin-web `auth/index.ts` 對 login error 的特殊路徑）；本 feature 不負責 login 錯誤路徑。
- **admin-web 既有 `.env.test` 內容**：本 feature 不動 `.env.test`（屬 feature 7 重構範圍）。
- **`.env` 改動會影響所有 vite mode**：dev / prod 都會讀 `.env` 為 base，後續 mode-specific override 由 feature 7 處理。

## Requirements *(mandatory)*

### Functional Requirements

#### admin-web/.env（GAP-0a + 0b 修補，4 行 value 改）

- **FR-201 (GAP-0a)**: `admin-web/.env` 內 `VITE_SERVICE_SUCCESS_CODE` 值 MUST 由 `0000` 改為 `200`，對齊 admin-rust-api `Res::new_data` 設 `code = StatusCode::OK.as_u16() = 200` 的實際行為。
- **FR-202 (GAP-0b 子項)**: `admin-web/.env` 內 `VITE_SERVICE_LOGOUT_CODES` 值 MUST 改為**空字串**（`VITE_SERVICE_LOGOUT_CODES=`），admin-rust-api 不回任何業務 logout code、預設 8888,8889 是 fake，留著會誤觸發。
- **FR-203 (GAP-0b 子項)**: `admin-web/.env` 內 `VITE_SERVICE_MODAL_LOGOUT_CODES` 值 MUST 改為**空字串**，理由同 FR-202（7777,7778 是 fake）。
- **FR-204 (GAP-0b 子項)**: `admin-web/.env` 內 `VITE_SERVICE_EXPIRED_TOKEN_CODES` 值 MUST 改為 `401`，對齊 admin-rust-api 對 unauthorized 的 HTTP status response。9999/9998/3333 是 fake、需清掉。

#### admin-web/src/service/api/auth.ts（GAP-0f 修補，1 行 data field rename）

- **FR-210 (GAP-0f)**: `admin-web/src/service/api/auth.ts` 內 `fetchLogin` 函式 MUST 把送出的 request body field 從 `userName` 改為 `identifier`，對齊 admin-rust-api `LoginInput.identifier`。具體：data 物件由 `{ userName, password }` 改為 `{ identifier: userName, password }`（保留入參名 `userName`、只改送出 field 名）。

#### 範圍邊界（負面 requirement）

- **FR-220**: 本 feature MUST NOT 動 `admin-web/.env.dev` / `.env.prod` / `.env.test`（屬 feature 7 範圍）。
- **FR-221**: 本 feature MUST NOT 動 admin-rust-api 任何檔（不修 GAP-0c/0d/1，不違反 §III 跨倉禁制）。
- **FR-222**: 本 feature MUST NOT 修 admin-web `auth/index.ts` 的 login 錯誤路徑邏輯 / refresh flow / route 載入邏輯（屬 features 4/5）。

### Key Entities

- **`admin-web/.env`**：admin-web base 環境變數樣板。本 feature 改 4 行 value（不新增 / 刪除變數）。是 admin-web 倉內既有檔。
- **`admin-web/src/service/api/auth.ts`**：admin-web 服務層 login API client。本 feature 改 1 行（data field rename）。是 admin-web 倉內既有檔。
- **送出 login body**（contract，被 admin-rust-api 消費）：MUST 含 `identifier` 與 `password` 兩 field、值為 string。
- **接收 login response**（contract，admin-web 消費）：admin-rust-api 回 `{ code: 200, data: { token: string, refreshToken: string }, msg: string }`（refreshToken 駝峰由 feature 3 修補，本 feature 假定它會被 fix）。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-201**: 新 operator 從拿到 dev stack 到完成「在 vite dev server 用 Soybean@123. login 看到首頁路由」流程 ≤ 5 分鐘（前提：feature 6 envsubst 已 merge、admin-rust-api 容器能 healthy）。
- **SC-202**: admin-web service 層處理 admin-rust-api 200 response 的成功識別率 = **100%**（無「成功被誤判失敗」案例）— 透過 DevTools Network + console 觀察驗證。
- **SC-203**: admin-web 不會被 admin-rust-api 任何真實 response 觸發 logout 或 modal logout（因 fake codes 已清空）— 觀察一日的 dev 操作 / 完整 7 條 smoke test 後，logout 觸發次數 = 0（除非 user 主動點 logout）。
- **SC-204**: 每個 GAP 修補的 diff 行數對齊「最小 GAP」承諾：FR-201/202/203/204 各 1 行、FR-210 1 行、總計 ≤ 5 行（不含註解微調）。

## Assumptions

### 設計假設（自我決策、無需 clarify）

- 採 INTEGRATION-PLAN §4 GAP-0a/0b/0f 的**推薦方案 A**（admin-web 端對齊、不改 admin-rust-api side）：成本低、risk 集中於 admin-web、不違反 §III 跨倉禁制。
- `.env` 改 4 個 value（不增不減 key）— 保持 admin-web 既有 env 結構。
- GAP-0f 採「保留入參名 `userName`、改送出 field `identifier`」（不對外改 fetchLogin signature，避免影響其他 caller）。
- 不動 `.env.dev` / `.env.prod` / `.env.test`（feature 7 重構時一起處理 — 在 build args 對接時統籌）。

### 對其他 feature 的依賴（明列以利 plan 階段排序）

- **依賴 feature 1 (deploy-infra)**：dev compose stack 是 acceptance 的前提（postgres / redis / admin-rust-api）。
- **依賴 feature 6 (dockerfile-envsubst)**：admin-rust-api 容器要能成功啟動才能跑 login flow（feature 6 把 application.yaml hardcode 改 envsubst）。本 feature 2 在 feature 6 完成前，**只能驗靜態 diff**（read code、grep `.env`、看 auth.ts diff）；**動態 login flow** acceptance 留 feature 6 完成後。
- **依賴 feature 3 (gap-0cd-rust-output-camel)**：admin-rust-api response 的 `refresh_token` 必須改為 `refreshToken` admin-web 才能正確 store。本 feature 2 假定 feature 3 會 merge（雖然順序在後）；如 feature 3 未 merge，admin-web `loginToken.refreshToken` 會是 `undefined`、但 token 本身仍能拿到 → login 算通、只是 refresh flow（屬 feature 4）會壞。

### 依賴順序（建議實施）

依 INTEGRATION-CHECKLIST 建議順序，feature 2 排在 feature 1 後 feature 3 前。本 feature 完成 = 給 feature 3 的 acceptance 提供 「admin-web 已對齊 wire-level、剩 admin-rust-api 端對齊」的測試前提。

### 待驗證的上游慣例（依 constitution §IV）

- [ ] 預設管理員密碼是 `Soybean@123.`（CLAUDE.md §5 待驗證項；本 feature US1 acceptance 是 verifying point — 完成本 feature + features 1+6 後跑第一次 login 即可勘驗，**驗完回填 CLAUDE.md §5**）。
- [ ] admin-rust-api `Res<T>` 對 200 response 確實送 `code: 200`（GAP-0a 的根據；spec 假設此處正確、需 implement 階段以 curl 驗證）。
- [ ] admin-rust-api 對 unauthorized 確實回 401（GAP-0b 的根據；本 feature 設 EXPIRED_TOKEN_CODES=401 假定此處正確；implement 階段順帶 curl 驗）。
- [ ] admin-rust-api `LoginInput` 結構為 `{identifier, password}`（GAP-0f 的根據；INTEGRATION-PLAN §4 已從 source 確認）。

### 不在範圍

- admin-web `.env.dev` / `.env.prod` / `.env.test` 重構（feature 7）。
- admin-web build-time env 變數（VITE_BASE_URL / VITE_SERVICE_BASE_URL / VITE_APP_TITLE 等 — 屬 feature 7 build args 接合時處理）。
- admin-web 既有錯誤處理 / refresh flow / route 載入邏輯（features 4/5）。
- admin-rust-api 任何修補（features 3/4 + 6）。
- 跨瀏覽器 / 響應式 / a11y 測試（admin-web 既有功能、不在本對齊範圍）。
- E2E 自動化測試（屬 admin-web 倉自身的 CI 範圍，本 feature 只到 manual smoke）。
