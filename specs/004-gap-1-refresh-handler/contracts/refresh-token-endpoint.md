# Contract: POST /auth/refreshToken

**Feature**: 004-gap-1-refresh-handler
**Endpoint**: `POST /auth/refreshToken`
**Public URL** (via nginx 同源反代): `POST /api/auth/refreshToken`

---

## 1. Wire-level Contract

### 1.1 Request

| 屬性 | 值 |
|---|---|
| Method | `POST` |
| Path | `/auth/refreshToken`（admin-api 內部）= `/api/auth/refreshToken`（admin-web 從 nginx 看） |
| Headers | `Content-Type: application/json`（必須）；`User-Agent` / `X-Request-Id` 等沿用既有中介層 |
| Body | `{ "refreshToken": "<ulid-string>" }` |
| Auth | **不需 access token**（refresh 本身是 auth endpoint）；不過 Casbin enforce |

**Body schema**:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema",
  "type": "object",
  "required": ["refreshToken"],
  "properties": {
    "refreshToken": {
      "type": "string",
      "minLength": 1,
      "description": "從 login response 或前次 refresh response 取得的 refresh token"
    }
  },
  "additionalProperties": false
}
```

### 1.2 Success Response（rotation 成功）

| 屬性 | 值 |
|---|---|
| HTTP Status | `200 OK`（admin-api 永遠以 200 + envelope code 表達結果） |
| Headers | `Content-Type: application/json` |
| Body shape | `Res<AuthOutput>` |

**Body**:

```json
{
  "code": 200,
  "data": {
    "token": "<新 JWT access token>",
    "refreshToken": "<新 ULID refresh token>"
  },
  "msg": "success",
  "success": true
}
```

**Invariants**：

- `data.token` 為新生成的 JWT、簽章用既有 `APP_JWT_SECRET`、`exp = now + APP_JWT_EXPIRE`、claims 含 user_id / username / roles / domain（與 login 同 shape）
- `data.refreshToken` 為新生成的 ULID 字串（26 chars，Crockford base32）、與輸入的 refreshToken **不同**
- 與 login response shape 完全對稱（admin-web 端共用 `Api.Auth.LoginToken` TS interface）

### 1.3 Failure Response（refresh token 非法 / 過期 / 已 refreshed）

| 屬性 | 值 |
|---|---|
| HTTP Status | `200 OK`（envelope 表達錯誤；admin-web 既有攔截器約定） |
| Body shape | `Res<()>`（`data: null`） |

**Body**:

```json
{
  "code": 401,
  "data": null,
  "msg": "Refresh token invalid",
  "success": false
}
```

**觸發 case**：

| Case | 觸發條件 | 是否寫 DB |
|---|---|---|
| token 不存在 | `sys_tokens` 表查不到對應 `refresh_token` | 否 |
| token 已過期 | `sys_tokens.expires_at < now()` | 否 |
| token 已 refreshed | `sys_tokens.status = 'REFRESHED'`（前次 refresh 已 rotate） | 否 |
| token 已 revoked | `sys_tokens.status = 'REVOKED'`（手動 logout） | 否 |

**Invariant**：失敗時 sys_tokens 表 0 變動（FR-432）。錯誤訊息建議統一為 `"Refresh token invalid"` 避免 information leak（不暴露是哪一種失敗）。

### 1.4 Validation Error（body 格式錯誤）

由既有 `ValidatedForm` 中介層處理；body 缺 `refreshToken` field 或為空字串：

```json
{
  "code": 400,
  "data": null,
  "msg": "<validator error message，例如 'Refresh token cannot be empty'>",
  "success": false
}
```

- 不進 service / DB query
- HTTP status 仍 200

---

## 2. 副作用（DB 變動）

| 條件 | sys_tokens 表變動 |
|---|---|
| **成功 rotation** | **+1 row**（新 ACTIVE row，含 `expires_at = now() + APP_REFRESH_TOKEN_EXPIRE`）+ **舊 row UPDATE**（`status: ACTIVE → REFRESHED`） |
| **失敗（任一）** | 0 變動 |

兩 statement 必須在同一 Sea-ORM transaction 內（FR-431 atomic；research.md R8）。

---

## 3. admin-web 端消費路徑（既有）

```
src/service/api/auth.ts
  └─ fetchRefreshToken({ refreshToken })
     └─ POST /api/auth/refreshToken
        └─ res.code === 200 → 取 res.data.token / res.data.refreshToken 更新 storage
           res.code === 401 → 觸發 force re-login（清 storage + 跳 /login）
```

- 既有 admin-web `Api.Auth.LoginToken` TS interface：`{ token: string; refreshToken: string }` — 與本 contract `data` shape 完全對齊（feature 2 / 3 已對齊）
- admin-web 攔截器在 access token 401 時自動觸發此 endpoint（refresh flow）

---

## 4. 不對外保證（明列以避免誤解）

- **不保證並發 dedupe**：兩個 tab 同時 401 → 同時打 refresh，先到者成功、後到者拿到 `REFRESHED` row → 401（spec edge case；admin-web 攔截器負責 dedupe）
- **不保證 grace period**：refresh 成功瞬間舊 refresh token 立刻失效（無「30 秒寬限期」設計）
- **不保證舊 access token 立刻失效**：舊 access token 仍 valid 到其 JWT exp 為止（無法 server 端 revoke stateless JWT；本 feature 不引入 token blacklist）
- **不保證跨 device 同步**：refresh 只 rotate 該 refresh token，不影響其他 device 的 session
- **不保證 IP 一致性檢查**：refresh request 從不同 IP 進來不會被擋（純 token-based、不綁 IP）

---

## 5. 對應 spec FR / SC（traceability）

| Contract 段 | spec 依據 |
|---|---|
| §1.1 Request | FR-401（RefreshTokenInput）、FR-402（validate）、FR-410（route URL） |
| §1.2 Success Response | FR-430 步驟 5、SC-403 |
| §1.3 Failure Response | FR-430 步驟 1、FR-432、SC-404、edge case「rotate 後新 refresh token 沒被 admin-web 存起來」 |
| §1.4 Validation Error | FR-402、edge case「body 為 `{}` 或 `{refreshToken: ''}`」 |
| §2 副作用 | FR-430 步驟 2-4、FR-431 atomic、SC-405 |
| §3 admin-web 消費路徑 | spec Assumptions「不依賴 feature 2/5」 |
| §4 不對外保證 | spec Edge Cases / 不在範圍 段 |
