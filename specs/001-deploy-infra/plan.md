# Implementation Plan: deploy-infra

**Branch**: `001-deploy-infra` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-deploy-infra/spec.md`

## Summary

建立 outer 倉 `new-admin-root` 的 `deploy/` 目錄，提供整合部署的 5 個基礎設定檔（`compose.yaml` / `compose.dev.yaml` / `nginx/default.conf` / `.env.example` 與 `.gitignore` 條目對齊），讓 operator 能：

- **dev 模式**：起 postgres + redis + migration + admin-rust-api（admin-web 走 host vite），驗證 13 張表 + 3 seed user 寫入。
- **prod 模式**（依賴 feature 6/7 完成）：對外只暴露 `:8080`，nginx 同源反代解決 GAP-0e CORS、所有 service 內網互通。

技術路線：採 INTEGRATION-PLAN §5.1-5.6 既有 compose/nginx/env 範例為基礎，補強 fail-fast secrets 驗證、idempotent migration 驗證、靜態驗證閘（compose config + nginx -t）。

## Technical Context

**Language/Version**: 不適用（本 feature 純設定檔；YAML 1.2 / nginx config DSL / sh 1.0）
**Primary Dependencies**:
- Docker Compose v2 (≥ 2.20，須支援 `service_completed_successfully` / `service_healthy` condition)
- postgres:17.4-alpine、redis:7.4-alpine、nginx:1.27-alpine（image tag pin 至 minor 版）
**Storage**: 不適用（本 feature 不寫 application 資料；只設定 named volumes `pg-data` / `redis-data`）
**Testing**:
- 靜態：`docker compose config -q`、`nginx -t`（用 `nginx:1.27-alpine` 映像跑）
- 動態：`docker compose up -d postgres redis migration` + `psql ... \dt` + `SELECT user_name FROM sys_user`
**Target Platform**: Linux x86_64（CI / production）+ Docker Desktop on Windows/macOS（dev）
**Project Type**: infrastructure / deployment（outer-only feature，無 source code 改動）
**Performance Goals**（從 spec SC 抽）:
- 新 operator onboarding（zero → 資料層 healthy + seed 寫入）≤ 10 分鐘
- migration 第一次跑 ≤ 30 秒，重跑 ≤ 5 秒（idempotent 快路徑）
- nginx 反代 `/api/health` round-trip ≤ 50ms（local docker network）
**Constraints**:
- outer-only：不動 `admin-web/` `admin-api/` submodule
- prod 模式對外 attack surface = 1 port（`:8080`）
- 跨平台：LF 換行、無 symlink
- secrets 必填項用 `${VAR:?must set}` 強制（fail-fast）
**Scale/Scope**: 內部 admin tool、< 1000 並發、< 5 個 service 的 single-host compose（依 INTEGRATION-PLAN §1.4 選項 A）

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 原則 | 通過 / 違反 / 不適用 | 證據 |
|---|---|---|
| **§I 同源反代優先** | ✅ 通過 | nginx 同源反代為核心交付（FR-121）；prod compose 不暴露任何非 nginx port（FR-116 + SC-005）；nginx conf 禁設 CORS header（FR-125） |
| **§II 外部化設定** | ✅ 通過（本 feature 範圍內） | 所有 secrets/config 透過 env 注入（FR-131/132），`.env.example` 為 contract（FR-130）；admin-api `application.yaml.tpl` envsubst 改造由 feature 6 負責 — 已在 spec assumption 顯式列為依賴 |
| **§III 最小 GAP 修補** | ✅ 通過 | spec.md Scope 段顯式列「涵蓋 GAP-0e」+ 分組理由（同主題同倉，符合例外條款）；不跨倉、不跨主題；§Clarifications Q1 把可能違反 §III 的 admin-web Dockerfile 切出為獨立 feature 7 |
| **§IV 上游驗證** | ✅ 通過 | spec Assumptions 段已列 4 項待驗證上游慣例；本 plan Phase 0 research 會生 verification 指令對應每項；本 plan 不主張任何「依文件假設」結論 |
| **§V 兩段式 submodule commit** | N/A | 本 feature 純 outer 倉改動，不動 admin-web/ admin-api/，無 submodule pin 變更（git submodule status 全程行首空格） |
| **§VI Spec-Driven Development** | ✅ 通過 | 已走 specify → clarify → 本 plan；後續 tasks → implement |
| **§VII Conventional Commits 中文** | ✅ 通過（流程內遵循） | 本 feature 既有 commits（`3ff40de` `2a6661a`）格式 `docs(spec): ...` 對齊 §VII |

**附加技術棧鎖定檢查**（constitution Additional Constraints）：
- nginx 1.27 ✅、Postgres 17 ✅、Redis 7 ✅、Docker Compose v2 ✅ — 全部與「鎖定技術棧」表一致

**部署條款檢查**：
- 對外只開 nginx-ui (`WEB_PORT=:8080`) ✅
- secrets via env，`.env.example` 必 commit、`.env` 進 `.gitignore` ✅（spec FR-105 + outer .gitignore 已含 `.env`）

**結論**：Constitution Check **PASS**，無違反、無需 Complexity Tracking justify。

## Project Structure

### Documentation (this feature)

```text
specs/001-deploy-infra/
├── plan.md              # 本檔（/speckit-plan 產出）
├── research.md          # Phase 0：rationale 整理 + 上游驗證指令清單
├── data-model.md        # Phase 1：service / volume / network 拓樸實體（部署層）
├── quickstart.md        # Phase 1：dev / prod 模式快速啟動
├── contracts/
│   ├── env-variables.md        # .env.example 變數契約（被 admin-api / admin-web build 階段消費）
│   ├── service-naming.md       # admin-net 內 service name DNS 契約（被 nginx / migration 引用）
│   └── nginx-routes.md         # nginx → admin-rust-api 路由契約（GAP-0e 的物理體現）
├── checklists/
│   └── requirements.md         # spec quality checklist（已存在，全綠）
└── tasks.md             # /speckit-tasks 產出（不在本 plan 範圍）
```

### Source Code (repository root)

本 feature 為 **outer-only** infrastructure feature，**不動** `admin-web/` 與 `admin-api/` submodule（git submodule status 全程行首空格）。新增的檔案位於 outer 倉根的 `deploy/` 子目錄：

```text
fork260509/                                  ← outer repo (new-admin-root) 工作區根
├── deploy/                                  ★ 本 feature 新增
│   ├── compose.yaml                         ★ prod 主編排（5 service：postgres / redis / migration / admin-rust-api / admin-base-web）
│   ├── compose.dev.yaml                     ★ dev override（暴露 5432/6379/10001 port、admin-base-web profile=never）
│   ├── nginx/
│   │   └── default.conf                     ★ reverse proxy + SPA fallback + /health
│   └── .env.example                         ★ env 變數樣板（必填用 :?、可選用 :-）
├── .gitignore                               ◇ 確認 `.env` / `deploy/.env` 已被忽略（既有 outer .gitignore 已涵蓋 .env）
├── docs/INTEGRATION-CHECKLIST.md            ◇ 6→7 feature 同步（plan 階段順帶處理）
├── admin-web/   (submodule, untouched)
├── admin-api/   (submodule, untouched)
└── specs/001-deploy-infra/                  （本 feature 規格與計畫，已存在）
```

**Structure Decision**: 採 INTEGRATION-PLAN §3.3 既定佈局（`deploy/{compose.yaml, compose.dev.yaml, nginx/default.conf, .env.example}`）。理由：

1. **不引入新頂層目錄**：所有部署檔放在單一 `deploy/` 下，外層 git 追蹤範圍清楚（`docs/`, `graphify-out/`, `specs/`, `deploy/`, `.specify/` 五個目錄各司其職）。
2. **與 INTEGRATION-PLAN 範例對齊**：減少規範漂移；INTEGRATION-PLAN §5.1-5.6 yaml/conf 範例可直接拿來作為 implementation 起點。
3. **dev/prod compose 分檔**：用 docker compose `-f a -f b` merge 機制做疊加，不寫條件判斷邏輯到 yaml。

## Phase 0: Outline & Research

**Status**: 將執行（在本 plan commit 後產出 `research.md`）。

**Scope**：

由於 spec 已通過 `/speckit-clarify` 解掉 2 個高影響 ambiguity（admin-web Dockerfile 歸屬、production hardening 範圍），剩餘 unknown 為「best practices 確認」與「上游驗證指令具現化」。research.md 涵蓋：

1. **Compose v2 dependency model**：`depends_on` 用 `condition: service_healthy` / `condition: service_completed_successfully` 的行為差異與失敗回饋。
2. **Healthcheck 最佳實踐**：postgres `pg_isready`、redis `redis-cli ping -a`、admin-rust-api `wget /health` 的 timeout / retries / start_period 推薦值，與 SC-004「30 秒內 healthy」的對齊。
3. **nginx → docker service-name DNS 解析**：`proxy_pass http://admin-rust-api:10001/` 在 docker compose 內網依靠 docker DNS resolver；nginx 啟動時 service 還沒起會怎樣（startup ordering）。
4. **Migration idempotency**：Sea-ORM `MigratorTrait::up` 對重複 migration 的處理（spec assumption 待驗證項 #2）。
5. **Compose project name `name:` 隔離**：避免與其他 stack 同名 service 撞（spec edge case）。
6. **Dev override 的 profile/never 模式**：profile 的 docker compose 文件版本支援度。
7. **跨平台換行**：Windows host 上 git autocrlf 對 alpine container 內 `entrypoint.sh` 的影響（雖然 entrypoint.sh 在 feature 6 才寫，但 .env / nginx conf 也須 LF）。
8. **§IV 上游驗證指令具現化**：把 spec assumption 4 項列為具體 `docker compose ... && psql -c '...'` 指令清單。

**Output**: `research.md`（含 7-8 個「Decision / Rationale / Alternatives considered」條目）。

## Phase 1: Design & Contracts

**Prerequisites**: research.md 完成。

### 1.1 Data Model（部署拓樸實體）

`data-model.md` 不是 application data model（feature 1 不動程式碼），而是**部署層的服務/volume/network 拓樸實體表**：

- 5 個 service entity（含 image / 對外 port / depends_on / healthcheck / restart policy）
- 2 個 volume entity（pg-data / redis-data，driver / mount path）
- 1 個 network entity（admin-net / driver=bridge）
- 7 個 service-to-service 依賴關係（depends_on graph）
- 4 個 service-to-volume 掛載
- 5 個 service-to-network 連接

### 1.2 Contracts

本 feature 的「契約」是被其他 feature / runtime 元件消費的介面：

#### `contracts/env-variables.md`
- 必填變數（4 個）：POSTGRES_PASSWORD、REDIS_PASSWORD、JWT_SECRET、（隱含）TZ
- 可選變數（≥ 8 個）：POSTGRES_DB / POSTGRES_USER / WEB_PORT / TZ / RUST_LOG / JWT_EXPIRE / DATABASE_MAX_CONNECTIONS / VITE_APP_TITLE / VITE_AUTH_ROUTE_MODE / VITE_STATIC_SUPER_ROLE
- 每個變數的：用途、消費者（postgres image / admin-rust-api / admin-web build args / nginx）、fallback、validation 規則

#### `contracts/service-naming.md`
- admin-net 內穩定 service name 清單（被 nginx 反代、被 admin-rust-api DATABASE_URL/REDIS_URL 引用、被 migration depends_on）：
  - `postgres` / `redis` / `migration` / `admin-rust-api` / `admin-base-web`
- DNS resolution: docker compose 為每個 service 在內網註冊 `<service>` 短名 + `<service>.admin-net` FQDN
- **變更政策**：service name 若改動，下游 nginx conf / admin-rust-api 環境變數須同步；視為 breaking change，需新 spec

#### `contracts/nginx-routes.md`
- 路由表（method / path / proxy_pass target / SPA fallback 行為 / cache header）
- `/api/*` → `http://admin-rust-api:10001/`（strip `/api/` 前綴）
- `/health` → static `200 ok\n`（給 docker healthcheck）
- `/` → SPA fallback（`try_files $uri $uri/ /index.html`）
- 靜態資源 cache 規則
- **GAP-0e 物理體現**：本契約即為「同源反代解 CORS」的 normative spec；違反此契約 = 違反 constitution §I

### 1.3 Quickstart

`quickstart.md` 給後續 feature 與新 operator 用，含：
- dev 模式 5 步啟動（cp .env / docker compose up partial / 驗 migration / 連 host DB / 跑 admin-web vite）
- prod 模式 4 步啟動（前提：features 6/7 完成）
- 排錯：compose config / nginx -t / docker logs 三條閘
- **不含**：smoke test 7 條 curl（屬 INTEGRATION-PLAN §6.4，跨 feature；本 quickstart 只到 infra 層）

### 1.4 Agent Context Update

更新 `CLAUDE.md` 的 `<!-- SPECKIT START -->` / `<!-- SPECKIT END -->` 區塊（若不存在則新建），指向本 plan 路徑 `specs/001-deploy-infra/plan.md`，讓後續 session 開頭 SOP 能載入當前 active plan。

**Output**: `data-model.md`、`contracts/{env-variables,service-naming,nginx-routes}.md`、`quickstart.md`、`CLAUDE.md` 內 SPECKIT 區塊更新。

## Phase 2 (out of scope for /speckit-plan)

`/speckit-tasks` 會把本 plan 拆成 dependency-ordered tasks。預期粒度：

- T001: 新增 `deploy/.env.example` + 更新 outer `.gitignore` 確認 `deploy/.env` 被擋
- T002: 新增 `deploy/compose.yaml`（prod 主編排）
- T003: 新增 `deploy/compose.dev.yaml`（dev override）
- T004: 新增 `deploy/nginx/default.conf`
- T005: 同步 `docs/INTEGRATION-CHECKLIST.md`：6 → 7 feature roadmap、加入 feature 7 admin-web-dockerfile
- T006: 靜態驗證（compose config + nginx -t）
- T007: 動態驗證（dev 模式起 postgres/redis/migration、驗 13 表 + 3 seed user）
- T008（依賴 feature 6 完成）: prod 模式 smoke + SC-005 / SC-008 驗證

預估 ~8 個 task，5 個可在 feature 6/7 完成前 merge（T001-T007），T008 留 follow-up。

## Constitution Check — Post-Design Re-evaluation

Phase 0 + Phase 1 產出已落地，回掃 7 條原則：

| 原則 | 狀態 | Phase 0/1 補強證據 |
|---|---|---|
| §I 同源反代優先 | ✅ 仍通過 | `contracts/nginx-routes.md` 把「禁 CORS」明文化為紅線契約、含 grep validation 指令；reverse proxy header 注入 normative |
| §II 外部化設定 | ✅ 仍通過（範圍內） | `contracts/env-variables.md` 把 4 必填 + 8+ 可選變數列為 normative contract，含 `.env.example` 不得有真實 secret 的 validation |
| §III 最小 GAP 修補 | ✅ 仍通過 | scope 維持單主題（deploy infra）；admin-web Dockerfile 拆出 feature 7 的決策已寫入 spec Clarifications + 本 plan dependency 段 |
| §IV 上游驗證 | ✅ 仍通過 | `research.md R8` 把 spec 4 項待驗證項落為具體 bash + jq + curl 指令，作為 task acceptance 執行藍本 |
| §V 兩段式 submodule commit | N/A | `data-model.md` 確認 build context 從 outer 看 admin-api/admin-web；本 feature 全部產出僅在 outer 倉、submodule pin 不動 |
| §VI Spec-Driven Development | ✅ 通過 | spec → clarify → plan 流程完整；後續 tasks → implement |
| §VII Conventional Commits 中文 | ✅ 通過 | 至本 plan commit 為止全部 commits 對齊（`docs(spec): ...` / `chore: ...`） |

**結論**：Post-design Constitution Check **PASS**，與 Phase 0 前 pre-design check 一致。無違反、無 Complexity Tracking 需 justify。

## Complexity Tracking

> **Constitution Check 全部通過、無違反，本表留空。**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (無) | — | — |
