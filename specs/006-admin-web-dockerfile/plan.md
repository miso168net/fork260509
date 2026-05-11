# Implementation Plan: admin-web Dockerfile (multi-stage build + nginx serve)

**Branch**: `006-admin-web-dockerfile` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/006-admin-web-dockerfile/spec.md`

## Summary

Feature 7 是把 admin-web (Vue 3 SPA) 容器化為單一 multi-stage Docker image：builder stage 用 pnpm 跑 vite build、runtime stage 用 nginx 直接 serve 產出 dist 並 reverse-proxy `/api/*` 到 admin-api。這個 image 是 compose 對外唯一入口（同源反代設計，constitution §I）。

**關鍵發現**（Phase 0 read of feature 1 產出）：feature 1 已經把整個架構鋪好——`deploy/compose.yaml` 已有 `new-admin-base-web` service entry（指向 `admin-web/Dockerfile`、預設 5 個 VITE_* build args）、`deploy/nginx/default.conf` 已寫好 SPA fallback + /api proxy 設定。**Feature 7 唯一缺的就是 `admin-web/Dockerfile` + `admin-web/.dockerignore` 兩個檔案**。Q1 之 Option A（合併 nginx）與既有設計完美對齊。

**Scope 邊界**：
- ✅ 寫 `admin-web/Dockerfile`（multi-stage，builder + runtime）
- ✅ 寫 `admin-web/.dockerignore`
- ❌ **不**改 `deploy/compose.yaml`（feature 1 已寫好 new-admin-base-web service entry）
- ❌ **不**改 `deploy/nginx/default.conf`（feature 1 已寫好，由 admin-web Dockerfile COPY 進 runtime stage）
- ❌ **不**補 admin-api `/health` endpoint（跨倉禁制 §III；列為 feature 6 prereq）

## Technical Context

**Language/Version**: JavaScript build chain — Node 22 LTS、pnpm 10.5+；runtime — nginx 1.27+（alpine 變體）
**Primary Dependencies**: Vue 3.5、Vite 8、TypeScript 6（all already in `admin-web/package.json`）；Dockerfile 不引入新 lib
**Storage**: N/A（純 stateless static assets）
**Testing**: 本 feature 不引入 unit test；驗證走 static acceptance（image build + size + 結構檢查）+ dynamic acceptance（瀏覽器登入；依 admin-api /health 補上 + feature 6 merge 後執行）
**Target Platform**: Linux x86_64 容器（amd64 only — arm64 留作 future enhancement）
**Project Type**: web-frontend production image（multi-stage Docker，無 Node.js 進 runtime layer）
**Performance Goals**: SC-701（5 min cold build）、SC-702（首頁 1s 顯示）、SC-705（image size ≤ 150 MB）、SC-706（cache hit rebuild ≤ 30 s）
**Constraints**:
- Final runtime image 不可含 source code / node_modules / 開發工具（FR-704、FR-706）
- 對外只暴露 :8080（constitution §I）
- VITE_SERVICE_BASE_URL 必為 relative `/api`（透過 build ARG override `.env.prod` 內 mock URL，見 Phase 0 R6）
- 不在 admin-api 加 CorsLayer（constitution §I）
**Scale/Scope**: 單一 production image，2 個 source 檔（Dockerfile + .dockerignore），預計 50-70 行 yaml/Dockerfile 內容

## Constitution Check

*GATE: 必過 Phase 0 與 Phase 1 各一次。*

| 條目 | 適用？ | 評估 |
|---|---|---|
| **§I 同源反代優先** | ✅ 直接適用 | admin-web image 內建 nginx 同時 serve static + proxy `/api/*` → `new-admin-rust-api:10001`；對外只暴露 :8080；不在 admin-api 加 CorsLayer。**完全合規**。 |
| **§II 外部化設定** | ⚠️ 部分適用 | Vite build-time bake 特性決定 VITE_* 在 image 內固化；遵循 §II 精神的做法：所有 VITE_* 用 Dockerfile `ARG` 帶預設值（合理 default），prod 時由 compose build args 注入 override（compose.yaml line 110-115 已寫）。secrets（JWT_SECRET 等）僅在 admin-api 端，本 feature 不接觸。**合規**。 |
| **§III 最小 GAP 修補** | ✅ 直接適用 | 本 feature 唯一 scope = 寫 admin-web/Dockerfile + .dockerignore；**不**跨倉夾帶 admin-api /health 補做（見 Phase 0 R5）；**不**順手 refactor admin-web 其他內容。**合規**。 |
| **§IV 上游驗證** | ✅ 直接適用 | 待驗證項 R1-R7 全部在 Phase 0 research.md 解析完成（read 既有 admin-web / admin-api / deploy 檔案）；R5 留作 follow-up（admin-api /health 缺失屬 feature 1 retrospective backlog）。**合規**。 |
| **§V 兩段式 submodule commit** | ✅ 直接適用 | Dockerfile + .dockerignore 在 admin-web/ 內 → inner commits 推 fork → 外層 chore(submodule) 更新 pin。**合規**。 |
| **§VI Spec-Driven Development** | ✅ 直接適用 | 已走 /speckit-specify + /speckit-clarify + 本 plan；後續 /speckit-tasks → /speckit-analyze → /speckit-implement。**合規**。 |
| **§VII Conventional Commits 中文** | ✅ 直接適用 | inner: `feat(admin-web): GAP-N/A 新增 multi-stage Dockerfile`；outer: `chore(submodule): bump admin-web 到 <短SHA>: feature 7 Dockerfile`。**合規**。 |

**Verification Plan**：
- §I：build 完 image → `docker compose up -d` → curl `http://localhost:8080/api/auth/login` 應 200（透過 nginx proxy 到 admin-api）；`docker ps` 應只看到 admin-web container 暴露 8080
- §II：`docker image inspect new-admin-base-web:latest --format='{{.Config.Env}}'` 不應含 secrets
- §III：`git diff` 範圍只含 `admin-web/Dockerfile`、`admin-web/.dockerignore`；inner branch 之外 commit 0 個
- §IV：research.md 列 R1-R7 finding + evidence
- §V：feature 完成後 `git submodule status` 行首為空格
- §VI：spec.md / plan.md / tasks.md 齊
- §VII：commit log grep `^(feat|fix|chore|...)` 全綠

**Gate 結論**：✅ PASS — 無 violation 需 justify、`Complexity Tracking` 段不需填。

## Project Structure

### Documentation (this feature)

```text
specs/006-admin-web-dockerfile/
├── plan.md              # 本檔（/speckit-plan output）
├── spec.md              # /speckit-specify + /speckit-clarify output
├── research.md          # Phase 0 output（R1-R7 解析）
├── data-model.md        # Phase 1 output（entities）
├── quickstart.md        # Phase 1 output（implementer + operator）
├── contracts/
│   └── admin-web-image.md   # Phase 1 output（image 外部介面契約）
├── checklists/
│   └── requirements.md  # /speckit-specify output
└── tasks.md             # /speckit-tasks output（尚未生成）
```

### Source Code (repository root)

```text
fork260509/                          ← outer
├── admin-web/                       ← submodule + worktree（branch new-admin-base-web）
│   ├── Dockerfile                   ← **本 feature 新增**
│   ├── .dockerignore                ← **本 feature 新增**
│   ├── package.json
│   ├── pnpm-lock.yaml
│   ├── vite.config.ts
│   ├── .env / .env.prod / .env.test
│   ├── src/
│   ├── build/                       ← Vite plugins / config helpers
│   └── ...
├── admin-api/                       ← submodule（feature 7 不動）
├── deploy/                          ← feature 1 產出（本 feature 不動）
│   ├── compose.yaml                 ← 已含 new-admin-base-web service entry
│   ├── compose.dev.yaml             ← 已 override admin-web profiles: ["never"]
│   ├── .env.example
│   └── nginx/
│       └── default.conf             ← 本 feature COPY 進 admin-web Dockerfile runtime
└── specs/006-admin-web-dockerfile/  ← 本 feature 規格目錄
```

**Structure Decision**: admin-web/ submodule 內新增 2 個檔案（Dockerfile + .dockerignore）。**不**動 outer 倉的 deploy/ 任何檔案。Phase 1 design 階段的 nginx config 來源就是既有的 `deploy/nginx/default.conf`（Dockerfile 從 build context 之外用 build arg 路徑 COPY 或從 admin-web/ 內保留一個拷貝——詳見 contracts/admin-web-image.md）。

## Complexity Tracking

> 不適用 —— Constitution Check 0 violation，無需 justify。

---

## Phase 0：詳見 [research.md](./research.md)

R1-R7 全部解析完成。Key findings：
- R1: `engines.pnpm: >=10.5.0`、無 packageManager pin → Dockerfile 用 `npm install -g pnpm@10.x` pin 精確版本
- R2: Vite outDir 預設 `dist/` → COPY `/app/dist` 到 nginx html dir
- R3: 0 WebSocket / SSE / socket.io → nginx 預備的 Upgrade header 留著無害
- R4: ✅ 由 Q1 confirmed Option A；feature 1 既有 deploy/nginx/default.conf 直接使用
- **R5（critical）**：admin-api **沒有** `/health` endpoint；feature 1 compose.yaml healthcheck `wget /health` 必失敗。Feature 7 不夾帶補 endpoint（§III 跨倉禁制），列為 feature 6 prereq；feature 7 dynamic acceptance 依 R5 補上 + feature 6 merge 後執行
- R6: VITE_SERVICE_BASE_URL prod 來源：compose build args (`/api`) override `.env.prod` (mock URL) → Dockerfile 用 `ARG`+`ENV` 注入 Vite
- R7: 0 命中 admin-web/src/ 內 hardcoded localhost:10001

## Phase 1：詳見 [data-model.md](./data-model.md)、[contracts/](./contracts/)、[quickstart.md](./quickstart.md)

- **data-model.md**: 4 個 artefact entities（Dockerfile、.dockerignore、nginx config 引用、compose service consumer）
- **contracts/admin-web-image.md**: image 對外契約（健康檢查 / 監聽 port / 暴露路由 / build args 介面 / 環境兼容性）
- **quickstart.md**: implementer（兩段式 commit）+ operator（pulls + builds + smoke browser test）

---

## Re-evaluate Constitution Check (post Phase 1)

Phase 1 設計後再過一次 gate：
- §I：image 唯一外暴 port 80（compose host 80→8080）、`/api/*` 內部反代 → ✅
- §II：所有 VITE_* 走 ARG → ENV → 合理 default、無 hardcode → ✅
- §III：source diff 範圍只 admin-web/ 內 2 個檔 → ✅
- §IV：R1-R7 evidence-based 解析 → ✅
- §V：兩段式 commit pattern 在 quickstart.md A.4 確切寫明 → ✅
- §VI：本 plan / research / data-model / contracts / quickstart 完整 → ✅
- §VII：commit message 範本準備好 → ✅

**Post-Phase 1 Gate**：✅ PASS。

下一步：`/speckit-tasks` 產 tasks.md。
