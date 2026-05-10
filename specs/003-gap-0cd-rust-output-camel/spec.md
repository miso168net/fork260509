# Feature Specification: gap-0cd-rust-output-camel（admin-api response serialize camelCase + buttons placeholder）

**Feature Branch**: `003-gap-0cd-rust-output-camel`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "gap-0cd-rust-output-camel"

## Scope（依 constitution §III）

| 項目 | 說明 |
|---|---|
| 主題 | admin-api response struct serialize 對齊 admin-web 期望（camelCase + buttons 完整性） |
| 涵蓋 GAP | **GAP-0c**（`AuthOutput.refresh_token` 駝峰問題）+ **GAP-0d**（`UserInfoOutput` 缺 `buttons` field） |
| 倉/層 | **admin-api**（=`fork260509-soybean-admin-rust@new-admin-rust-api`，本機透過 worktree 在 `admin-api/` 操作） |
| 分組理由 | 兩個 GAP 都屬「admin-api response struct → admin-web 消費對齊」同主題、且全部位於 admin-api 倉內，符合 §III 例外條款（同主題同倉合併）。spec 開頭顯式列 GAP id；inner commits 各自帶對應 GAP scope（拆 commit 保留 traceability）。 |
| 不涵蓋 | admin-rust-api 啟動 envsubst 改造（feature 6）、refresh handler（feature 4）、admin-web 端的對應（features 2/5）、button 級權限的真實實作（buttons 暫給 `[]` placeholder，未來功能） |
| 規模 | ~5 行 Rust diff（GAP-0c 1 行 derive attribute + GAP-0d 1 行 struct field + 1 行 handler init + 必要 use / 空行調整） |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - admin-web 可正確消費 admin-rust-api 的 token / refresh / user info response (Priority: P1)

當 admin-web（feature 2 已對齊 wire-level codes + login body field）發 login 請求成功時，admin-rust-api 回傳的 response body 內：
- `data.refreshToken`（駝峰）field 存在且為非空字串 ← GAP-0c 修補
- 後續 `getUserInfo` 呼叫拿到 response 含 `data.buttons`（陣列、目前為空）← GAP-0d 修補

admin-web 不會出現「`loginToken.refreshToken` 是 undefined」「`userInfo.buttons` 解構失敗 / 元件 props 不對」這類 runtime error。

**Why this priority**：admin-web 期望的 contract 已寫死（`Api.Auth.LoginToken` / `Api.Auth.UserInfo` 兩個 TS interface），admin-rust-api 不對齊 → admin-web 直接壞。本 feature 是 features 2/4 完整 work 的前提之一。

**Independent Test**:

1. 前置：feature 1 deploy stack ready、feature 6 envsubst 完成（admin-rust-api 容器能啟動）
2. 跑 `curl -sS -X POST http://localhost:8080/api/auth/login -H 'Content-Type: application/json' -d '{"identifier":"Soybean","password":"Soybean@123."}' | jq`
3. **預期**：response body 含 `data.refreshToken`（不是 `data.refresh_token`）、為非空字串
4. 用拿到的 token 跑 `curl -sS http://localhost:8080/api/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq`
5. **預期**：response body 含 `data.buttons`（陣列、可能為空 `[]`），其他既有 fields（userId / userName / roles）不變

**Acceptance Scenarios**:

1. **Given** admin-rust-api 容器 healthy，**When** 跑 login curl，**Then** response body `data` 物件含 key `refreshToken`（不含 key `refresh_token`，**駝峰 only**）— 對應 GAP-0c。
2. **Given** login 成功拿到 token，**When** 跑 `GET /auth/getUserInfo`，**Then** response body `data` 物件含 key `buttons` 為 array type（值可能為空 `[]`）— 對應 GAP-0d。
3. **Given** UserInfoOutput 既有 fields（`userId`、`userName`、`roles`），**When** 看 response body，**Then** 三個既有 fields 仍存在、命名仍為 camelCase（既有 `#[serde(rename)]` 不被誤動）— 兼容性。
4. **Given** admin-web service 層讀 `loginToken.refreshToken`，**When** login 成功，**Then** 該 field 是 string 而非 undefined — 端對端對齊（依賴 feature 2 已 merged 的 admin-web 端）。

### Edge Cases

- **token 為空字串**：admin-rust-api 永遠送非空 token / refreshToken（既有 ULID / JWT 生成保證）— 本 feature 不負責 token 生成、只負責 serialize。
- **buttons 永遠空 `[]`**：本 feature 提供 placeholder 不涉及 button 權限邏輯；未來 button 級權限實作（屬獨立 feature）會替換 placeholder 的填值邏輯，但 field 本身與 schema 不變。
- **舊 admin-web caller 期望 snake `refresh_token`**：admin-web 上游 type 用 camelCase（`Api.Auth.LoginToken { token, refreshToken }`），無 snake caller。修補後仍對齊既有 admin-web TS types。
- **對外其他 caller**（hypothetical 第三方整合）：admin-rust-api response 從 snake 改 camel 是 breaking change for any non-admin-web caller。本 feature **假定 admin-web 是唯一 caller**（內部 admin tool），FR-321 顯式列為負面 requirement 範圍邊界。
- **Rust serde 編譯**：加 `#[serde(rename_all = "camelCase")]` 是 derive macro 加 attribute、cargo build 應正常通過；如 cargo build 失敗 implementer BLOCKED 上報。

## Requirements *(mandatory)*

### Functional Requirements

#### admin-api/server/model/src/admin/output/sys_authentication.rs（GAP-0c + 0d struct 修改）

- **FR-301 (GAP-0c)**: `AuthOutput` struct MUST 加 `#[serde(rename_all = "camelCase")]` derive attribute（位於 `#[derive(Clone, Debug, Serialize)]` 後一行），讓 `refresh_token` field 序列化成 `refreshToken`；既有 `token` field（已是單字、camelCase 不變）行為不變。
- **FR-310 (GAP-0d struct)**: `UserInfoOutput` struct MUST 加 `pub buttons: Vec<String>` field，置於既有 `roles` field 後。既有 3 個 fields（`user_id` / `user_name` / `roles`）的 `#[serde(rename)]` attributes 不變。

#### admin-api/server/api/src/admin/sys_authentication_api.rs（GAP-0d handler 修改）

- **FR-311 (GAP-0d handler)**: `get_user_info` handler 內建立 `UserInfoOutput { ... }` 的初始化區塊 MUST 加一行 `buttons: vec![]`（置於 `roles: ...` 後）。值為空 vector — placeholder，未來 button 級權限實作會替換。

#### 範圍邊界（負面 requirement）

- **FR-320**: 本 feature MUST NOT 動 admin-api 其他 struct（如 `UserRoute` / `LoginInput` / `MenuRoute` 等不在 scope 內）。
- **FR-321**: 本 feature MUST NOT 改 admin-rust-api 端的 caller assumptions — 假定 admin-web 是唯一消費者（內部 admin tool）。任何第三方整合視為 future work、breaking change 由獨立 feature 處理。
- **FR-322**: 本 feature MUST NOT 動 admin-rust-api 啟動相關（envsubst / Dockerfile / application.yaml — 屬 feature 6）。
- **FR-323**: 本 feature MUST NOT 改 admin-web 任何檔（admin-web 端對齊由 features 2/5 處理）。

### Key Entities

- **`admin-api/server/model/src/admin/output/sys_authentication.rs`**：admin-rust-api response struct 模組。被本 feature 修改的有 `AuthOutput`（加 `rename_all = "camelCase"`）與 `UserInfoOutput`（加 `buttons` field）。是 admin-api 倉內既有檔。
- **`admin-api/server/api/src/admin/sys_authentication_api.rs`**：admin-rust-api auth API handler。被本 feature 修改的是 `get_user_info` handler（加 `buttons: vec![]` 初始化）。是 admin-api 倉內既有檔。
- **wire contract `AuthOutput`**（被 admin-web 消費）：MUST 含 `token` (string) 與 `refreshToken` (string) 兩 field，**非** `refresh_token`。
- **wire contract `UserInfoOutput`**（被 admin-web 消費）：MUST 含 `userId` / `userName` / `roles` (string array) / **`buttons`** (string array) 4 fields。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-301**: 跑 `cargo build --release` 在 admin-api 倉 PASS（無 compile error / warning），代表本 feature 加的 derive + struct field 不破壞既有 build。
- **SC-302**: login response 內 100% 包含 `data.refreshToken` field（駝峰）、0% 包含 `data.refresh_token`（snake） — 透過 jq 解析驗證。
- **SC-303**: `GET /auth/getUserInfo` response 內 100% 包含 `data.buttons` field（為 array type，值可能為空），既有 `userId` / `userName` / `roles` 三 field 全保留。
- **SC-304**: 本 feature 的 diff 行數 ≤ **5 行**（不含 use / blank lines / comment 微調）— 對齊 §III 最小 GAP 承諾。

## Assumptions

### 設計假設（自我決策、無需 clarify）

- 採 INTEGRATION-PLAN §4 GAP-0c 推薦方案 A（`#[serde(rename_all = "camelCase")]` derive）：1 行修改、影響整個 struct、未來新加 field 自動 camelCase；不採方案 B（per-field `#[serde(rename = "refreshToken")]`，較冗）或 C（改 admin-web type 接 snake，違反 admin-web upstream 慣例）。
- 採 INTEGRATION-PLAN §4 GAP-0d 推薦方案 A（empty placeholder）：buttons 暫為 `vec![]`，避免阻塞 admin-web 元件正確 destruct；未來實作 button 級權限時替換填值邏輯（屬獨立 feature）。
- **保留** `UserInfoOutput` 既有 per-field `#[serde(rename = "userId")]` 與 `#[serde(rename = "userName")]`：不換成 struct-level `rename_all = "camelCase"`，理由：既有 fields 已對齊、改 attribute 形式對 admin-web 視角無差異、屬無謂風險（本 feature 主旨是「最小修補」）。`buttons` 是 single word、不需任何 rename。

### 對其他 feature 的依賴（明列以利 plan 階段排序）

- **依賴 feature 1（已 merged）**：dev compose stack 是 acceptance 的前提（postgres / redis / admin-rust-api docker network）。
- **依賴 feature 2（已 merged）**：admin-web 端 wire-level 已對齊（codes 200/401/empty/empty + login body identifier）；feature 3 完成後合 features 2+3 即可讓 admin-web 完整消費 admin-rust-api login response。
- **依賴 feature 6（dockerfile-envsubst，未開）**：admin-rust-api 容器要能成功啟動才能跑動態 acceptance（curl /auth/login）。本 feature 自身可跑「靜態 verification」（cargo build PASS + grep struct attribute + grep handler 初始化），動態驗等 feature 6 merge。
- **不依賴 feature 4（gap-1-refresh-handler）**：feature 4 是 refresh handler 新增，本 feature 只動 login response struct；feature 4 完成後可順帶驗 refresh response 也是 camelCase。

### 待驗證的上游慣例（依 constitution §IV）

- [ ] `Res::new_data` 把 `AuthOutput` / `UserInfoOutput` 的 serde 序列化結果包進 `data` field（不是放在 root level）— 看 `admin-api/server/model/src/admin/types/mod.rs` 或對應 Res impl 即可確認；implementation 階段順帶 read。
- [ ] `cargo build --release` 加上述 derive 後仍能完整 build（admin-api 倉沒其他 caller 因加 derive 受影響）。
- [ ] admin-rust-api 對 admin-web `Api.Auth.UserInfo` 的 4 個 fields（userId / userName / roles / buttons）契約完整 — 修補後 100% 命中（前 3 個既有、buttons 由本 feature 加）。
- [ ] admin-web 對 `loginToken.refreshToken` 的 storage / refresh 流程能正確接收（依賴 features 2 已 merged + 4 完成）— 動態驗在 feature 4 完成後跑。

### 不在範圍

- admin-rust-api 啟動 / envsubst / Dockerfile / application.yaml 改造（feature 6）。
- refresh token endpoint 實作（feature 4）。
- admin-web 任何檔變更（features 2/5）。
- button 級權限的真實邏輯（buttons 永遠 placeholder `[]` — 未來功能）。
- 其他 admin-rust-api struct 的 camelCase 對齊（未來 feature 範圍 — 本 feature 只動 GAP-0c/0d 涉及的 2 個 struct）。
- admin-rust-api 內部第三方 caller / 外部 SDK 整合（FR-321）。
