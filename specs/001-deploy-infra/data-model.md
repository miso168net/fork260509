# Phase 1 Data Model: deploy-infra（部署拓樸實體）

**Feature**: `001-deploy-infra`
**Date**: 2026-05-11

> 本檔記錄部署層的 service / volume / network 拓樸實體，**不是** application data model（feature 1 不動程式碼）。資料庫 schema 與 application entity 由 admin-api 倉維護，本 feature 只透過 migration init container 觸發其建立。

---

## 1. Service Entities

| ID | Service Name | Image | 對外 Port (prod) | 對外 Port (dev override) | Restart Policy | Healthcheck | depends_on |
|---|---|---|---|---|---|---|---|
| S1 | `postgres` | `postgres:17.4-alpine` | — | `5432:5432` | `unless-stopped` | `pg_isready` 10s/5s/10/30s | — |
| S2 | `redis` | `redis:7.4-alpine` | — | `6379:6379` | `unless-stopped` | `redis-cli ping` 10s/5s/10/5s | — |
| S3 | `migration` | build from `../admin-api/Dockerfile` (target=build) | — | — | `"no"`（init container） | — | postgres: `service_healthy` |
| S4 | `admin-rust-api` | build from `../admin-api/Dockerfile` | — | `10001:10001` | `unless-stopped` | `wget /health` 15s/5s/5/30s | postgres: healthy / redis: healthy / migration: completed_successfully |
| S5 | `admin-base-web` | build from `../admin-web/Dockerfile`（feature 7 提供） | `${WEB_PORT:-8080}:80` | profile=`never`（dev 不啟） | `unless-stopped` | （nginx HEALTHCHECK 在 Dockerfile，feature 7 內建） | admin-rust-api: healthy |

**Service 屬性說明**：
- **healthcheck 格式** `interval/timeout/retries/start_period`，源自 `research.md R2`。
- **restart policy** 統一 `unless-stopped`（admin-rust-api / admin-base-web / postgres / redis），唯獨 migration 用 `"no"`（依 R1 init container 模型）— spec FR-112 已鎖。
- **build context**：S3 / S4 從 `../admin-api/`、S5 從 `../admin-web/`。compose.yaml 在 `deploy/` 下，故 context 用 `..` 上溯一層到 outer repo 根 → 進 admin-api / admin-web worktree（這兩個是 git worktree + submodule，runtime 是普通目錄）。

---

## 2. Volume Entities

| ID | Volume Name | Driver | Mount Target | Service | 用途 | 持久化保證 |
|---|---|---|---|---|---|---|
| V1 | `pg-data` | local（compose 預設） | `/var/lib/postgresql/data` | S1 postgres | postgres 全域資料（schema + seed + 之後新增資料） | `docker volume rm` 才會刪 |
| V2 | `redis-data` | local | `/data` | S2 redis | redis AOF + RDB（appendonly mode） | 同上 |

**Volume 變更政策**：
- 升 postgres major 版（17 → 18）需 `pg_dumpall` 後重建 volume，**不能直接掛舊 volume 起新 image**（postgres data dir 不向後兼容）。寫入 `quickstart.md` 排錯段。
- redis 升版同 image family（7.x）資料相容；跨 major 版需先 `BGSAVE` 再升。

---

## 3. Network Entity

| ID | Network Name | Driver | Scope | 連接的 Service |
|---|---|---|---|---|
| N1 | `admin-net` | `bridge` | local（單 host） | S1 / S2 / S3 / S4 / S5 全部 |

**DNS 解析行為**（依 research.md R3）：
- docker embedded DNS（`127.0.0.11`）為每個 service 註冊 short name + `<service>.admin-net` FQDN。
- 跨 service 通訊用 service name（如 `postgres:5432`、`admin-rust-api:10001`），**不寫 IP**。

---

## 4. Service-to-Service Dependency Graph

```
postgres (healthy) ──┬──> migration (completed) ──> admin-rust-api (healthy) ──> admin-base-web
redis (healthy) ─────┘                              ↑
                                                    │ (內網互通)
                                          (postgres / redis 直連)
```

**邊（dependency edges）**：

| From | To | Condition | 說明 |
|---|---|---|---|
| migration | postgres | service_healthy | migration 必須等 DB 就緒才能跑 schema |
| admin-rust-api | postgres | service_healthy | runtime DB 連線 |
| admin-rust-api | redis | service_healthy | runtime cache / token store |
| admin-rust-api | migration | service_completed_successfully | schema 必須先建好 |
| admin-base-web | admin-rust-api | service_healthy | nginx 反代目標就緒才開放對外（避免大量 502） |

---

## 5. Build Context 來源（gitlink / submodule pin 對齊）

| Service | Build Context Path | git submodule pin（HEAD） |
|---|---|---|
| migration | `../admin-api` | `42fb7b37a03d68a257b97bcc1a883ba96f26aa7f` 或更新（feature 4/6 推進後變動） |
| admin-rust-api | `../admin-api` | 同上 |
| admin-base-web | `../admin-web` | `40e9764a83f8b1d4f59cc8aba1b6dd7bb7b8887a` 或更新（feature 2/5/7 推進後變動） |

**重要**：build 行為依賴**當前 outer repo 看到的 submodule pin 對應 commit**。CI 應在 `git checkout --recurse-submodules` 後 build，避免拿到舊版 source。

---

## 6. Validation Rules（部署層）

| Rule | 對應 spec FR / SC | 驗證方式 |
|---|---|---|
| Service name 全小寫、`-` 分隔 | spec FR-101 | yaml linter / docker compose config |
| Image tag 鎖到 minor 版（不用 `latest`） | spec FR-110/111 + 慣例 | `grep -E "image:.*:latest" deploy/compose.yaml` 必須 0 命中 |
| 必填變數（POSTGRES_PASSWORD / REDIS_PASSWORD / JWT_SECRET）用 `:?` | spec FR-131 | `grep -E '\$\{[A-Z_]+:\?' deploy/compose.yaml \| wc -l` ≥ 3 |
| 可選變數用 `:-` | spec FR-132 | 對 spec.md FR-132 列出的每項變數做 `grep -F ":${key}:-"` 命中 |
| prod 模式對外 port 數 = 1 | spec FR-114/116 + SC-005 | `docker compose -f compose.yaml config --format json \| jq '[.services[].ports // empty \| flatten] \| flatten \| length'` = 1 |
| dev override 暴露 5432 / 6379 / 10001 | spec US3 + R6 | `docker compose -f compose.yaml -f compose.dev.yaml config --format json \| jq '[.services[].ports // empty \| flatten[]]'` 應包含這三組 mapping |
| 所有 service 接到 admin-net | spec FR-115 | `docker compose config --format json \| jq '.services \| map_values(.networks \| keys)'` 全部含 `admin-net` |

---

## 7. State Transitions（compose 啟動 lifecycle）

```
[stopped] ──compose up──> [creating] ──> [starting]
                                          │
                                          ▼
[postgres / redis] ──pg_isready / ping──> [healthy]
                                          │
                                          ▼
[migration] ──cargo run -p migration──> [exited 0]
                                          │
                                          ▼
[admin-rust-api] ──wget /health──> [healthy]
                                          │
                                          ▼
[admin-base-web] ──nginx HEALTHCHECK──> [healthy]
                                          │
                                          ▼
[stack ready]   ←── operator 此時可從 host 訪問 :8080
```

**異常路徑**：
- postgres healthcheck 重試 10 次後仍 unhealthy → migration 不啟、後續鏈條斷 → operator 看 `docker compose logs postgres` 找原因（密碼錯 / volume 損毀 / port 衝突）。
- migration `Exited 1` → admin-rust-api 不啟 → operator 看 `docker compose logs migration` 找 schema 錯誤（多半是 admin-api 倉的 migration code bug）。
- admin-rust-api healthcheck 失敗 → admin-base-web 不對外 → operator 看 `docker compose logs admin-rust-api` 找 panic / config 錯誤（多半是 envsubst 沒就位、應已由 feature 6 處理）。

---

**Output 完成**：5 個 Service entity / 2 個 Volume / 1 個 Network / 5 條 dependency edge / 7 條 validation rule / 1 個 lifecycle state machine。
