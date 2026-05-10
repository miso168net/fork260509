# Phase 0 Research: gap-0ab0f-frontend-env-and-login

**Feature**: `002-gap-0ab0f-frontend-env-and-login`
**Date**: 2026-05-11
**Purpose**: 把 spec.md Assumptions 段的 §IV 上游慣例待驗證項落為具體可執行指令；把 §V 兩段式 submodule commit 流程具現化（本 feature 是第一個動 submodule 的 feature）。

> 本檔目標是給 tasks.md 用的「精確指令藍本」，避免 implementer 自行揣測步驟。

---

## R1: GAP-0a 上游驗證 — admin-rust-api 對 200 response 的 code 值

**待驗證命題**：admin-rust-api `Res::new_data` 對成功 response 送 `{"code": 200, ...}` 而非 `{"code": "0000", ...}` 或其他業務碼。

**Verification 指令**（feature 6 envsubst 完成、admin-rust-api 容器 healthy 後跑）：

```bash
BASE=http://localhost:8080/api    # 同源反代後（feature 1 nginx）
# 或 dev 直連 BASE=http://localhost:10001（feature 1 dev override）

# 預期 response：{"code":200,"data":{"token":"...","refreshToken":"..."},"msg":"..."}
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq '.code'
# 期望輸出：200（純 number、不是 "0000" string）
```

**判讀**：
- 輸出 `200` → ✅ R1 通過、FR-201 採用值正確
- 輸出 `"0000"` 或其他 → ❌ INTEGRATION-PLAN §4 GAP-0a 描述有誤、回頭重新評估方案
- 輸出 `null` 或非 200 → admin-rust-api 不在預期狀態（檢查 docker compose logs）

---

## R2: GAP-0b 上游驗證 — admin-rust-api 對 unauthorized 的 code 值

**待驗證命題**：admin-rust-api 對 unauthorized 確實回 HTTP 401 + body code 401（而非 9999/9998/3333 等業務碼）。

**Verification 指令**：

```bash
BASE=http://localhost:8080/api

# 用無效 token 訪問需授權 endpoint
curl -sS -o /tmp/resp.json -w 'HTTP %{http_code}\n' \
  $BASE/auth/getUserInfo \
  -H 'Authorization: Bearer invalid-token-xxxx'
cat /tmp/resp.json | jq '.code'
# 期望：HTTP 401 + body code 401
```

**判讀**：
- HTTP 401 + body code 401 → ✅ R2 通過、FR-204 採用值正確
- HTTP 200 + body code != 200 → admin-rust-api 把 error 包進 200 wrapper（不是 spec 假設）
- HTTP 401 + body code 字串非 401 → admin-rust-api 用業務碼但與 fake codes 不對齊

---

## R3: GAP-0f 上游驗證 — admin-rust-api LoginInput 結構

**待驗證命題**：admin-rust-api `LoginInput` 是 `{identifier, password}`（INTEGRATION-PLAN §4 已從 source 確認；本 R3 補 runtime curl 驗）。

**Verification 指令**：

```bash
BASE=http://localhost:8080/api

# 試 1: 用 identifier（預期成功）
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq '.code'
# 期望：200

# 試 2: 用 userName（預期失敗 — 缺 identifier field）
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"userName":"Soybean","password":"Soybean@123."}' \
  | jq '.code'
# 期望：400 / 422 / 其他非 200（identifier missing 觸發 deserialize error）
```

**判讀**：
- 試 1 = 200 + 試 2 != 200 → ✅ R3 通過、FR-210 patch 必要
- 試 1 != 200 → admin-rust-api 不認 identifier、INTEGRATION-PLAN §4 GAP-0f 描述有誤
- 試 1 = 200 + 試 2 = 200 → admin-rust-api 同時接 identifier + userName（用 `#[serde(alias)]`）— FR-210 patch 仍正確但 R3 命題稍弱

---

## R4: 預設密碼驗證（CLAUDE.md §5 待驗證項）

**待驗證命題**：3 個 seed user（Soybean / Administrator / GeneralUser）的預設密碼都是 `Soybean@123.`。

**Verification 指令**：

```bash
BASE=http://localhost:8080/api

for user in Soybean Administrator GeneralUser; do
  CODE=$(curl -sS -X POST $BASE/auth/login \
    -H 'Content-Type: application/json' \
    -d "{\"identifier\":\"$user\",\"password\":\"Soybean@123.\"}" \
    | jq -r '.code // "no-response"')
  echo "$user: code=$CODE"
done
# 期望：3 行都是 code=200
```

**回填**（Verification 通過後）：
- 把 CLAUDE.md §5.1 表格內「依上游慣例，待驗證」字樣移除
- spec.md `Assumptions > 待驗證的上游慣例 > 預設管理員密碼` 勾選 ✅、加 evidence ref

---

## R5: §V 兩段式 submodule commit 流程（本 feature 第一個動 submodule，必做具現化）

**Workflow Reference**：`CLAUDE.md §6.1` + `CLAUDE.md §9.2` 已寫一般原則。本 R5 給本 feature tasks 用的精確指令序列。

### 5.1 第一段：admin-web/ worktree 內 commit + push fork

```bash
# 從 outer repo root 出發
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web

# Step A：確認在對的 branch（new-admin-base-web）
git branch --show-current        # 必輸出：new-admin-base-web
test "$(git branch --show-current)" = "new-admin-base-web" \
  || { echo "FAIL: 不在 new-admin-base-web branch"; exit 1; }

# Step B：改檔（依 task 範圍）
# 例：T001 改 .env 的 4 行
# 例：T002 改 src/service/api/auth.ts 的 1 行

# Step C：inner commit（每個 GAP 獨立 commit）
git status                       # 確認改動範圍正確
git diff --stat                  # 看行數
git add .env  # 或對應檔
git commit -m "fix(admin-web): GAP-0a 修正 success code（0000→200）

對齊 admin-rust-api Res::new_data 設 code = StatusCode::OK.as_u16() = 200。
$VITE_SERVICE_SUCCESS_CODE 由 0000 改 200，避免 admin-web 把所有
成功 response 當失敗。

Refs: new-admin-root specs/002-gap-0ab0f-frontend-env-and-login/spec.md FR-201
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

# Step D：所有 inner commits 完成後一次 push fork remote
git push origin new-admin-base-web
# 預期：To https://github.com/miso168net/fork260509-soybean-admin.git
#       <old-SHA>..<new-SHA>  new-admin-base-web -> new-admin-base-web
```

### 5.2 第二段：outer 倉 SHA pin 提交 + push outer

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer repo root

# Step E：確認 git status 顯示 admin-web 有新 commits
git status
# 預期看到：
#   modified: admin-web (new commits)
# 而非 (modified content) — 因為 worktree 內已 commit 完。

# Step F：取 admin-web 新 SHA（短 7 碼）
NEW_ADMIN_WEB_SHA=$(cd admin-web && git rev-parse --short HEAD)
echo "admin-web 新 SHA: $NEW_ADMIN_WEB_SHA"

# Step G：outer commit（依 §VII Conventional Commits 中文 + outer commit 慣例）
git add admin-web   # 注意：add 目錄、git 會記 SHA pin（gitlink），不會記檔案 diff
git commit -m "chore(submodule): bump admin-web 到 ${NEW_ADMIN_WEB_SHA}: feature 2 GAP-0ab0f

inner commits（在 fork260509-soybean-admin@new-admin-base-web 上）：
- fix(admin-web): GAP-0a 修正 success code（0000→200）
- fix(admin-web): GAP-0b 清空 fake logout codes + 對齊 expired token 401
- fix(admin-web): GAP-0f login body field userName→identifier

Refs: specs/002-gap-0ab0f-frontend-env-and-login/spec.md
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

# Step H：push outer
git push origin 002-gap-0ab0f-frontend-env-and-login
# 預期：To https://github.com/miso168net/fork260509.git
#       <old-SHA>..<new-SHA>  002-gap-0ab0f-frontend-env-and-login -> 002-gap-0ab0f-frontend-env-and-login
```

### 5.3 同步檢查（之後任何時間都應 PASS）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git submodule status
# 預期 admin-web 行行首是空格（clean）：
#  <SHA> admin-web (heads/new-admin-base-web)

# 行首是 + → outer pin 與 worktree HEAD 不同步、必補第二段
# 行首是 - → 未 init（新 clone 才會、本場景不會）
```

---

## 6 個 Decisions 摘要

| ID | Decision | Rationale | Alternatives |
|---|---|---|---|
| R1 | curl `/auth/login` `.code` 應 = 200 | 驗 INTEGRATION-PLAN §4 GAP-0a 描述、是 FR-201 根據 | 讀 admin-rust-api source（已做、本 R 補 runtime） |
| R2 | curl 無效 token `.code` 應 = 401 | 驗 INTEGRATION-PLAN §4 GAP-0b、是 FR-204 根據 | 同上 |
| R3 | curl 用 `identifier`（成功）+ `userName`（失敗）| 驗 INTEGRATION-PLAN §4 GAP-0f、是 FR-210 根據 | 同上 |
| R4 | 3 user × Soybean@123. → 全 code 200 | 驗 CLAUDE.md §5 待驗證項、是 §IV 第一個 verifying point | 看 admin-api migration seed source（已做、本 R 補 runtime） |
| R5 | 兩段式 submodule commit 精確指令序列 | 本 feature 第一個動 submodule、必須給 tasks 用的精確藍本 | inline in CLAUDE.md §9（已有，本 R5 是 feature-specific 增訂） |

**Phase 0 結論**：5 個 decisions 全落地，含 verification 指令 + 流程具現化。動態 verify 等 feature 6 merge 後跑（spec assumption 已說明）。本 feature **靜態 verify**（grep `.env` 值 + read auth.ts diff）可在 implement 階段直接做。

進入 Phase 1: Design & Contracts。
