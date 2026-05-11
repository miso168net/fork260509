---

description: "Tasks for feature 006-admin-web-dockerfile"
---

# Tasks: admin-web-dockerfile

**Input**: Design documents from `/specs/006-admin-web-dockerfile/`
**Prerequisites**: plan.md ✅、spec.md ✅、research.md ✅、data-model.md ✅、contracts/admin-web-image.md ✅、quickstart.md ✅

**Tests**: 本 feature 屬 deploy artefact，無 unit test 加入點；驗證走 (a) static acceptance（image build + structural inspect + size + cache hit）、(b) dynamic acceptance（瀏覽器登入 smoke），其中 (b) 因 R5 (admin-api `/health` endpoint 缺失) 必須等 feature 6 merge 或獨立 micro-feature 補 /health 後執行 —— 列為 follow-up（與 features 4/5 同模式）。

**Organization**: tasks 依 2 個 user stories（US1 P1 = 整套 prod stack 可起 + 登入 / US2 P2 = image hygiene）+ §V 兩段式 commit（admin-web 版，第 3 次走 — 重用 features 2/5 模式）展開。**唯一**動到的檔在 `admin-web/`（Dockerfile + .dockerignore），所有改動屬同一個 inner commit。

## Format: `[ID] [P?] [Story] Description`

- 路徑：admin-web 倉內檔以 `admin-web/<path>` 表示；outer 倉檔以 root-relative path
- §V 兩段式 commit（**admin-web** 版、第 3 個使用本模式的 feature）：T002 在 admin-web/ worktree 內 commit、T005 push fork、T006 是 outer SHA pin commit

---

## Phase 1: Setup（共享前置）

**Purpose**: 確認 admin-web/ worktree health + 切到對的 branch（new-admin-base-web）+ Docker 環境 ready + 確認 feature 1 既有 deploy artefacts（nginx config、compose.yaml 內 new-admin-base-web service entry）就位。

- [ ] T001 在 outer repo root（`/mnt/d/AnewSpaces/x_Project/fork260509`）跑 `git submodule status` 確認 admin-web 行行首為空格（clean，SHA 為 feature 5 完成時的 7b167559）；`cd admin-web && git branch --show-current` 確認在 `new-admin-base-web`；`git status` 確認 worktree clean；`ls -la admin-web/.git` 確認是 ASCII text（worktree mode）；`ls admin-web/Dockerfile admin-web/.dockerignore 2>&1` 確認兩檔皆 "No such file or directory"（避免覆蓋既有）；`ls deploy/nginx/default.conf deploy/compose.yaml` 確認 feature 1 既有 artefacts 都在；`docker --version && docker compose version` 確認 docker ≥ 24、compose v2 已裝。

---

## Phase 2: Foundational

**Purpose**: 無 —— 所有改動位於 admin-web/Dockerfile + .dockerignore 兩個 brand-new 檔；feature 1 既有 compose / nginx 不動；foundational concept 不適用本 feature 結構。

---

## Phase 3: User Story 1 - Operator 可用單一指令啟動完整 prod stack 並從瀏覽器登入 (Priority: P1) 🎯 MVP

**Goal**: 寫出 admin-web/Dockerfile（multi-stage builder + runtime）+ .dockerignore，產出可被 compose.yaml line 106-125 `new-admin-base-web` build 規格觸發的 image。image build 通過後，整套 prod stack（postgres + redis + migration + admin-api + admin-web）可 `docker compose up -d` 起來、瀏覽器訪問 :8080 可看到 login 頁、`Soybean/123456` 登入後進 dashboard。

**Independent Test**:
- 靜態（本 feature 自身可跑）：`docker compose build new-admin-base-web` 成功；`docker images new-admin-base-web` 顯示 image 已產生；`docker run --rm --entrypoint sh new-admin-base-web -c 'ls /etc/nginx/conf.d/default.conf && ls /usr/share/nginx/html/index.html'` 兩個檔都在
- 動態（**依 R5 補上 + feature 6 merge**）：`docker compose up -d` 全 service healthy；瀏覽器 `http://localhost:8080` 顯示 login → 輸入 `Soybean/123456` → dashboard 出現 + ROLE_SUPER menu tree；deep link `/home/analysis` 直接 nav 也成功；停 admin-api 後 API request 回 502 → 列入 T010 follow-up

### Inner Commit（在 admin-web/ worktree 內，§V 第一段、admin-web 版）

- [ ] T002 [US1] 在 `admin-web/` 內新增**兩個檔**（同一 inner commit；對應 spec FR-701~721 全部、依 quickstart.md §A.1 落地）：
   - **`admin-web/Dockerfile`**（multi-stage）：
     - `syntax=docker/dockerfile:1.7` directive
     - **builder stage** `FROM node:22-alpine`：6 個 ARG（PNPM_VERSION=10.5.0、VITE_BASE_URL=/、VITE_SERVICE_BASE_URL=/api、VITE_APP_TITLE=NewAdmin、VITE_AUTH_ROUTE_MODE=static、VITE_STATIC_SUPER_ROLE=R_SUPER）+ ENV 把 5 個 VITE_* 暴露給 build（R6 已驗，覆蓋 .env.prod 內 mock URL）；`RUN npm install -g pnpm@${PNPM_VERSION}`；COPY `admin-web/package.json admin-web/pnpm-lock.yaml ./` 先；`RUN pnpm install --frozen-lockfile`；COPY `admin-web/ ./`；`RUN pnpm build` → 產出 `/app/dist`（R2 verified outDir 預設）
     - **runtime stage** `FROM nginx:1.27-alpine AS runtime`：`COPY --from=builder /app/dist /usr/share/nginx/html`；`COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf`（從 build context outer 根，R4 已驗）；3 個 OCI image labels；`EXPOSE 80`；`HEALTHCHECK --interval=15s --timeout=5s --retries=3 --start-period=5s CMD wget --spider --quiet http://localhost/health || exit 1`
   - **`admin-web/.dockerignore`**（per data-model.md Entity 2）：排除 `node_modules/`、`dist/`、`.turbo/`、`.git/`、`.vscode/`、`.idea/`、`*.log`、`coverage/`、`.DS_Store`、`Thumbs.db`、`Dockerfile`（self）、`.dockerignore`（self）—— **不**排除 `.env*` / `build/` / `src/` / `public/`（Vite build 需要）
   - 驗：`grep -c "^FROM " admin-web/Dockerfile` ≥ 2（multi-stage）；`grep -q "^node_modules" admin-web/.dockerignore`；`grep -E "COPY.*deploy/nginx" admin-web/Dockerfile` ≥ 1 hit
   - 在 admin-web/ worktree 內 inner commit：`feat(admin-web): 新增 multi-stage Dockerfile + .dockerignore`（commit body per quickstart.md §A.1）

- [ ] T003 [US1] 在 outer repo root 跑 `docker compose build new-admin-base-web`（依 build context = outer 根、`admin-web/Dockerfile`）。預期：cold build < 5 分鐘（SC-701），結束無 error。失敗診斷：(a) 若 `pnpm install` 失敗 → 檢查 `pnpm-lock.yaml` 是否被 `.dockerignore` 排除（不該被）；(b) 若 nginx COPY 失敗 → 檢查 build context 是否為 outer 根（compose.yaml line 108 `context: ..`）；(c) 若 `pnpm build` 失敗 → cd admin-web 本機跑 `pnpm build` 對照。

**Checkpoint**: T002 + T003 完成 = US1 MVP 主交付完成；image 已 build 出來、結構正確。瀏覽器登入屬 dynamic acceptance（T010 follow-up）。

---

## Phase 4: User Story 2 - Build 與 image 符合 image hygiene 最佳實踐 (Priority: P2)

**Goal**: image size ≤ 150 MB、final layer 不含 source code / node_modules / 開發工具、第二次 build（source 無變動）≤ 30 秒。

**Independent Test**: image build 後跑 4 個 inspect 指令 + 2 次 build 時間量測，全部達標即 US2 完成。

- [ ] T004 [US2] **靜態 hygiene 驗收**：在 outer repo root 跑下列 5 個驗證（全部 PASS 才算 US2 達標；對應 SC-704~708）：
  1. **image size ≤ 150 MB**（SC-705）：`docker images new-admin-base-web --format '{{.Size}}'` —— 預期數字 ≤ 150 MB（typical nginx-alpine + Vue dist ~ 30-50 MB）
  2. **runtime 無 node**（SC-708 + FR-704）：`docker run --rm --entrypoint sh new-admin-base-web -c 'which node || echo NO_NODE'` —— 預期 `NO_NODE`
  3. **runtime 無 source / node_modules / tsconfig**（SC-708 + FR-706）：`docker run --rm --entrypoint sh new-admin-base-web -c 'ls /'`，輸出 grep `src\|node_modules\|tsconfig` 應 0 hits
  4. **nginx config 在 image 內**（FR-707/708）：`docker run --rm --entrypoint sh new-admin-base-web -c 'grep -E "try_files|proxy_pass" /etc/nginx/conf.d/default.conf'` —— 兩個 directive 都應 hit
  5. **第二次 build 時間 ≤ 30 秒**（SC-706）：`time docker compose build new-admin-base-web`（直接重跑、source 無變動）—— 預期全 layer cache hit、real time ≤ 30s
  任一失敗：回 T002 修 Dockerfile 結構（如 stage 分割不對、`COPY` 順序錯導致 layer cache 失效）。

**Checkpoint**: T004 完成 = US2 主交付完成；image 符合 production hygiene 標準。

---

## Phase 5: Polish & Cross-Cutting

### Submodule push（§V 第一段 push）

- [ ] T005 在 admin-web/ 內 `git push origin new-admin-base-web` 把 T002 之 inner commit 推到 fork（`miso168net/fork260509-soybean-admin`）。**NEEDS USER AUTHORIZATION**（per CLAUDE.md §5 全域 push 確認規則）—— 推前先問使用者：「Inner commit 已落、ready to push admin-web fork？」

### Outer SHA pin commit（§V 第二段）

- [ ] T006 在 outer repo root：`git status` 應看到 `modified content: admin-web (new commits)`；`SHORT_SHA=$(cd admin-web && git rev-parse --short HEAD)`；`git add admin-web`；`git commit -m "chore(submodule): bump admin-web 到 $SHORT_SHA: feature 7 Dockerfile + .dockerignore"`（commit body per quickstart.md §A.4）。**不**直接 push outer，等 T008。

### Static Acceptance Evidence

- [ ] T007 在 `specs/006-admin-web-dockerfile/acceptance-evidence/` 下建 `T007-static.md`，把 T003 build log（時間、size）+ T004 全部 5 個 hygiene 驗證 output（包含 image inspect、ls 輸出、grep 結果、time 量測）貼上、標 PASS/FAIL；對應 SC-701/SC-705/SC-706/SC-708。最後在 outer 加 1 個 commit：`test(admin-web): T007 static acceptance evidence PASS`。

### Outer push（依使用者授權）

- [ ] T008 在 outer 跑 `git push`（推到 `miso168net/fork260509@new-admin-root`）。**NEEDS USER AUTHORIZATION** —— 推前先問：「Feature 7 outer commits（submodule bump + acceptance evidence）ready to push origin？」此時可同 PR 一起推 feature 7 全套。

### CHECKLIST 同步 + R# writeback

- [ ] T009 更新 `docs/INTEGRATION-CHECKLIST.md`（**outer commit，與本 feature 同 PR**）：
   - **roadmap 表 row 7（admin-web-dockerfile）**：spec / plan / impl 三欄改 `✅`，狀態欄改「完成 (SHA range；admin-web inner: <短SHA>)」
   - **跨 feature 待驗證項**：若 R5 在本 feature 期間獨立解（不太可能，本 feature 不夾帶 admin-api 改動）則勾掉；否則維持 `[ ]` 等 feature 6
   - **Retrospective code review backlog**：若 T004 hygiene 驗收過程發現新的 review item（如 nginx config 漂移、Dockerfile layer 不夠 lean），列入該段
   - 把 R1-R7 結果（research.md 已 verified 的 finding）以一段 summary 寫進 spec.md `## Assumptions` 段尾，標 ✅，引用 commit SHA + 證據出處（package.json、vite.config.ts、grep result）
   - 在 outer 加 1 個 commit：`docs: T009 INTEGRATION-CHECKLIST feature 7 標完成 + spec.md R1-R7 writeback`

### Dynamic Acceptance Follow-up（不在本 feature 範圍，列為 follow-up tracker）

- [ ] T010 **本 task 不在本 feature 期間執行** —— 依 R5（admin-api `/health` endpoint 補上）+ feature 6 (`dockerfile-envsubst`) merge 之後執行：
   - `docker compose up -d` 起整套 stack；
   - 等所有 service healthy（admin-api healthcheck `/health` 通過）；
   - 瀏覽器 `http://localhost:8080` → login `Soybean/123456` → dashboard + menu tree（SC-702/703，spec US1 Acceptance Scenario 2/3）；
   - deep link `/home/analysis` 直接 nav 應成功（SC-704，US1 Scenario 4）；
   - `docker compose stop new-admin-rust-api`，瀏覽器 API request 應收 502（US1 Scenario 5）；
   - 把 evidence 寫進 `specs/006-admin-web-dockerfile/acceptance-evidence/T010-dynamic.md`，作為 retrospective archive 附在 feature 6 merge PR 或獨立 micro-PR；
   - 完成後在 CHECKLIST 內把本 task `[ ]` → `[x]`。

---

## 依賴圖

```
T001 (Setup)
  ↓
T002 [US1] (Dockerfile + .dockerignore + inner commit)
  ↓
T003 [US1] (docker compose build verify)
  ↓
T004 [US2] (image hygiene checks)
  ↓
T005 (inner push, user auth)
  ↓
T006 (outer SHA pin commit)
  ↓
T007 (static evidence + commit)
  ↓
T008 (outer push, user auth)  ─┬─→  T009 (CHECKLIST sync + spec writeback)
                                 │
                                 └──→ T010 (dynamic, follow-up — 依 feature 6)
```

無 [P] 並行機會 —— 本 feature 結構偏 sequential（單一 artefact、單一 inner commit、序列驗證）。

---

## Implementation Strategy

**MVP scope** = US1（T001 → T002 → T003）。完成 T003 即可宣稱「admin-web 容器化 image 已產出且 build 通過」。

**Incremental delivery**:
1. **MVP delivery point**: T003 完成 —— image 已 build、結構正確（dynamic acceptance 屬 follow-up）
2. **Quality gate**: T004 完成 —— image hygiene 達標
3. **Submodule sync**: T005 + T006 完成 —— outer pin 對齊 inner HEAD
4. **Evidence + doc**: T007 + T009 完成 —— acceptance evidence + CHECKLIST/spec 更新
5. **Remote sync**: T008 完成 —— outer remote 收到全套 feature 7
6. **Future**: T010 等 R5 + feature 6

**對齊原則**: §I 同源反代（nginx 在 admin-web image 內）、§II 外部化設定（VITE_* 用 ARG）、§III 最小 GAP（不夾帶 admin-api /health）、§IV 上游驗證（R1-R7 research.md 已 verify）、§V 兩段式 commit、§VI Spec-Driven、§VII Conventional Commits 中文。
