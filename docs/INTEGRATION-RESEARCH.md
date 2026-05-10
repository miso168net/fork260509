# 整合評估：fork260509-soybean-admin × fork260509-soybean-admin-rust

> 日期：2026-05-10
> 資料來源：graphify 知識圖譜（`graphify-out/graph.json`，3,616 nodes / 3,543 edges）+ 直接讀原始碼驗證
> 範圍：前端 = `fork260509-soybean-admin`（standalone Vue 3 starter）、後端 = `fork260509-soybean-admin-rust`（axum + Casbin）

## 1. 前端實際的 API 表面（極小）

`fork260509-soybean-admin` 是 **starter template**：

- `src/views/` 只有 `home` 與 `_builtin`（login / 403 / 404 / 500 / iframe-page），**沒有任何管理頁面**
- `.env.prod` 指向 `https://mock.apifox.cn/m1/3109515-0-default`（Apifox mock），預設用 mock 跑

實際呼叫的 API 只有 **7 條**（`src/service/api/auth.ts` + `route.ts`）：

| # | Method | Path | 用途 |
|---|---|---|---|
| 1 | POST | `/auth/login` | 登入 |
| 2 | GET  | `/auth/getUserInfo` | 取使用者資料 |
| 3 | POST | `/auth/refreshToken` | 刷新 token |
| 4 | GET  | `/auth/error` | 自訂錯誤測試 |
| 5 | GET  | `/route/getConstantRoutes` | 取常數路由 |
| 6 | GET  | `/route/getUserRoutes` | 取使用者路由 |
| 7 | GET  | `/route/isRouteExist` | 路由存在檢查 |

## 2. Rust 後端實際提供（豐富）

從 `server/router/src/admin/*.rs` 直接讀 axum route 表：

| Mount path | 路由清單 | 對應功能 |
|---|---|---|
| `/auth` | `POST /login`、`GET /getUserInfo`、`GET /getUserRoutes` | 登入 + 使用者資訊 |
| `/authorization` | `POST /assign-permission`、`POST /assign-routes`、`GET /getUserRoutes` | RBAC 指派 |
| `/route` | `GET /getConstantRoutes`、`GET /tree`、CRUD、`GET /auth-route/{roleId}` | 路由（Menu）管理 |
| `/user` | `GET /users`、CRUD、`GET /add_policies`、`GET /remove_policies` | 使用者 + Casbin 政策綁定 |
| `/role` | CRUD | 角色管理 |
| `/domain` | CRUD | 多租戶 domain |
| `/api-endpoint` | `GET /`、`GET /tree`、PUT auth | endpoint 自動註冊 + 授權 |
| `/login-log` | `GET /` | 登入日誌 |
| `/operation-log` | `GET /` | 操作日誌 |
| `/org` | `GET /` | 組織（唯讀） |
| `/access-key` | `GET /`、POST、DELETE | API Key 管理 |
| `/sandbox` | `GET /simple-api-key`、`GET /complex-api-key` | API Key 簽章驗證 |

Server port 在 `server/resources/application.yaml`：`10001`。

## 3. 7 個前端呼叫對照 Rust 提供

| # | 前端呼叫 | Rust | 狀態 |
|---|---|---|---|
| 1 | `POST /auth/login` | `POST /auth/login` (`sys_authentication_route.rs:13`) | ✅ 完全匹配 |
| 2 | `GET /auth/getUserInfo` | `GET /auth/getUserInfo` (`sys_authentication_route.rs:19`) | ✅ 完全匹配 |
| 3 | **`POST /auth/refreshToken`** | ❌ 不存在 | 🔴 **GAP** |
| 4 | **`GET /auth/error`** | ❌ 不存在 | 🟡 GAP（測試用，可選） |
| 5 | `GET /route/getConstantRoutes` | `GET /route/getConstantRoutes` (`sys_menu_route.rs:14`) | ✅ 完全匹配 |
| 6 | `GET /route/getUserRoutes` | `GET /auth/getUserRoutes` 或 `/authorization/getUserRoutes` | ⚠️ **路徑不一致** |
| 7 | **`GET /route/isRouteExist`** | ❌ 不存在 | 🔴 **GAP** |

**總結**：4/7 完美對接、1/7 路徑要改、2/7 完全沒有。

## 4. 三個 GAP 的建議方案

### 🔴 GAP-1：`POST /auth/refreshToken`

| 選項 | 變動規模 | 評估 |
|---|---|---|
| **A. 在 Rust 後端加 refresh handler**（推薦） | 在 `sys_authentication_route.rs` 加一行 route + `SysAuthenticationApi::refresh_token_handler`，~50 行 Rust。Casbin 不受影響 | ⭐ 維持原有 token 流程，前後端零改動 |
| B. 改長效 JWT 不刷新 | 把 `application.yaml` 的 `jwt.expire: 7200` 改為 86400+，前端把 refreshToken 函式改 no-op | 內部 admin 系統可接受；安全弱 |
| C. 用 cookie + sliding session | 把 JWT 換成 server-side session，每次請求自動延長 | 過度工程，整個 auth 要重寫 |

### 🟡 GAP-2：`GET /auth/error`

這是**前端開發測試工具** — 故意觸發後端回 `code/msg` 來驗證 axios 攔截器。生產不會用。

| 選項 | 評估 |
|---|---|
| **A. 直接從前端刪除呼叫**（推薦） | `src/service/api/auth.ts` 刪掉 `fetchCustomBackendError` 函式，前端 0 引用點 |
| B. 在 Rust 加 1 行 `.route("/error", get(\|q: Query<ErrParams>\| ...))` | 5 行 Rust 達成相容，未來開發測試方便 |
| C. 用 vite-plugin-mock 在前端模擬 | 開發期攔截 `/auth/error` 回 fake response |

### 🔴 GAP-3：`GET /route/isRouteExist`

| 選項 | 評估 |
|---|---|
| **A. 在 Rust 加 endpoint**（推薦） | `sys_menu_route.rs` 加 `.route("/isRouteExist", get(SysMenuApi::is_route_exist))`，handler 查 `SysMenu where route_name = ?` 回 bool。~30 行 |
| B. 前端用 `getUserRoutes` 結果做 client-side 檢查 | 把 `fetchIsRouteExist` 改成本地查 `useRouteStore`。0 行後端變動，但 `router/guard/route.ts` init flow 要改 |
| C. 用 Casbin enforce 替代 | `enforcer.enforce(user, routeName, "read")` 直接判斷有沒權限訪問，等同於存在檢查 |

### ⚠️ 路徑不一致：`/route/getUserRoutes` vs `/auth/getUserRoutes`

| 選項 | 評估 |
|---|---|
| **A. 改前端**（推薦） | `src/service/api/route.ts:9` 從 `/route/getUserRoutes` 改 `/auth/getUserRoutes`。1 行 |
| B. 改 Rust（在 `/route` 也掛同一 handler） | 1 行 axum `.route("/getUserRoutes", get(SysAuthenticationApi::get_user_routes))` 加到 `init_protected_menu_router` |
| C. 走 `/authorization/getUserRoutes` | Rust 在 `init_authorization_router` 已掛這條，前端只要改 prefix |

## 5. 為「未來擴充管理頁面」做準備

如果之後要把 standalone admin 從 starter 升級到完整 admin（加使用者、角色、選單管理），**Rust 後端已經備好幾乎全部**：

| 管理功能 | NestJS 前端的 API client | Rust 後端對應 | 狀態 |
|---|---|---|---|
| 使用者 CRUD | `/user` | `/user` | ✅ |
| 角色 CRUD | `/role` | `/role` | ✅ |
| 選單 CRUD | `/route` | `/route` | ✅ |
| API endpoint 樹 | `/api-endpoint/tree` | `/api-endpoint/tree` | ✅ |
| 指派權限 | `/authorization/assign-permission` | `/authorization/assign-permission` | ✅ |
| 指派路由 | `/authorization/assign-routes` | `/authorization/assign-routes` | ✅ |
| 登入日誌 | `/login-log` | `/login-log` | ✅ |
| 操作日誌 | `/operation-log` | `/operation-log` | ✅ |
| 取所有角色（dropdown） | `/systemManage/getAllRoles` | ❌ 沒有 | 🔴 用 `/role` 取 + 前端 paginate |
| 取所有頁面（dropdown） | `/systemManage/getAllPages` | ❌ 沒有 | 🔴 用 `/route/tree` 替代 |
| Access Key 管理 | `/access-key` | `/access-key` | ✅ |
| 多租戶 domain | — | `/domain` | ✅ Rust 額外提供 |
| 組織管理 | — | `/org` (僅 GET) | ⚠️ Rust 只實作了讀 |

**結論**：NestJS frontend 的 `src/service/api/system-manage.ts` 幾乎可以直接複製到 standalone admin 上配 Rust 後端，只要改 2 個 endpoint（`getAllRoles`、`getAllPages`），就能用 Rust 跑完整管理功能。

## 6. 整體評估

| 維度 | 評分 | 說明 |
|---|---|---|
| 基本可行性 | ⭐⭐⭐⭐⭐ | 7 條前端 API，4 條完美匹配，3 條小修即可 |
| 做為 starter 直接跑 | ⭐⭐⭐⭐ | 改 2 處前端（GAP-2 刪呼叫、路徑統一）+ 加 1 個 Rust handler（refreshToken） |
| 擴充到完整 admin | ⭐⭐⭐⭐ | Rust 後端 90% 功能就緒；複製 NestJS 前端的 system-manage.ts、改 2 條 endpoint |
| Casbin 授權品質 | ⭐⭐⭐⭐⭐ | Rust 用 `axum_casbin::CasbinAxumLayer` + Sea-ORM adapter，每 request 都過 enforce，是專案最強的部分 |

### 風險點

1. **Endpoint 自動註冊**：Rust 的 `process_collected_routes()`（`router_initialization.rs:328`）在 boot 時會把所有掛上去的 router path/method 寫進 `SysEndpoint` 表。**第一次 boot 後**才有 endpoint 清單可在 admin UI 指派權限。如果在 boot 失敗的情況下（例如 DB 還沒 migrate）這張表會是空的。
2. **Rust AuthZ 寫法**：圖譜裡 `initialize_admin_router()`（`router_initialization.rs:93`）用一個 `merge_router!` 巨集 + `apply_layers(need_casbin, need_auth, api_validation)` 統一決定每條路由的中介層組合。**改授權策略只需改這個函式**。但反過來說，單一函式也是單一風險點 — 寫錯 `need_casbin: false` 就會讓某條路由完全裸奔。
3. **`get_named_connection()` 是潛在 sharding 出口**（`server/service/src/helper/db_helper.rs:16`）— 程式碼存在但 `#[allow(dead_code)]`。如果未來要支援「不同 domain 走不同 DB」，每個 service method 簽章都要加 `domain_name: &str` 並改用 `get_named_connection`。

## 7. 建議的最小可行整合步驟

1. **設定環境**：把 `fork260509-soybean-admin/.env.prod` 的 `VITE_SERVICE_BASE_URL` 從 Apifox mock 改成 `http://localhost:10001`
2. **修 GAP-3**：選方案 B（前端 `fetchIsRouteExist` 改本地查）— 0 行後端變動
3. **修 GAP-1**：選方案 A，加 `POST /auth/refreshToken` 到 Rust（~50 行）
4. **修 GAP-2**：選方案 A，前端刪掉 `fetchCustomBackendError`
5. **修路徑不一致**：選方案 A，前端 `/route/getUserRoutes` → `/auth/getUserRoutes`
6. **測通 7 條 API**，驗證 Casbin layer 在所有 protected endpoints 都生效

之後再考慮把 NestJS 前端的 `system-manage.ts` 移植過來開啟管理功能。

## 附錄：關鍵檔案位置

### 前端
- API client：`fork260509-soybean-admin/src/service/api/{auth,route,index}.ts`
- HTTP wrapper：`fork260509-soybean-admin/src/service/request/index.ts`
- 環境變數：`fork260509-soybean-admin/.env.{test,prod}`
- Router guard 實作：`fork260509-soybean-admin/src/router/guard/{index,route,progress,title}.ts`

### Rust 後端
- Router 定義：`fork260509-soybean-admin-rust/server/router/src/admin/*.rs`
- API handlers：`fork260509-soybean-admin-rust/server/api/src/admin/`
- Service 層：`fork260509-soybean-admin-rust/server/service/src/admin/`
- 組合根：`fork260509-soybean-admin-rust/server/initialize/src/router_initialization.rs:93` (`initialize_admin_router`)
- Casbin 模型：`fork260509-soybean-admin-rust/server/resources/rbac_model.conf`
- DB helper：`fork260509-soybean-admin-rust/server/service/src/helper/db_helper.rs`
- 主設定：`fork260509-soybean-admin-rust/server/resources/application.yaml`

### 參考實作（NestJS 前端）
- 完整管理 API client：`fork260509-soybean-admin-nestjs/frontend/src/service/api/{access-key,auth,log,route,system-manage}.ts` — 可移植到 standalone 前端
