# Phase 1 Data Model: gap-0ab0f-frontend-env-and-login

**Feature**: `002-gap-0ab0f-frontend-env-and-login`
**Date**: 2026-05-11

> 本 feature 不動 application data schema，本檔列被改動的 file entity + 跨組件 wire-level contract。

---

## 1. File Entities（admin-web 倉內被動的檔）

| ID | File | Type | 改動範圍 | GAP 對應 |
|---|---|---|---|---|
| F1 | `admin-web/.env` | env vars 樣板 | 4 行 value 改（不增不減 key） | GAP-0a + GAP-0b |
| F2 | `admin-web/src/service/api/auth.ts` | TypeScript service module | 1 行 data field rename（`fetchLogin` 內 request body） | GAP-0f |

### F1 改動細項（admin-web/.env）

當前內容（line 32, 35, 38, 41）：
```
VITE_SERVICE_SUCCESS_CODE=0000
VITE_SERVICE_LOGOUT_CODES=8888,8889
VITE_SERVICE_MODAL_LOGOUT_CODES=7777,7778
VITE_SERVICE_EXPIRED_TOKEN_CODES=9999,9998,3333
```

改為：
```
VITE_SERVICE_SUCCESS_CODE=200
VITE_SERVICE_LOGOUT_CODES=
VITE_SERVICE_MODAL_LOGOUT_CODES=
VITE_SERVICE_EXPIRED_TOKEN_CODES=401
```

行數 diff：4 行 value 改（key 不變、註解不動）。

### F2 改動細項（admin-web/src/service/api/auth.ts）

當前內容（fetchLogin 函式內 data 物件）：
```ts
data: {
  userName,
  password
}
```

改為：
```ts
data: {
  identifier: userName,
  password
}
```

行數 diff：1 行（多 1 個 colon-renamed key）。

---

## 2. Wire-Level Contracts（admin-web ↔ admin-rust-api）

### W1: POST `/api/auth/login` request body

| Field | Type | Source | Required |
|---|---|---|---|
| `identifier` | string | admin-web fetchLogin 的入參 `userName` 改名送出（GAP-0f 修補） | ✅ |
| `password` | string | admin-web fetchLogin 的入參 `password` | ✅ |

**Source of truth**：admin-rust-api `server/model/src/admin/input/sys_authentication.rs` `LoginInput` struct。

### W2: HTTP response code 識別約定（admin-rust-api 端送 / admin-web 端讀）

| HTTP code | admin-rust-api 行為 | admin-web 識別（修補後） |
|---|---|---|
| 200 | `Res::new_data(data)` 成功包 | `VITE_SERVICE_SUCCESS_CODE=200` 識別為成功 |
| 401 | unauthorized | `VITE_SERVICE_EXPIRED_TOKEN_CODES=401` 觸發 refresh flow（feature 4 補 refresh handler） |
| 其他 4xx / 5xx | 各自 error code | admin-web 顯示 toast（既有行為） |

**fake codes 不再使用**（清空）：
- `VITE_SERVICE_LOGOUT_CODES`：原 `8888,8889`，admin-rust-api 不送 → 清空避免誤觸
- `VITE_SERVICE_MODAL_LOGOUT_CODES`：原 `7777,7778`，admin-rust-api 不送 → 清空

### W3: POST `/api/auth/login` response body（success 200）

| Field | Type | 提供方 | 修補狀態 |
|---|---|---|---|
| `code` | number | admin-rust-api `Res::new_data` | 已 200（無需 admin-rust-api 改） |
| `data.token` | string | admin-rust-api `AuthOutput.token` | 已對齊（無需改） |
| `data.refreshToken` | string | admin-rust-api `AuthOutput.refresh_token` | **由 feature 3 修補**（`#[serde(rename_all = "camelCase")]`）— 本 feature 2 完成但 feature 3 未完成時，admin-web 讀到 `undefined` |
| `msg` | string | admin-rust-api | 既有，無需改 |

---

## 3. Cross-Reference

- **Spec FR**：F1 ↔ FR-201 ~ FR-204；F2 ↔ FR-210
- **Contracts**：W1 ↔ `contracts/login-body.md`；W2/W3 ↔ `contracts/env-codes.md` + `contracts/login-body.md`
- **Source（admin-api）**：`server/model/src/admin/input/sys_authentication.rs`、`server/model/src/admin/output/sys_authentication.rs`、`server/api/src/admin/sys_authentication_api.rs`、`server/handler/Res::new_data` impl

---

## 4. State Transitions（admin-web login flow，本 feature 修補後）

```
[user 在 admin-web login 頁]
        │
        ▼ user 輸入 identifier (= username) + password
[admin-web fetchLogin]
        │
        ▼ POST /api/auth/login {identifier, password}（GAP-0f 修補）
[admin-rust-api]
        │
        ├──[成功]──> 200 {code:200, data:{token, refreshToken}, msg}
        │              │
        │              ▼
        │           [admin-web service 層 success_code === 200 ✅]（GAP-0a 修補）
        │              │
        │              ▼ store token + refreshToken（refreshToken 待 feature 3 對齊）
        │           [admin-web 跳首頁]（依 VITE_ROUTE_HOME）
        │
        ├──[失敗 / 密碼錯]─> 401 {code:401, msg}
        │              │
        │              ▼
        │           [admin-web service 層 expired_token_codes 含 401 → refresh flow]
        │              │
        │              ▼ ⚠️ 但 login context 觸發 refresh 是錯的 — feature 5 處理此衝突
        │
        └──[fake codes]──> 不會發生（admin-rust-api 不送 7777/8888/9999/3333 等）
                       └──> LOGOUT_CODES / MODAL_LOGOUT_CODES 清空後，0 fake-code 誤觸（GAP-0b 修補）
```

注意：login context 內 401 被 admin-web 視為 token expired 而觸發 refresh — 這是設計衝突，由 **feature 5 admin-web-cleanup** 處理（admin-web auth/index.ts 對 login error path 加特殊判斷）。本 feature 2 不負責解這個衝突，FR-222 已明文劃出。

---

**Output 完成**：2 個 file entity（含改動 line/value）+ 3 個 wire contract（W1/W2/W3）+ state machine（含 cross-feature deferred 衝突點標記）。
