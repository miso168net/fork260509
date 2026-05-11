# Contract: admin-web ↔ admin-api endpoint alignment（feature 5 cleanup）

**Feature**: 005-admin-web-cleanup
**Scope**: admin-web `src/service/api/*.ts` 對 admin-api endpoints 的呼叫契約

---

## 1. Endpoints in scope（feature 5 動）

### `GET /auth/getUserRoutes` （GAP-4 修補 target）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ✅ `init_protected_router()` 內 `.route("/getUserRoutes", get(SysAuthenticationApi::get_user_routes))` (line 25)，nest 在 `/auth` 下 |
| admin-web 修補前 path | ❌ `/route/getUserRoutes`（404） |
| admin-web 修補後 path | ✅ `/auth/getUserRoutes` |
| admin-web caller | `fetchGetUserRoutes()` in `src/service/api/route.ts:9-11` |
| admin-web 上游使用 | `useRouteStore().fetchAuthRoutes()` → `addAuthRoutes(data.routes)` + `setRouteHome(data.home)` |
| 回應 shape | `Api.Route.UserRoute = { routes: MenuRoute[], home: string }` |

### ~~`GET /route/isRouteExist`~~ （GAP-3 修補 — admin-web 不再呼叫）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ❌ **不存在**（admin-api 無此 router） |
| admin-web 修補前 | `fetchIsRouteExist(routeName)` in `src/service/api/route.ts:18-20`（dynamic-mode 會打 → 404） |
| admin-web 修補後 | **函式整個刪除** |
| 替代方案 | `getIsAuthRouteExist()` dynamic-mode 改本地查 `isRouteExistByRouteName(routeName, authRoutes.value)` |
| 取得 `authRoutes` 來源 | `addAuthRoutes(routes)` 在 `fetchGetUserRoutes` 成功後 populate（既有流程） |

### ~~`GET /auth/error?code=X&msg=Y`~~ （GAP-2 修補 — admin-web 不再呼叫）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ❌ **不存在**（admin-api 無此 router） |
| admin-web 修補前 | `fetchCustomBackendError(code, msg)` in `src/service/api/auth.ts:46-48`（dev-only debug helper） |
| admin-web 修補後 | **函式整個刪除** |
| Callers 殘留風險 | ✅ grep 確認 `src/` 內 0 callers — 純 dead code |

---

## 2. Endpoints in scope（feature 5 **不**動，因已對齊）

### `POST /auth/login` （feature 2 已對齊）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ✅ `init_authentication_router()` 內 `.route("/login", post(SysAuthenticationApi::login_handler))`，nest 在 `/auth` 下 |
| admin-web caller | `fetchLogin(userName, password)` 送 body `{ identifier, password }`（feature 2 GAP-0f 已對齊） |
| 修補狀態 | feature 2 已完成 — 本 feature 不動 |

### `GET /auth/getUserInfo` （已對齊）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ✅ `init_protected_router()` 內 `.route("/getUserInfo", get(SysAuthenticationApi::get_user_info))` |
| admin-web caller | `fetchGetUserInfo()` |
| 修補狀態 | 已對齊 — 本 feature 不動 |

### `POST /auth/refreshToken` （feature 4 已加 admin-api 端）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ✅ feature 4 加入 `init_authentication_router()`（inner commit `91747a3` route + `a6dc815` handler） |
| admin-web caller | `fetchRefreshToken(refreshToken)` 送 body `{ refreshToken }` |
| 修補狀態 | feature 4 已 merge — 本 feature 不動 |

### `GET /route/getConstantRoutes` （R2 verified）

| 項目 | 值 |
|---|---|
| admin-api endpoint | ✅ `sys_menu_route.rs:15` 註冊 `.route("/getConstantRoutes", ...)`，nest 在 `/route` 下 |
| admin-web caller | `fetchGetConstantRoutes()` in `src/service/api/route.ts:5` |
| 修補狀態 | 對齊 admin-api 既有 path — 本 feature 不動 |

---

## 3. Endpoints out of scope（feature 5 不評估）

- `/auth/assign-permission` / `/auth/assign-routes`（admin-api `init_authorization_router`）— admin-web 無 caller
- 其他 sys_*  endpoints（user / role / menu / endpoint / login_log / operation_log / domain / organization / access_key）— admin-web 既有 caller 對齊（本 feature 不評）

---

## 4. 修補前後 callers 對照

| admin-web caller | 修補前 | 修補後 | feature 5 動作 |
|---|---|---|---|
| `fetchLogin` (auth.ts:9) | `/auth/login` body `{userName, password}` | `/auth/login` body `{identifier, password}` | 不動（feature 2 處理） |
| `fetchGetUserInfo` (auth.ts:21) | `/auth/getUserInfo` | `/auth/getUserInfo` | 不動 |
| `fetchRefreshToken` (auth.ts:30) | `/auth/refreshToken` | `/auth/refreshToken` | 不動 |
| `fetchCustomBackendError` (auth.ts:46) | `/auth/error` | **刪除** | **GAP-2 ✅** |
| `fetchGetConstantRoutes` (route.ts:4) | `/route/getConstantRoutes` | `/route/getConstantRoutes` | 不動（已對齊 R2） |
| `fetchGetUserRoutes` (route.ts:9) | `/route/getUserRoutes`（404） | **`/auth/getUserRoutes`** | **GAP-4 ✅** |
| `fetchIsRouteExist` (route.ts:18) | `/route/isRouteExist`（404） | **刪除（改本地查 authRoutes.value）** | **GAP-3 ✅** |

---

## 5. admin-web 端 routeStore dynamic-mode 行為對照

| 流程 | 修補前 | 修補後 |
|---|---|---|
| `authRouteMode === 'dynamic'` + login 後 | fetchGetUserRoutes（404 path） → routes 載不到 → dashboard 進不去 | fetchGetUserRoutes（已對 path） → routes 載入 → addAuthRoutes 寫 `authRoutes.value` → dashboard 正常 |
| `authRouteMode === 'dynamic'` + navigate to not-found URL | `routeStore.getIsAuthRouteExist(path)` → dynamic mode 打 `fetchIsRouteExist(name)`（404）→ 攔截器報錯 / 卡住 | `routeStore.getIsAuthRouteExist(path)` → dynamic mode 本地查 `isRouteExistByRouteName(name, authRoutes.value)` → 立即 boolean 回 → 0 HTTP request |
| `authRouteMode === 'static'` （既有）| 本地查 `createStaticRoutes()` → boolean | **不變**（FR-535 保留 static path） |

---

## 6. 對應 spec FR/SC（traceability）

| Contract section | spec 依據 |
|---|---|
| §1 `/auth/getUserRoutes` GAP-4 | FR-511, SC-504, SC-506 |
| §1 `/route/isRouteExist` GAP-3 API removal | FR-510, FR-520, FR-521, SC-503, SC-505 |
| §1 `/auth/error` GAP-2 | FR-501, FR-502, SC-502 |
| §2 已對齊 endpoints | 不在本 feature scope（FR-530/532/534） |
| §3 out of scope | FR-531（2-M4 follow-up）/ FR-533/534 |
| §5 routeStore dynamic-mode 行為 | US2, edge cases, FR-535（static path 保留） |
