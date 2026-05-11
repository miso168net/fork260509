---

description: "Tasks for feature 007-dockerfile-envsubst"
---

# Tasks: admin-api envsubst template + hardening 收尾

**Input**: Design documents from `/specs/007-dockerfile-envsubst/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/entrypoint-contract.md ✅、quickstart.md ✅

**Tests**: 本 feature 為部署 artefact 改造，無 unit test 加入點；驗證走 (a) static acceptance（grep / docker ls / cat 命中數）、(b) dynamic acceptance（重跑 feature 7 T010 五場景 + 新 fail-fast/sentinel 場景）。**不另寫 unit test**（與 features 1/7 同模式）。

**Organization**: tasks 依 2 user stories（US1 P1 envsubst template + entrypoint / US2 P2 deploy hardening）+ §V 兩段式 commit 展開。admin-api inner 改動為 1 個 inner commit；outer 3-4 commits（deploy hardening + submodule pin + acceptance evidence + CHECKLIST sync）。

## Format: `[ID] [P?] [Story] Description`

- 路徑：admin-api 倉內檔以 `admin-api/<path>` 表示；outer 倉檔以 root-relative path
- §V 兩段式 commit（admin-api 版、第 2 個 admin-api inner-commit feature）：T005 是 admin-api inner commit、T006 是 push fork、T013 是 outer SHA pin commit

---

## Phase 1: Setup（共享前置）

**Purpose**: 確認 admin-api worktree health + outer branch 對 + docker 環境。

- [ ] T001 在 outer repo root（`/mnt/d/AnewSpaces/x_Project/fork260509`）跑：(a) `git branch --show-current` 確認 = `007-dockerfile-envsubst`、`git status` clean（除 `.claude/scheduled_tasks.lock`）；(b) `git submodule status` 確認 admin-api SHA = `8ae2432`、admin-web SHA = `65f3060a`、行首皆空格（clean）；(c) `cd admin-api && git branch --show-current` = `new-admin-rust-api`、worktree clean；(d) `ls admin-api/server/resources/application.yaml admin-api/entrypoint.sh 2>&1`：應前者**存在**（待替換）、後者**不存在**（待新增）；(e) `docker --version && docker compose version` 確認 docker ≥ 24 + compose v2。

---

## Phase 2: Foundational

**Purpose**: 無 —— 所有改動位於 admin-api/ + deploy/ 既有檔，foundational concept 不適用本 feature 結構。

---

## Phase 3: User Story 1 - Operator 透過 env 完全外部化 admin-api 設定 (Priority: P1) 🎯 MVP

**Goal**: 把 application.yaml 換成 .tpl + 新增 entrypoint.sh + 改 Dockerfile，admin-api image 內**無** hardcoded prod 預設值；entrypoint 階段 envsubst render；required env 缺失 + APP_JWT_ISSUER sentinel 必 fail-fast。

**Independent Test**:
- 靜態：`docker run --rm new-admin-rust-api:latest ls /app/server/resources/` 不含 `application.yaml`（只含 `.tpl` + 其他）；`grep -rE "pgbouncer|soybean-admin-rust|ByteByteBrew|123456" admin-api/server/resources/application.yaml.tpl` 0 命中
- 動態（依 US2 + outer deploy 改動，於 Phase 5 一併驗）：full stack `docker compose up -d` 通、login 200；故意缺 env 必 fail-fast

### admin-api Inner 改動（在 `admin-api/` worktree 內）

- [ ] T002 [US1] **`admin-api/server/resources/application.yaml` → `application.yaml.tpl`**（per data-model.md Entity 1 + 2）：
   - 用 `git mv server/resources/application.yaml server/resources/application.yaml.tpl`
   - 編輯 `application.yaml.tpl` 把 hardcoded 值替換為 `${APP_*}` 占位：
     - `url: "postgres://...@pgbouncer:6432/..."` → `url: "${APP_DATABASE_URL}"`
     - `max_connections: 10` → `max_connections: ${APP_DATABASE_MAX_CONNECTIONS:-10}`
     - `host: "0.0.0.0"` → `host: "${APP_SERVER_HOST:-0.0.0.0}"`
     - `port: 10001` → `port: ${APP_SERVER_PORT:-10001}`
     - `jwt_secret: "soybean-admin-rust"` → `jwt_secret: "${APP_JWT_JWT_SECRET}"`
     - `issuer: "https://github.com/ByteByteBrew/soybean-admin-rust"` → `issuer: "${APP_JWT_ISSUER}"`
     - `expire: 7200` → `expire: ${APP_JWT_EXPIRE:-7200}`
     - `url: "redis://:123456@redis:6379/10"` → `url: "${APP_REDIS_URL}"`
   - 驗：`grep -E "pgbouncer|soybean-admin-rust|ByteByteBrew|123456" admin-api/server/resources/application.yaml.tpl` 0 命中、`grep "\${APP_" admin-api/server/resources/application.yaml.tpl` ≥ 8 命中
   - **不**動 `application-test.yaml/toml/json`（dev only，prod 不 ship）

- [ ] T003 [US1] **新增 `admin-api/entrypoint.sh`**（per contracts/entrypoint-contract.md §4 reference shell skeleton）：
   - 內容：`#!/bin/sh` + `set -eu` + log/fatal helpers + required env 預檢（4 個 secret env）+ sentinel rejection（3 字串 exact-match）+ envsubst render + `exec "$@"`
   - sentinel 清單寫死：`""`、`"https://github.com/your-org/new-admin"`、`"change-me-issuer-url"`
   - 寫入路徑：`TEMPLATE=/app/server/resources/application.yaml.tpl`、`OUTPUT=/app/server/resources/application.yaml`
   - `chmod +x admin-api/entrypoint.sh`
   - 驗：`bash -n admin-api/entrypoint.sh` syntax check pass、`ls -l admin-api/entrypoint.sh` 應 +x permission

- [ ] T004 [US1] **修 `admin-api/Dockerfile`** runtime stage（per data-model.md Entity 4）：
   - `apk add --no-cache openssl ca-certificates tzdata` 一行加上 `gettext`（提供 envsubst）
   - COPY block 內 `application.yaml` 改 `application.yaml.tpl`
   - 新增 `COPY --chown=${APP_USER}:${APP_USER} entrypoint.sh /usr/local/bin/entrypoint.sh`
   - 新增 `RUN chmod +x /usr/local/bin/entrypoint.sh`（雖然 COPY 帶 +x，加 chmod 確保）
   - 在 `USER ${APP_USER}` 之後、`EXPOSE` 之前加 `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`（CMD 不變保留 `["/bin/server"]`）
   - 驗：`grep "gettext" admin-api/Dockerfile`、`grep "ENTRYPOINT" admin-api/Dockerfile`、`grep "application.yaml.tpl" admin-api/Dockerfile` 都應命中

- [ ] T005 [US1] **admin-api inner commit**（§V 第一段）：在 `admin-api/` 內：
   ```bash
   git add server/resources/application.yaml server/resources/application.yaml.tpl entrypoint.sh Dockerfile
   git status  # 確認 application.yaml = deleted、.tpl = new、entrypoint.sh = new、Dockerfile = modified
   ```
   commit message：`feat(admin-api): envsubst template + entrypoint validate（per constitution §II）`（body 引 plan.md Summary 與 SC 對應）。

### admin-api inner Push 與 image build verify

- [ ] T006 [US1] 在 `admin-api/` 跑 `git push origin new-admin-rust-api` 推 inner commit 到 fork。**NEEDS USER AUTHORIZATION**（per CLAUDE.md §5 全域 push 規則）— 推前先問。

- [ ] T007 [US1] 在 `deploy/` 內 `docker compose build new-admin-rust-api` 重 build admin-api image（含 gettext + entrypoint）。預期 build 成功；time ≤ feature 7 cold build base ±10%。失敗診斷：(a) `apk add gettext` 失敗 → 檢查 alpine repo 連線；(b) entrypoint COPY 路徑錯 → 檢查 Dockerfile build context；(c) chmod 失敗 → 檢查 USER 順序（chmod 應在 USER 切換前）。

### Static Acceptance（US1 SC-601~603）

- [ ] T008 [US1] **Static acceptance：image 內無 hardcoded 預設值**：
   1. `docker run --rm new-admin-rust-api:latest ls /app/server/resources/` 列表**不含** `application.yaml`（per SC-603）
   2. `docker run --rm new-admin-rust-api:latest cat /app/server/resources/application.yaml.tpl | grep -E "pgbouncer|soybean-admin-rust|ByteByteBrew|123456"` → **0 命中**（per SC-601 + SC-602）
   3. `docker run --rm new-admin-rust-api:latest ls -l /usr/local/bin/entrypoint.sh` → **存在 + 可執行** (+x perm)
   4. `docker run --rm new-admin-rust-api:latest cat /usr/local/bin/entrypoint.sh | head -10` → 確認 shebang + required env list
   5. `docker run --rm new-admin-rust-api:latest sh -c 'which envsubst'` → `/usr/bin/envsubst`（驗 gettext installed）
   全 5 項 PASS 才算 US1 image-level 達標。

**Checkpoint**: T002~T008 完成 = US1 image build + static 達標。Dynamic（fail-fast / sentinel）在 Phase 5 T014 一併跑。

---

## Phase 4: User Story 2 - Stack 啟動穩定性 hardening 收尾 (Priority: P2)

**Goal**: redis healthcheck CMD-SHELL（1-I1）+ postgres start_period verify（1-M1）+ nginx WebSocket header + gzip_proxied（1-M2/M3）+ .env.example placeholder 更新（FR-611 + redis argv doc）。

**Independent Test**:
- 靜態：`grep "CMD-SHELL.*redis-cli.*\$\$REDIS_PASSWORD" deploy/compose.yaml` 命中；`grep "gzip_proxied any" deploy/nginx/default.conf` 命中；`grep "change-me-issuer-url" deploy/.env.example` 命中
- 動態（per Phase 5 T014）：`docker top redis-container` healthcheck argv 不含明文 password

### Outer deploy/ 改動

- [ ] T009 [US2] **修 `deploy/compose.yaml`**：
   - **redis service** healthcheck（1-I1）：
     - 既有 `test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]`
     - 改為 `test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping"]`
     - 註解標 `# 1-I1：CMD-SHELL form + $$REDIS_PASSWORD env interpolation（避免 docker compose 提前展開 password 到 healthcheck argv）`
   - **postgres service** healthcheck（1-M1 verify）：confirm `start_period: 30s` 存在；若已有則無需改、加註解 verify 1-M1
   - 驗：`grep -E "CMD-SHELL.*redis-cli" deploy/compose.yaml` 命中、`grep "start_period: 30s" deploy/compose.yaml` 命中（postgres 段）

- [ ] T010 [US2] **修 `deploy/nginx/default.conf`**（per FR-631 / FR-632）：
   - 確認 `/api/` proxy block 含完整 WebSocket header：
     ```nginx
     proxy_set_header Upgrade $http_upgrade;
     proxy_set_header Connection "upgrade";
     ```
     既有應已包含；verify 即可（1-M2）
   - gzip 區段補：在 `gzip on;` 後加 `gzip_proxied any;`（per 1-M3）
   - 驗：`grep "gzip_proxied any" deploy/nginx/default.conf` 命中、`grep "proxy_set_header Upgrade" deploy/nginx/default.conf` 命中

- [ ] T011 [US2] **修 `deploy/.env.example`**（per FR-611 + FR-621 + R5 doc）：
   - **a. Sentinel placeholder**：把 `JWT_ISSUER=...` 或 `APP_JWT_ISSUER=https://github.com/...` 改為 `APP_JWT_ISSUER=change-me-issuer-url`
   - **b. Sentinel list doc comment** 加在該行上方：
     ```
     # APP_JWT_ISSUER 必填且不可為下列 sentinel 之一（entrypoint 會 abort）：
     #   - "" (空字串)
     #   - "https://github.com/your-org/new-admin"
     #   - "change-me-issuer-url"
     ```
   - **c. Redis argv limitation doc comment**（FR-621）加在 `REDIS_PASSWORD=` 行附近：
     ```
     # Note：redis container 之 main process argv 仍會在 `docker top` 暴露
     # REDIS_PASSWORD 之明文值（redis-server `--requirepass` CLI flag 設計）。
     # 本專案接受此 limitation；future hardening 可改用 ACL config file。
     # （healthcheck argv 在 1-I1 hotfix 已修為 CMD-SHELL form 不暴露）
     ```
   - 驗：`grep "change-me-issuer-url" deploy/.env.example` 命中、`grep "sentinel" deploy/.env.example` 命中、`grep "redis-server.*requirepass" deploy/.env.example` 命中

**Checkpoint**: T009 + T010 + T011 完成 = US2 hardening 改動完成。

---

## Phase 5: Polish & Cross-Cutting

### Outer Commits + Submodule Bump

- [ ] T012 **Outer commit A: deploy hardening**：`git add deploy/compose.yaml deploy/nginx/default.conf deploy/.env.example` 後 commit：`fix(deploy): 1-I1 + 1-M1~M3 hardening + .env.example placeholder（搭配 admin-api envsubst feature）`（body 引 spec FR-620/630/631/632/611 對應）

- [ ] T013 **Outer commit B: submodule SHA bump**：`git add admin-api` 後 commit：`chore(submodule): bump admin-api 到 <短SHA>: envsubst template + entrypoint`（短 SHA 從 `cd admin-api && git rev-parse --short HEAD` 取）

### Dynamic Acceptance（含 fail-fast + sentinel + feature 7 T010 重跑）

- [ ] T014 **Dynamic acceptance 完整跑**（per quickstart.md Part B + spec SC-604~609）：
   1. **Happy path（SC-607 + SC-608）**：`docker compose up -d`、等 admin-api healthy（per 7-I1 healthcheck 應 < 30s）、`curl POST /api/auth/login Soybean/123456` → 200 + JWT
   2. **Required env fail-fast（SC-604）**：暫時 unset `APP_JWT_JWT_SECRET`（comment .env 該行）、`docker compose up -d new-admin-rust-api`、`docker compose logs new-admin-rust-api | tail -5` → 應見 `[entrypoint] FATAL: APP_JWT_JWT_SECRET is empty or unset`、container exit 1
   3. **Sentinel rejection（SC-609）**：set `APP_JWT_ISSUER=https://github.com/your-org/new-admin` 啟動 → log 應見 `[entrypoint] FATAL: APP_JWT_ISSUER=... is a known placeholder`、container exit 2
   4. **Sentinel false-positive 反向（SC-609）**：set `APP_JWT_ISSUER=https://my-company.example.com/auth`（合法 URL 內含「com」「auth」常見字根）→ container 啟動成功、不誤拒
   5. **Rendered yaml 內容（SC-605）**：`docker exec <admin-api-container> cat /app/server/resources/application.yaml | head -20` → 看到 real env values（無 `${...}` 殘留）
   6. **Redis healthcheck argv（SC-606）**：`docker top new-admin-root-redis-1` → healthcheck argv 應顯 `sh -c "redis-cli -a "$REDIS_PASSWORD" ping"`（字面 `$REDIS_PASSWORD`）、**不**含明文 password
   7. **Feature 7 T010 五場景重跑（SC-608）**：依 `specs/006-admin-web-dockerfile/acceptance-evidence/T010-dynamic.md` 五場景跑、全綠

   每項 evidence（log 片段 / curl output / docker top 截圖）收集備用 T015。

### Static + Dynamic Acceptance Evidence

- [ ] T015 在 `specs/007-dockerfile-envsubst/acceptance-evidence/T015-acceptance.md` 整合 T008 static + T014 dynamic 全部結果（7 scenarios + 5 static checks）標 PASS/FAIL；對照 SC-601~609 對齊表。在 outer 1 個 commit：`test: T015 envsubst + hardening acceptance evidence`。

### CHECKLIST Sync

- [ ] T016 更新 `docs/INTEGRATION-CHECKLIST.md`（與本 feature 同 PR）：
   - **roadmap 表 row 6** dockerfile-envsubst：spec/plan/impl 全 ✅、狀態欄改「完成 (SHA range，admin-api inner <SHA>)」
   - **跨 feature 待驗證**：無新增（既有 R# 已在 feature 7 T009 內結算）
   - **Retrospective backlog**：1-I1 / 1-M1 / 1-M2 / 1-M3 / 1-M4 / 1-M5 / 1-I3 全標 ✅ 已修（hotfix range）；新增 row 6-M1（若 T014 過程發現新項）
   - outer 加 1 個 commit：`docs: T016 INTEGRATION-CHECKLIST feature 6 dockerfile-envsubst 標完成`

### Outer Push

- [ ] T017 在 outer 跑 `git push origin 007-dockerfile-envsubst`。**NEEDS USER AUTHORIZATION** — 推前先問：「Feature 6 outer commits（hardening + submodule + evidence + CHECKLIST）ready to push？」

---

## 依賴圖

```
T001 (Setup)
  ↓
T002 [US1] (.tpl) ─┐
T003 [US1] (entrypoint.sh) ┤  parallel within US1 inner work
T004 [US1] (Dockerfile) ─┘
  ↓
T005 [US1] (inner commit)
  ↓
T006 [US1] (inner push, USER AUTH)
  ↓
T007 [US1] (build verify)
  ↓
T008 [US1] (static acceptance image-level)
  ↓
T009 [US2] (compose.yaml redis + postgres) ─┐
T010 [US2] (nginx config) ────────────────┤  parallel within US2 deploy work
T011 [US2] (.env.example) ────────────────┘
  ↓
T012 (deploy commit) ─┐
T013 (submodule bump) ┤ sequential（兩個都 outer commit、相鄰）
  ↓
T014 (dynamic acceptance)
  ↓
T015 (evidence commit)
  ↓
T016 (CHECKLIST sync commit)
  ↓
T017 (outer push, USER AUTH)
```

**[P] 標記**：
- T002 / T003 / T004 在 admin-api 內 **不同檔**，可並行 implement 但因都屬同個 inner commit（T005），實作可並行、commit 一次
- T009 / T010 / T011 在 outer 不同 deploy/ 檔，可並行 implement 但同樣由同 outer commit（T012）涵蓋
- T012 / T013 雖然都是 outer commit 但需 sequential（T013 依賴 admin-api 已 inner-pushed = T006）

實際並行機會有限（多數 task 是 sequential 依賴）。

---

## Implementation Strategy

**MVP scope** = US1（T001~T008）。完成 T008 即可宣稱「admin-api envsubst image 已產出 + static acceptance PASS」。

**Incremental delivery**:
1. **MVP point**: T008 PASS — image 結構正確、無 hardcoded 預設
2. **Hardening point**: T011 完成 — deploy/ 改動完整
3. **Submodule sync**: T013 完成 — outer pin 對齊 inner HEAD
4. **Acceptance**: T014 + T015 — dynamic 全綠 + evidence 落地
5. **Doc sync**: T016 — CHECKLIST 標完成
6. **Remote sync**: T017 — outer push

**對齊原則**: §I 同源（不變）、§II 外部化（本 feature 主軸完全達成）、§III 最小 GAP（scope 控在 admin-api + deploy 6 個檔）、§IV 上游驗證（R1-R6 PASS）、§V 兩段式 commit、§VI Spec-Driven、§VII Conventional Commits 中文。
