# Quickstart: deploy-infra

**Feature**: `001-deploy-infra`
**Audience**: 新 operator（拿到 repo 第一次部署）+ 後續 feature 的開發人員
**Estimated Time**: dev 模式 ~10 分鐘 / prod 模式 ~15 分鐘（前提：features 6 + 7 完成）

> 本 quickstart 涵蓋 **本 feature 範圍內**（infra 層）。完整 7 條 API smoke test 屬 INTEGRATION-PLAN §6.4，跨 feature 範圍，本檔不涵蓋。

---

## 0. 前置條件

```bash
# 1. Docker Compose v2.20+
docker compose version
# 預期：Docker Compose version v2.20.x 以上

# 2. 在 outer repo 工作區根
cd /path/to/fork260509
git submodule status
# 預期兩行行首皆空格（admin-web / admin-api 都 clean、SHA 對齊）

# 3. 已 pull 最新 admin-api / admin-web 內容
git submodule update --init --recursive
```

---

## 1. Dev 模式（資料層 + new-admin-rust-api，admin-web 走 host vite）

### 1.1 設定 .env

```bash
cd deploy
cp .env.example .env
$EDITOR .env
```

填入 4 個必填變數：
- `POSTGRES_PASSWORD` — 自選強密碼
- `REDIS_PASSWORD` — 自選強密碼
- `JWT_SECRET` — ≥ 32 字元隨機（建議 `openssl rand -base64 48`）
- `TZ` — IANA tz（如 `Asia/Taipei`）

### 1.2 起資料層（postgres + redis）

```bash
docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis
```

等 60 秒內健康：

```bash
docker compose -f compose.yaml -f compose.dev.yaml ps
# postgres / redis 兩列 STATUS 應為 "healthy"
```

### 1.3 跑 migration（init schema + seed）

```bash
docker compose run --rm migration
# 預期 stdout 含「Migrate up」之類，最後 Exited (0)
```

驗證 schema + seed：

```bash
# 13 張表應全部就位
docker compose exec postgres psql -U admin -d new_admin -c '\dt'

# 3 個預設 user
docker compose exec postgres psql -U admin -d new_admin \
  -c "SELECT username FROM sys_user ORDER BY username;"
# 預期 3 筆：Administrator / GeneralUser / Soybean
```

### 1.4 起 new-admin-rust-api（依賴 feature 6 完成）

> ⚠️ feature 6 (`dockerfile-envsubst`) 完成後才能跑此步。當前若直接起，application.yaml hardcode 的 DB URL 不指向 docker postgres，會啟動失敗。

```bash
docker compose -f compose.yaml -f compose.dev.yaml up -d new-admin-rust-api
docker compose -f compose.yaml -f compose.dev.yaml logs -f new-admin-rust-api
# 等到 "axum listening on 0.0.0.0:10001"
```

驗證 host 可連到：

```bash
nc -zv localhost 10001
# 預期：connection succeeded
curl -s http://localhost:10001/health
# 預期：ok
```

### 1.5 起 admin-web（host 端 vite，依賴 features 2/5/7 完成才完整）

```bash
cd ../admin-web
pnpm install
pnpm dev
# vite 跑在 :9527 / :9528（依 admin-web vite config）
# vite proxy 把 /proxy-default 反代到 http://localhost:10001
```

開瀏覽器到 vite dev server URL，預期能看到 admin-web SPA。

---

## 2. Prod 模式（依賴 features 6 + 7 完成）

### 2.1 完整啟動

```bash
cd deploy
cp .env.example .env && $EDITOR .env  # 填必填變數
docker compose build --pull            # build admin-api 與 admin-web image
docker compose up -d                   # 起全部 5 個 service
docker compose ps                      # 等 healthcheck 全綠
```

### 2.2 對外 attack surface 驗證

```bash
# 應只看到 :8080
docker compose ps --format json \
  | jq -r '.[] | select(.Publishers != null) | .Service + ": " + (.Publishers | tostring)'
# 預期單行：new-admin-base-web: [..."HostPort":8080...]
```

### 2.3 訪問

```bash
curl -s http://localhost:8080/health
# 預期：ok（nginx /health endpoint）

# Browse:
open http://localhost:8080   # macOS
xdg-open http://localhost:8080  # Linux
```

完整 7 條 API smoke test 見 INTEGRATION-PLAN §6.4。

---

## 3. 排錯指引

### 3.1 靜態驗證（任何時候都該先跑）

```bash
# Compose syntactically valid
docker compose -f deploy/compose.yaml config -q
docker compose -f deploy/compose.yaml -f deploy/compose.dev.yaml config -q

# Nginx conf valid
docker run --rm -v "$(pwd)/deploy/nginx:/etc/nginx/conf.d:ro" \
  nginx:1.27-alpine nginx -t
```

### 3.2 常見問題

| 症狀 | 可能原因 | 對策 |
|---|---|---|
| `docker compose up` 報 `variable POSTGRES_PASSWORD is required` | `.env` 沒填或不存在 | `cp .env.example .env && $EDITOR .env` |
| postgres healthcheck 一直 unhealthy | password 含特殊字元未轉義 / 5432 port 衝突（host 上有別的 postgres） | 改密碼、`docker compose -f compose.dev.yaml down`、檢查 `lsof -i :5432` |
| migration `Exited (1)` | DB 連不上 / migration code bug（admin-api 倉） | `docker compose logs migration`；DB 連不上 → 檢查 postgres healthy 與 .env DATABASE_URL；code bug 上報 admin-api 倉 |
| new-admin-rust-api 啟動 panic「config not found」 | feature 6 envsubst 未完成 / `.env` 缺變數 | 等 feature 6 merge；補 .env |
| nginx 反代回 502 | new-admin-rust-api 還沒 healthy / DNS resolve 失敗 | `docker compose ps` 看 new-admin-rust-api 狀態；`docker compose exec new-admin-base-web nslookup new-admin-rust-api` |
| postgres 升 major 版起不來 | 17 → 18 data dir 不向後兼容 | `docker volume rm new-admin-root_pg-data`（**毀資料**！）或先 `pg_dumpall` 後 restore |
| Windows host 上 alpine container 報 `^M: not found` | git autocrlf 把 LF → CRLF | 確認 outer repo 有 `.gitattributes` 鎖 LF；重 checkout：`git rm --cached -r . && git reset --hard` |
| `git submodule status` 行首 `+` | worktree HEAD 超前 outer pin | 兩段 commit 第二段沒做：`git add admin-api admin-web && git commit -m "chore(submodule): bump ..."` |

### 3.3 完全重置 dev 環境

```bash
docker compose -f deploy/compose.yaml -f deploy/compose.dev.yaml down -v
# -v 會刪掉 pg-data + redis-data volume，等於 zero state 從頭來
```

---

## 4. 進階用法

### 4.1 從 host 連 dev DB（DBeaver / psql）

```bash
psql -h localhost -p 5432 -U admin -d new_admin
# 密碼為 .env 內 POSTGRES_PASSWORD
```

### 4.2 從 host 連 dev redis

```bash
redis-cli -h localhost -p 6379 -a "$(grep ^REDIS_PASSWORD deploy/.env | cut -d= -f2)" ping
# 預期：PONG
```

### 4.3 跑 new-admin-rust-api 的 host cargo watch（完全跳過 docker）

```bash
cd admin-api
DATABASE_URL=postgres://admin:$POSTGRES_PASSWORD@localhost:5432/new_admin \
REDIS_URL=redis://:$REDIS_PASSWORD@localhost:6379/0 \
JWT_SECRET=$JWT_SECRET \
SERVER_HOST=0.0.0.0 SERVER_PORT=10001 \
cargo watch -x 'run -p server'
```

> 此模式下 `docker compose up new-admin-rust-api` 不要起（避免兩個 process 搶 :10001 port）。

---

## 5. 後續 features 的接續路徑

本 feature 完成後，建議實施順序：

1. **本 feature (deploy-infra)** ✅
2. **gap-0ab0f-frontend-env-and-login**：admin-web `.env.dev` / `.env.prod` + login body field 對齊
3. **gap-0cd-rust-output-camel**：admin-api response serialize camelCase
4. **驗 login flow**（含 §IV 預設密碼驗證）
5. **gap-1-refresh-handler**：admin-api refresh token endpoint（含 sys_tokens.expires_at migration）
6. **admin-web-cleanup**：GAP-2/3/4
7. **admin-web-dockerfile**：admin-web multi-stage Dockerfile（解鎖 prod 完整啟動）
8. **dockerfile-envsubst**：admin-api Dockerfile envsubst 收尾

prod 模式完整 smoke test（INTEGRATION-PLAN §6.4 七條 API）在第 8 個 feature 完成後執行。
