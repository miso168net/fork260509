# Contract: POST /api/auth/login Wire-Level（admin-web ↔ admin-rust-api）

**Feature**: `002-gap-0ab0f-frontend-env-and-login`
**File**: `admin-web/src/service/api/auth.ts`（被本 feature 改 1 行 data field rename）
**Endpoint**: `POST /api/auth/login`（透過 nginx 反代 / vite proxy 到 admin-rust-api `:10001/auth/login`）

> 本契約鎖 admin-web 送出 + admin-rust-api 回收的 wire-level 結構。違反此契約 = 違反 spec FR-210 + GAP-0f 修補意圖。

---

## 1. Request Body（admin-web 送 → admin-rust-api 收）

```json
{
  "identifier": "Soybean",
  "password": "Soybean@123."
}
```

| Field | Type | Required | Source（admin-web 端） | Sink（admin-rust-api 端） |
|---|---|---|---|---|
| `identifier` | string | ✅ | `fetchLogin(userName, password)` 入參 `userName` rename | `LoginInput.identifier`（`server/model/src/admin/input/sys_authentication.rs`） |
| `password` | string | ✅ | `fetchLogin` 入參 `password` | `LoginInput.password` |

### 修補前 vs 修補後（admin-web fetchLogin 函式）

**修補前**（GAP-0f 問題）：
```ts
export function fetchLogin(userName: string, password: string) {
  return request<Api.Auth.LoginToken>({
    url: '/auth/login',
    method: 'post',
    data: {
      userName,         // ❌ 送出 {"userName": "..."} — admin-rust-api 不認、會 deserialize 失敗
      password
    }
  });
}
```

**修補後**：
```ts
export function fetchLogin(userName: string, password: string) {
  return request<Api.Auth.LoginToken>({
    url: '/auth/login',
    method: 'post',
    data: {
      identifier: userName,    // ✅ 送出 {"identifier": "..."} — 對齊 admin-rust-api LoginInput.identifier
      password
    }
  });
}
```

**重要**：函式 signature `fetchLogin(userName: string, password: string)` **不變**（避免影響其他 caller）。只改 `data` 物件內 key name（用 `identifier: userName` 即可）。

---

## 2. Response Body — Success 200 OK

```json
{
  "code": 200,
  "data": {
    "token": "<JWT access token>",
    "refreshToken": "<ULID-format refresh token>"
  },
  "msg": "..."
}
```

| Field | Type | admin-rust-api Source | admin-web Sink | 本 feature 修補狀態 |
|---|---|---|---|---|
| `code` | number | `Res::new_data` 設 200 | service 層比對 `VITE_SERVICE_SUCCESS_CODE=200` 識別為成功 | ✅（GAP-0a 修補後 admin-web 識別） |
| `data.token` | string | `AuthOutput.token` | 存進 admin-web auth store | ✅（既有，無需改） |
| `data.refreshToken` | string | `AuthOutput.refresh_token`（**snake**） | admin-web 期望讀 `refreshToken`（**camel**） | ⚠️ **依賴 feature 3 (gap-0cd-rust-output-camel)** 用 `#[serde(rename_all = "camelCase")]` 把 admin-rust-api 端送出改 camel；本 feature 2 完成但 feature 3 未完成時，admin-web `loginToken.refreshToken` 是 `undefined` |
| `msg` | string | admin-rust-api 自填 | admin-web 顯示在 toast / log | 不變 |

---

## 3. Response Body — Unauthorized 401

```json
{
  "code": 401,
  "msg": "Unauthorized"
}
```

| Field | Type | admin-rust-api Source | admin-web Sink |
|---|---|---|---|
| `code` | number | HTTP status mapping = 401 | 比對 `VITE_SERVICE_EXPIRED_TOKEN_CODES=401` 觸發 refresh flow |
| `msg` | string | admin-rust-api 自填 | admin-web error toast |

**注意**：在 login context 內收到 401 不該觸發 refresh（沒有 token 可 refresh）— 這是 admin-web auth/index.ts 既有邏輯衝突，**屬 feature 5 admin-web-cleanup 處理**。本 feature 2 不負責解。

---

## 4. End-to-End Validation

### 4.1 靜態 verification（本 feature 自身可跑）

```bash
cd admin-web

# auth.ts 含 identifier: userName
grep -qE 'identifier:\s*userName' src/service/api/auth.ts && echo "PASS: auth.ts 對齊" || echo FAIL

# auth.ts **不**再含 data: { userName, password } pattern（修補後該 pattern 不存在）
! grep -qE 'data:\s*\{\s*userName,' src/service/api/auth.ts && echo "PASS: 舊 pattern 已清" || echo FAIL
```

### 4.2 動態 verification（feature 6 merge 後跑）

```bash
BASE=http://localhost:8080/api

# Test 1: identifier 應 success
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq '.code'
# 期望：200

# Test 2: 對照組 — userName 應 fail（admin-rust-api 期望 identifier）
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"userName":"Soybean","password":"Soybean@123."}' \
  | jq '.code'
# 期望：非 200（deserialize error / 400 / 422）
```

---

## 5. 變更政策

- **改 request field 名稱**（`identifier` → 別名）：須協同 admin-rust-api `LoginInput` struct 改名（屬 admin-rust-api 倉 spec 變更）；本 contract 同步更新
- **新增 request field**（如 `tenant_id`、`captcha_token`）：必先在 admin-rust-api 端加 schema、本契約增列、admin-web fetchLogin signature 同步擴
- **改 response field**（如 `data.token` → `data.accessToken`）：屬 admin-rust-api 倉 breaking change、跨 feature 協調

---

## 6. Out of Scope

- admin-rust-api `LoginInput` / `AuthOutput` struct 本身 — 屬 admin-api 倉（features 3/4 涵蓋）
- admin-web auth store / login flow logic（接 token 後做什麼）— 屬 admin-web 倉既有 code（features 4/5 涵蓋 refresh 與 cleanup）
- 跨域 / CORS / cookies — feature 1 nginx 同源反代 + feature 6 envsubst 處理
