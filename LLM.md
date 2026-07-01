# hanzoai/migration — Hanzo V8 "Open Cloud" migration & decommission

Deep agent doc. `migration.yaml` is the machine-readable chart (the single source
of truth); this file is the narrative that explains it. `README.md` is the human
entry point. Data dumps NEVER land in git (`.gitignore` blocks `*.sql`/`*.sqlite`).

## The target (what "V8 Open Cloud" means)

ONE unified Go binary — `ghcr.io/hanzoai/cloud` — that:
1. **`go:embed`s the console2 SPA** (`webui.go //go:embed all:webui/dist`, mounted
   LAST in `serve.go` so `/v1` and `/zap` win, SPA-fallback for the rest),
2. holds **every capability** either in the BE (cloud subsystems) or the FE
   (console2 modules) — nothing served from a third place,
3. is **all-SQLite** — per-tenant SQLite via `hanzoai/base`, **no internal
   Postgres**, enforced by a hard boot guard (`storagelock.CheckEnv` fails the pod
   if any Postgres pin is present),
4. collapses the deployed estate to **ONE Service / ONE origin**
   (`api.cloud.hanzo.ai`), retiring the separate console2 SSR Service and the old
   console.

## Where we are — ~40% (assessment wf_bcf82f7c-b54, 7-mapper CTO swarm)

**Real and live:** the unified binary is deployed and healthy
(`api.cloud.hanzo.ai/v1/health → {status: ok}`, SQLite-backed, single-writer RWO
PVC, replicas 1 + Recreate). The go:embed mechanism is fully wired and
unit-tested. The mount registry (`cloud.Register`/`MountAll`) composes ~18
subsystems; org-level tenancy is honored end-to-end (JWT-minted `X-Org-Id` +
`c.Org()`). iam and base are SQLite by construction; cloud has no DSN and refuses
Postgres at boot. console2 has 72 honest enabled modules.

**Four load-bearing gaps stand between here and done** (`status.load_bearing_gaps`
in `migration.yaml`):
1. **The embed is a 3.5KB shell, not the real SPA.** console2 is Next SSR with 15
   `app/**/route.ts` server handlers (they hold KMS tokens / mint user tokens); it
   has no `output: export` and no `build:embed` script, so the Docker console
   stage silently ships the fallback shell every build. Prod is still TWO Services.
2. **cloud main is RED** — `9d47757` fails `go build ./cmd/cloud`; the CR is pinned
   to the pre-embed image `1.785.24`.
3. **All-SQLite is code-ready but not executed in GitOps** — the PG18 `sql`
   StatefulSet + insights-sql + ~20 `DATABASE_URL` services still run; no universe
   Job invokes the `pg2sqlite`/`migrate-pg-to-sqlite` tools that already exist.
4. **FE→BE contract gaps** — `X-Project-Id` (FE) vs `X-IAM-Project-Id` (only eval
   reads it) means project selection scopes ZERO calls; `X-Environment` has no BE
   reader; 6 FE modules have no BE route; `/zap` is live with its FE client deleted.

## How to read the chart

- **`components`** — the migration matrix. Every current piece → a `destination`:
  `BE` (into the cloud binary), `FE` (into console2), `SQLITE` (flip storage),
  `KILL` (decommission), `COLLAPSE` (fold Service into the one binary), `KEEP`.
- **`execution`** — the single ordered list (rank 1 first), ranked by impact ÷
  blast-radius. Rank 1 is the RED build; it unblocks everything.
- **`postgres_decommission`** — the 10 ordered steps, **EXPORT first, SHUTDOWN
  last**, each tagged `safe`/`caution`/`destructive`.

## The one rule that keeps "kill Postgres" from breaking customers

**All-SQLite is about INTERNAL storage only.** The `sql` StatefulSet is BOTH the
internal store AND the backend for the customer-facing **managed-Postgres
product** (the pgx provisioner offering + Neon `cloud-sql`). Those are in
`keep_postgres_product` and must survive. Resolve the dual role on paper (step 2)
BEFORE any `scale --replicas=0`. Killing `sql` blind breaks paying customers.

## Decommission order (the "shut down all other versions" ask)

Nothing is killed before a verified replacement + a verified backup:
1. EXPORT every DB (safe) → operator desktop, off-cluster.
2. CONVERT + `-verify` per service (caution) — row-count parity gating.
3. FLIP per service to SQLite only after its verify passes (reversible).
4. Migrate KMS with encryption parity (security-critical).
5. Collapse console2 SSR + retire the old console (after FE migration).
6. SHUTDOWN `sql` + insights-sql LAST (destructive) — PVCs are Retain, so keep the
   Retain'd PVC + the off-cluster dumps as the recovery point.

## Execution status

Tracked per-rank in `migration.yaml:execution`. This repo is the plan of record;
the actual code changes land in `cloud`, `console2`, `iam`, and `universe`. Update
a component's `status` (`todo`→`partial`→`done`) as each rank lands — this file
and the chart are the one place the migration state lives.
