# Quickstart: feature 8 timestamptz migration 套用流程

**Date**: 2026-05-11
**Feature**: `008-gap-tz-1-timestamptz-migration`

## 套用前檢查

1. 確認 `deploy/.env` 設 `TZ=Asia/Taipei`（per Phase 0 R1 假設）

   ```bash
   grep "^TZ=" deploy/.env
   # → 預期：TZ=Asia/Taipei
   ```

   若 TZ 不是 Asia/Taipei，**停止**並回報 — 本 feature USING clause hardcode Asia/Taipei、不對齊會引入 instant skew。

2. 確認 admin-api / admin-web 處於 worktree 模式

   ```bash
   ls -la admin-api/.git admin-web/.git
   # → 兩者應為 file（指向 .git/worktrees/）；若為 dir 則 worktree 已壞、需重建
   ```

3. （可選）備份 sys_tokens 既有 row 作 instant 對照

   ```bash
   docker exec new-admin-root-postgres-1 \
     psql -U admin -d new_admin -c \
     "COPY sys_tokens TO STDOUT WITH CSV HEADER" > /tmp/sys_tokens_before.csv
   ```

## 套用步驟（per implementation）

### Step 1: 切到 admin-api worktree、確認 inner branch

```bash
cd admin-api
git status          # 應在 new-admin-rust-api branch
git fetch origin
git pull            # 確認 HEAD 對齊 origin
cd ..
```

### Step 2: 套用 admin-api 改動（migration + entity + write paths）

依 tasks.md 完成下列改動：

- 新檔 `admin-api/migration/src/schemas/m20260512_000000_alter_sys_tokens_timestamptz.rs`（per contracts/migration-contract.md）
- 註冊到 `admin-api/migration/src/schemas/mod.rs`
- 改 `admin-api/server/model/src/admin/entities/sys_tokens.rs` 3 個 field（per contracts/entity-contract.md）
- 改 `admin-api/server/service/src/admin/sys_auth_service.rs:153`
- 改 `admin-api/server/service/src/admin/event_handlers/auth_event_handler.rs:51`
- 改 `admin-api/server/service/src/admin/events/access_token_event.rs`（struct field type + write site）

### Step 3: 編譯與單元測試

```bash
cd admin-api
cargo build -p server_model --all-features
cargo build -p server_service --all-features
cargo clippy --all-targets --all-features -- -D warnings
cargo test --workspace
cd ..
```

預期：全 pass。

### Step 4: 起動 compose stack（含 migration init container）

```bash
cd deploy
docker compose down -v        # 重起 stack 確保 migration service 從頭執行
docker compose up -d --build
docker compose logs migration  # 確認 migration service 完成（exit 0）
docker compose ps              # 確認 new-admin-rust-api 進入 healthy
cd ..
```

## 動態驗證（acceptance evidence 收集）

### Verify 1: Schema 確認（SC-001）

```bash
docker exec new-admin-root-postgres-1 \
  psql -U admin -d new_admin -c "\d sys_tokens"
```

預期輸出片段：

```
   Column    |           Type           | ...
-------------+--------------------------+---
 login_time  | timestamp with time zone | ...
 created_at  | timestamp with time zone | ...
 expires_at  | timestamp with time zone | ...
```

→ acceptance evidence: `acceptance-evidence/T0XX-schema.md`

### Verify 2: Login + Refresh functional flow（SC-002）

```bash
# 取 access + refresh token
curl -sS -X POST http://localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"123456"}' | tee /tmp/login.json

# 解出 refresh_token，refresh 一次
REFRESH=$(jq -r '.data.refreshToken' /tmp/login.json)
curl -sS -X POST http://localhost:8080/api/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH\"}" | tee /tmp/refresh.json
```

預期：兩個請求都 HTTP 200 + body 含 `accessToken/refreshToken`。

→ acceptance evidence: `acceptance-evidence/T0XX-functional.md`

### Verify 3: TZ-skew 反證測試（SC-003）

```bash
# 連入 postgres 容器、用兩個不同 session TZ 觀察同一 row
docker exec -it new-admin-root-postgres-1 psql -U admin -d new_admin <<'SQL'
\timing
SELECT id, refresh_token, expires_at, EXTRACT(EPOCH FROM expires_at) AS epoch_utc
  FROM sys_tokens WHERE status = 'ACTIVE' ORDER BY created_at DESC LIMIT 1;

SET TIME ZONE 'Asia/Taipei';
SELECT id, expires_at, EXTRACT(EPOCH FROM expires_at) AS epoch_after_taipei
  FROM sys_tokens WHERE status = 'ACTIVE' ORDER BY created_at DESC LIMIT 1;

SET TIME ZONE 'UTC';
SELECT id, expires_at, EXTRACT(EPOCH FROM expires_at) AS epoch_after_utc
  FROM sys_tokens WHERE status = 'ACTIVE' ORDER BY created_at DESC LIMIT 1;
SQL
```

預期：

- 3 次 SELECT 的 `epoch_utc / epoch_after_taipei / epoch_after_utc` 完全相等（同一 instant、Postgres 內部 UTC 儲存、只 render 不同）
- `expires_at` 文字格式：Asia/Taipei 顯示 `+08`、UTC 顯示 `+00`

→ acceptance evidence: `acceptance-evidence/T0XX-tz-skew-repro.md`

### Verify 4: 既有 row instant 不偏移（SC-004）

```bash
# 假設 Step 0 已備份 /tmp/sys_tokens_before.csv（含 expires_at naive 值）
# 從備份取一筆 expires_at（讀為 Asia/Taipei naive）轉成 UTC epoch
EPOCH_BEFORE=$(... 從 CSV 計算 ...)

# migration 套用後同 id 的 row epoch
EPOCH_AFTER=$(docker exec new-admin-root-postgres-1 psql -U admin -d new_admin -t -c \
  "SELECT EXTRACT(EPOCH FROM expires_at) FROM sys_tokens WHERE id = '<id>'")

# 預期 EPOCH_BEFORE == EPOCH_AFTER（差 0）
```

→ acceptance evidence: `acceptance-evidence/T0XX-row-instant-preserve.md`

### Verify 5: 其他 table 未受影響（SC-006）

```bash
docker exec new-admin-root-postgres-1 psql -U admin -d new_admin <<'SQL'
\d sys_user
\d sys_role
\d sys_login_log
SQL
```

預期：三表的 timestamp 欄位仍顯示 `timestamp without time zone`（FR-010 enforced）。

→ acceptance evidence: 同 T0XX-schema.md 一併附

## 兩段式 commit（per constitution §V）

### 第一段（admin-api worktree 內）

```bash
cd admin-api
git add migration/src/schemas/m20260512_000000_alter_sys_tokens_timestamptz.rs \
        migration/src/schemas/mod.rs \
        server/model/src/admin/entities/sys_tokens.rs \
        server/service/src/admin/sys_auth_service.rs \
        server/service/src/admin/event_handlers/auth_event_handler.rs \
        server/service/src/admin/events/access_token_event.rs
git commit -m "feat(admin-api): F8-T0XX sys_tokens TIMESTAMP→TIMESTAMPTZ + DateTimeWithTimeZone

- migration m20260512_000000：3 欄 ALTER TYPE 帶 USING ... AT TIME ZONE 'Asia/Taipei'
- entity sys_tokens.rs：login_time/created_at/expires_at → DateTimeWithTimeZone
- write-path 3 處：Local::now().naive_local() → Utc::now().fixed_offset()
- AccessTokenEvent.expires_at struct field 同步改型別
- 移除 sys_auth_service.rs:158-166 的 TZ-skew limitation inline comment

根治 retrospective 4-I1（TZ-skew silent prod risk）。
"
git push origin new-admin-rust-api
cd ..
```

### 第二段（outer repo 更新 SHA pin）

```bash
git add admin-api
git commit -m "chore(submodule): bump admin-api 到 <短SHA>: F8 timestamptz migration"
# git push 等用戶確認（per global CLAUDE.md §5）
```

## Rollback（dev only）

```bash
cd admin-api
cargo run -p migration -- down -n 1
# 注意：down 會把 3 欄 ALTER 回 TIMESTAMP（不帶 USING）
# 若 session TZ ≠ Asia/Taipei 會偏移既有 row instant；prod 不應 down
```

## 假設未通過時的處理

| 失敗情境 | 處理 |
|---|---|
| `deploy/.env` TZ ≠ Asia/Taipei | 停止套用、改 migration USING TZ 對齊實際設定後重試 |
| sys_tokens 中存在外部寫入的 row（無法追溯 TZ） | 個別 row 評估是否需 corrective UPDATE；本 feature 不處理（per spec Edge Cases） |
| migration ALTER 卡住超過 30 秒 | 可能 row 數量超預期、評估 lock + downtime；prod 場景需另 plan |
| cargo test workspace 有 unrelated fail | per constitution §III「禁止順手 refactor」、回報但不順手修 |
