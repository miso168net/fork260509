# new-admin-root

> 傘狀整合 repo：把 [SoybeanAdmin](https://github.com/soybeanjs/soybean-admin)（Vue 3 starter）與 [SoybeanAdmin Rust](https://github.com/ByteByteBrew/soybean-admin-rust)（axum + Casbin）整合成一套 admin，docker-compose 編排運行環境。

跨倉設計產出（GAP 分析、實施計畫、知識圖譜）放在 `docs/` 與 `graphify-out/`。實際前後端原始碼透過 git submodule 連到 fork repo 的對應分支。

| 子件 | 來源 | 對應目錄 |
|---|---|---|
| 傘狀 repo | 本 repo `miso168net/fork260509` | `.` |
| 前端（base-web） | `miso168net/fork260509-soybean-admin` 的 `new-admin-base-web` 分支 | `admin-web/` (submodule) |
| 後端（rust-api） | `miso168net/fork260509-soybean-admin-rust` 的 `new-admin-rust-api` 分支 | `admin-api/` (submodule) |

---

## 1. 在新機器上重建

### 必要工具

| 工具 | 用途 | 最低版本 |
|---|---|---|
| git | 全部都需要 | 2.30+（worktree 支援好） |
| gh CLI | push、PR 操作（可選） | 2.0+ |
| Docker + Docker Compose | 跑整套 stack | docker 24+ / compose v2 |
| pnpm | 改 admin-web 時建置（可選） | 10.5+ |
| Node.js | pnpm 依賴 | 22+ |
| Rust toolchain | 改 admin-api 時建置（可選） | 1.86+ |
| Python 3.11+ + [`graphify`](https://github.com/safishamsi/graphify) | 重新查知識圖譜（可選） | — |

### 模式 A：純 submodule（推薦起手）

```bash
git clone --recurse-submodules https://github.com/miso168net/fork260509.git new-admin-root
cd new-admin-root

# 驗證
git submodule status
# 應該看到兩行行首是空格（clean）：
#  <SHA> admin-api (...)
#  <SHA> admin-web (...)
```

完成。能直接 `cd admin-web && pnpm install && pnpm dev`、`cd admin-api && cargo build` 等。改完在各自目錄 commit/push 會直接進對應 fork branch。

**回外層更新 SHA pin** 是兩段式 commit 的第二段，詳見 `CLAUDE.md §6.1`。

### 模式 B：worktree + submodule 雙重（進階，本機開發者用）

只有當您**經常在這台機器拉 upstream rebase**、想保留源倉做同步區、worktree 做開發區時才走這條。

```bash
# 步驟 1：先模式 A clone 一次
git clone --recurse-submodules https://github.com/miso168net/fork260509.git new-admin-root
cd new-admin-root

# 步驟 2：記下當前 SHA pin（轉換完要對齊驗證）
git submodule status | tee /tmp/pins.txt

# 步驟 3：移除 submodule auto-clone 的 admin-web / admin-api
#   注意：這只刪 working tree，不影響 outer repo 的 .gitmodules / gitlink
rm -rf admin-web admin-api

# 步驟 4：另外 clone 兩個 fork 源倉
git clone https://github.com/miso168net/fork260509-soybean-admin.git
git clone https://github.com/miso168net/fork260509-soybean-admin-rust.git

# 步驟 5：源倉切到 main，再用 worktree checkout 既有分支
cd fork260509-soybean-admin
git switch main
git worktree add ../admin-web new-admin-base-web
cd ..

cd fork260509-soybean-admin-rust
git switch main
git worktree add ../admin-api new-admin-rust-api
cd ..

# 步驟 6：對齊 SHA pin（worktree HEAD 應該與 outer pin 一致）
git submodule status
diff /tmp/pins.txt <(git submodule status)
# 若不一致，cd 進 worktree 用 git checkout <pinned-sha>，或回外層 git add admin-web/admin-api 更新 pin
```

詳細運維手冊（升級 / 故障處理 / Claude session 開場 SOP）見 `CLAUDE.md §9`。

---

## 2. 跑整套 stack（docker-compose）

> ⚠️ **未實作**：`deploy/compose.yaml` 尚未建立。完整樣板與啟動順序見 `docs/INTEGRATION-PLAN.md §5、§6`。

預期流程（待 deploy/ 建好後）：

```bash
cd deploy
cp .env.example .env && vim .env       # 填 secrets
docker compose build
docker compose up -d postgres redis
docker compose run --rm migration       # 初始化 schema + seed
docker compose up -d new-admin-rust-api new-admin-base-web
# 對外：http://localhost:8080
# 預設帳號：Soybean / Soybean@123.（待驗證）
```

---

## 3. 文件導覽

| 檔案 | 內容 |
|---|---|
| `README.md` | 本檔（給人類讀） |
| `CLAUDE.md` | dev assistant 的內部手冊（命名約定、開發守則、submodule SOP、commit 規範） |
| `docs/INTEGRATION-RESEARCH.md` | 初版 gap 分析（4 GAP） |
| `docs/INTEGRATION-PLAN.md` | 完整實施計畫（10 GAP、docker compose 範本、CI、風險） |
| `graphify-out/GRAPH_REPORT.md` | 跨 4 fork 的知識圖譜總覽（god nodes / surprises / suggested questions） |
| `graphify-out/graph.json` | 結構化圖譜資料（可被 `graphify query` 查） |

---

## 4. 改動 admin-web / admin-api 的兩段式 commit

```bash
# === 第一段：在 worktree 內 commit + push 到 fork ===
cd admin-web              # 或 admin-api
git status                                       # 確認在 new-admin-base-web 分支
git add <files> && git commit -m "feat(...): ..."
git push origin new-admin-base-web

# === 第二段：回外層更新 SHA pin ===
cd ..
git status                                       # 應該看到 "modified content" 在 admin-web
git add admin-web                                # 只 add 目錄（記 SHA，不記檔案）
git commit -m "chore(submodule): bump admin-web 到 <短SHA>: <一行描述>"
git push
```

**Commit 規範**：中文 + Conventional Commits（`feat` / `fix` / `docs` / `chore` / 等），詳細範例與規則見 `CLAUDE.md §6.3`。

---

## 5. 授權

各子件依其上游授權：
- SoybeanAdmin (admin-web 來源): MIT
- SoybeanAdmin Rust (admin-api 來源): Apache-2.0
- 本傘狀 repo 的 docs/ 與 graphify-out/：見各檔案
