---

description: "Tasks for feature 001-deploy-infra"
---

# Tasks: deploy-infra

**Input**: Design documents from `/specs/001-deploy-infra/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/ ✅、quickstart.md ✅

**Tests**: 本 feature 為 infrastructure feature（無 application code），「test」即各 acceptance scenario 的 docker / psql / curl 驗證指令。不另寫 unit test。

**Organization**: tasks 依 user stories 分組，每組可獨立交付與驗證。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可平行（不同檔、無依賴）
- **[Story]**: US1 / US2 / US3 / US4 對應 spec.md 的 user stories
- 路徑採 outer repo 工作區根 `fork260509/` 為基準

---

## Phase 1: Setup（共享基礎設施）

**Purpose**: 建立 outer 倉的 `deploy/` 目錄骨架。

- [ ] T001 在 outer 倉新增 `deploy/` 與 `deploy/nginx/` 目錄（`mkdir -p deploy/nginx`），確認以空 commit 或第一個 task 建檔時自然產生（git 不追蹤空目錄，本 task 不獨立 commit）

---

## Phase 2: Foundational（阻塞前置 — 所有 stories 依賴）

**Purpose**: 寫所有 user story 都會引用的共享產物（env 樣板、git 跨平台規則、roadmap 文件對齊）。

**⚠️ CRITICAL**: 本階段未完成前，所有 user story 任務不能啟動。

- [ ] T002 寫 `deploy/.env.example`，依 `contracts/env-variables.md` normative：4 個必填變數（POSTGRES_PASSWORD / REDIS_PASSWORD / JWT_SECRET / TZ，含 `change-me-*` 提示）+ 10 個可選變數（POSTGRES_DB / POSTGRES_USER / WEB_PORT / RUST_LOG / JWT_EXPIRE / JWT_ISSUER / DATABASE_MAX_CONNECTIONS / VITE_APP_TITLE / VITE_AUTH_ROUTE_MODE / VITE_STATIC_SUPER_ROLE，附 default + 用途註解）；分區註解清楚標「必填」「可選」。
- [ ] T003 [P] 確認 outer 倉 `.gitignore` 已涵蓋 `.env`（line 61-63 已存）；補一行 `deploy/.env`（精確 path 防護），並驗證 `git check-ignore deploy/.env` 命中。
- [ ] T004 [P] 在 outer 倉根新增 `.gitattributes`，鎖 `*.sh` / `*.conf` / `*.yaml` / `*.yml` / `deploy/.env.example` 為 LF（依 research.md R7）；包含 `* text=auto eol=lf`。
- [ ] T005 [P] 同步 `docs/INTEGRATION-CHECKLIST.md`：roadmap 由 6-feature 改為 7-feature，加入 feature 7 `admin-web-dockerfile`（admin-web 倉、multi-stage Dockerfile、依賴 features 2/5 完成、為 features 1 prod 模式啟動的前置條件），並調整建議實施順序。

**Checkpoint**: Foundation 完成，可開始 user story 任務。

---

## Phase 3: User Story 1 - Dev 資料層能起 (Priority: P1) 🎯 MVP

**Goal**: 新 operator 從拿到 repo 起 5-10 分鐘內讓 postgres + redis + migration 三件 service 跑起來，並驗證 13 張表 + 3 個預設 user 寫入。

**Independent Test**:
```bash
cd deploy && cp .env.example .env && $EDITOR .env  # 填 4 個必填
docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration
docker compose ps                                   # postgres/redis healthy、migration Exited(0)
docker compose exec postgres psql -U admin -d new_admin -c '\dt'                       # ≥ 13 張 sys_* + casbin_rule
docker compose exec postgres psql -U admin -d new_admin -c "SELECT user_name FROM sys_user;"  # 3 列
```

### Implementation for User Story 1

- [ ] T006 [US1] 在 `deploy/compose.yaml` 寫頂層骨架 + postgres/redis/migration 三 service：包含 `name: new-admin-root`、`networks: admin-net (bridge)`、`volumes: pg-data, redis-data`（依 data-model.md §2/§3）、postgres service（image `postgres:17.4-alpine`、healthcheck `pg_isready` 10/5/10/30、volume mount、env POSTGRES_*、network admin-net）、redis service（image `redis:7.4-alpine`、`command: ["redis-server","--requirepass","${REDIS_PASSWORD:?must set REDIS_PASSWORD}","--appendonly","yes"]`、healthcheck `redis-cli -a $REDIS_PASSWORD ping` 10/5/10/5、volume mount、network）、migration service（build context `../admin-api` target=build、command `cargo run -p migration -- up`、env DATABASE_URL、`depends_on postgres: service_healthy`、`restart: "no"`、network）。
- [ ] T007 [US1] 在 `deploy/compose.dev.yaml` 寫 dev override 對 postgres/redis：`name: new-admin-root-dev`、`postgres.ports: ["5432:5432"]`、`redis.ports: ["6379:6379"]`（依 INTEGRATION-PLAN §5.2 + research.md R6）。
- [ ] T008 [US1] 跑 dev 模式 acceptance（spec US1 acceptance scenarios 1-3 + R4 idempotency 部分）：`cp .env.example .env` + 填必填變數 + `docker compose -f compose.yaml -f compose.dev.yaml up -d postgres redis migration` + 驗 healthy/Exited(0) + `psql ... \dt` 計數 ≥ 13 + `psql ... SELECT count(*) FROM sys_user` = 3 + 第二次 `migration up` 驗 idempotent（user 數仍 = 3、表數不變）。把 stdout 截錄存到 commit message body 或新增 `specs/001-deploy-infra/acceptance-evidence/us1.md`（依 constitution §IV「verification 證據」要求）。

**Checkpoint**: US1 完成 = MVP 可交付的最小單位（dev 模式資料層）。可獨立 commit + push。

---

## Phase 4: User Story 3 - Dev vite proxy 對接點 (Priority: P2)

**Goal**: dev 模式下 admin-rust-api 容器把 :10001 暴露給 host，讓 admin-web 在 host 跑 vite 時能 proxy 到。

**Independent Test**:
```bash
docker compose -f compose.yaml -f compose.dev.yaml config --format json \
  | jq -r '.services."admin-rust-api".ports[]?' \
  | grep -q '10001:10001' && echo PASS || echo FAIL
```
（不要求 admin-rust-api 實際啟動 — 啟動依賴 feature 6 envsubst；本 story 只到「設定面對外暴露」）

### Implementation for User Story 3

- [ ] T009 [US3] 在 `deploy/compose.yaml` 加入 admin-rust-api service：build context `../admin-api`、env DATABASE_URL/REDIS_URL/JWT_SECRET/JWT_ISSUER/JWT_EXPIRE/SERVER_HOST/SERVER_PORT/RUST_LOG/TZ（依 contracts/env-variables.md）、`depends_on postgres: healthy / redis: healthy / migration: completed_successfully`、healthcheck `wget -q -O - http://localhost:10001/health` 15/5/5/30、network admin-net。**不在 prod compose 設 ports**（prod 走同源反代）。
- [ ] T010 [US3] 在 `deploy/compose.dev.yaml` 加入 admin-rust-api dev override：`ports: ["10001:10001"]`、`environment.RUST_LOG: debug`（覆蓋 prod 預設 info）；跑 acceptance 指令確認 `jq` 命中 `10001:10001`。

**Checkpoint**: US3 完成 = dev 模式 vite proxy 對接點就緒（待 feature 6 完成 envsubst 後才可實際 curl）。

---

## Phase 5: User Story 4 - Prod 同源端口 (Priority: P2)

**Goal**: prod 模式對外只暴露 :8080，nginx 同源反代解 GAP-0e CORS。

**Independent Test**:
```bash
# 對外只 :8080
docker compose -f deploy/compose.yaml config --format json \
  | jq '[.services | to_entries[] | select(.value.ports != null) | .key]' \
  | jq 'length == 1 and .[0] == "admin-base-web"' && echo PASS || echo FAIL

# nginx -t 過
docker run --rm -v "$(pwd)/deploy/nginx:/etc/nginx/conf.d:ro" nginx:1.27-alpine nginx -t

# CORS 紅線
! grep -iE 'access-control|cors' deploy/nginx/default.conf && echo "PASS: §I 紅線守住"
```

### Implementation for User Story 4

- [ ] T011 [US4] 在 `deploy/compose.yaml` 加入 admin-base-web service：build context `..`（outer 倉根，因為 admin-web Dockerfile 在 `admin-web/Dockerfile`，content 由 feature 7 提供）、build args（VITE_BASE_URL=`/`、VITE_SERVICE_BASE_URL=`/api`、VITE_APP_TITLE/VITE_AUTH_ROUTE_MODE/VITE_STATIC_SUPER_ROLE）、`ports: ["${WEB_PORT:-8080}:80"]`、`depends_on admin-rust-api: service_healthy`、network admin-net、`restart: unless-stopped`。
- [ ] T012 [US4] 在 `deploy/compose.dev.yaml` 加入 admin-base-web dev override：`profiles: ["never"]`（依 research.md R6 — dev 模式 admin-web 走 host vite，admin-base-web 永不啟）。
- [ ] T013 [US4] 寫 `deploy/nginx/default.conf` — 嚴格依 `contracts/nginx-routes.md` normative：`listen 80`、`root /usr/share/nginx/html`、`location = /health` 回 `200 ok`（access_log off）、`location /api/` 反代到 `http://admin-rust-api:10001/`（含 X-Real-IP / X-Forwarded-For/Proto / X-Request-Id / Host header + WebSocket Upgrade preserve + 60s timeout）、`location /` SPA fallback、靜態 cache (`expires 30d`)、gzip 設定。**禁止**任何 `Access-Control-*` header（§I 紅線）。寫完跑 acceptance：`nginx -t` 過 + 上述 jq 對外 port 驗證 + grep CORS 紅線。

**Checkpoint**: US4 完成 = prod 設定面就緒（等 feature 6+7 完成 image build 後可實際 prod 啟動）。

---

## Phase 6: User Story 2 - 靜態驗證閘 (Priority: P1) 🎯 MVP-quality-gate

**Goal**: 在所有 yaml/conf 寫完後，靠 `docker compose config` 與 `nginx -t` 與 contracts 的 grep validation 指令把所有設定問題擋在 PR 之前。

**Independent Test**: 各 task 內含的指令執行結果為 PASS。

> **Note**: 此 story priority P1 但實作面必須在 US1+US3+US4 後跑（依賴 yaml/conf 存在）。Phase 順序與 priority 順序的張力：本 phase 排在 US3/US4 後，因為 P1 的 user-facing value 是「能信任設定」，實作前置才能產生 value。

### Implementation for User Story 2

- [ ] T014 [P] [US2] 跑兩組靜態 compose 驗證並紀錄 stdout：(a) `docker compose -f deploy/compose.yaml config -q`、(b) `docker compose -f deploy/compose.yaml -f deploy/compose.dev.yaml config -q`，兩者都 exit 0、stderr 無 WARN/ERROR；額外跑 `docker compose -f deploy/compose.yaml config --format json | jq` 觀察展開後內容對齊 contracts/service-naming.md。
- [ ] T015 [P] [US2] 跑 contracts/* 三份契約的 validation 指令清單並回填結果：(a) `contracts/env-variables.md` 段尾 4 條（必填 :? / 可選 :- / 無真實 secret / .env gitignored）、(b) `contracts/service-naming.md` 段尾 3 條（5 service 存在 / nginx 反代正確 / 全接 admin-net）、(c) `contracts/nginx-routes.md` 段尾 5 條（nginx -t / 路由完整 / proxy_pass target / CORS 紅線 / 必要 header）。任一 FAIL 即回前 stories phase 修正 + 重跑。

**Checkpoint**: US1 + US2 + US3 + US4 全部完成 = feature 1 主交付完成（除 follow-up T020 外）。可整合 PR 推 origin。

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: 上游驗證、最終確認、跨 story polish。

- [ ] T016 [P] 跑 §IV 上游驗證 #2（migration idempotency，依 research.md R4）：第二次 `docker compose run --rm migration` Exited(0) + stdout 含「nothing to do」或同義 + sys_user 計數不變。把 PASS 結果回填 `spec.md` Assumptions 段「待驗證的上游慣例」第 2 項勾選為 ✅。
- [ ] T017 [P] 跑 §IV 上游驗證 #3（postgres/redis 60 秒內穩定 healthy，依 research.md R8）：使用 `until docker compose ps ... healthy` 迴圈計時，必 ≤ 60 秒。把 PASS 結果回填 `spec.md` 第 3 項。
- [ ] T018 [P] 跑 §IV 上游驗證 #4（compose project name `new-admin-root` 隔離）：`docker compose config | grep -E '^name:' | head -1` 回 `name: new-admin-root`；若資源允許可額外做雙 stack 撞名測試（依 research.md R8 完整指令）。把 PASS 結果回填 `spec.md` 第 4 項。
- [ ] T019 完成本 feature：`git status` clean、`git submodule status` 全行首空格、確認所有 commit 對齊 §VII 中文 conventional commit 格式；最終 commit 把 spec.md Assumptions 上游驗證項勾選改 ✅、tasks.md 內所有 task 改 [x]、`docs/INTEGRATION-CHECKLIST.md` 把 feature 1 標完成（spec/plan/impl 三欄都 ✅、加 SHA、狀態欄改完成）。

---

## Out-of-Scope (Follow-up，依賴後續 features)

- [ ] T020 (follow-up) Prod 模式完整 acceptance：依賴 feature 6 (dockerfile-envsubst) + feature 7 (admin-web-dockerfile) 都 merge 後跑 — `docker compose build --pull && docker compose up -d` + SC-005（對外 ports 數 = 1）+ SC-006（nginx 反代 /api/health round-trip ≤ 50ms）+ SC-008（nmap 對外只 :8080）。本 task 不在 feature 1 主 PR 內，留作 follow-up issue 或 features 6/7 收尾時順帶完成。

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**：無依賴、立即可跑。
- **Phase 2 (Foundational)**：依賴 Phase 1。BLOCKS 所有 user stories。
- **Phase 3 (US1)**：依賴 Phase 2。Phase 3 完成 = MVP 1（dev 資料層）。
- **Phase 4 (US3)**：依賴 Phase 2 + Phase 3（US3 在 compose.yaml 加 admin-rust-api，需要 US1 已建好骨架）。
- **Phase 5 (US4)**：依賴 Phase 2 + Phase 4（US4 加 admin-base-web 依賴 admin-rust-api、admin-rust-api 由 US3 加）。
- **Phase 6 (US2)**：依賴 Phase 3 + 4 + 5（要先有 yaml/conf 才能驗）。
- **Phase 7 (Polish)**：依賴 Phase 6 完成。
- **T020 follow-up**：依賴 features 6 + 7 完成（外部依賴，不在本 feature scope）。

### Within Each User Story

- US1：T006 → T007（compose.yaml 必須先有骨架才能寫 dev override） → T008（acceptance 必須在 yaml 寫完後跑）。
- US3：T009 → T010（dev override 在 prod 加完後）。
- US4：T011 → T012（同 US3）→ T013（nginx conf 與 compose 平行邏輯但建議 compose 先）。
- US2：T014 與 T015 [P] 可平行（不同指令、不同檔）。
- Polish：T016 / T017 / T018 [P] 可平行（不同驗證項）。

### Parallel Opportunities

- **Phase 2** 內：T003 / T004 / T005 標 [P]，可並行（不同檔：outer .gitignore / outer .gitattributes / docs/INTEGRATION-CHECKLIST.md）。
- **Phase 6** 內：T014 / T015 標 [P]，可並行（不同驗證指令）。
- **Phase 7** 內：T016 / T017 / T018 標 [P]，可並行（不同驗證項，且都對 dev 環境跑）。

---

## Parallel Example: Phase 2

```bash
# 三個並行（不同檔、無依賴）：
Task T003: 確認 outer .gitignore 涵蓋 deploy/.env
Task T004: 在 outer 倉根新增 .gitattributes 鎖 LF
Task T005: 同步 docs/INTEGRATION-CHECKLIST.md 6 → 7 features
```

## Parallel Example: Phase 7

```bash
# 三個 §IV 上游驗證並行（dev 環境已起、互不干擾）：
Task T016: §IV 驗證 #2 migration idempotent
Task T017: §IV 驗證 #3 postgres/redis 60s healthy
Task T018: §IV 驗證 #4 compose project name 隔離
```

---

## Implementation Strategy

### MVP First（最小可交付，~50% 工時）

1. Phase 1: T001 建目錄
2. Phase 2: T002 + T003/T004/T005 [P] 寫 foundational
3. Phase 3 (US1): T006/T007/T008 寫 dev 三件 + 驗 schema/seed
4. **STOP and VALIDATE**: dev 資料層 healthy、13 表 + 3 user OK
5. 此時可做第一次 push 拿 review feedback（PR title: `feat(deploy): MVP — dev 資料層可起`）

### 完整交付（~100% 工時）

6. Phase 4 (US3): admin-rust-api compose 設定
7. Phase 5 (US4): admin-base-web + nginx conf + 同源解 GAP-0e
8. Phase 6 (US2): 靜態驗證閘全綠
9. Phase 7 Polish: §IV 三項上游驗證 + 最終 commit

### Follow-up（feature 6+7 merge 後）

10. T020：prod 完整 acceptance（SC-005 / SC-006 / SC-008）

---

## Notes

- [P] tasks = 不同檔、無依賴。Phase 內標 [P] 的可同 commit 也可拆 commit。
- 每個 task 完成後 commit（依 §VII 中文 conventional），不必等整個 phase 結束。
- spec.md US1 acceptance 含 idempotency scenario，與 R4 / T016 重疊 — 在 T008 內順帶驗一次（同一個 dev 環境）即可，T016 不必另起。
- T015 contracts validation 失敗會回退 US1/US3/US4 修正 — 視為正常迭代，不算重做。
- Constitution §IV「驗證證據附在 PR / commit body」：T008/T013/T016/T017/T018 stdout 紀錄方式可選 (a) commit body 截錄、(b) `specs/001-deploy-infra/acceptance-evidence/<task-id>.md`、(c) PR description。本 feature 採 (a)，避免新建額外目錄；超長 stdout 採 (b)。
- 本 feature 純 outer 倉改動，**全程不涉及 §V 兩段式 submodule commit**；單段 commit 即可。
