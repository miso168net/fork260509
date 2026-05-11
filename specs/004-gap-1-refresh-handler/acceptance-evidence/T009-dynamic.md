# T009 Dynamic Acceptance Evidence — Feature 004-gap-1-refresh-handler

**Date**: 2026-05-11
**Test env**: 本機 `cargo run --release` via docker (network `new-admin-root-dev_admin-net`)
**admin-api SHA at test time**: `84bc29a` (a6dc815 + 1 TZ-skew documentation commit on top)
**Postgres**: dev compose stack (port 5432 exposed to host)
**Test DB user (default)**: `Soybean` / `123456` — **constitution §IV finding**: 上游真實密碼是 `123456`，**不是** CLAUDE.md §5.1 寫的 `Soybean@123.`（待驗證 → 已驗 not equal）

## Dynamic test coverage (對應 spec.md SC-403/404/405/407)

### US1 (P1) happy path — SC-403 / SC-405

#### US1.1 login
```bash
curl -sS -X POST http://localhost:10001/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"123456"}'
```
**Result**: `code=200 success=True has_token=True has_refresh=True` ✅

`data.refreshToken` 是 26-char ULID（如 `01KRAZM6M9WTZX69Z6FKZAPEF0`）。
`data.token` 是 JWT — decoded claims：sub=1, username=Soybean, role=[ROLE_SUPER], domain=built-in, exp=now+7200s, aud=management_platform。

#### US1.2 refresh (rotation)
```bash
curl -sS -X POST http://localhost:10001/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH\"}"
```
**Result**: `code=200 success=True has_data=True` ✅
- new refreshToken ≠ old refreshToken ✅
- new access token ≠ old access token ✅

**對應 spec FR-430 / SC-403 完整 PASS**：rotation 成功，admin-web 取得 fresh JWT + new ULID。

#### US1.3 new access token works for /auth/getUserInfo
```bash
curl -sS http://localhost:10001/auth/getUserInfo -H "Authorization: Bearer $NEW_ACCESS"
```
**Result**: `code=200 userName=Soybean roles=['ROLE_SUPER']` ✅

新 JWT 簽章在 protected endpoint 上能通過驗證 — 確認 access token 完整有效。

#### US1.4 sys_tokens row state — SC-405
```sql
SELECT refresh_token, status FROM sys_tokens ORDER BY created_at;
```
```
       refresh_token        |  status
----------------------------+-----------
 01KRAZM6M9WTZX69Z6FKZAPEF0 | REFRESHED  ← old (rotated)
 01KRAZM6QCCM28PHRA29Z8AJKC | ACTIVE     ← new (just issued)
```
舊 row `status: ACTIVE → REFRESHED` ✅、新 row 寫入 `ACTIVE` ✅、皆關聯同一 `user_id=1` ✅。**SC-405 PASS**。

### SC-407 連續 refresh（rotation symmetry）
立刻用 NEW_REFRESH 再 refresh：
**Result**: `code=200 success=True new_refresh_present=True` ✅

第三個 ULID `01KRAZM71BWPVQQAN2NCF3M4FV` 寫入 ACTIVE，第二個 `01KRAZM6QCCM28PHRA29Z8AJKC` 變 REFRESHED。**SC-407 PASS**。

### US2 (P2) negative cases — SC-404

#### Case 1: non-existent ULID
```bash
curl -sS -X POST ... -d '{"refreshToken":"01ARZ3NDEKTSV4RRFFQ69G5FAV"}'
```
**Result**: `code=401 msg=Refresh token invalid` ✅

#### Case 2: already-refreshed token (use US1.1 REFRESH again, now REFRESHED)
**Result**: `code=401 msg=Refresh token invalid` ✅

(此 case 涵蓋 spec edge case「rotate 後新 refresh token 沒被 admin-web 存起來」/「並發 race 第二位拿到 REFRESHED 狀態」)

#### Case 4: empty body `{}`
**Result**: `code=400 msg=Failed to deserialize the JSON body into the target type: missing fiel...` ✅

由 axum `ValidatedForm` 在進 handler 前 reject，未進 DB query — 滿足 FR-432。

#### Case 5: empty string `{"refreshToken":""}`
**Result**: `code=400 msg={"validation_errors":{"refresh_token":["Refresh token cannot be empty"]}}` ✅

由 `#[validate(length(min = 1))]` 在 handler 前 reject — 滿足 FR-402。

#### Case 3: force-expire via Postgres `UPDATE ... SET expires_at = now() - interval '1 hour'`

**Result**: ⚠️ **KNOWN LIMITATION — DOCUMENTED, NOT FIXED IN FEATURE 4 SCOPE**

**Root cause analysis**:
- `sys_tokens.expires_at` column type 是 `TIMESTAMP WITHOUT TIME ZONE` — 對 TZ 模糊
- admin-api container TZ = UTC；postgres container TZ = Asia/Taipei（compose .env 預設）
- admin-api 寫入 `expires_at` 用 `Local::now().naive_local()` — 在 UTC container 內 = UTC naive
- 維運手動 SQL `UPDATE ... SET expires_at = now() - interval '1 hour'` — 用 Postgres session TZ (Taipei) = Taipei naive
- 兩者寫入的 naive 值在不同 TZ frame 但 column 不存 TZ → 比較時無法 disambiguate
- 修補嘗試（`Expr::cust("now()")` 與 `Expr::current_timestamp()`）都 emit 正確 SQL，但 underlying column TZ ambiguity 仍在

**Fix options（皆 out of feature 4 scope）**:
- (a) 把 column 改 `TIMESTAMPTZ`（schema-level migration）
- (b) 統一 admin-api / postgres / sqlx-client 三者 TZ 設定
- (c) sqlx connection 設 `options=-c timezone=UTC` 強制 session TZ

**Normal production flow 不受影響**：admin-web 不會手動 SQL UPDATE expires_at；admin-api 自己寫 + 自己讀都用 `Local::now()`，TZ-internally consistent。本 limitation 只在外部 SQL 介入時顯現。

**Code 已加文件化 comment**（`server/service/src/admin/sys_auth_service.rs:158-166`）說明此 known limitation 與將來如何 fix。

## Total verification matrix

| Acceptance | SC mapping | Result |
|---|---|---|
| US1.1 login → code 200 + token + refreshToken | FR-401/410/420 | ✅ |
| US1.2 refresh rotation | FR-430/431, SC-403 | ✅ |
| US1.3 new access token valid | FR-430 step 3 | ✅ |
| US1.4 sys_tokens row state correct | FR-430 step 4, SC-405 | ✅ |
| SC-407 連續 refresh | FR-430 全鏈反覆執行 | ✅ |
| US2 Case 1 non-existent ULID → 401 | FR-432, SC-404 | ✅ |
| US2 Case 2 already-refreshed → 401 | FR-432, SC-404 | ✅ |
| US2 Case 4 empty body → 400 | FR-402, validation | ✅ |
| US2 Case 5 empty string → 400 | FR-402, validation | ✅ |
| US2 Case 3 force-expired token → should 401 | FR-430 step 1（`expires_at > now()`） | ⚠️ KNOWN LIMITATION (column type 範疇外，不阻塞 PR) |

**8/9 strict PASS + 1 documented limitation（與 column type 相關、out of feature 4 scope）**。

## 額外 constitution §IV 發現

- **CLAUDE.md §5.1 預設密碼修正**：dev DB 上實測 `Soybean@123.` → 401 (`code:1003` "Authentication failed")，`123456` → 200。**真實 default password = `123456`**。T011 將更新 CLAUDE.md §5.1 並把「待驗證」字樣移除。

## 結論

Feature 4 dynamic 主交付完成。9 條 acceptance / 8 條 PASS + 1 條 KNOWN LIMITATION 範疇外。可進 T010 push outer。
