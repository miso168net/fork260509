# Quickstart: gap-0cd-rust-output-camel

**Feature**: `003-gap-0cd-rust-output-camel`
**Audience**: implementer（實作者，走 §V 兩段式 commit、admin-api 版）+ operator（依 feature 6 merge 後跑動態 wire smoke）
**Estimated Time**: implementer ~30-45 分鐘（含一次 cargo check）/ operator ~3 分鐘

---

## 0. 前置條件

### implementer

- outer repo 已 fetch、本機已 checkout `003-gap-0cd-rust-output-camel` branch
- `admin-api/` worktree 健康（`git submodule status` 行首空格、`admin-api/.git` 是檔案）
- 在 `admin-api/` worktree 內 branch 是 `new-admin-rust-api`
- 已熟讀 `CLAUDE.md §6.1` 兩段式 commit + `feature 2 research.md R5` 兩段式範本（admin-web 版，本 feature reuse 結構）+ `research.md R5`（admin-api 版精確指令）
- 已讀過 `spec.md` / `plan.md` / `data-model.md` / `contracts/*`

### operator（動態驗證）

- feature 6 (dockerfile-envsubst) 已 merge（admin-rust-api 容器才能起）
- feature 1 deploy stack running（postgres + redis + migration healthy）
- 主機端 docker compose 可用、curl + jq 裝好

---

## 1. Implementer 流程（30-45 分鐘）

### 1.1 Pre-flight（5 分鐘）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509

# Step 1: 確認 outer 在對的 branch
git branch --show-current
# 應為 003-gap-0cd-rust-output-camel

# Step 2: 確認 admin-api worktree
cd admin-api
git branch --show-current   # 應為 new-admin-rust-api
git status                   # 應 clean
cd ..

# Step 3: 確認 submodule
git submodule status
# 兩行行首應為空格
```

### 1.2 Read source（3 分鐘 — 確認 spec assumption）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# 看 AuthOutput / UserInfoOutput 既有狀態
cat server/model/src/admin/output/sys_authentication.rs | head -25

# 看 get_user_info handler
sed -n '58,68p' server/api/src/admin/sys_authentication_api.rs

# 看 Res::new_data 把 data 包進 .data field（research R1）
grep -rnE 'fn new_data' server/ | head -3
# 確認 data 包進 Res<T> 的 data field
```

### 1.3 Inner commits（15 分鐘）— 在 admin-api/ worktree 內

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-api

# === Inner Commit 1: GAP-0c AuthOutput camelCase ===
# 用 Edit / sed 加 derive attribute
$EDITOR server/model/src/admin/output/sys_authentication.rs
# 在 line 4 (AuthOutput #[derive(...)] 後一行) 加 #[serde(rename_all = "camelCase")]

# 自驗
grep -B 1 'pub struct AuthOutput' server/model/src/admin/output/sys_authentication.rs

# cargo check（重要：早驗、避免 commit 後才發現 syntax error）
cargo check --release 2>&1 | tail -5

# inner commit 1
git diff --stat   # 應只動 1 檔、+1 行
git add server/model/src/admin/output/sys_authentication.rs
git commit -m "$(cat <<'EOF'
fix(admin-api): GAP-0c AuthOutput camelCase

加 #[serde(rename_all = "camelCase")] derive，讓 refresh_token 序列化
為 refreshToken，對齊 admin-web Api.Auth.LoginToken 期望。

Refs: new-admin-root specs/003-gap-0cd-rust-output-camel/spec.md FR-301

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"

# === Inner Commit 2: GAP-0d UserInfoOutput buttons placeholder ===
# 改 2 處：struct field + handler init
$EDITOR server/model/src/admin/output/sys_authentication.rs
# 在 UserInfoOutput 的 roles field 後加 pub buttons: Vec<String>,

$EDITOR server/api/src/admin/sys_authentication_api.rs
# 在 get_user_info 的 UserInfoOutput 初始化 roles: ... 後加 buttons: vec![],

# cargo check
cargo check --release 2>&1 | tail -5

# inner commit 2
git diff --stat   # 應動 2 檔、各 +1 行
git add server/model/src/admin/output/sys_authentication.rs \
        server/api/src/admin/sys_authentication_api.rs
git commit -m "$(cat <<'EOF'
fix(admin-api): GAP-0d UserInfoOutput buttons placeholder

UserInfoOutput 加 pub buttons: Vec<String> field（admin-web Api.Auth.UserInfo
期望此 field）；get_user_info handler 內初始化 buttons: vec![] placeholder。
未來 button 級權限實作會替換填值邏輯，但 field/schema 不變。

Refs: new-admin-root specs/003-gap-0cd-rust-output-camel/spec.md FR-310 FR-311

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 1.4 cargo build 完整驗（5 分鐘）

```bash
# inner 完成後跑完整 build 確認沒 break 既有
cargo build --release 2>&1 | tail -10
# 期望：Finished `release` profile [optimized] target(s) in <X>s
```

### 1.5 Push fork（2 分鐘）

```bash
git log --oneline -3   # 看最近 3 commits（含本 feature 2 inner commits + 既有 fork branch HEAD）
git push origin new-admin-rust-api
# 預期推 2 commits 到 fork
```

### 1.6 Outer SHA pin commit（5 分鐘）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer

git status   # 應看到 modified: admin-api (new commits)

NEW_SHA=$(cd admin-api && git rev-parse --short HEAD)
echo "new admin-api SHA: $NEW_SHA"

git add admin-api
git commit -m "$(cat <<EOF
chore(submodule): bump admin-api 到 ${NEW_SHA}: feature 3 GAP-0cd

inner commits（在 fork260509-soybean-admin-rust@new-admin-rust-api）：
- fix(admin-api): GAP-0c AuthOutput camelCase
- fix(admin-api): GAP-0d UserInfoOutput buttons placeholder

at this point: admin-api response 對 admin-web 端期望完成 wire-level
對齊（feature 2 已對齊送出 + codes 識別、本 feature 3 對齊接收 shape）。
動態 acceptance 等 feature 6 merge 後跑（admin-rust-api 容器啟動）。

Refs: specs/003-gap-0cd-rust-output-camel/spec.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 1.7 Static acceptance verification（5 分鐘）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509

# (a) AuthOutput 有 rename_all derive
cd admin-api && grep -B 1 'pub struct AuthOutput' server/model/src/admin/output/sys_authentication.rs \
  | grep -q 'rename_all = "camelCase"' && echo "PASS (a)" || echo FAIL && cd ..

# (b) UserInfoOutput 有 buttons field
cd admin-api && grep -A 8 'pub struct UserInfoOutput' server/model/src/admin/output/sys_authentication.rs \
  | grep -q 'pub buttons: Vec<String>' && echo "PASS (b)" || echo FAIL && cd ..

# (c) get_user_info handler 有 buttons: vec![]
cd admin-api && grep -A 6 'fn get_user_info' server/api/src/admin/sys_authentication_api.rs \
  | grep -q 'buttons: vec!\[\]' && echo "PASS (c)" || echo FAIL && cd ..

# (d) submodule status clean
test "$(git submodule status | grep -c '^ ')" -eq 2 && echo "PASS (d)" || echo FAIL

# (e) cargo build 過
cd admin-api && cargo check --release 2>&1 | grep -qE 'Finished' && echo "PASS (e)" || echo FAIL && cd ..
```

### 1.8 Push outer（user 同意後）

```bash
git push origin 003-gap-0cd-rust-output-camel
```

---

## 2. Operator 動態驗證流程（3 分鐘）— 依 feature 6 merge

### 2.1 起 dev stack（前提：feature 1 + feature 6 已 merged）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/deploy
docker compose -f compose.yaml -f compose.dev.yaml up -d \
  postgres redis migration new-admin-rust-api
docker compose ps   # 全 healthy / Exited(0)
```

### 2.2 GAP-0c 動態驗（refreshToken 駝峰）

```bash
BASE=http://localhost:8080/api    # 同源反代（feature 1）
# 或 BASE=http://localhost:10001  # dev override

# 拿 login response
RESP=$(curl -sS -X POST $BASE/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"Soybean@123."}')

echo "$RESP" | jq '.data | keys'
# 期望：["refreshToken", "token"]

echo "$RESP" | jq -r 'tostring' | grep -c 'refresh_token'
# 期望：0（snake 完全消失）
```

### 2.3 GAP-0d 動態驗（buttons array）

```bash
TOKEN=$(echo "$RESP" | jq -r '.data.token')

curl -sS $BASE/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq '.data'
# 期望輸出含 4 個 fields：
# {
#   "userId": "...",
#   "userName": "Soybean",
#   "roles": [...],
#   "buttons": []
# }

curl -sS $BASE/auth/getUserInfo -H "Authorization: Bearer $TOKEN" | jq '.data.buttons | type'
# 期望：array
```

---

## 3. 排錯指引

| 症狀 | 可能原因 | 對策 |
|---|---|---|
| `cargo check` 報 `error[E0277]: trait Serialize not implemented` | derive 順序錯（rename_all 應在 derive 後） | 檢查 attribute 順序：`#[derive(Clone, Debug, Serialize)]` 在前、`#[serde(rename_all = "camelCase")]` 在後 |
| `cargo check` 報 `unused variable buttons` | 加了 field 但 handler 沒用 / handler init 漏了 | 檢查 `get_user_info` 是否含 `buttons: vec![]` |
| login response 仍 `refresh_token` snake | image 沒 rebuild（feature 6 用了舊 cache） | `docker compose build --no-cache new-admin-rust-api && docker compose up -d` |
| getUserInfo response 缺 buttons | UserInfoOutput field 沒加 / handler 沒 init / image 沒 rebuild | 看 acceptance (b) (c)；如靜態驗 PASS、跑 docker compose build --no-cache |
| `git submodule status` 行首 `+` | inner 已 commit + push、outer 還沒 add+commit | `git add admin-api && git commit -m "chore(submodule): ..."` |

---

## 4. 完成標準

- ≤ 5 行 Rust diff（實際 +3 行：F1 +2 + F2 +1）
- 兩段式 commit 完成（fork branch + outer SHA pin）
- 5 條 static acceptance 全 PASS（含 cargo check）
- `git submodule status` 行首空格
- （依 feature 6 merge）動態 acceptance 2 條 PASS（GAP-0c + GAP-0d wire shape）
