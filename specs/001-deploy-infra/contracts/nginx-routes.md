# Contract: Nginx Routes（同源反代解 GAP-0e）

**Feature**: `001-deploy-infra`
**File**: `deploy/nginx/default.conf`
**Constitution alignment**: 本契約即 §I「同源反代優先」的物理體現。違反此契約 = 違反 §I（特別是新增 `Access-Control-*` header 即為紅線）。

---

## 路由表（normative）

| Method | Path Pattern | 行為 | 上游 / 回應 | Cache 規則 |
|---|---|---|---|---|
| `*` | `= /health` | static return | `200 "ok\n"` + `Content-Type: text/plain` | `access_log off`、no cache |
| `*` | `/api/<rest>` | reverse proxy | `proxy_pass http://admin-rust-api:10001/<rest>`（strip `/api/` 前綴） | 不 cache（API 預設） |
| `*` | `~* \.(css\|js\|jpe?g\|png\|gif\|svg\|ico\|woff2?)$` | static serve | 從 `/usr/share/nginx/html` | `expires 30d` + `Cache-Control: public, immutable` |
| `*` | `/` | SPA fallback | `try_files $uri $uri/ /index.html` | static 預設（index.html 不應 cache） |

---

## 反代 Header 注入（normative）

`/api/` location 必須注入以下 header 給上游 admin-rust-api：

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Request-Id $request_id;

# WebSocket 預備（未來如果加，現在不用會無害）
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

proxy_read_timeout 60s;
proxy_send_timeout 60s;
```

**為何**：
- `Host` / `X-Real-IP` / `X-Forwarded-*`：讓 admin-rust-api 能拿到原 client IP（log / audit / rate limit 用）。
- `X-Request-Id`：nginx 1.11+ 自動產生 uuid-like ID，可作為 distributed tracing baseline（未來接 jaeger / tempo 時直接可用）。
- `proxy_*_timeout 60s`：避免 long-poll / 大 query 被默默截斷。

---

## CORS 政策（紅線）

**禁止**在 nginx conf 設定任何 `Access-Control-*` header（包括 `Access-Control-Allow-Origin`、`Access-Control-Allow-Methods`、`Access-Control-Allow-Headers`、`Access-Control-Allow-Credentials`、`Access-Control-Expose-Headers`、`Access-Control-Max-Age`）。

**理由**（與 spec FR-125 / constitution §I 重複強調）：
- 本架構是**同源**部署（瀏覽器 → nginx :8080 → 內網 admin-rust-api:10001），瀏覽器只看到一個 origin → 根本不會發 CORS preflight。
- 在 nginx 加 CORS header 等於宣稱本系統設計支援跨源；prod 出問題（origin allowlist 漏洞、credentials 偷渡）難排查。
- 解 GAP-0e 的方式就是「不設 CORS，靠同源消除問題」— 這是本 feature 的核心交付物之一。

**Validation**:
```bash
! grep -iE 'access-control|cors' deploy/nginx/default.conf \
  && echo "PASS: 無 CORS header（GAP-0e 紅線守住）" \
  || echo "FAIL: nginx conf 出現 CORS 痕跡"
```

---

## SPA Fallback 行為

`location /` 用 `try_files $uri $uri/ /index.html` 達成：

- 請求 `/login` → 找不到 file → 回 `index.html`（讓 vue-router 接管）
- 請求 `/static/app.123abc.js` → file 存在 → 直接回該檔
- 請求 `/api/auth/login` → 不會走到 `/`（被 `/api/` 攔截先反代）

**陷阱**：若有 `/api` 路徑開頭的「真實檔案」（罕見），會被 `/api/` location 蓋。本契約不允許 admin-base-web image 內 `dist/api/*` 出現任何檔（feature 7 admin-web-dockerfile 須確保 build 產出無此路徑）。

---

## gzip 壓縮

```nginx
gzip on;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
gzip_min_length 1024;
gzip_vary on;
```

- `gzip_min_length 1024`：< 1KB 的檔不壓（壓縮 overhead 大過收益）。
- `gzip_vary on`：發 `Vary: Accept-Encoding`，避免 CDN 把壓縮版本錯給不支援 gzip 的 client。

**未壓縮的 type**（蓄意排除）：
- 影像檔（jpg/png/gif/webp）：本身已壓縮、再 gzip 反而變大
- woff2/woff：同上

---

## 健康檢查 endpoint

`location = /health`（精確匹配，不被 `/` SPA fallback 蓋）：

```nginx
location = /health {
    access_log off;
    return 200 "ok\n";
    add_header Content-Type text/plain;
}
```

**用途**：
1. docker HEALTHCHECK：`wget -qO- http://localhost/health || exit 1`（admin-base-web image Dockerfile 內，feature 7 處理）
2. 外部 LB / k8s readiness probe（未來接入時直接可用）

**`access_log off`**：避免 log 被 healthcheck 噪音淹沒（每 30 秒一次 → 每天 ~2880 行）。

---

## 變更政策

- **加新 location**：必須在本契約表新增一行 + 明列 cache / header 行為。
- **改 `/api/` 反代 target**：屬於違反 service-naming.md 契約，須跨 feature 協調（同 service-naming.md 變更政策）。
- **加任何 CORS header**：紅線，需先 amend constitution §I（依 governance Amendment 流程）才能進行。

---

## End-to-End Validation 指令

```bash
# 1. nginx -t 過
docker run --rm \
  -v "$(pwd)/deploy/nginx:/etc/nginx/conf.d:ro" \
  nginx:1.27-alpine nginx -t
# 預期 stderr: "nginx: configuration file /etc/nginx/nginx.conf test is successful"

# 2. 路由表完整
for pattern in '= /health' 'location /api/' 'try_files \$uri' 'expires 30d'; do
  grep -qE "$pattern" deploy/nginx/default.conf \
    && echo "PASS: 含 $pattern" \
    || echo "FAIL: 缺 $pattern"
done

# 3. proxy_pass target 對齊 service-naming.md
grep -qE 'proxy_pass http://admin-rust-api:10001/?$' deploy/nginx/default.conf \
  && echo "PASS: proxy_pass 指向 admin-rust-api:10001" \
  || echo "FAIL: proxy_pass target 錯誤"

# 4. CORS 紅線
! grep -iE 'access-control|cors' deploy/nginx/default.conf \
  && echo "PASS: 無 CORS（§I 紅線）" \
  || echo "FAIL: 出現 CORS 痕跡（違反 §I）"

# 5. 必要 header
for header in 'X-Real-IP' 'X-Forwarded-For' 'X-Forwarded-Proto' 'X-Request-Id' 'Host'; do
  grep -qE "proxy_set_header ${header}" deploy/nginx/default.conf \
    && echo "PASS: 含 $header header" \
    || echo "FAIL: 缺 $header header"
done
```
