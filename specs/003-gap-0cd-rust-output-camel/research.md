# Phase 0 Research: gap-0cd-rust-output-camel

**Feature**: `003-gap-0cd-rust-output-camel`
**Date**: 2026-05-11
**Purpose**: 把 spec.md Assumptions §IV 上游慣例待驗證項落為具體可執行指令；§V 兩段式 commit 流程的 admin-api 版具現化（reuse feature 2 R5 結構、目標 submodule 改 admin-api）。

---

## R1: `Res::new_data` 包 data field 確認（spec assumption #1）

**待驗證命題**：admin-rust-api `Res::new_data(data)` 把序列化的 struct 包進 `{"code":..., "data": <struct>, "msg": ...}` 的 `data` field（不是 root-level merge）。

**Verification 指令**（implement 階段必跑、不依賴 feature 6）：

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# 找 Res 定義
grep -rnE 'pub fn new_data|impl.*Res|struct Res' server/ | head -10

# 預期看到 Res<T> struct 含 data: T field、new_data 把 data param 包進 struct
# 範例可能在 server/model/src/admin/types/mod.rs 或 server/handler/...
```

**判讀**：
- Res 用 `data: T` field 包：✅ R1 通過、AuthOutput/UserInfoOutput 加 derive 修補後對 admin-web 可見的 path 為 `.data.refreshToken` / `.data.buttons`
- Res 用其他結構（root merge / data unwrapped）：spec 假設不成立、回頭重新評估 patch 範圍

**結果回填位置**：spec.md `Assumptions > 待驗證的上游慣例` 第 1 項

---

## R2: GAP-0c 動態驗證（依 feature 6 merge）

**待驗證命題**：修補後 admin-rust-api login response `.data` 含 `refreshToken`（駝峰）、不含 `refresh_token`（snake）。

**Verification 指令**（feature 6 envsubst 完成、admin-rust-api 容器 healthy 後跑）：

```bash
BASE=http://localhost:8080/api    # 同源反代後（feature 1 nginx）

# 拿 token + refresh token
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq '.data | keys'
# 期望輸出：["refreshToken", "token"]（駝峰）
# 不該看到："refresh_token"

# 反向驗：grep snake 應 0 命中
curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq -r 'tostring' | grep -c 'refresh_token'
# 期望：0
```

**判讀**：
- `.data | keys` 含 `refreshToken` + 不含 `refresh_token`：✅ R2 通過、FR-301 修補生效
- 仍含 `refresh_token`：cargo build 沒重 build / image 沒 rebuild / derive attribute 沒生效

---

## R3: GAP-0d 動態驗證（依 feature 6 merge）

**待驗證命題**：修補後 admin-rust-api `getUserInfo` response `.data` 含 `buttons` field（array type）。

**Verification 指令**：

```bash
BASE=http://localhost:8080/api

# 先 login 拿 token
TOKEN=$(curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}' \
  | jq -r '.data.token')

# 拿 user info
curl -sS $BASE/auth/getUserInfo \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.data'
# 期望輸出包含 4 個 fields：
# {
#   "userId": "...",
#   "userName": "Soybean",
#   "roles": [...],
#   "buttons": []     ← 本 feature 加，目前永空 placeholder
# }

# 驗 buttons 是 array type
curl -sS $BASE/auth/getUserInfo \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.data.buttons | type'
# 期望：array
```

**判讀**：
- `.data.buttons` 存在且是 array：✅ R3 通過、FR-310 + FR-311 修補生效
- `.data.buttons` 不存在：handler 沒加 init / struct 沒加 field / image 沒 rebuild

---

## R4: cargo build 驗證（implement 階段必跑、不依賴 feature 6）

**待驗證命題**：本 feature 加的 derive attribute + struct field + handler init 不破壞 admin-api 既有 cargo build。

**Verification 指令**：

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# 改完後跑 cargo check（比 build 快）
cargo check --release 2>&1 | tail -30
# 期望：Finished + 0 errors + 0 new warnings（既有 warnings 可能保留）

# 完整 build（更嚴）
cargo build --release 2>&1 | tail -10
# 期望：Compiling ... Finished `release` profile [optimized] target(s) in <X>s
```

**判讀**：
- `cargo check` PASS：✅ R4 通過、SC-301 達成
- 出現 `error[`：implementation 有 syntax / type error，BLOCKED 上報

**注意**：第一次 build admin-api 可能 ~10-30 分鐘（與 feature 1 T008 同數量級，因為 build cache 已在 feature 1 dev 跑時建立、第二次應快很多）。如要省時間、用 `cargo check` 即可（不產 binary）。

---

## R5: §V 兩段式 commit 流程（admin-api 版，reuse feature 2 R5 結構）

**Workflow Reference**：`CLAUDE.md §6.1` + `CLAUDE.md §9.2` + `feature 2 research.md R5`（admin-web 版藍本）。本 R5 給 feature 3 tasks 用的 admin-api 版精確指令序列。

### 5.1 第一段：admin-api/ worktree 內 commit + push fork

```bash
# 從 outer repo root 出發
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# Step A：確認在對的 branch（new-admin-rust-api）
git branch --show-current        # 必輸出：new-admin-rust-api
test "$(git branch --show-current)" = "new-admin-rust-api" \
  || { echo "FAIL: 不在 new-admin-rust-api branch"; exit 1; }

# Step B：改檔（依 task 範圍）
# 例：T002 改 server/model/src/admin/output/sys_authentication.rs（GAP-0c + 0d struct）
# 例：T003 改 server/api/src/admin/sys_authentication_api.rs（GAP-0d handler）

# Step C：cargo check 驗證（每個 task 改完後跑）
cargo check --release 2>&1 | tail -10

# Step D：inner commits（每個 GAP 獨立 commit；GAP-0d 涉及 model + api 兩處改、合 1 commit）
git status
git diff --stat

# inner commit 1：GAP-0c
git add server/model/src/admin/output/sys_authentication.rs   # 注意：只 add GAP-0c 改的部分
# 若 GAP-0c 改動已 staged：
git commit -m "fix(admin-api): GAP-0c AuthOutput camelCase

加 #[serde(rename_all = \"camelCase\")] derive，讓 refresh_token 序列化
為 refreshToken，對齊 admin-web Api.Auth.LoginToken 期望。

Refs: new-admin-root specs/003-gap-0cd-rust-output-camel/spec.md FR-301
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

# inner commit 2：GAP-0d（涉及 model + api 兩檔，合 1 commit）
git add server/model/src/admin/output/sys_authentication.rs \
        server/api/src/admin/sys_authentication_api.rs
git commit -m "fix(admin-api): GAP-0d UserInfoOutput buttons placeholder

UserInfoOutput 加 pub buttons: Vec<String> field（admin-web Api.Auth.UserInfo
期望此 field）；get_user_info handler 內初始化 buttons: vec![] placeholder。
未來 button 級權限實作會替換填值邏輯，但 field/schema 不變。

Refs: new-admin-root specs/003-gap-0cd-rust-output-camel/spec.md FR-310 FR-311
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

# Step E：所有 inner commits 完成後一次 push fork remote
git push origin new-admin-rust-api
# 預期：To https://github.com/miso168net/fork260509-soybean-admin-rust.git
#       <old-SHA>..<new-SHA>  new-admin-rust-api -> new-admin-rust-api
```

### 5.2 第二段：outer 倉 SHA pin 提交 + push outer

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer repo root

# Step F：確認 git status 顯示 admin-api 有新 commits
git status
# 預期看到：modified: admin-api (new commits)

# Step G：取 admin-api 新 SHA（短 7 碼）
NEW_ADMIN_API_SHA=$(cd admin-api && git rev-parse --short HEAD)
echo "admin-api 新 SHA: $NEW_ADMIN_API_SHA"

# Step H：outer commit
git add admin-api   # add 目錄、git 記 SHA pin（gitlink）
git commit -m "chore(submodule): bump admin-api 到 ${NEW_ADMIN_API_SHA}: feature 3 GAP-0cd

inner commits（在 fork260509-soybean-admin-rust@new-admin-rust-api）：
- fix(admin-api): GAP-0c AuthOutput camelCase
- fix(admin-api): GAP-0d UserInfoOutput buttons placeholder

at this point: admin-api response 對 admin-web 端期望完成 wire-level
對齊（feature 2 已對齊送出 + codes 識別、本 feature 3 對齊接收 shape）。
動態 acceptance 等 feature 6 merge 後跑（admin-rust-api 容器啟動）。

Refs: specs/003-gap-0cd-rust-output-camel/spec.md
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

# Step I：push outer（user 同意後）
git push origin 003-gap-0cd-rust-output-camel
```

### 5.3 同步檢查（之後任何時間都應 PASS）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509
git submodule status
# 預期 admin-api 行行首是空格（clean）：
#  <SHA> admin-api (heads/new-admin-rust-api)
```

---

## 5 個 Decisions 摘要

| ID | Decision | Rationale | Alternatives |
|---|---|---|---|
| R1 | grep `Res::new_data` impl 確認 data 包進 `data` field | spec assumption #1 是後續 wire shape 解讀的根據 | implementer 跳過直接信 — 風險：spec 可能錯、回頭重做 |
| R2 | curl /auth/login + jq `.data \| keys` 應含 refreshToken | 驗 GAP-0c FR-301 修補生效 | 讀 image 內 binary symbols（過度） |
| R3 | curl /auth/getUserInfo + jq `.data.buttons \| type` = array | 驗 GAP-0d FR-310/311 修補生效 | 同上 |
| R4 | cargo check --release 應 0 errors | 驗 SC-301、確認 Rust syntax 正確 | cargo build（慢、但更嚴）— 也可選 |
| R5 | admin-api 兩段式 commit 流程（reuse feature 2 結構、目標改 admin-api） | 第一次動 admin-api submodule、需具現化藍本給 tasks | inline in CLAUDE.md §9（已有，本 R5 是 admin-api specific） |

**Phase 0 結論**：5 個 decisions 全落地，含 verification 指令 + 流程具現化。R1/R4 在 implement 階段直接驗（不依賴 feature 6）；R2/R3 動態驗等 feature 6 merge。

進入 Phase 1: Design & Contracts。
