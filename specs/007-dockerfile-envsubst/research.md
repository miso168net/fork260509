# Phase 0 Research: admin-api envsubst template

**Feature**: 007-dockerfile-envsubst
**Date**: 2026-05-11
**Status**: Completed

R1-R6 全部 evidence-based 解析。

---

## R1：admin-api yaml 路徑來源 + entrypoint 寫 file 去處

- **Decision**: entrypoint render 後寫到 **`/app/server/resources/application.yaml`**（與 main.rs hardcode 路徑一致）
- **Evidence**:
  - `admin-api/server/bin/src/main.rs` line 7-10：
    ```rust
    let config_path = if cfg!(debug_assertions) {
        "server/resources/application-test.yaml"
    } else {
        "server/resources/application.yaml"
    };
    ```
  - **Release build**（prod）讀 `server/resources/application.yaml`，**相對 CWD**（不是絕對路徑）
  - admin-api/Dockerfile runtime stage `WORKDIR /app` → 實際解析為 `/app/server/resources/application.yaml`
  - Dockerfile 已 `chown -R appuser:appuser /app` → appuser 可寫此路徑
- **Alternatives considered**:
  - 改 main.rs 用 `APP_CONFIG_PATH` env var 控制路徑 → 需 admin-api code change，**拒絕**（最小 GAP）
  - 寫到 `/tmp/application.yaml` → admin-api binary 仍 hardcode 相對路徑，無法生效
  - symlink `/app/server/resources/application.yaml` → `/tmp/...` → 多餘複雜
- **Implementer note**: Dockerfile **不**在 build 階段 COPY application.yaml（per constitution §II）；entrypoint 才產生此檔；首次 boot 即建立、後續重啟 idempotent overwrite

---

## R2：envsubst 未設 env 時行為 + admin-api config crate parse 結果

- **Decision**: entrypoint **預先** validate required envs（FR-605）；不依賴 config crate 之 fallback；envsubst-only rendering 不留錯誤檢測 surface
- **Evidence**:
  - envsubst 預設行為：若 env var 未設，render 為 **空字串**（silent default，不報錯）
  - 例：`${APP_JWT_JWT_SECRET}` 未設 → render 為 `jwt_secret: ""` → admin-api JWT signing 用 empty secret → 簽出 token 仍 valid 但極弱（安全風險）
  - admin-api config crate（per feature 1-I4 hotfix research）走 `Environment::with_prefix("APP").separator("_")` 之 env override；config crate 對 yaml empty 值之行為**未 verify**，但**避免進入此分支**最安全
- **Alternatives considered**:
  - envsubst `-v` strict 模式：實際 envsubst 沒有 strict mode；GNU envsubst 不檢測未設 env
  - 用 `${VAR:?error message}` 寫在 .tpl 內：envsubst **不支援** bash `:?` syntax（envsubst 只認 `${VAR}` 與 `$VAR`）
  - 改用 `envsubst` 替代工具如 `gomplate` / `dockerize`：增 image dep，本 feature 範圍外
- **Implementer note**: entrypoint shell script 對每個 required env 做：
  ```sh
  if [ -z "${APP_JWT_JWT_SECRET}" ]; then
    echo "[entrypoint] FATAL: APP_JWT_JWT_SECRET is empty or unset" >&2
    exit 1
  fi
  ```

---

## R3：rootless USER + writable path

- **Decision**: entrypoint 以 `appuser` (uid 10001) 身分執行；寫 file 到 `/app/server/resources/application.yaml` 安全
- **Evidence**:
  - admin-api/Dockerfile：
    ```
    adduser ... --uid "${APP_UID}" ${APP_USER}
    mkdir -p /app/server/resources && chown -R ${APP_USER}:${APP_USER} /app
    ...
    USER ${APP_USER}
    ```
  - `/app` 與下面 dir 全 owned by appuser，appuser 可建檔
- **Implementer note**: ENTRYPOINT 寫在 `USER ${APP_USER}` 之後生效（entrypoint 以 appuser 跑）；不需 root；不需 sudo

---

## R4：envsubst yaml 字元相容性

- **Decision**: ✅ 安全 —— envsubst 純文字 substitution、不解析 yaml 結構；env 值含 `:` `@` `$` 等字元正確替換到 yaml string field
- **Evidence**:
  - envsubst 行為：掃描 input 文字、遇 `${VAR}` 或 `$VAR` 替換為 env value、其他字元原文輸出
  - 不解析 yaml indentation、quotation、key/value structure
  - 替換結果可能讓 yaml 變 invalid（若 value 內含 `\n` 或 unescaped `"`），但 admin-api 用 typical url / secret 值（無此風險）
- **Edge cases note**:
  - **DB URL 含 `$` 字元**：若 POSTGRES_PASSWORD 內含 `$`，env 值內 `$` 被 envsubst 視為 var 引用前綴，可能誤替；解法：env value 內 `$` 應 escape 或避免使用 → 文件化於 deploy/.env.example
  - Multi-line value（如 PEM key）：admin-api 當前 config 無 multi-line 需求，不適用

---

## R5：redis `--requirepass` argv 暴露

- **Decision**: 接受 redis-server main process argv 暴露 password 為**既有 limitation**（redis-server CLI flag 設計）；本 feature 只 fix **healthcheck argv** 暴露（per 1-I1）
- **Evidence**:
  - 現 compose.yaml redis 啟動：
    ```yaml
    command:
      - "redis-server"
      - "--requirepass"
      - "${REDIS_PASSWORD:?must set REDIS_PASSWORD}"
    ```
    → `docker top` 看 main process argv = `redis-server --requirepass <password>` （暴露）
  - 解決方案：(a) 改用 ACL config file → 複雜 + redis 7+ syntax；(b) redis 7+ 之 `requirepass` config directive in `redis.conf` → 需 mount config file；(c) 接受 + doc
- **Implementer note**:
  - 本 feature 不變 redis 啟動命令（不解 main argv 暴露）
  - **修正 healthcheck**（1-I1）：
    - 原：`test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]` → `${REDIS_PASSWORD}` 被 docker compose 提前展開、healthcheck argv 也含明文 password
    - 改：`test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping"]` → `$$` 雙錢字 escape，docker compose 不展開，shell 在 container 內以 env 解析 → healthcheck argv 為 `sh -c "redis-cli -a \"$REDIS_PASSWORD\" ping"`（含 `$REDIS_PASSWORD` 字面字串，非明文 value）
  - `.env.example` / `deploy/README.md` 加 doc 段：「main process argv 暴露 password 為 redis-server limitation；future hardening 路徑：ACL config file 或 mount-based config」

---

## R6：hardcoded 值出現位置 grep

- **Decision**: 只 .tpl 化 `application.yaml`（prod 路徑）；`application-test.{yaml,toml,json}` **保留現狀**（debug build only、Dockerfile 不 COPY 進 runtime image）
- **Evidence**: `grep -rn "pgbouncer\|soybean-admin-rust\|123456\|your-org\|ByteByteBrew" admin-api/server/resources/` 結果：
  - `application.yaml` 4 行命中（database.url / jwt.jwt_secret / jwt.issuer / redis.url）→ **本 feature 要清除**（換 .tpl）
  - `application-test.yaml/toml/json` 多行命中（dev mode 用）→ **保留**（debug build 才讀；Dockerfile runtime stage 只 COPY application.yaml + ip2region.xdb + rbac_model.conf，**不**含 application-test.\* → 不會 ship prod image）
- **Implementer note**:
  - 改 `application.yaml` → `application.yaml.tpl`，內容除 hardcoded url/secret 改 `${APP_*}` 占位、其餘 yaml 結構保留
  - Dockerfile COPY 改成 `COPY --from=build .../application.yaml.tpl /app/server/resources/`
  - **驗證 SC-601** 用 `grep -rn` admin-api/server/resources/ 排除 application-test.\*：`grep -rn ... --exclude="application-test.*"` 必 0 命中

---

## 結論：所有 Phase 0 unknowns 已具現化

| R# | Status | Action |
|---|---|---|
| R1 | ✅ Resolved | entrypoint 寫 `/app/server/resources/application.yaml`，與 main.rs CWD 相對路徑對齊 |
| R2 | ✅ Resolved | entrypoint 預先 validate required envs；不依賴 envsubst silent default |
| R3 | ✅ Resolved | appuser 已 chown /app；entrypoint 以 appuser 跑、可寫 resources/ |
| R4 | ✅ Resolved | envsubst 純文字替換、無 yaml 結構風險；POSTGRES_PASSWORD `$` 字元需 doc 警示 |
| R5 | ✅ Accepted limitation | redis main argv 限制接受 + doc；本 feature fix healthcheck argv（CMD-SHELL + `$$REDIS_PASSWORD`） |
| R6 | ✅ Resolved | 只 .tpl 化 application.yaml；application-test.* 保留（dev only，不 ship prod） |

implementation 階段可直接落地。
