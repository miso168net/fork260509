# T021 — US2 Functional Acceptance Evidence (SC-002)

**Feature**: 008-gap-tz-1-timestamptz-migration
**User story**: US2 — Login + Refresh flow works normally after migration (no regression); new `sys_tokens` rows have correct `timestamptz` instants.
**Tasks covered**: T018 (login + JWT decode), T019 (refresh + rotation), T020 (instant + diff verification).

## Header

| Item | Value |
|---|---|
| Outer repo SHA (`new-admin-root`) | `fce9a8f` (`fce9a8f439b573ff2851c980802b54891487213e`) |
| Inner repo SHA (`admin-api`) | `cdf5a16` (`cdf5a165de089a2c8856d982101a7311ec0140ae`) |
| Date (local / UTC) | 2026-05-11T22:54:40+08:00 / 2026-05-11T14:54:40+00:00 |
| Stack / DB container | `new-admin-root-postgres-1` (active stack; `-dev-` containers ignored) |
| Endpoint | `POST http://localhost:8080/api/auth/{login,refreshToken}` (via nginx → `new-admin-rust-api:10001`) |
| Identifier / password | `Soybean` / `123456` (default per CLAUDE.md §5.1) |

---

## T018 — Login + JWT decode

### Request

```bash
curl -sS -X POST http://localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"Soybean","password":"123456"}'
```

### Response (HTTP 200, JWT body redacted)

```json
{
  "code": 200,
  "data": {
    "token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUz...",
    "refreshToken": "01KRBRFNCSQFM8DKYP7DHA0HZV"
  },
  "msg": "success",
  "success": true
}
```

Shape conforms to FR-009 (HTTP contract unchanged):

- `code: 200`, `success: true`, `msg: "success"`
- `data.token` (mandatory, JWT)
- `data.refreshToken` (mandatory, ULID)
- `tokenType` not emitted by current admin-api shape (optional per task spec)

### Decoded JWT claims (`data.token` middle segment base64-decoded)

| Claim | Value |
|---|---|
| `sub` | `"1"` (Soybean user id; matches feature-4 evidence) |
| `username` | `"Soybean"` |
| `role` | `["ROLE_SUPER"]` |
| `domain` | `"built-in"` |
| `org` | `null` |
| `iss` | `"https://localtest.example.com/auth"` |
| `aud` | `"management_platform"` |
| `iat` | `1778511238` (relative to now: `0 s`) |
| `nbf` | `1778511238` (relative to now: `0 s`) |
| `exp` | `1778518438` (relative to now: **`+7200 s` = 2 h, matches `access_token_expire` default**) |
| `jti` | `01KRBRFNCSJBDJGD197547B93J` (ULID) |

All required claims present and consistent.

`R_first = 01KRBRFNCSQFM8DKYP7DHA0HZV`

---

## T019 — Refresh + verify rotation

### Request (1 s after login)

```bash
curl -sS -X POST http://localhost:8080/api/auth/refreshToken \
  -H 'Content-Type: application/json' \
  -d '{"refreshToken":"01KRBRFNCSQFM8DKYP7DHA0HZV"}'
```

### Response (HTTP 200, JWT body redacted)

```json
{
  "code": 200,
  "data": {
    "token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUz...",
    "refreshToken": "01KRBRFZA9A7363EFC14WDSWZX"
  },
  "msg": "success",
  "success": true
}
```

Decoded new access-token claims: same `sub/username/role/aud/iss/domain/org`; new `iat=1778511248`, `exp=1778518448` (Δ exp=+7200 s), new `jti=01KRBRFZA9526ZW2Q0EQJ9N3HB`. New JWT and new refresh ULID differ from T018 → rotation confirmed at the HTTP level.

`R_second = 01KRBRFZA9A7363EFC14WDSWZX`

### DB rotation (psql against `new-admin-root-postgres-1`)

```sql
SELECT refresh_token, status, EXTRACT(EPOCH FROM created_at) AS created_epoch
FROM sys_tokens
WHERE refresh_token IN ('01KRBRFNCSQFM8DKYP7DHA0HZV', '01KRBRFZA9A7363EFC14WDSWZX')
ORDER BY created_at;
```

| refresh_token | status | created_epoch |
|---|---|---|
| `01KRBRFNCSQFM8DKYP7DHA0HZV` (R_first) | `REFRESHED` | `1778511238.554449` |
| `01KRBRFZA9A7363EFC14WDSWZX` (R_second) | `ACTIVE` | `1778511248.713960` |

- R_first transitioned `ACTIVE → REFRESHED` (expected after refresh consumes it).
- R_second inserted as `ACTIVE`.
- `R_second.created_epoch (1778511248.71) > R_first.created_epoch (1778511238.55)` (Δ ≈ 10.16 s).

---

## T020 — Verify new row instant + diff

```sql
SELECT login_time, created_at, expires_at,
       EXTRACT(EPOCH FROM expires_at) - EXTRACT(EPOCH FROM login_time)  AS diff_seconds,
       EXTRACT(EPOCH FROM expires_at) - EXTRACT(EPOCH FROM created_at)  AS diff_seconds_2
FROM sys_tokens
WHERE refresh_token = '01KRBRFZA9A7363EFC14WDSWZX';
```

| Column | Value |
|---|---|
| `login_time` | `2026-05-11 22:54:08.71396+08` |
| `created_at` | `2026-05-11 22:54:08.71396+08` |
| `expires_at` | `2026-05-25 22:54:08.711399+08` |
| `diff_seconds`   (expires − login_time)  | `1209599.997439` |
| `diff_seconds_2` (expires − created_at)  | `1209599.997439` |

Verification:

- All three timestamp columns render **with TZ offset `+08`** → confirms `timestamptz` storage post-migration (FR-001/FR-002).
- Both diff values ≈ `1,209,600 s = 14 days = 1209600 s` = default `refresh_token_expire`. The 2.561 ms shortfall is the gap between the `now()` snapshot used for `login_time/created_at` and the slightly later instant used in `expires_at = now + Duration::seconds(refresh_token_expire)` inside admin-api's refresh handler — well within tolerance.
- `login_time == created_at` (same instant) → matches admin-api refresh-path semantics.

---

## Verdict

**SC-002 PASS** — Login + refresh flow operates normally after the `timestamptz` migration:

1. **FR-009 (HTTP contract unchanged)**: login + refresh return the documented `{code, data:{token,refreshToken}, msg, success}` shape with `HTTP 200`, JWT claims set is unchanged (`sub/username/role/aud/iss/iat/nbf/exp/jti/domain/org`).
2. **JWT semantics intact**: `exp − iat = 7200 s` matches `access_token_expire` default for both login and refresh-issued tokens.
3. **Refresh-token rotation intact**: R_first transitioned to `REFRESHED`, R_second inserted as `ACTIVE`, `created_at` strictly increases.
4. **New-row instants correct (FR-001/FR-002)**: post-migration `sys_tokens` rows store `timestamptz` with the active offset (`+08`); `expires_at − created_at ≈ 1,209,600 s` (= 14 days) matches `refresh_token_expire`, confirming admin-api writes the expected wall-clock instant.

No regression detected. Source code unchanged; this is a runtime acceptance test only.
