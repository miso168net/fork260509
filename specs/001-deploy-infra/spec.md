# Feature Specification: deploy-infra（Docker Compose 編排 + nginx 反代 + .env 樣板）

**Feature Branch**: `001-deploy-infra`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "deploy-infra"

## Scope（依 constitution §III）

| 項目 | 說明 |
|---|---|
| 主題 | 整合部署基礎設施（outer 倉 `new-admin-root` 的 `deploy/` 目錄） |
| 涵蓋 GAP | **GAP-0e（CORS）** — 透過 nginx 同源反代「順帶」解決，不在 Rust 加 CorsLayer |
| 倉/層 | outer（`new-admin-root` 自身追蹤；不動 `admin-web/` 與 `admin-api/`） |
| 分組理由 | deploy/ 內所有檔案（compose、nginx、.env.example）同主題、同倉，符合 §III 例外條款（同主題同倉合併） |
| 不涵蓋 | admin-web 內 Dockerfile（**將由新增的 feature 7 admin-web-dockerfile 處理**，見 Clarifications Q1）、admin-api 的 envsubst 改造（feature 6）、admin-web env 對齊（feature 2）、admin-api response 對齊（feature 3）、refresh handler（feature 4） |

## Clarifications

### Session 2026-05-11

- Q: admin-web Dockerfile（multi-stage pnpm build → nginx serve）由哪個 feature 負責？ → A: C — 新增獨立 feature 7「admin-web-dockerfile」，排在 feature 5 後、feature 6 前。理由：主題單一（容器化）、單倉（admin-web）、符合 constitution §III 邊界（不跨倉、不跨主題）。本 feature 1 只負責 outer 端 compose.yaml 對該 Dockerfile 的引用契約。
- Q: 是否在本 feature 鎖定 production hardening（redis maxmemory / service memory/cpu limits / read-only fs 等）？ → A: A — 不涵蓋，與 INTEGRATION-PLAN §5.1 既有 compose.yaml 範例一致。理由：(1) 主題正交（本 feature 只負責「能跑起來」，hardening 是獨立關注點）；(2) admin tool 是內部低流量、預先設 limit 反而易誤殺；(3) 符合 constitution §III「最小 GAP」與全域 §2「Simplicity First」。如後續實際運行觀察到 OOM 或資源競爭，再開獨立 feature 處理。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator 可從 .env.example 一鍵起 dev 資料層 (Priority: P1)

新 operator 拿到 repo、依 README 指示，從 `deploy/.env.example` 複製成 `.env`、填完 secrets，即可在 5 分鐘內讓資料層（postgres + redis + migration）跑起來，並且 migration 已完成 13 張表 + 預設 seed 資料寫入。

**Why this priority**：deploy infra 的最低可驗證價值就是「資料層能起、migration 能跑」。這是後續所有 feature 驗證 acceptance（含 feature 2 admin-web env 對齊、feature 4 refresh handler）的前提。

**Independent Test**：
- 在乾淨環境執行 `cp .env.example .env`、填 secrets、`docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration`
- 執行 `docker compose ps` 看到 postgres/redis healthy、migration `Exited (0)`
- 執行 `docker compose exec postgres psql -U admin -d new_admin -c '\dt'` 看到 13 張 `sys_*` 表 + `casbin_rule`
- 執行 `psql ... -c "SELECT user_name FROM sys_user;"` 看到 3 個預設 user（Soybean / Administrator / GeneralUser）

**Acceptance Scenarios**:

1. **Given** 乾淨的 host 與已 clone 完成的 workspace（含 admin-api/ 內容），**When** operator 跑 `cp .env.example .env`、填 4 個必填 secrets（POSTGRES_PASSWORD / REDIS_PASSWORD / JWT_SECRET / TZ）、執行 `docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration`，**Then** 三個 service 在 60 秒內 healthy / Exited(0)、`sys_user` 有 3 筆 seed 資料。
2. **Given** `.env` 缺 `POSTGRES_PASSWORD`，**When** 跑 `docker compose up -d`，**Then** compose 回 `error: variable POSTGRES_PASSWORD is required` 而非靜默用空字串啟動。
3. **Given** infra 已起且乾淨，**When** 第二次跑 `docker compose run --rm migration`，**Then** migration 回 `nothing to do` 或同義訊息（idempotent，不會覆寫 seed）。

---

### User Story 2 - Compose 與 nginx 設定靜態驗證 (Priority: P1)

任何人（CI 或人工）能在不啟動實際容器的前提下，用 `docker compose config` 與 `nginx -t` 驗證 deploy/ 設定 syntactically valid，作為 PR review 的低成本第一道閘。

**Why this priority**：靜態驗證是 deploy infra 的最低可信度保證。實際啟動驗證需要完整的 Dockerfile 改造（feature 6 才完成），這個 feature 必須提供「就算 image 還沒對齊，至少 compose / nginx 文件本身是對的」這層保證。

**Independent Test**：
- `cd deploy && docker compose -f compose.yaml config -q`（exit 0）
- `cd deploy && docker compose -f compose.yaml -f compose.dev.yaml config -q`（exit 0）
- `docker run --rm -v $(pwd)/nginx:/etc/nginx/conf.d:ro nginx:1.27-alpine nginx -t`（回 `syntax is ok` + `test is successful`）

**Acceptance Scenarios**:

1. **Given** deploy/ 設定完成，**When** 跑 `docker compose -f compose.yaml config -q`，**Then** exit code = 0、stderr 無警告。
2. **Given** dev override 也完成，**When** 跑 `docker compose -f compose.yaml -f compose.dev.yaml config`，**Then** 輸出包含 postgres/redis/new-admin-rust-api 的 port mapping `0.0.0.0:5432`、`6379`、`10001`，且 new-admin-base-web 的 profile 為 `never`（dev 不啟）。
3. **Given** nginx conf 完成，**When** 用官方 nginx:1.27-alpine image 跑 `nginx -t`，**Then** 回報 `test is successful`。

---

### User Story 3 - Dev 模式為 admin-web vite 提供 API proxy 對接點 (Priority: P2)

開發人員在 host 跑 `pnpm dev`（admin-web vite dev server）時，能透過 `http://localhost:10001` 直連到 docker 內的 new-admin-rust-api，讓 vite proxy 規則 `/proxy-default → http://localhost:10001` 可用。

**Why this priority**：開發迭代速度的關鍵 — 沒有這個對接點，admin-web hot reload 無從測試 API 整合。但比 US1/US2 優先度低，因為實際 API 流量驗證要等 feature 6（new-admin-rust-api 啟動依賴 envsubst）。

**Independent Test**：
- `docker compose -f compose.yaml -f compose.dev.yaml ps` 顯示 new-admin-rust-api `0.0.0.0:10001->10001/tcp`
- 從 host 執行 `curl -I http://localhost:10001/health` 回 200（前提：feature 6 完成 envsubst 後，new-admin-rust-api 容器能成功啟動 — 此 acceptance 在 feature 6 spec 內驗）

**Acceptance Scenarios**:

1. **Given** dev compose stack 已起，**When** 從 host 跑 `nc -zv localhost 10001`，**Then** 連線成功（前提：new-admin-rust-api 容器已 healthy，依賴 feature 6）。
2. **Given** dev override 設定，**When** 看 `compose.dev.yaml`，**Then** new-admin-base-web 的 profile 是 `never`（dev 模式不需要起 nginx-ui，admin-web 走 host vite）。

---

### User Story 4 - Prod 模式對外只暴露 :8080 同源端口 (Priority: P2)

部署到生產環境的 operator 啟動完整 stack 後，host 上只有一個對外 port（`:8080`），所有 `/api/*` 流量透過 nginx 反代到內網 new-admin-rust-api，瀏覽器只看到一個 origin → CORS 自動消失（GAP-0e 解決）。

**Why this priority**：constitution §I 同源反代優先 + GAP-0e 修補 = 此 feature 的核心交付物之一。但比 US1/US2 優先度低，因為靜態驗證即可確認設定正確；實際 prod 啟動依賴 admin-web Dockerfile（不在本 scope）。

**Independent Test**：
- `docker compose -f compose.yaml config | grep -A2 ports:` 預期只有 `new-admin-base-web` 有 `0.0.0.0:8080:80` 一條，其他 service 全無 ports 段。
- nginx conf 包含 `location /api/ { proxy_pass http://new-admin-rust-api:10001/; ... }` 與 `location / { try_files $uri $uri/ /index.html; }` SPA fallback。

**Acceptance Scenarios**:

1. **Given** prod compose 設定，**When** 跑 `docker compose -f compose.yaml config --format json | jq '.services | map_values(.ports)'`，**Then** 只有 `new-admin-base-web` 的 ports 不為 null，其他全為 null。
2. **Given** nginx conf，**When** grep `proxy_pass`，**Then** 命中且指向 `http://new-admin-rust-api:10001/`（內網 service 名）。
3. **Given** nginx conf，**When** grep `Cors\|Access-Control`（CORS header 相關），**Then** 0 命中（不在 nginx 設 CORS — 同源不需要）。

---

### Edge Cases

- **`.env` 完全沒填**：compose 必須 fail fast，列出所有缺的必填變數（透過 `:?must set` 語法），而非啟動後再 crash。
- **同名 service 已存在於另一個 compose project**：`name: new-admin-root` 應確保隔離，避免誤連到別的 stack 的 postgres。
- **重複跑 migration**：必須 idempotent — 第二次 `migration up` 不應產生 duplicate seed 或更動既有資料。
- **redis 重啟資料遺失**：appendonly 必須開（`--appendonly yes`），volume 掛載 `/data` 確保 RDB/AOF 落地。
- **postgres data corruption / 升版**：`pg-data` volume 必須 named volume（不是 bind mount），讓 docker 管理；但同時要警示 operator 升 major 版需 dump/restore。
- **TZ 不一致**：postgres / redis / new-admin-rust-api 三個容器的 TZ 必須統一，避免 timestamp 寫入時錯位。
- **nginx 反代到 unhealthy new-admin-rust-api**：should `502 Bad Gateway`（預設行為），不應 hang。
- **Windows 換行**：deploy/ 內所有 yaml / conf / sh 必須 LF；CRLF 會讓 alpine container 內 sh script 報錯（constitution 跨平台相容條款）。

## Requirements *(mandatory)*

### Functional Requirements

#### 檔案存在與結構（FR-100 ~ FR-110）

- **FR-101**: `deploy/compose.yaml` MUST 存在且為 prod 主編排，定義 5 個 service：postgres、redis、migration、new-admin-rust-api、new-admin-base-web。
- **FR-102**: `deploy/compose.dev.yaml` MUST 存在且作為 dev override，把 postgres/redis/new-admin-rust-api 三個 port 暴露給 host（5432/6379/10001），並把 new-admin-base-web 的 profile 設為 `never`（dev 模式排除）。
- **FR-103**: `deploy/nginx/default.conf` MUST 存在，提供 `/api/*` 反代 + SPA fallback + 健康檢查 `/health`。
- **FR-104**: `deploy/.env.example` MUST 存在，列出所有 compose 引用的環境變數，必填項用註解標明，可選項給合理 default。
- **FR-105**: `deploy/.env` MUST 在 `.gitignore` 內（已由 outer .gitignore 處理 `.env.local`，需確認 `.env` 也在）。

#### 服務拓樸（FR-110 ~ FR-130）

- **FR-110**: postgres service MUST 用 `postgres:17.4-alpine`、healthcheck 用 `pg_isready`、資料 volume `pg-data`、TZ 注入。
- **FR-111**: redis service MUST 用 `redis:7.4-alpine`、`--requirepass` 從 env 讀、`--appendonly yes`、healthcheck 用 `redis-cli ping`、資料 volume `redis-data`。
- **FR-112**: migration service MUST 用 `restart: "no"`（init container 模型）、`depends_on: postgres healthy`、跑完 exit 0。
- **FR-113**: new-admin-rust-api service MUST 透過 env 注入 DATABASE_URL / REDIS_URL / JWT_SECRET / SERVER_HOST / SERVER_PORT / RUST_LOG / TZ；MUST 不在 prod compose 暴露任何 port（同源反代）；MUST 設 healthcheck（`wget /health`）；MUST `depends_on` postgres healthy + redis healthy + migration completed。
- **FR-114**: new-admin-base-web service MUST 用 `${WEB_PORT:-8080}:80` 對外暴露 port、MUST 是**唯一**對外有 ports 的 service。
- **FR-115**: 所有 service MUST 接到同一個 `admin-net` bridge network。
- **FR-116**: postgres + redis + migration + new-admin-rust-api 四個 service MUST 不在 prod compose.yaml 設定任何 `ports:` 段（內網互通即可）。

#### nginx 反代（FR-120 ~ FR-129）

- **FR-120**: nginx conf MUST listen 80 並 set root `/usr/share/nginx/html`。
- **FR-121**: `location /api/` MUST `proxy_pass http://new-admin-rust-api:10001/`（注意尾巴斜線：strip `/api/` 前綴）。
- **FR-122**: nginx MUST 設定下列 5 個 `proxy_set_header`：`Host`、`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto`、`X-Request-Id`，讓 Rust 端可拿到原始 client 資訊（cf. `contracts/nginx-routes.md` § 反代 Header 注入）。
- **FR-123**: `location /` MUST 走 SPA fallback (`try_files $uri $uri/ /index.html`)，避免 history mode router refresh 404。
- **FR-124**: `location = /health` MUST 直接 `return 200 "ok\n"`、`access_log off`，給 docker healthcheck 用。
- **FR-125**: nginx MUST **不**設定任何 `Access-Control-*` header — CORS 由同源解決，違反即違反 constitution §I。
- **FR-126**: 靜態資源（css/js/img/font）MUST 設 `expires 30d` 與 `Cache-Control: public, immutable`。
- **FR-127**: gzip MUST 啟用，至少涵蓋 `text/css`、`application/javascript`、`application/json`、`text/html`、`image/svg+xml`。

#### 環境變數樣板（FR-130 ~ FR-139）

- **FR-130**: `.env.example` MUST 用顯式的「必填」「可選」分組註解標明欄位語意。
- **FR-131**: 必填欄位（POSTGRES_PASSWORD / REDIS_PASSWORD / JWT_SECRET）MUST 在 compose.yaml 用 `${VAR:?must set VAR}` 語法強制。
- **FR-132**: 可選欄位（POSTGRES_DB / POSTGRES_USER / WEB_PORT / TZ / RUST_LOG / JWT_EXPIRE / DATABASE_MAX_CONNECTIONS / VITE_APP_TITLE / VITE_AUTH_ROUTE_MODE / VITE_STATIC_SUPER_ROLE）MUST 用 `${VAR:-default}` 給安全 fallback。
- **FR-133**: `.env.example` MUST 不包含真實 secret（POSTGRES_PASSWORD 用 `change-me-strong-password` 之類提示字串）。
- **FR-134**: TZ MUST 由 operator 顯式指定（compose 用 `${TZ:?must set TZ}`，**無 default fallback**）；建議值 `Asia/Taipei`。理由：跨地區部署的 log timestamp 對齊與 postgres TIMESTAMP 行為一致性無法依賴隱式預設（cf. `contracts/env-variables.md` § 必填變數 + 「為何 TZ 改必填」段）。

#### 跨平台與相容（FR-140 ~ FR-149）

- **FR-140**: deploy/ 下所有檔案 MUST 用 LF 換行（Linux/Windows 共通）。
- **FR-141**: deploy/ MUST 不使用 symlink（依 constitution 跨平台相容）。
- **FR-142**: compose.yaml MUST 不依賴 docker compose 特定 plugin（如 swarm overlay network）— 標準 compose v2 即可。

### Key Entities *(deploy 設定的概念實體)*

- **deploy/ 目錄**：本 feature 唯一新增的 outer 倉目錄，集中所有部署設定。歸屬：outer（new-admin-root）。
- **compose.yaml（prod 主編排）**：定義 5 service、networks、volumes，是 production deploy 的唯一真相源。
- **compose.dev.yaml（dev override）**：依 docker compose merge 規則疊加在 compose.yaml 上，僅修改 ports 與 profiles。
- **nginx/default.conf**：UI 容器內的 reverse proxy 設定，是「同源 = 解 CORS」的物理體現。
- **.env.example**：env 變數宣告與 fallback 文件，operator 入口。
- **admin-net network**：所有 service 內網互通的 bridge network，名稱固定。
- **pg-data / redis-data volumes**：postgres / redis 資料持久化的 named volume。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 新 operator 從拿到 repo 到完成「資料層 healthy + migration 完成 + 13 張表存在 + 3 個 seed user 存在」全流程 ≤ 10 分鐘（含填 .env、`docker compose up`、驗證查詢）。
- **SC-002**: `docker compose -f compose.yaml config -q` 與 `docker compose -f compose.yaml -f compose.dev.yaml config -q` 兩個指令 exit code 0、stderr 無 WARN/ERROR。
- **SC-003**: `nginx -t` 對 `default.conf` 回 `syntax is ok` 與 `test is successful`、stderr 無警告。
- **SC-004**: 第一次 migration 完成總耗時 ≤ 30 秒（postgres healthy 後到 migration container exit 0），第二次重跑 ≤ 5 秒（idempotent 快路徑）。
- **SC-005**: prod compose（不疊 dev override）跑起來後，`docker compose ps --format json | jq '.[].Publishers'` 顯示**只有** new-admin-base-web 有非空 publisher list，其他四個 service 全部 null/[]。
- **SC-006**: nginx 反代回應 `/api/health` 的 round-trip latency ≤ 50ms（local docker network；前提：feature 6 完成後再驗）。
- **SC-007**: `.env.example` 列出的必填變數數量 ≤ 4（最少摩擦），可選變數數量 ≥ 8（覆蓋常見調整需求）。
- **SC-008**: 對外 attack surface = 1 個 port（`:8080`）— `nmap -p 1-65535 localhost` 在 prod 模式下只應命中 8080（前提：admin-web image 可 build，依賴後續 feature）。

## Assumptions

### 設計假設（自我決策、無需 clarify）

- 採 **A. 單機 docker-compose** 部署拓樸（INTEGRATION-PLAN §1.4 推薦起手）；K8s/HA/traefik 等選項超出範圍。
- 反向代理選 **A. nginx**（INTEGRATION-PLAN §1.2 推薦），非 caddy/traefik。
- DB 連線層**不放 pgbouncer**（admin app 流量低，Sea-ORM 自帶 pool 夠用 — 依 INTEGRATION-PLAN §1.1）。
- migration 採 **init container** 模型（一次性 run + exit 0），非 sidecar 也非 entrypoint 內注入。
- volume 用 **named volume**（pg-data、redis-data），非 bind mount（避免 host 路徑與權限問題）。
- 預設 timezone `Asia/Taipei`（依 CLAUDE.md / INTEGRATION-PLAN 慣例）。

### 對其他 feature 的依賴（明列以利 plan 階段排序）

- **依賴 feature 6 (dockerfile-envsubst)**：new-admin-rust-api 容器要能成功啟動，需要 admin-api 的 Dockerfile 改造為 envsubst template + entrypoint.sh + application.yaml.tpl。本 feature 只負責 outer 端設定正確；new-admin-rust-api 容器啟動的 acceptance 屬 feature 6。
- **依賴 feature 7 (admin-web-dockerfile，新增)**：new-admin-base-web image 的 multi-stage Dockerfile（pnpm build → nginx serve，INTEGRATION-PLAN §5.4）將由新增的 feature 7 處理，排在 feature 5 後、feature 6 前。本 feature 範圍只到「compose.yaml 引用該 Dockerfile + nginx/default.conf 透過 build context COPY 進 image」的契約面；prod 模式完整啟動的 acceptance 屬 feature 7。**roadmap 由 6-feature 擴為 7-feature**（待同步更新 `docs/INTEGRATION-CHECKLIST.md`）。
- **不涵蓋 GAP-0a~0d、GAP-0f、GAP-1~4**：屬 features 2/3/4/5。

### 待驗證的上游慣例（依 constitution §IV）

- [ ] 預設管理員密碼是 `Soybean@123.`（CLAUDE.md §5 待驗證項；本 feature US1 acceptance 會經由 `psql ... SELECT user_name FROM sys_user` 順帶驗到 user 存在，但密碼本身要等 feature 2/3 login flow 完成才能驗）。
- [ ] Sea-ORM migration 是 idempotent（重跑不報錯不覆寫 seed）— 本 feature US1 acceptance scenario #3 直接驗證。
- [ ] postgres/redis 的 healthcheck 條件（`pg_isready` / `redis-cli ping -a $PASSWORD`）能在 60 秒內穩定回 healthy — 本 feature 啟動時驗。
- [ ] `name: new-admin-root` 在 compose 內能避免與其他 stack 同名 service 撞名 — 本 feature 用乾淨環境驗。

### 不在範圍

- TLS / HTTPS（單機內網部署，外部 TLS 由前置 cloud LB / cloudflare 處理；INTEGRATION-PLAN §1.4 選項 B 是未來擴充路徑）。
- 多環境 secret 管理（vault / SOPS / docker secret）— 預期 operator 直接管理 `.env`。
- CI workflow（INTEGRATION-PLAN §8 範圍，獨立 feature）。
- 監控 / log aggregation（grafana / loki / prometheus）— 未來擴充。
- backup / DR（pg_dump 排程、redis snapshot 上傳）— 未來擴充。
- **Production hardening**（依 Clarifications Q2 = A）：redis maxmemory / eviction policy、service memory/cpu limits、read-only filesystem、capability drop、ulimit、health 失敗重啟次數等，皆不在本 feature 內鎖定。實際運行觀察後若有需求，獨立 feature 處理。
