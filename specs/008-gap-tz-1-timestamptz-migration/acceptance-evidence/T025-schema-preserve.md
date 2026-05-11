# T025 — Schema & Row Preservation Acceptance Evidence (US3)

| Field | Value |
|---|---|
| Feature | 008-gap-tz-1-timestamptz-migration |
| Outer SHA (new-admin-root) | `fce9a8f439b573ff2851c980802b54891487213e` |
| Inner SHA (admin-api) | `cdf5a165de089a2c8856d982101a7311ec0140ae` |
| Date | 2026-05-11 |
| Postgres container | `new-admin-root-postgres-1` |
| Volume | `new-admin-root_pg-data` |

Success Criteria covered: **SC-001** (sys_tokens 3 columns are timestamptz), **SC-006 / FR-010** (other tables NOT modified), **SC-004** (existing row instants preserved).

---

## T022 — `\d sys_tokens` (SC-001)

Command:

```bash
docker exec new-admin-root-postgres-1 psql -U admin -d new_admin -c "\d sys_tokens"
```

Output:

```
                              Table "public.sys_tokens"
    Column     |           Type           | Collation | Nullable |      Default
---------------+--------------------------+-----------+----------+-------------------
 id            | character varying        |           | not null |
 access_token  | character varying        |           | not null |
 refresh_token | character varying        |           | not null |
 status        | character varying        |           | not null |
 user_id       | character varying        |           | not null |
 username      | character varying        |           | not null |
 domain        | character varying        |           | not null |
 login_time    | timestamp with time zone |           | not null |
 ip            | character varying        |           | not null |
 port          | integer                  |           |          |
 address       | character varying        |           | not null |
 user_agent    | character varying        |           | not null |
 request_id    | character varying        |           | not null |
 type          | character varying        |           | not null |
 created_at    | timestamp with time zone |           | not null | CURRENT_TIMESTAMP
 created_by    | character varying        |           | not null |
 expires_at    | timestamp with time zone |           | not null |
Indexes:
    "sys_tokens_pkey" PRIMARY KEY, btree (id)
```

### T022 verification

| Column | Type | Nullable | Verdict |
|---|---|---|---|
| `login_time` | `timestamp with time zone` | not null | timestamptz ✓ |
| `created_at` | `timestamp with time zone` | not null | timestamptz ✓ |
| `expires_at` | `timestamp with time zone` | not null | timestamptz ✓ |

**SC-001 PASS** — sys_tokens 3 timestamp columns are all `timestamp with time zone`, all NOT NULL.

---

## T023 — `\d` on 9 other tables (SC-006 / FR-010)

Command (each table queried individually):

```bash
docker exec new-admin-root-postgres-1 psql -U admin -d new_admin -c "\d <table>"
```

### Summary table

| # | Table | Timestamp columns | Type | Verdict |
|---|---|---|---|---|
| 1 | `sys_user` | `created_at`, `updated_at` | timestamp without time zone | without TZ ✓ |
| 2 | `sys_role` | `created_at`, `updated_at` | timestamp without time zone | without TZ ✓ |
| 3 | `sys_menu` | `created_at`, `updated_at` | timestamp without time zone | without TZ ✓ |
| 4 | `sys_domain` | `created_at`, `updated_at` | timestamp without time zone | without TZ ✓ |
| 5 | `sys_endpoint` | `created_at`, `updated_at` | timestamp without time zone | without TZ ✓ |
| 6 | `sys_access_key` | `created_at` | timestamp without time zone | without TZ ✓ |
| 7 | `sys_organization` | `created_at`, `updated_at` | timestamp without time zone | without TZ ✓ |
| 8 | `sys_login_log` | `login_time`, `created_at` | timestamp without time zone | without TZ ✓ |
| 9 | `sys_operation_log` | `start_time`, `end_time`, `created_at` | timestamp without time zone | without TZ ✓ |

**Total timestamp columns scanned**: 18 columns across 9 tables.
**Count of `with time zone` columns**: **0** (zero) in the 9 non-sys_tokens tables.

**SC-006 / FR-010 PASS** — All 9 other tables retain `timestamp without time zone` for every timestamp column. Migration scope is correctly limited to sys_tokens only.

---

## T024 — Existing row instant preservation (SC-004)

Command:

```bash
docker exec new-admin-root-postgres-1 psql -U admin -d new_admin -c \
  "SELECT id, status, created_at, EXTRACT(EPOCH FROM created_at) AS created_epoch
   FROM sys_tokens
   ORDER BY created_at"
```

Output:

```
             id             |  status   |          created_at           |   created_epoch
----------------------------+-----------+-------------------------------+-------------------
 01KRBR880GH55G5CZQ94W5RFY6 | REFRESHED | 2026-05-11 22:49:55.472197+08 | 1778510995.472197
 01KRBRA9Z772CEDDANJDVCNMCF | ACTIVE    | 2026-05-11 22:51:03.015163+08 | 1778511063.015163
 01KRBRENRKW46N4E3RMRH5RV6X | ACTIVE    | 2026-05-11 22:53:26.163996+08 | 1778511206.163996
 01KRBRFNCTNQCWKJW89QE5ABY9 | REFRESHED | 2026-05-11 22:53:58.554449+08 | 1778511238.554449
 01KRBRFZA9E2EY7TYVSZN2TQM7 | ACTIVE    | 2026-05-11 22:54:08.71396+08  | 1778511248.713960
(5 rows)
```

### Row analysis

- **Total rows**: 5
- **created_at range**: 2026-05-11 22:49:55 +08 → 2026-05-11 22:54:08 +08 (a ~4-minute window)
- **Pre-migration cutoff**: T013 stack rebuild happened earlier today (2026-05-11). All 5 rows show created_at in the 22:49–22:54 window on 2026-05-11, which is consistent with post-T013 login/refresh activity (T018–T021 US2 evidence collection traffic).
- **Pre-existing rows in active volume**: **0** — every row in the active stack's sys_tokens was inserted AFTER migration applied (during US2 functional evidence collection).

### -dev- vs active stack volume separation (sanity check)

Per the task description's note, T003's `/tmp/sys_tokens_before_epoch.csv` was taken from `new-admin-root-dev-postgres-1` (a different volume). Cross-check:

```bash
docker exec new-admin-root-dev-postgres-1 psql -U admin -d new_admin \
  -c "SELECT id, status, created_at FROM sys_tokens"
```

Output:

```
             id             |  status   |         created_at
----------------------------+-----------+----------------------------
 01KRAZM6MCZNTHMHR62R6P1RXE | REFRESHED | 2026-05-11 07:39:32.876456
 01KRAZM71CGM3GKDHXYWACVBTS | ACTIVE    | 2026-05-11 07:39:33.292291
 01KRAZM6QDD0136XZZJ8JM3AS1 | REFRESHED | 2026-05-11 07:39:32.973787
(3 rows)
```

**ID comparison** — the 3 IDs in `-dev-` (`01KRAZM6…`, `01KRAZM7…`) are completely disjoint from the 5 IDs in active stack (`01KRBR8…`, `01KRBRA…`, `01KRBRE…`, `01KRBRF…`). Distinct ULID prefixes (`KRAZM` vs `KRBR`) confirm separate volumes — the 3 -dev- rows were never present in the active volume.

Note also: the `-dev-` output `created_at` is **without** the `+08` TZ suffix (because that container hasn't received the feature 8 migration; columns are still `timestamp without time zone`), while the active stack shows `+08` (timestamptz post-migration). This second-order check reinforces that `-dev-` and active are independent stacks.

### SC-004 verdict

**Trivially PASS** — the active stack volume (`new-admin-root_pg-data`) contained no pre-migration sys_tokens rows at the time T013 brought the rebuilt stack up (the 5 visible rows were all generated post-migration during US2 functional evidence collection). Per `tasks.md` T024 fallback clause, this is acceptable.

The migration's `ALTER COLUMN … TYPE timestamptz USING …` did execute against the table on this volume; absence of pre-existing rows just means there were no row instants to compare. The schema-level evidence (T022 above) confirms the migration logic ran. Cross-stack comparison with `-dev-` is not meaningful (different volume).

---

## Verdict summary

| Success Criterion | Status |
|---|---|
| **SC-001** — sys_tokens 3 columns are timestamptz, all NOT NULL | **PASS** |
| **SC-006 / FR-010** — 9 other tables' timestamp columns remain `without time zone` (0 stray `with time zone`) | **PASS** |
| **SC-004** — existing row instants preserved | **Trivially PASS** (no pre-migration rows in active volume; per tasks.md fallback clause) |

US3 acceptance: **PASS (3/3 SCs cleared)**.
