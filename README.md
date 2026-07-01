# hanzoai/migration

Migration & decommission plan of record for **Hanzo V8 "Open Cloud"** — one
unified Go binary (`ghcr.io/hanzoai/cloud`) that `go:embed`s the console2 SPA,
every capability in the FE (console2) or BE (cloud), **all-SQLite** (no internal
Postgres), collapsed to one Service / one origin, all live in production.

## What's here

| File | Role |
|------|------|
| [`migration.yaml`](./migration.yaml) | **The chart** (single source of truth): the migration matrix, the ordered execution list, and the Postgres decommission runbook. |
| [`LLM.md`](./LLM.md) | The narrative — what V8 is, where we are (~40%), the four load-bearing gaps, how to read the chart. |
| [`scripts/pg-export.sh`](./scripts/pg-export.sh) | The safe first step — `pg_dump` every internal DB to the operator desktop before any migration. |

## Status: ~40%

The unified binary is **live and healthy** (`api.cloud.hanzo.ai/v1/health → ok`,
SQLite-backed, Postgres refused at boot). The go:embed mechanism is wired and
tested. Still ahead: the real SPA embed, the RED cloud build, the Postgres
shutdown (code-ready, not executed in GitOps), and the FE→BE contract fixes.

## The rule that protects customers

All-SQLite is about **internal** storage. The customer-facing **managed-Postgres
product** (the pgx provisioner + Neon `cloud-sql`) stays. The `sql` StatefulSet is
both — carve out the product role before any shutdown (see `keep_postgres_product`
and step 2 of the decommission runbook). **Nothing is killed before a verified
replacement and a verified backup.**

## Order of operations

`migration.yaml:execution`, rank 1 first. Export before flip; shutdown dead last.
