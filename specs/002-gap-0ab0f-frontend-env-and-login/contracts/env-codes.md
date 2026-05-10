# Contract: admin-web .env Codes 變數（admin-web ↔ admin-rust-api wire-level）

**Feature**: `002-gap-0ab0f-frontend-env-and-login`
**File**: `admin-web/.env`（被本 feature 改 4 行 value）
**Consumer**: admin-web service 層（service/request 攔截器、auth store）

> 本契約鎖 4 個 admin-web `.env` 變數的值與 admin-rust-api 端行為對齊規則。違反此契約 = 違反 spec FR-201 ~ FR-204 + GAP-0a/0b 修補意圖。

---

## 1. `VITE_SERVICE_SUCCESS_CODE`

| 屬性 | 值 |
|---|---|
| 修補後值 | `200` |
| 修補前值 | `0000`（admin-web 上游預設 — 對舊版業務碼設計） |
| Type | string（admin-web 比較時轉 number 或 string equality 視 service 層 impl） |
| Consumer 邏輯 | `if response.code === SUCCESS_CODE → success branch、否則失敗 branch` |
| admin-rust-api 對應 | `Res::new_data` 永遠送 `code = StatusCode::OK.as_u16() = 200` |
| 修補理由 | admin-rust-api 端使用標準 HTTP semantics（200 = OK），admin-web 必須對齊；上游 `0000` 是業務碼設計、不適用本架構 |

**Validation 指令**:
```bash
grep -E '^VITE_SERVICE_SUCCESS_CODE=200$' admin-web/.env && echo PASS || echo FAIL
```

---

## 2. `VITE_SERVICE_LOGOUT_CODES`

| 屬性 | 值 |
|---|---|
| 修補後值 | （空字串 — `VITE_SERVICE_LOGOUT_CODES=`） |
| 修補前值 | `8888,8889` |
| Type | comma-separated list of codes |
| Consumer 邏輯 | `if response.code in LOGOUT_CODES → 直接 logout、跳轉 login 頁` |
| admin-rust-api 對應 | **從不送**業務 logout codes（8888/8889 是 admin-web 上游預設 fake） |
| 修補理由 | admin-rust-api 用 HTTP status code 表達 unauthorized（401）；保留 fake codes 不會誤觸真實 logout（因為從不命中）但**spec 要求顯式清空**避免讀者困惑 |

**Validation 指令**:
```bash
grep -E '^VITE_SERVICE_LOGOUT_CODES=$' admin-web/.env && echo PASS || echo FAIL
```

---

## 3. `VITE_SERVICE_MODAL_LOGOUT_CODES`

| 屬性 | 值 |
|---|---|
| 修補後值 | （空字串） |
| 修補前值 | `7777,7778` |
| Type | comma-separated list of codes |
| Consumer 邏輯 | `if response.code in MODAL_LOGOUT_CODES → 跳 modal 提示「session 結束」、然後 logout` |
| admin-rust-api 對應 | **從不送**業務 modal logout codes |
| 修補理由 | 同 `VITE_SERVICE_LOGOUT_CODES` |

**Validation 指令**:
```bash
grep -E '^VITE_SERVICE_MODAL_LOGOUT_CODES=$' admin-web/.env && echo PASS || echo FAIL
```

---

## 4. `VITE_SERVICE_EXPIRED_TOKEN_CODES`

| 屬性 | 值 |
|---|---|
| 修補後值 | `401` |
| 修補前值 | `9999,9998,3333` |
| Type | comma-separated list of codes |
| Consumer 邏輯 | `if response.code in EXPIRED_TOKEN_CODES → 觸發 fetchRefreshToken → 取新 access token → retry 原 request` |
| admin-rust-api 對應 | unauthorized → HTTP 401（response code = 401） |
| 修補理由 | admin-rust-api 用 HTTP 401 表達 token expired；admin-web 必須對齊。9999/9998/3333 是上游 fake codes、留著無害但 spec 要求顯式對齊 |

**Validation 指令**:
```bash
grep -E '^VITE_SERVICE_EXPIRED_TOKEN_CODES=401$' admin-web/.env && echo PASS || echo FAIL
```

---

## 5. Cross-Validation（4 個一起驗）

```bash
cd admin-web

# 一鍵跑全部 4 條 validation
test "$(grep -cE '^(VITE_SERVICE_SUCCESS_CODE=200|VITE_SERVICE_LOGOUT_CODES=|VITE_SERVICE_MODAL_LOGOUT_CODES=|VITE_SERVICE_EXPIRED_TOKEN_CODES=401)$' .env)" -eq 4 \
  && echo "PASS: 4 條 codes 全對齊" \
  || echo "FAIL: 有 codes 未對齊"

# 確認**沒有殘留** fake codes
! grep -E '^VITE_SERVICE_(SUCCESS_CODE=0000|LOGOUT_CODES=8888|MODAL_LOGOUT_CODES=7777|EXPIRED_TOKEN_CODES=9999)' .env \
  && echo "PASS: 無 fake codes 殘留" \
  || echo "FAIL: 仍有 fake codes"
```

---

## 6. 變更政策

- **改任一 code 值**：須對齊 admin-rust-api 行為改變（屬 admin-rust-api 倉的 spec 變更）；本 contract 應同步更新
- **新增 / 刪除 code 變數**：須協同 admin-web service 層消費邏輯改動（features 5/6 範圍）

---

## 7. Out of Scope（本 contract 不涵蓋）

- `admin-web/.env.dev` / `.env.prod` / `.env.test` 內 codes overrides — 屬 feature 7 (admin-web-dockerfile) 重構範圍
- admin-web service 層消費邏輯本身（`if-else` chain in service/request.ts）— 屬 admin-web 倉自身既有 code、本 contract 假定它正確
- admin-rust-api 端 `Res::new_data` impl 本身 — 屬 admin-api 倉（features 3/4/6 涵蓋）
