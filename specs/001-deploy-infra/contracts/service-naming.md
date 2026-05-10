# Contract: Service Naming（admin-net 內 service name DNS）

**Feature**: `001-deploy-infra`
**Producers**: `deploy/compose.yaml`（service 定義）
**Consumers**: nginx conf（反代 target）、admin-rust-api 環境變數（DATABASE_URL / REDIS_URL）、migration（depends_on）

> 本契約鎖定 `admin-net` 網路內 5 個 service 的穩定 short name，作為跨 feature 的命名邊界。違反此契約 = 違反 spec FR-101 / FR-115。

---

## Stable Service Names（不可破壞性變更）

| Service Name | 是什麼 | 用途 | 內部 port | 外部 port (prod) | 外部 port (dev override) |
|---|---|---|---|---|---|
| `postgres` | PostgreSQL 資料庫 | 應用資料持久化、Casbin policy 持久化 | 5432 | 不暴露 | 5432:5432 |
| `redis` | Redis cache / token store | session、refresh token、CAS lock | 6379 | 不暴露 | 6379:6379 |
| `migration` | Sea-ORM migration init container | 一次性 schema + seed | — | 不暴露 | 不暴露 |
| `admin-rust-api` | Rust + axum 後端 | API 主服務 | 10001 | 不暴露 | 10001:10001 |
| `admin-base-web` | nginx + 靜態 dist + reverse proxy | 對外唯一入口 | 80 | `${WEB_PORT:-8080}:80` | profile=`never`（不啟） |

**重要**：service name = **長名**（與 git branch / docker image tag 同樣用 `new-admin-base-web` / `new-admin-rust-api` 慣例）。本契約使用 `admin-base-web` / `admin-rust-api` 是出於 compose v2 service name 慣例（不前綴 `new-`），**避免與短名 admin-web / admin-api 混淆但與長名一致**。

> 命名分工依 CLAUDE.md §1：
> - **檔案層面用短名**：`admin-web/`、`admin-api/`（worktree 目錄）
> - **服務層面用長名**：`admin-base-web`、`admin-rust-api`（compose service / git branch / image tag）
> - 本契約屬服務層面 → 用長名變體。

---

## DNS Resolution（admin-net 內）

每個 service 在 admin-net 內可被以下名稱解析（依 research.md R3）：

```
<service>             # short name，最常用
<service>.admin-net   # FQDN
```

範例（從 admin-rust-api container 內看）：
```bash
$ getent hosts postgres
172.18.0.2      postgres.admin-net postgres

$ getent hosts redis
172.18.0.3      redis.admin-net redis
```

---

## Cross-Service Reference Patterns

### 1. nginx → admin-rust-api

```nginx
location /api/ {
    proxy_pass http://admin-rust-api:10001/;
    # ... headers ...
}
```

**契約**：service name `admin-rust-api` + port `10001`，end of `/api/` 後的路徑以 `/` 為起點傳給上游（strip `/api/` 前綴）。

### 2. admin-rust-api → postgres

```
DATABASE_URL=postgres://${POSTGRES_USER:-admin}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-new_admin}
```

**契約**：host = `postgres`、port = `5432`，credentials 由 compose env 注入（不寫死）。

### 3. admin-rust-api → redis

```
REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
```

**契約**：host = `redis`、port = `6379`、db index = `0`。

### 4. migration → postgres

```yaml
migration:
  command: ["cargo", "run", "-p", "migration", "--", "up"]
  environment:
    DATABASE_URL: postgres://${POSTGRES_USER:-admin}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-new_admin}
  depends_on:
    postgres:
      condition: service_healthy
```

**契約**：跟 admin-rust-api 用同一個 DATABASE_URL pattern；只跑一次（`restart: "no"`）。

---

## 變更政策（Breaking Change）

修改任一 service name 視為 **breaking change**，必須：

1. 開新 spec（不能在現有 feature 內偷偷改）。
2. 同步修改所有 consumer：
   - nginx conf（`proxy_pass http://<new-name>:...`）
   - admin-rust-api 環境變數（DATABASE_URL / REDIS_URL）
   - 任何 docs / quickstart 引用
3. PR 必須在 title 標 `BREAKING:` 前綴。

例：未來若 `admin-rust-api` 改為 `admin-api-server`，需 nginx + admin-rust-api env + docs 三處同步。

---

## 為何不用容器化常見的 `app` / `db` / `cache` 短名？

- 跨 stack 撞名：`db` 在多 stack 機器上會混淆。
- 與 git branch / image tag 不一致：`new-admin-base-web` / `new-admin-rust-api` 已存在；compose service 用長名變體（去掉 `new-` 前綴避免冗長）保持一致脈絡。
- 違反「服務層面用長名」慣例（CLAUDE.md §1）。

---

## Validation（給 task 階段引用）

```bash
# 抽 5 個 service name 全部存在
for svc in postgres redis migration admin-rust-api admin-base-web; do
  docker compose -f deploy/compose.yaml config --services | grep -qx "$svc" \
    && echo "PASS: $svc 存在" \
    || echo "FAIL: $svc 缺失"
done

# nginx conf 反代到正確 service name
grep -E 'proxy_pass http://admin-rust-api:10001' deploy/nginx/default.conf \
  && echo "PASS: nginx → admin-rust-api:10001" \
  || echo "FAIL: nginx 反代 service name 不對"

# admin-net 涵蓋所有 service
test "$(docker compose -f deploy/compose.yaml config --format json | jq '[.services | to_entries[] | select(.value.networks | has("admin-net") | not)] | length')" -eq 0 \
  && echo "PASS: 所有 service 都接 admin-net" \
  || echo "FAIL: 有 service 未接 admin-net"
```
