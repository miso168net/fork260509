# Contract: AuthOutput Wire-Level（admin-rust-api → admin-web）

**Feature**: `003-gap-0cd-rust-output-camel`
**File**: `admin-api/server/model/src/admin/output/sys_authentication.rs`（被本 feature 加 1 行 derive attribute）
**Endpoint**: `POST /api/auth/login` response

> 本契約鎖 admin-rust-api 對 successful login 的 response shape。違反此契約 = 違反 spec FR-301 + GAP-0c 修補意圖。

---

## 1. Response Body — Success 200 OK（修補後）

```json
{
  "code": 200,
  "data": {
    "token": "<JWT access token>",
    "refreshToken": "<ULID refresh token>"
  },
  "msg": "..."
}
```

| Field | Path | Type | Source（admin-rust-api struct field） | 修補狀態 |
|---|---|---|---|---|
| `code` | `.code` | number | `Res::new_data` 設 200 | 既有 |
| `data.token` | `.data.token` | string | `AuthOutput.token` | 既有（單字、camelCase 友善） |
| `data.refreshToken` | `.data.refreshToken` | string | `AuthOutput.refresh_token` 透過 `#[serde(rename_all = "camelCase")]` 序列化 | **本 feature 修補**（GAP-0c） |
| `msg` | `.msg` | string | admin-rust-api 自填 | 不變 |

---

## 2. Rust Source Mapping

```rust
// admin-api/server/model/src/admin/output/sys_authentication.rs
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]    // ← 本 feature 加（FR-301）
pub struct AuthOutput {
    pub token: String,                 // → "token"（camelCase friendly）
    pub refresh_token: String,         // → "refreshToken"（駝峰，由 rename_all 達成）
}
```

**`#[serde(rename_all = "camelCase")]` 行為**：
- snake_case Rust field → camelCase JSON key（自動）
- 如 `refresh_token` → `"refreshToken"`、`some_long_field` → `"someLongField"`
- 既有 per-field `#[serde(rename)]` 仍會 override struct-level rename_all（本 feature 不混用、AuthOutput 沒 per-field rename）

---

## 3. admin-web 端消費

```ts
// admin-web/src/typings/api/auth.d.ts（既有 admin-web type）
namespace Api.Auth {
  interface LoginToken {
    token: string;
    refreshToken: string;     // admin-web 既有期望 camelCase
  }
}

// admin-web 在 service 層收到 response 後
const loginToken = response.data;          // type: Api.Auth.LoginToken
loginToken.token;                           // ✅ string
loginToken.refreshToken;                    // ✅ string（修補後；修補前為 undefined）
```

---

## 4. 修補前 vs 修補後

### 修補前（GAP-0c 問題）

```json
{
  "code": 200,
  "data": {
    "token": "...",
    "refresh_token": "..."     // ❌ snake，admin-web 讀 .refreshToken 會 undefined
  },
  "msg": "..."
}
```

### 修補後

```json
{
  "code": 200,
  "data": {
    "token": "...",
    "refreshToken": "..."      // ✅ camel，admin-web 對齊
  },
  "msg": "..."
}
```

---

## 5. End-to-End Validation

### 5.1 靜態（implement 階段、不依賴 feature 6）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# 確認 derive attribute 加在 AuthOutput 上方
grep -BE 1 'pub struct AuthOutput' server/model/src/admin/output/sys_authentication.rs \
  | grep -q 'rename_all = "camelCase"' \
  && echo "PASS: AuthOutput 有 rename_all derive" \
  || echo FAIL

# cargo check 過
cargo check --release 2>&1 | grep -qE 'Finished|warning' \
  && echo "PASS: cargo check" || echo FAIL
```

### 5.2 動態（feature 6 merge 後）

```bash
BASE=http://localhost:8080/api

# 跑 login + 檢查 keys
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq '.data | keys'
# 期望：["refreshToken", "token"]
# 不該看到："refresh_token"

# 反向驗
RESP=$(curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}')
echo "$RESP" | jq -r 'tostring' | grep -c 'refresh_token'
# 期望：0
```

---

## 6. 變更政策

- **改 `AuthOutput` field 名稱**：影響 admin-web 端 TypeScript type；breaking change，需協同 admin-web Api.Auth.LoginToken 變更（屬 admin-web 倉的 spec 變更）
- **加新 field**（如 `accessTokenExpireAt`）：可加、struct-level rename_all 自動處理 camelCase；contract 須同步更新
- **改 derive attribute**（移除 `rename_all`、改用 per-field rename）：屬 stylistic refactor、admin-web 視角無差異；可作獨立 refactor commit、不需新 spec

---

## 7. Out of Scope

- `AuthOutput` field 內容生成邏輯（token / refresh_token 的 JWT 產生 / ULID 產生）— 屬 admin-rust-api login_handler 既有 code、本 contract 不涵蓋
- `Res::new_data` impl 本身 — 屬 admin-api 倉的 wrapper（research R1 已驗）
- admin-web 端 store / refresh flow — 屬 admin-web 倉（features 4/5）
