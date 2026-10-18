# ClickHouse as a sidekick for PostgreSQL - live demos

Three re-runnable, pausable shell demos for the talk **"Stop Torturing PostgreSQL - Why Your
PostgreSQL Database Needs a ClickHouse Sidekick"**. They all use the same beer-sales theme.

| Demo | Script | What it shows |
|---|---|---|
| 1 | `demo1_clickhouse_basics.sh` | Download the single ClickHouse binary, start it, ingest beer data, look under the hood: engine, parts, merges, files on disk, granules, compression, what a query really reads, server status |
| 2 | `demo2_postgres_federation.sh` | A **temporary** PostgreSQL instance, ClickHouse reading it live (`postgresql()` and `ENGINE = PostgreSQL`), why a plain materialized view does *not* pull from Postgres, a local copy via a **refreshable** materialized view |
| 3 | `demo3_aiven.sh` | The same on the Aiven platform with the Aiven CLI (`avn`), or with Terraform; optional Kafka integration |

Everything is plain bash. Every step is **shown first and only executed when you press ENTER**, so you
can talk before each command.

## Repository layout

```
demo1_clickhouse_basics.sh     demo 1
demo2_postgres_federation.sh   demo 2
demo3_aiven.sh                 demo 3 (avn CLI or Terraform)
cleanup.sh                     remove everything the demos created
lib/common.sh                  shared helpers (pausing, OS detection, start/stop/cleanup)
sql/pg_seed.sql                PostgreSQL beer data, used by demo 2 and demo 3
terraform/                     demo 3 as code (Aiven provider)
config.env.example             copy to config.env to override defaults
```

## Requirements

* Linux with bash 4+. Written for **Oracle Linux 8/9** (`dnf`); **Debian/Ubuntu** (`apt`) works as well.
  The package manager is detected automatically, force it with `PKG_MGR=dnf|yum|apt` in `config.env`.
* A **normal user** with `sudo` (PostgreSQL's `initdb` refuses to run as root; `sudo` is only used to
  install packages).
* `curl`. Demo 2 installs the PostgreSQL packages if they are missing. Demo 3 additionally needs
  `jq`, `psql`, the Aiven CLI and an Aiven account (see below).
* Internet access (the ClickHouse binary is about 850 MB) and roughly 2 GB free disk space.
* Free ports: 8123 and 9000 (ClickHouse), 5433 (temporary PostgreSQL). Change them in `config.env`
  (`CH_HTTP_PORT`, `CH_TCP_PORT`, `PG_PORT`).

Everything the demos create lives under `~/clickhouse-demo` (`WORKDIR`). Nothing is installed
system-wide except the PostgreSQL packages in demo 2. On Debian/Ubuntu those packages also create and
start a system cluster on port 5432; the demo never touches it.

## Quick start

```bash
git clone <your repo url> && cd <repo>
cp config.env.example config.env      # optional
./demo1_clickhouse_basics.sh          # leaves ClickHouse running
./demo2_postgres_federation.sh        # reuses it, adds the temporary PostgreSQL
./cleanup.sh                          # stop and delete everything
```

Dry run without pauses: add `-y` (or `DEMO_AUTO=1`). Add `--stop` to demos 1 and 2 to stop the
servers at the end.

## Presenting: keys and re-running

Before each step the command (or SQL) is printed and the demo waits:

| Key | Action |
|---|---|
| `ENTER` | run the step |
| `s` | skip the step |
| `c` | run the rest without pauses |
| `q` | quit |

Grey lines are talking points. Every demo starts with a **maintenance** phase that removes leftovers
of earlier runs (demo 1: stops and deletes the demo ClickHouse; demo 2: drops its ClickHouse objects
and recreates the temporary PostgreSQL; demo 3: removes the integrations and demo tables), so you can
run them as often as you like.

Tip: `KEEP_BINARY=1` keeps the downloaded ClickHouse binary between runs. Do the first download before the talk, or
leave the default to show the real download live.

## Demo 1 - ClickHouse basics

Slides: *The quick binary*, *First steps*, *Hands on*, *On disk: from table to granule*, *Components*.

1. Download the single binary (`curl https://clickhouse.com/ | sh`), version check
2. Start the server in the background (with `query_log` and `part_log` switched on, see note below)
3. Connect: native client and HTTP interface, `SHOW DATABASES`
4. `CREATE TABLE shop.beer_sales ... ENGINE = MergeTree ORDER BY (country, sold_at)`
5. Engine, sorting key, DDL, `system.tables`
6. Insert 3 rows: one INSERT is one part (Compact format)
7. Anti-pattern: merges paused, 5 tiny INSERTs produce 5 more parts
8. Bulk ingest of 2,000,000 generated rows (two Wide parts)
9. Merges: all parts before and after `OPTIMIZE ... FINAL`, `system.part_log`
10. The part directory on disk (`ls`, `columns.txt`, `count.txt`)
11. Granules, marks, compression ratio per column
12. Queries: aggregation, `EXPLAIN indexes = 1` (granules skipped), `system.query_log` rows read
13. Server status: `system.metrics`, `system.events`, `system.disks`
14. Bonus: `clickhouse-local`

The built-in minimal configuration has no `query_log`/`part_log`. The start command therefore passes
config overrides after `--`; the demo shows this on screen and explains it.

File names in a part change between ClickHouse versions: current builds show `primary.cidx` and
`*.cmrk2` (compressed marks) where older documentation says `primary.idx` and `*.mrk2`.

## Demo 2 - ClickHouse meets PostgreSQL

Slides: *Path 2*, *Careful with the terms*, *Path 3*.

1. Install the PostgreSQL packages if missing (`dnf install -y postgresql-server postgresql` /
   `apt-get install -y postgresql postgresql-client`)
2. `initdb` and start a throw-away instance in `~/clickhouse-demo/postgres` on port 5433
   (unix socket in that directory, SCRAM auth over TCP, every statement logged)
3. Create `ro_user` and seed 1,000,000 beer sales (`sql/pg_seed.sql`)
4. `postgresql()` table function: live read, no copy
5. `CREATE TABLE ... ENGINE = PostgreSQL(...)` (the password is hidden in `SHOW CREATE TABLE`)
6. Proof from PostgreSQL's log: ClickHouse sends `COPY (SELECT <needed columns> ...) TO STDOUT`;
   new rows in PostgreSQL are visible immediately
7. A plain `MATERIALIZED VIEW` on the PostgreSQL table stays empty: in ClickHouse it is an insert trigger
8. A **refreshable** materialized view (`REFRESH EVERY 10 SECOND`) builds the local MergeTree copy;
   `system.view_refreshes`; new PostgreSQL rows arrive with the next refresh
9. Timing: PostgreSQL vs. ClickHouse via the PG engine vs. the local copy

Passwords (`secret`) are for this throw-away demo only.

## Demo 3 - Aiven platform

### What you need

1. **An Aiven account and a project.** A free trial with credits is enough:
   <https://console.aiven.io/signup>. Note the **project name**.
2. **The Aiven CLI** (needs Python 3):
   ```bash
   python3 -m pip install --user aiven-client     # or: pipx install aiven-client
   avn --version
   ```
   On Oracle Linux: `sudo dnf install -y python3-pip` first. With `INSTALL_AVN=1` the demo installs it for you.
3. **Authentication**, either
   * `avn user login you@example.com` (add `--token` to log in with a personal token), or
   * a personal token (console: *User information > Authentication tokens*) exported as
     `export AIVEN_AUTH_TOKEN=<token>`.
4. **The project**: `export AIVEN_PROJECT=<your project>` (or put it into `config.env`).
5. `jq` and `psql` (the demo offers to install them): `sudo dnf install -y jq postgresql` or
   `sudo apt-get install -y jq postgresql-client`.
6. Optional: Terraform >= 1.3 for the `--terraform` mode.

Check: `avn user info`, `avn project details`, `avn cloud list`.

### Running it

```bash
export AIVEN_PROJECT=my-project
./demo3_aiven.sh prepare      # before the talk: creates services + data (10+ minutes the first time)
./demo3_aiven.sh              # live part, with pauses
./demo3_aiven.sh --kafka      # additionally the Kafka -> ClickHouse integration
./demo3_aiven.sh --terraform  # services and integrations from ./terraform instead of avn
./demo3_aiven.sh status
./demo3_aiven.sh cleanup      # terminate the services
```

**The services cost money while they run** (plans below). Always run `./demo3_aiven.sh cleanup` afterwards.
Services are reused between runs; `--recreate` terminates and recreates them. Defaults (override in
`config.env`): cloud `google-europe-west1` (`avn cloud list`), PostgreSQL `startup-4`, ClickHouse
`startup-16`, Kafka `startup-2`, service names `shop-pg`, `beer-clickhouse`, `events-kafka`.

### Steps

1. Account, project, cloud regions (`avn user info`, `avn project details`, `avn cloud list`)
2. `avn service create ... -t pg | clickhouse [| kafka]`, `avn service wait`
3. Seed the beer table into Aiven for PostgreSQL (`psql "$PG_URI" -f sql/pg_seed.sql`)
4. `avn service integration-create -t clickhouse_postgresql -s shop-pg -d beer-clickhouse` - ClickHouse
   gets the database `service_shop-pg_defaultdb_public`
5. Query PostgreSQL from ClickHouse with the plain `clickhouse-client` over TLS (the demo downloads the binary if needed)
6. A local, replicated MergeTree copy kept fresh by a refreshable materialized view
7. Optional Kafka: topic, `clickhouse_kafka` integration with a table mapping, `INSERT` produces to the
   topic, a materialized view consumes it into MergeTree

If your Aiven ClickHouse version lacks refreshable materialized views, skip step 6 with `s`.

### Terraform

`terraform/` defines the same setup: `aiven_pg`, `aiven_clickhouse`, `aiven_service_integration`
(`clickhouse_postgresql`) and, with `with_kafka = true`, Kafka, a topic and the `clickhouse_kafka`
integration.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_name
export AIVEN_TOKEN=<token>
terraform init && terraform apply
terraform destroy
```

`./demo3_aiven.sh --terraform` runs `init`/`plan`/`apply` for you with the token from `AIVEN_AUTH_TOKEN`
or from your `avn user login` credentials, and `cleanup` runs `terraform destroy`. The provider
arguments are `source_service_name` and `destination_service_name` (plus `project`).

## Configuration reference (`config.env`)

See `config.env.example`. The most useful: `WORKDIR`, `KEEP_BINARY`, `DEMO_AUTO`, `AUTO_DELAY`,
`CH_HTTP_PORT`, `CH_TCP_PORT`, `PG_PORT`, `ROWS_CH`, `ROWS_PG`, `PKG_MGR`, and for demo 3
`AIVEN_PROJECT`, `AIVEN_CLOUD`, plan and service names, `WITH_KAFKA`, `MODE`, `CH_LOCAL_ENGINE`
(`MergeTree` for a non-replicated test target), `CH_AIVEN_NATIVE_PORT`.

## Cleanup

```bash
./cleanup.sh                  # stop ClickHouse + temporary PostgreSQL, delete ~/clickhouse-demo
./cleanup.sh --keep-binary    # keep the 850 MB ClickHouse download
./cleanup.sh --purge-pg       # also remove the PostgreSQL packages
./cleanup.sh --aiven          # also terminate the Aiven services
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port 8123 is in use` | another ClickHouse is running; change `CH_HTTP_PORT`/`CH_TCP_PORT` |
| `initdb ... cannot be run as root` | run as a normal user |
| `Unknown table expression 'system.query_log'` | server was started without the log overrides: rerun demo 1 |
| `ClickHouse did not come up` | read `~/clickhouse-demo/clickhouse/server.log` |
| Demo 3: `not logged in` | `avn user login <email>` or export `AIVEN_AUTH_TOKEN` |
| Demo 3: cannot connect to ClickHouse | check the native TLS port in the console, set `CH_AIVEN_NATIVE_PORT` (default 9440); your IP must be allowed by the service IP filter |
| Refreshable MV not supported | older ClickHouse version: skip that step |

## Tested

* Demos 1 and 2 were run end to end on Ubuntu 24.04 (the `apt` path) with ClickHouse 26.11 and
  PostgreSQL 16, including re-runs, custom ports, `--stop` and `cleanup.sh`.
* The `dnf` path (Oracle Linux) uses the standard `postgresql-server`/`postgresql` packages and the
  same code otherwise; it was not executed during authoring. Please do a dry run (`-y`) on your machine.
* Demo 3: the script flow was verified against a local stand-in for `avn`, and the Terraform files
  pass `terraform validate` against the Aiven provider 4.x. They were not run against a live Aiven
  project: do a full dry run (`prepare`, then `run`) once before the talk.

## License

Add the license of your choice before publishing.
