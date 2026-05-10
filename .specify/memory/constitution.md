<!--
SYNC IMPACT REPORT
Version change: (initial) → 1.0.0
Bump rationale: First ratification — 把 CLAUDE.md / INTEGRATION-PLAN.md 既有決策正式化為 normative constitution。
Modified principles: (none, initial draft)
Added sections: Core Principles (7 條)、Additional Constraints、Development Workflow、Governance
Removed sections: (none)
Templates requiring updates:
  ✅ .specify/templates/plan-template.md — `Constitution Check` 段保留通用 placeholder（plan 階段會引用本檔）；本檔 7 原則中的 §I/§II/§III/§IV/§V 將作為 plan-time gates
  ✅ .specify/templates/spec-template.md — 無需修改（spec 不直接引用 constitution）
  ✅ .specify/templates/tasks-template.md — 無需修改
Follow-up TODOs:
  - CLAUDE.md §4/§6/§7 與本檔有部分重疊（兩段式 commit、no CorsLayer、commit 規範）— 後續可在 CLAUDE.md 加 cross-reference 指向本檔，當衝突時以本檔為準（已寫進 §Governance）
-->

# new-admin-root Constitution

## Core Principles

### I. 同源反代優先 (Same-Origin via Reverse Proxy)

對外通訊一律走 nginx 同源（瀏覽器 → `/api/*` → rust-server）。**禁止**在 Rust 後端啟用 `tower_http::cors::CorsLayer`；**禁止**在 production compose 把 rust-server / postgres / redis port 暴露給 host。dev override 允許在 `compose.dev.yaml` 顯式暴露，僅供 vite 開發 proxy 使用。

**Rationale**：CORS 是部署層問題、不是應用層問題。在 Rust 加 CorsLayer 會讓 dev 與 prod 的 origin 行為分歧、prod 要小心 origin allowlist；同源 nginx 一勞永逸。

**Verification**：`grep -rn "CorsLayer\|tower_http::cors" admin-api/server/` 必須 0 命中；prod compose.yaml 對外只暴露 nginx-ui port。

### II. 外部化設定 (Externalized Configuration)

任何隨環境變動的設定（DB url、secret、port、host、log level）必須透過 env 變數注入，使用 envsubst template (`application.yaml.tpl`) 在 entrypoint 階段渲染。**禁止** hardcode 在 `application.yaml`、`.env.prod`、Dockerfile 內、compose.yaml 內（除了預設 fallback）。

**Rationale**：避免「dev 改了 prod 沒改」的設定漂移；secrets 必須能用 docker secret / k8s secret / CI vault 注入，不能寫死在 image layer 裡。

**Verification**：`server/resources/` 不再有 `application.yaml`、改為 `application.yaml.tpl`；`grep -rn "<HARDCODED_VALUE>"` 對所有可能 hardcode 點（DB url、JWT secret、host）必須 0 命中；`docker exec rust-server env` 能列出所有 runtime config。

### III. 最小 GAP 修補 (Smallest Diff per GAP)

每個整合 GAP（INTEGRATION-PLAN §4 列出的 10 個）必須有自己的 spec / plan / tasks / commit 系列。**禁止**把多個 GAP 綁在一個 PR 或一個 spec 內。**禁止**順手 refactor 不在 spec scope 內的程式碼。

**Rationale**：GAP 之間互相獨立，bundle 起來增加 review 與 rollback 成本；每個 GAP 的 verification 標準不同，混在一起無法分別驗。

**Verification**：每個 spec.md 開頭明確指出 scope（單一 GAP id 或單一 feature 主題）；commit message 的 scope 段（`feat(admin-web): GAP-0a ...`）與 spec 對齊；diff 不包含與 scope 無關的檔案。

### IV. 上游驗證 (Verify Upstream Conventions)

任何依賴上游約定的部分（預設密碼、endpoint 存在、idempotency 保證、欄位命名、回應結構）必須在 spec 的 Assumptions 段明列為「待驗證」，並在 implementation 階段以**運行中的 infrastructure** 證實。**不得**只憑文件 / README / 上游 commit message 假設。

**Rationale**：CLAUDE.md §5 列預設密碼 `Soybean@123.` 但加上「依上游慣例，但要實驗驗證」警告 — 歷史證明上游文件常與 code 不一致（例如 GAP-0a 的 success code 0000 vs 200 就是這種陷阱）。

**Verification**：spec.md 的 Assumptions 段必須列出所有上游依賴；plan.md 的 Verification 段對每項給出具體驗證指令（curl / psql query / cargo test）；實作 commit 訊息註明已驗證的依賴項。

### V. 兩段式 Submodule Commit (NON-NEGOTIABLE)

改 `admin-web/` 或 `admin-api/` 內的內容必有兩段 commit：

1. **第一段**（worktree 內）：`feat(<scope>): <subject>` → `git push origin <branch>` 推到 fork branch
2. **第二段**（外層）：`chore(submodule): bump <admin-web|admin-api> 到 <短SHA>: <一行描述>` → `git push` 到 outer remote

跳過第二段會導致 outer 的 SHA pin 與實際 fork HEAD 不同步、別人 clone 拿到舊版檔案，違反 submodule 模型的承諾。

**Rationale**：submodule 模型只記 SHA pin、不記檔案 diff；維持 pin integrity 是 outer repo 唯一能提供的「跨倉版本綁定」。

**Verification**：每次外層 commit 後 `git submodule status` 行首必須是空格（clean）；`+` 表示 worktree 超前 outer pin、需立刻補第二段；CI 應加 check：每個動了 submodule pin 的 commit 都對應到該 fork branch 上的真實 commit。

### VI. Spec-Driven Development (NON-NEGOTIABLE)

任何 feature（含 GAP 修補、deploy infra 建立、Dockerfile 改造）必須走完 spec-kit **規劃階段**（specify / plan / tasks）：

```
/speckit-specify → (/speckit-clarify) → /speckit-plan → /speckit-tasks → (/speckit-analyze) → /speckit-implement
```

**實作階段**可二選一：(a) `/speckit-implement` 直接執行 tasks、或 (b) 轉給 `superpowers:test-driven-development` skill 走 TDD 流程。兩者都必須先有 `spec.md / plan.md / tasks.md` 為依據。

**禁止**直接動 code 而沒有對應的 `specs/<###-feature>/spec.md`。例外只限：(a) 修 typo 或格式、(b) 救火型 hotfix（事後補 spec）。

**Rationale**：規格在前能避免「邊寫邊想需求」的反覆 rework；plan 階段的 Constitution Check 能擋下違反 §I-§V 的設計；tasks 的依賴排序避免 implementation 走錯順序。實作階段保留兩條路（spec-kit implement vs superpowers TDD），讓「快速直譯 tasks」與「test-first 嚴格紀律」兩種風格都有正規入口。

**Verification**：每個非 hotfix commit 訊息能對應到 `specs/<###-feature>/spec.md`；`/speckit-analyze` 跑完回 0 issues；無對應 spec 的 commit 必須在 commit body 明示「hotfix, spec to follow」。

### VII. Conventional Commits in 中文 (NON-NEGOTIABLE)

所有 commit message 採 [Conventional Commits](https://www.conventionalcommits.org/) 格式 + **中文 subject / body**：

```
<type>(<scope>): <subject 中文>

<body 中文，可選>

Co-Authored-By: ...
```

`type` 從 `feat / fix / docs / chore / refactor / style / perf / test / build / ci / revert` 擇一；`scope` 用 `admin-web / admin-api / deploy / docs / graphify / submodule / spec` 等。詳細範例見 CLAUDE.md §6.3。

**Rationale**：commit history 是 changelog 的源頭；統一格式讓 changelog generator 可運作、log 可被機器分析、log 可搜尋。

**Verification**：`git log --oneline -20 | grep -vE '^[a-f0-9]+ (feat|fix|docs|chore|refactor|style|perf|test|build|ci|revert)(\(.+\))?(!)?: '` 應為空（除 merge commits 外）。

---

## Additional Constraints

### 技術棧（鎖定）

| 層 | 用途 | 元件 | 版本 |
|---|---|---|---|
| 前端 | UI 框架 | Vue | 3.5+ |
| 前端 | 建置工具 | Vite | 8 |
| 前端 | UI 元件庫 | NaiveUI | 2.44+ |
| 前端 | 型別系統 | TypeScript | 6 |
| 前端 | 套件管理 | pnpm | 10.5+ |
| 後端 | 程式語言 | Rust | 1.86+ |
| 後端 | Web 框架 | axum | 0.8 |
| 後端 | ORM 框架 | Sea-ORM | 1.1 |
| 後端 | 權限管理 | Casbin | 2.10 |
| Infra | 容器編排 | Docker Compose | v2 |
| Infra | 反向代理 | nginx | 1.27 |
| Infra | 資料緩存 | Redis | 7 |
| Infra | 資料庫 | Postgres | 17 |
| 工具 | SDD 框架 | spec-kit | v0.8.7 |
| 工具 | 知識圖譜 | graphify | latest |

### 部署

- 對外只開 nginx-ui (`UI_PORT`，預設 `:8080`)，其他服務內網互通。
- secrets via env 注入；`.env` 進 `.gitignore`，`.env.example` 必 commit。
- 預設管理員密碼（如 `Soybean@123.`）必須在首次部署後立即更換；migration seed 不得帶弱密碼進 production image。

### 跨平台相容

- 必須在 Linux + Windows（含 TortoiseGit）都能正常 clone / commit / push。
- **禁止**在追蹤檔案中使用 symlink（已有先例：docs/GRAPH_REPORT.md symlink 移除事件，commit `f872242`）。
- 換行統一以 LF 為準，必要時用 `.gitattributes` 強制。

### 語言

- **文件 / 註解 / commit message / spec / plan / tasks**：中文。
- **code identifier (變數 / 函式 / 類別 / API 路由 / 環境變數名)**：英文。
- **產品介面（admin UI）**：簡中 + 繁中 + 英文（依 SoybeanAdmin i18n）。

---

## Development Workflow

### 兩層 Git 結構

| 層 | 倉 | 追蹤 |
|---|---|---|
| outer | `./ (本 repo)` ⊂ `miso168net/fork260509@new-admin-root` | spec / plan / tasks 文件、deploy 設定、constitution、graphify 產出、submodule SHA pin |
| inner (worktree) | `admin-web/` ⊂ `miso168net/fork260509-soybean-admin@new-admin-base-web` | 前端 source code |
| inner (worktree) | `admin-api/` ⊂ `miso168net/fork260509-soybean-admin-rust@new-admin-rust-api` | 後端 source code |

詳細操作手冊（worktree 建立、submodule 同步、故障處理、Claude session 開場 SOP）見 `CLAUDE.md §9`。

### Spec-Driven Development 全流程

```
1. /speckit-specify <feature description>     # 產 spec.md（user stories + acceptance + assumptions）
2. /speckit-clarify     (optional)             # 5 個澄清問題
3. /speckit-plan                               # 產 plan.md（technical context + Constitution Check + structure）
4. /speckit-tasks                              # 產 tasks.md（依賴排序的 actionable tasks）
5. /speckit-analyze     (optional)             # 跨 artifact 一致性檢查
6. /speckit-implement   (optional)             # 詢問是否執行 tasks / 或轉給 superpowers (Test-Driven Development)
7. 兩段式 commit                                # 見 §V
```

### 驗證閘 (Verification Gates)

- **Plan 階段**：Constitution Check 必過（檢查 §I-§V 是否被違反）。
- **GAP 修補完成後**：smoke test 必跑（curl 7 條 API 全綠才算成功，見 INTEGRATION-PLAN §6.4）。
- **PR 合併前**：CI 必 build 雙 image (`new-admin-base-web`, `new-admin-rust-api`) + 單元測試通過。
- **上游慣例（§IV）**：必須有 verification 證據（curl / psql output / cargo test 結果）附在 PR / commit body。

---

## Governance

### Constitution 凌駕 ad-hoc 決策

當 `CLAUDE.md` / `docs/INTEGRATION-PLAN.md` / Conversation 中的決策與本 constitution 衝突，**以本 constitution 為準**。其他文件需修正以對齊；如本 constitution 過時，走下方 Amendment 流程更新。

### Amendment 流程

任何原則變更：

1. 提出修改的 PR，附 rationale（為何變、為何現在變）。
2. 跑 `/speckit-constitution` 重產 sync impact report、更新本檔。
3. 更新所有受影響的 templates（特別是 `plan-template.md` 的 Constitution Check）。
4. 更新版本號（語意化版本）：
   - **MAJOR**：移除原則、向後不相容的治理變更。
   - **MINOR**：新增原則 / section / 顯著擴充指引。
   - **PATCH**：用詞修正、typo、無語意變動的微調。
5. PR title 格式：`docs: 修訂 constitution 至 vX.Y.Z (修改概要)`。
6. 更新 `Last Amended` 日期。

### Compliance

- 所有 PR 在 `/speckit-plan` 階段必過 Constitution Check（gate）。
- `/speckit-analyze` 報告中發現違反原則的項目必須在 merge 前 resolve、或在 plan.md `Complexity Tracking` 段明確 justify。
- **季度回顧**：每季回顧 constitution 是否仍貼合 project 實況、修訂或廢止過時條款。

---

**Version**: 1.0.0 | **Ratified**: 2026-05-10 | **Last Amended**: 2026-05-10
