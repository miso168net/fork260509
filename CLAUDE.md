# CLAUDE.md — workspace 指引

> 此檔覆寫並補充全域 `~/.claude/CLAUDE.md`。專案特定規則優先；通用規則沿用全域。

---

## 1. 工作區用途

這是**跨 fork 的整合研究與設計工作區**，也是傘狀整合 repo（`new-admin-root`）的根。最終結構由三個 git 物件組成：

| 命名 | 是什麼 | 對應目錄 | remote / 來源 | 在外層 git |
|---|---|---|---|---|
| `new-admin-root` | 傘狀 monorepo（**就是當前 workspace**） | `.` | （TBD：未來推到自己的 GitHub） | 自身 |
| `new-admin-base-web` | `fork260509-soybean-admin` 上的新分支 | `admin-web/`（worktree） | push 回 `miso168net/fork260509-soybean-admin` 的 `new-admin-base-web` 分支 | submodule（記 SHA pin） |
| `new-admin-rust-api` | `fork260509-soybean-admin-rust` 上的新分支 | `admin-api/`（worktree） | push 回 `miso168net/fork260509-soybean-admin-rust` 的 `new-admin-rust-api` 分支 | submodule（記 SHA pin） |

`admin-web/` 與 `admin-api/` 是**worktree + submodule 雙重身分**：
- **本機**：透過 `git worktree add -b <branch>` 建立，`.git` 是 file 指向源倉的 `worktrees/`，`cd admin-web && git commit/push` 直接寫回 fork repo 的對應分支。
- **外層 `new-admin-root`**：把它們當 submodule 處理（gitlink + `.gitmodules`），每次外層 commit 紀錄當下使用的 fork SHA。**外層看不到檔案 diff，只看到 SHA pin 變動**。
- **別人 clone 外層**：`git clone --recurse-submodules` 會拉 fork repo 到 admin-web/ admin-api/（變正常 clone 而非 worktree，但內容相同）。

兩段式 commit 是日常工作流，詳見 §6 與 §9 操作手冊。

**目前狀態**：研究與計畫階段完成；尚未建立 worktree 與 submodule 配置。

## 2. 目錄結構

```
fork260509/                                ← workspace root（傘狀 repo new-admin-root 的工作目錄）
├── CLAUDE.md                              ← 本檔（workspace 指引）
├── .gitignore                             ← 排除 fork 源倉與 graphify cache（不排除 admin-web/admin-api，它們是 submodule）
├── .gitmodules           (尚未建立)        ← 未來：admin-web/admin-api 的 submodule 設定（指 fork remote）
├── docs/                                  ← 跨倉設計產出（外層 git 追蹤）
│   ├── INTEGRATION-RESEARCH.md            ← 初版 gap 分析（4 個 GAP）
│   └── INTEGRATION-PLAN.md                ← 完整實施計畫（10 個 GAP、含 docker compose / Dockerfile / nginx conf）
│   ※ 知識圖譜報告在 ../graphify-out/GRAPH_REPORT.md（不放 symlink，避免 Windows TortoiseGit 操作異常）
├── graphify-out/                          ← 知識圖譜輸出（外層 git 只追蹤 graph.json + GRAPH_REPORT.md）
│   ├── GRAPH_REPORT.md                    ← 含 god nodes / surprises / suggested questions
│   ├── graph.json                         ← 結構化圖譜資料（可被 graphify query 查）
│   ├── manifest.json           (gitignored, --update 增量基準，個人化)
│   ├── cost.json               (gitignored, token 用量帳單，個人化)
│   ├── cache/                  (gitignored, LLM 擷取快取，可重產)
│   ├── obsidian/               (gitignored, 4674 筆記)
│   └── graph.html              (gitignored, 互動視覺化)
├── fork260509-soybean-admin/              ← Vue 3 starter，worktree 源倉（gitignored，本機必留）
├── fork260509-soybean-admin-docs/         ← 文件站（gitignored，整合不用，僅參考）
├── fork260509-soybean-admin-nestjs/       ← NestJS backend + Vue frontend（gitignored，整合不用，僅參考）
├── fork260509-soybean-admin-rust/         ← Rust axum + Casbin backend，worktree 源倉（gitignored，本機必留）
├── admin-web/        (尚未建立)            ← 未來：worktree + submodule（外層記 gitlink SHA）
├── admin-api/        (尚未建立)            ← 未來：worktree + submodule（外層記 gitlink SHA）
└── deploy/           (尚未建立)            ← 未來：docker-compose / nginx / .env.example
```

**關鍵事實**：
- `admin-web/` `admin-api/` 是 worktree + submodule 雙重身分（見 §1 與 §9 操作手冊）— 外層 commit 只記 SHA pin、不記檔案 diff；別人 clone 用 `--recurse-submodules`。
- `fork260509-*` 源倉 gitignored，但**本機必須留著**（worktree 源倉）；別台機器若用 submodule clone 重來則不需要這 4 個源倉。
- 知識圖譜報告 `GRAPH_REPORT.md` 只存在 `graphify-out/`，docs/ 不放 symlink（Windows TortoiseGit 對 symlink 處理異常）。要看就直接開 `graphify-out/GRAPH_REPORT.md`。
- 外層 git 追蹤：`CLAUDE.md`、`.gitignore`、`.gitmodules`（未來）、`docs/{INTEGRATION-RESEARCH.md, INTEGRATION-PLAN.md}`、`graphify-out/{graph.json, GRAPH_REPORT.md}`、以及 `admin-web` `admin-api` 兩個 gitlink SHA（未來）。

## 3. 知識圖譜（graphify）

圖譜已建好（3,616 nodes / 3,543 edges / 1058 communities，跨 4 個 fork）。

**使用方式**：
- 查問題：在 workspace root 執行 `graphify query "你的問題"` — 走 BFS 預設、`--dfs` 改 DFS、`--budget N` 限 token
- 解釋節點：`graphify explain "節點名"`
- 找路徑：`graphify path "節點A" "節點B"`
- 增量更新：`graphify update`（會用 `manifest.json` 比對變更）

**已知圖譜限制**（重要 — 推論前要記得）：
- **NestJS DI 結構在圖中是破碎的**：AST extractor 看不懂 `@Module({ imports, providers })` decorator 也沒解 ES6 `import`。22 個 NestJS module + ~1900 個 .ts file-level node 是孤立的。問 NestJS 部分時要直接讀檔，別只信圖。
- **Vue component composition 也破碎**：182 個 `.vue` 元件孤立（因為 `<template>` 標籤對應到 import 元件的關係沒被抓）。
- **Rust 部分圖譜可信**：god nodes / cohesion / bridges 都站得住腳。
- **PNG 流程圖（如 router-guard-flow.png）擷取準確 ~94%**，但**沒連到實作**：33 個流程節點與 `router/guard/route.ts` 的 4 個函式之間 0 邊。
- **`get_db_connection()` 的 48 條 INFERRED edge 方向是反的**（實際是 caller→callee，圖譜寫成 callee→caller）。

詳見 `docs/INTEGRATION-RESEARCH.md` 的「圖譜可信度」章節。

## 4. 整合計畫的關鍵決策（從 docs/INTEGRATION-PLAN.md 摘要）

| 主題 | 決策 |
|---|---|
| 倉儲結構 | 傘狀 monorepo `new-admin-root/{admin-web,admin-api,deploy,docs}` — `admin-web/` 與 `admin-api/` 同時是 git worktree（本機操作）+ git submodule（外層記 SHA pin） |
| Reverse proxy | nginx（解 CORS via 同源）— 不在 Rust 加 CorsLayer |
| Database 連線 | 不用 pgbouncer，Sea-ORM 內建 pool 即可 |
| Refresh token | DB-backed（用既有 `sys_tokens` 表）— 不用 stateless JWT |
| Migration | init container（`docker compose run --rm migration`） |
| Dev workflow | docker compose 起 infra+rust-server，host 跑 `pnpm dev`（vite proxy 到 :10001） |
| Prod workflow | 全 docker compose；對外只暴露 nginx-ui :8080 |

**10 個必修 GAP**（清單在 docs/INTEGRATION-PLAN.md §4）。最危險的：
- GAP-0a：Rust 回 `code:200`，前端要 `'0000'` → 改 `.env`
- GAP-0c：Rust serialize `refresh_token`（snake），前端要 `refreshToken`（camel） → 加 `#[serde(rename_all = "camelCase")]`
- GAP-0f：Login body field `userName` vs `identifier` → 改前端 1 行
- GAP-1：refresh handler 完全不存在 → ~80 行 Rust

## 5. 預設帳號（dev 用）

依 `migration/src/datas/m20241024_033005_insert_sys_user.rs`：

| 帳號 | 角色 | 密碼 |
|---|---|---|
| `Soybean` | 超級管理員 | `Soybean@123.`（依上游慣例，但要實驗驗證） |
| `Administrator` | admin | 同上 |
| `GeneralUser` | 一般 | 同上 |

3 個 user 共用同一個 argon2id 雜湊。**驗證後若密碼不同，請更新此處**。

## 6. 開發守則（workspace-specific）

### 6.1 兩段式 commit（submodule 模式的核心紀律）

改 `admin-web/` 或 `admin-api/` 內檔案後，**永遠是兩段 commit**：

```bash
# === 第一段：在 worktree 內 commit + push 到 fork ===
cd admin-web
git status                                    # 確認在 new-admin-base-web 分支
git add <files> && git commit -m "..."
git push origin new-admin-base-web            # 推到 miso168net/fork260509-soybean-admin

# === 第二段：回外層更新 SHA pin ===
cd ..
git status                                    # 應該看到 "modified content" 在 admin-web
git add admin-web                             # 只 add 目錄即可（記 SHA，不記檔案）
git commit -m "bump admin-web to <短 SHA>: <一行描述>"
git push                                      # 推到外層 new-admin-root remote
```

第二段的 outer commit 訊息**建議帶 SHA 與 fork 提交標題**，以後在外層 log 看得懂：

```
bump admin-web to abc1234: GAP-0a fix success code
bump admin-api to def5678: GAP-1 add refresh handler
```

### 6.2 其他守則

1. **改 fork 源倉**（如要拉 upstream rebase）：`cd fork260509-xxx && git fetch upstream && git rebase ...`。worktree 自動跟著走（共用 .git database）；之後仍要回外層 `git add admin-web && git commit` 更新 pin。
2. **CLAUDE.md / docs/INTEGRATION-*.md 改動**：在外層 `new-admin-root` repo 改、commit、push（單段 commit，不需第二段）。
3. **不要在 docs/ 重新建 symlink** 指向 graphify-out/（Windows TortoiseGit 對 symlink 處理會出問題）。GRAPH_REPORT.md 唯一位置就是 `graphify-out/GRAPH_REPORT.md`，要在 docs/ 看到「凍結快照」就 `cp graphify-out/GRAPH_REPORT.md docs/` 並 commit 為實檔。
4. **graphify 重跑前**：先讀 `graphify-out/cost.json` 看是否真有需要（一次 ~440K input / 190K output token）。多數時候 `graphify update` 即可。
5. **不要改 `graphify-out/cache/`**：那是 graphify 內部的 LLM 擷取結果快取，手改會破壞下次 update 的 diff。
6. **新功能設計問題**先用 `graphify query "..."` 試 — 但 NestJS / Vue component 部分要警覺圖譜盲點（§3）。

### 6.3 Commit message 規範

**格式**：[Conventional Commits](https://www.conventionalcommits.org/)、**訊息一律中文**。

```
<type>(<scope>): <subject>          ← subject 用中文

<body 可選，中文>

<footer 可選，中文，例如 BREAKING CHANGE / Closes #N>
```

**常用 type**：

| type | 用途 | 範例 |
|---|---|---|
| `feat` | 新功能 | `feat(admin-api): GAP-1 加入 POST /auth/refreshToken` |
| `fix` | 修 bug | `fix(admin-web): GAP-0a 修正 success code 對齊（0000 → 200）` |
| `docs` | 純文件改動 | `docs: INTEGRATION-PLAN §3 補上 submodule 註冊流程` |
| `chore` | 雜項（設定、submodule pin、依賴） | `chore: 註冊 admin-web/admin-api 為 submodule` |
| `refactor` | 重構（不改功能、不修 bug） | `refactor(admin-api): 抽出 token 產生器 helper` |
| `style` | 格式調整（不影響邏輯） | `style: 統一 .env 排版` |
| `perf` | 效能優化 | `perf(admin-api): get_db_connection 加 lazy init` |
| `test` | 增加測試 | `test(admin-api): refresh handler 單元測試` |
| `build` | 建置系統 / 外部依賴 | `build(admin-web): 升 vite 8.0.8 → 8.1.0` |
| `ci` | CI 設定 | `ci: 加入 admin-web build workflow` |
| `revert` | 還原 commit | `revert: 撤回 chore: 註冊 submodule` |

**scope 建議**（本專案）：`admin-web` / `admin-api` / `deploy` / `docs` / `graphify` / `submodule` 等；可省略。

**兩段式 commit 的 message 慣例**（搭配 §6.1）：

第一段（worktree 內，正常 conventional commit）：
```
feat(admin-api): GAP-1 加入 POST /auth/refreshToken

實作 refresh token 處理器，使用 sys_tokens 表查詢 + rotate。
~80 行 Rust。

Closes GAP-1
```

第二段（外層更新 SHA pin，用 `chore(submodule)`）：
```
chore(submodule): bump admin-api 到 abc1234 — GAP-1 refresh handler
```

> outer commit 訊息**務必帶上短 SHA 與 fork 提交主旨**，這樣外層 log 一眼看出每次 pin 移動對應哪個改動。

### 6.4 Claude session 開場 SOP

每次 session 開頭先檢查 submodule 狀態，發現 drift 主動提示：

```bash
git submodule status         # 列出兩個 submodule 的 SHA 與 branch
# 若行首是 ' ' = clean、'+' = SHA 不一致（pin 與 worktree HEAD 不同）、'-' = 未 init
```

若看到 `+` 開頭，代表 worktree 的 HEAD 已超前 outer 記的 SHA pin — 提醒使用者：「admin-web/ 或 admin-api/ 的 worktree 已超前 outer pin，要不要更新 pin？」

## 7. 不要做的事

- ❌ 不要在外層 `new-admin-root` repo `git add fork260509-*/`（4 個源倉 gitignored，會變 embedded git）。`admin-web/` `admin-api/` **可以** add（它們是 submodule，唯一正確方式就是 `git add admin-web` 記 SHA pin）。
- ❌ 不要 `git submodule add ../<...> admin-web`：這會嘗試 clone 進 admin-web/、與既有 worktree 衝突。submodule 設定要**手寫 .gitmodules**（見 §9）。
- ❌ 不要在 worktree 裡跑 `git push` 不指定 remote/branch — `cd admin-web` 預設推到 fork260509-soybean-admin，可能誤推 main 分支；用 `git push origin new-admin-base-web` 顯式指定。
- ❌ 不要忘記第二段 commit：worktree 內改完 push 完，**一定要回外層 `git add admin-web && git commit`** 更新 pin，否則外層下次 commit 才會包進去（容易混淆 SHA 對應關係）。
- ❌ 不要在 Rust `application.yaml` 直接改 hardcode（已決定改用 envsubst template，見 docs/INTEGRATION-PLAN.md §5.3）。
- ❌ 不要新增 README.md 到外層 root（已有 CLAUDE.md + docs/，多了亂；要外發再寫）。
- ❌ 不要在 Rust 加 CorsLayer（決策走 nginx 同源；改 CorsLayer 會讓 prod 路徑分歧）。
- ❌ 不要碰 `fork260509-soybean-admin-docs/` 與 `fork260509-soybean-admin-nestjs/`（不在整合範圍內，留作參考）。

## 8. 該做但目前還沒做

- [ ] **建立 worktree + submodule 配置**（一次性，跟著 §9 SOP 跑）
- [ ] 建立 `deploy/` 與裡面的 `compose.yaml` / `nginx/default.conf` / `.env.example`（樣板都在 docs/INTEGRATION-PLAN.md §5）
- [ ] 修補 10 個 GAP（清單與 patch 在 docs/INTEGRATION-PLAN.md §4；GAP-0 系列要先做才能 login）
- [ ] 驗證預設密碼是不是 `Soybean@123.`
- [ ] 驗證 `process_collected_routes()` 是 idempotent upsert（重啟不重複）
- [ ] 驗證 Rust 是否有 `/health` endpoint（compose healthcheck 需要）
- [ ] 在 `sys_tokens` 表加 `expires_at` 欄位（refresh token 否則永不過期）

---

## 9. Submodule 操作手冊（給未來 Claude session）

> 此節是讓我（Claude）在後續對話接手時知道怎麼處理 submodule 的權威來源。
> User 的角色是審核與下達指令；實際操作與檢查由我執行。

### 9.1 一次性初始化（worktree + 手寫 .gitmodules）

```bash
# Step 1：建立 worktree（從 fork 源倉開新分支）
cd fork260509-soybean-admin
git fetch origin
git worktree add -b new-admin-base-web ../admin-web
cd ..

cd fork260509-soybean-admin-rust
git fetch origin
git worktree add -b new-admin-rust-api ../admin-api
cd ..

# Step 2：把 worktree 分支推到 fork remote（submodule 必須有 url 可指）
cd admin-web && git push -u origin new-admin-base-web && cd ..
cd admin-api && git push -u origin new-admin-rust-api && cd ..

# Step 3：手寫 .gitmodules（不能用 git submodule add，會與 worktree 衝突）
cat > .gitmodules << 'EOF'
[submodule "admin-web"]
    path = admin-web
    url = https://github.com/miso168net/fork260509-soybean-admin.git
    branch = new-admin-base-web
[submodule "admin-api"]
    path = admin-api
    url = https://github.com/miso168net/fork260509-soybean-admin-rust.git
    branch = new-admin-rust-api
EOF

# Step 4：把 submodule 註冊進 outer git config（讓 git submodule status 認得）
git config -f .gitmodules submodule.admin-web.path admin-web
git config -f .gitmodules submodule.admin-api.path admin-api
git submodule init

# Step 5：outer 第一次 add 兩個 gitlink + .gitmodules
#   小心：git 會跳 "warning: adding embedded git repository"，正常
git add .gitmodules admin-web admin-api
git commit -m "init: register admin-web/admin-api as submodules"
```

### 9.2 平時工作流（兩段 commit）

詳見 §6.1。

### 9.3 同步檢查（每次 session 開頭）

```bash
git submodule status
# 範例輸出：
#  abc1234 admin-web (heads/new-admin-base-web)        ← 開頭空格 = clean
# +def5678 admin-api (heads/new-admin-rust-api-2-gxyz) ← 開頭 + = SHA 不一致
# -                  admin-web                         ← 開頭 - = 未 init（需 git submodule update --init）
```

行為對照：
- **空格開頭**：outer pin == worktree HEAD，乾淨。
- **`+` 開頭**：worktree HEAD 已超前 outer pin。**主動提示**使用者：「admin-web/ worktree 已超前 outer pin，要不要 `git add admin-web && git commit -m '...'` 更新？」
- **`-` 開頭**：在新 clone 的機器上，submodule 還沒 init。跑 `git submodule update --init --recursive`。

### 9.4 別台機器 clone 流程

```bash
git clone --recurse-submodules <outer repo url> new-admin-root
cd new-admin-root
git submodule update --init --recursive
# 此時 admin-web/ admin-api/ 是「正常 clone」（不是 worktree），但內容相同
# 若要恢復 worktree 模式（需要源倉），手動 init fork 源倉再 worktree
```

### 9.5 升級 fork branch 到最新（拉 upstream rebase 後）

```bash
cd admin-web
git fetch upstream                    # upstream 是原 soybeanjs 的 repo
git rebase upstream/main              # 或對應分支
git push --force-with-lease           # 推自己的 fork（會改寫 history，注意）
cd ..

# 同步 outer pin
git add admin-web
git commit -m "bump admin-web: rebase on upstream <短 SHA>"
```

### 9.6 故障處理速查

| 症狀 | 原因 | 處理 |
|---|---|---|
| `git status` 在外層顯示 `modified: admin-web (modified content)` | worktree 內有未 commit 的變動 | 進 worktree commit，再回外層更新 pin |
| `git status` 顯示 `modified: admin-web (new commits)` | worktree HEAD 超前 outer pin | 回外層 `git add admin-web && git commit` 更新 pin |
| `git submodule update` 想覆蓋本機改動 | outer pin SHA 與本機 worktree HEAD 不同 | **不要 submodule update**！會 reset worktree。應走「更新 pin」方向 |
| 別人 clone 後 admin-web/ 是空的 | 沒跑 `--recurse-submodules` | 補跑 `git submodule update --init --recursive` |
| `warning: adding embedded git repository` | 正常警告，git 提醒這是 gitlink 行為 | 忽略，可用 `git config advice.addEmbeddedRepo false` 永久關掉 |

### 9.7 我（Claude）每次接手前的快速健檢

```bash
# 跑這 4 個指令並回報結果：
git status                            # 外層狀態
git submodule status                  # submodule SHA 對齊狀況
ls -la admin-web/.git admin-api/.git  # 確認還是 worktree（檔而非目錄）
git log --oneline -5                  # 最近 5 個外層 commit，看 pin 變動歷史
```

若發現 worktree 不存在（`.git` 不在），代表使用者可能在新機器或 worktree 被誤刪 — 提示走 §9.1 重建。
