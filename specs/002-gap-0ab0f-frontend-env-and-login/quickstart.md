# Quickstart: gap-0ab0f-frontend-env-and-login

**Feature**: `002-gap-0ab0f-frontend-env-and-login`
**Audience**: implementer（實作者，走 §V 兩段式 commit）+ operator（dev 模式 manual smoke 驗 login）
**Estimated Time**: implementer 30 分鐘 / operator 5 分鐘

---

## 0. 前置條件

### implementer

- 在 outer repo `001-deploy-infra` 已 merge 進 `new-admin-root`、本機已 checkout `002-gap-0ab0f-frontend-env-and-login` branch
- `admin-web/` worktree 健康（`git submodule status` 行首空格、`admin-web/.git` 是檔案）
- 已熟讀 `CLAUDE.md §6.1` 兩段式 commit + `CLAUDE.md §9` submodule 操作手冊
- 已讀過本 feature 的 `spec.md` / `plan.md` / `research.md` / `contracts/*`

### operator（動態驗證）

- feature 6 (dockerfile-envsubst) 已 merge（admin-rust-api 容器才能起）
- feature 1 deploy stack 已 running（postgres + redis + migration healthy）
- host 端裝好 pnpm 10.5+ / Node 22+ / 現代瀏覽器

---

## 1. Implementer 流程（30 分鐘）

### 1.1 Pre-flight（5 分鐘）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509

# Step 1: 確認 outer 在對的 branch
git branch --show-current
# 應為 002-gap-0ab0f-frontend-env-and-login

# Step 2: 確認 admin-web worktree 在對的 branch
cd admin-web
git branch --show-current
# 應為 new-admin-base-web
git status   # 應 clean
cd ..

# Step 3: 確認 submodule 健康
git submodule status
# admin-web 行行首應為空格（clean）
```

### 1.2 Inner commits（10 分鐘）— 在 admin-web/ worktree 內

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web

# === Inner Commit 1: GAP-0a + 0b（4 行 .env value）===
# 編輯 .env：把 line 32, 35, 38, 41 的 4 個 codes 對齊 admin-rust-api
$EDITOR .env
# 改完後跑 grep 自驗（contracts/env-codes.md 段尾）：
grep -cE '^(VITE_SERVICE_SUCCESS_CODE=200|VITE_SERVICE_LOGOUT_CODES=|VITE_SERVICE_MODAL_LOGOUT_CODES=|VITE_SERVICE_EXPIRED_TOKEN_CODES=401)$' .env
# 應輸出 4

# 看 diff
git diff .env

# 拆 2 個 commit：GAP-0a 一個、GAP-0b 一個（雖然同檔，但 GAP id 獨立可追溯）
# Strategy: 用 git add -p 分區
git add .env
git commit -m "$(cat <<'EOF'
fix(admin-web): GAP-0a 修正 success code（0000→200）

admin-rust-api Res::new_data 設 code = StatusCode::OK.as_u16() = 200，
admin-web 上游 .env 預設 VITE_SERVICE_SUCCESS_CODE=0000 會把所有
成功 response 當失敗。對齊改為 200。

Refs: new-admin-root specs/002-gap-0ab0f-frontend-env-and-login/spec.md FR-201

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"

# 注意：實際上 4 行 value 最好同 1 個 commit（同檔同主題、stage 拆 2 個 commit 反而 ceremony 過度）。
# 如要拆，用 git add -p 互動式選 hunks；或用單一 commit 涵蓋 GAP-0a + 0b：

# === （替代）單一 inner commit 涵蓋 GAP-0a + 0b ===
git commit -m "$(cat <<'EOF'
fix(admin-web): GAP-0a + 0b 對齊 admin-rust-api wire-level codes

GAP-0a: VITE_SERVICE_SUCCESS_CODE 0000 → 200
  對齊 admin-rust-api Res::new_data 設 code = 200（HTTP semantics）

GAP-0b: 清空 fake codes + 對齊 expired token 401
  - VITE_SERVICE_LOGOUT_CODES: 8888,8889 → 空
  - VITE_SERVICE_MODAL_LOGOUT_CODES: 7777,7778 → 空
  - VITE_SERVICE_EXPIRED_TOKEN_CODES: 9999,9998,3333 → 401
  admin-rust-api 用 HTTP status code 表達狀態，業務碼 fake 應清。

Refs: new-admin-root specs/002-gap-0ab0f-frontend-env-and-login/spec.md FR-201..204

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"

# === Inner Commit 2: GAP-0f（1 行 .ts data field rename）===
$EDITOR src/service/api/auth.ts
# 把 fetchLogin 內 data: { userName, password } 改為 data: { identifier: userName, password }

# 自驗（contracts/login-body.md §4.1）：
grep -qE 'identifier:\s*userName' src/service/api/auth.ts && echo PASS

git diff src/service/api/auth.ts
git add src/service/api/auth.ts
git commit -m "$(cat <<'EOF'
fix(admin-web): GAP-0f login body field userName → identifier

admin-web fetchLogin 送出 {"userName":"..."} 但 admin-rust-api
LoginInput 期望 {"identifier":"..."}，導致 deserialize 失敗。

改 data 物件 key 從 userName 改 identifier: userName（保留入參名
userName 避免影響其他 caller、只改送出 field 名）。

Refs: new-admin-root specs/002-gap-0ab0f-frontend-env-and-login/spec.md FR-210

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 1.3 Push fork（2 分鐘）

```bash
# 仍在 admin-web/ worktree
git log --oneline -3   # 看最近 3 個 commit
git push origin new-admin-base-web
# 預期推 2 commits（GAP-0a/0b 合一 + GAP-0f 單一）
```

### 1.4 Outer SHA pin commit（5 分鐘）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509   # 回 outer

# 確認 git status 顯示 admin-web 有 new commits
git status
# 預期：modified: admin-web (new commits)

# 取新 SHA
NEW_SHA=$(cd admin-web && git rev-parse --short HEAD)
echo "new admin-web SHA: $NEW_SHA"

git add admin-web
git commit -m "$(cat <<EOF
chore(submodule): bump admin-web 到 ${NEW_SHA}: feature 2 GAP-0ab0f

inner commits（在 fork260509-soybean-admin-base@new-admin-base-web）：
- fix(admin-web): GAP-0a + 0b 對齊 admin-rust-api wire-level codes
- fix(admin-web): GAP-0f login body field userName → identifier

at this point: admin-web 端對 admin-rust-api 完成 wire-level 對齊，
配合 features 3/6 後即可動態驗 login flow。

Refs: specs/002-gap-0ab0f-frontend-env-and-login/spec.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 1.5 Static acceptance verification（3 分鐘）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509

# (a) admin-web/.env 4 條 codes
test "$(cd admin-web && grep -cE '^(VITE_SERVICE_SUCCESS_CODE=200|VITE_SERVICE_LOGOUT_CODES=|VITE_SERVICE_MODAL_LOGOUT_CODES=|VITE_SERVICE_EXPIRED_TOKEN_CODES=401)$' .env)" = "4" \
  && echo "PASS: 4 codes 對齊"

# (b) auth.ts 已對齊
cd admin-web && grep -qE 'identifier:\s*userName' src/service/api/auth.ts && echo "PASS: auth.ts 對齊" && cd ..

# (c) 沒殘留 fake codes
cd admin-web && ! grep -E '^VITE_SERVICE_(SUCCESS_CODE=0000|LOGOUT_CODES=8888|MODAL_LOGOUT_CODES=7777|EXPIRED_TOKEN_CODES=9999)' .env \
  && echo "PASS: 無 fake codes 殘留" && cd ..

# (d) submodule status clean
git submodule status | grep '^ ' | wc -l   # 應 = 2（兩 submodule 都 clean）
```

### 1.6 Push outer（1 分鐘）

```bash
# user 同意後（CLAUDE.md §5 push 須 user confirmation）
git push origin 002-gap-0ab0f-frontend-env-and-login
```

---

## 2. Operator 動態驗證流程（5 分鐘）— 依賴 features 1+6 merge

### 2.1 起 dev stack（前提：feature 1 已 merge）

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/deploy
docker compose -f compose.yaml -f compose.dev.yaml up -d \
  postgres redis migration new-admin-rust-api
docker compose ps   # 全 healthy / Exited(0)
```

### 2.2 跑 admin-web vite dev server

```bash
cd /mnt/d/AnewSpaces/x_Project/fork260509/admin-web
pnpm install   # 第一次跑、~2 分鐘
pnpm dev       # vite 起在 :9527
```

### 2.3 manual smoke login

1. 開瀏覽器 → `http://localhost:9527`（或 admin-web vite dev server 顯示的 URL）
2. 進 login 頁、輸入 `Soybean` / `Soybean@123.`
3. 點 login
4. **DevTools Network tab 觀察**：
   - POST `/proxy-default/auth/login`
   - request body: `{"identifier":"Soybean","password":"Soybean@123."}` ✅
   - response status: 200 + body `{"code":200, "data":{...}, ...}` ✅
5. **預期結果**：
   - admin-web 識別為成功（無錯誤 toast）
   - 跳轉首頁（依 admin-web `VITE_ROUTE_HOME=home` 設定）
   - 可在 DevTools Application > Local Storage 看到 token 已 store

### 2.4 預設密碼順帶驗（CLAUDE.md §5 待驗證項回填）

跑 `/auth/login` 對 3 個 user：

```bash
BASE=http://localhost:8080/api    # 同源反代
# 或 BASE=http://localhost:10001（dev override）

for user in Soybean Administrator GeneralUser; do
  CODE=$(curl -sS -X POST $BASE/auth/login \
    -H 'Content-Type: application/json' \
    -d "{\"identifier\":\"$user\",\"password\":\"Soybean@123.\"}" \
    | jq -r '.code // "no-resp"')
  echo "$user: code=$CODE"
done

# 期望：3 行都是 code=200
# 通過 → 回填 CLAUDE.md §5.1 移除「待驗證」字樣 + spec.md 勾 ✅
```

---

## 3. 排錯指引

| 症狀 | 可能原因 | 對策 |
|---|---|---|
| login 跳「成功被當失敗」 toast | `.env` 修補沒生效 / vite cache 沒重建 | 重啟 `pnpm dev`；或 `rm -rf admin-web/node_modules/.vite` |
| login 報 400 / 422 | request body field 還是 `userName` | `auth.ts` 改了沒 commit；vite hot reload 失靈 → 重啟 |
| login 後不跳首頁 | dashboard load 失敗（feature 5 未 merge） | 屬 feature 5 範圍，本 feature 不解 |
| `git submodule status` 行首 `+` | inner 已 commit + push、outer 還沒 add+commit | 跑 `git add admin-web && git commit -m "chore(submodule): ..."` |
| outer commit 失敗 `nothing to commit` | inner 還沒 commit、worktree 內仍 staged | 先回 admin-web/ commit 再回外層 |

---

## 4. 完成標準

- 5 行 diff 全在 admin-web/.env + admin-web/src/service/api/auth.ts
- 兩段式 commit 兩段都做完（fork branch + outer SHA pin）
- 4 條 static acceptance 全 PASS
- `git submodule status` 行首空格
- （依賴 feature 6 merge）動態 acceptance + 預設密碼驗證 PASS
