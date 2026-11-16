# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## General
- When implementing anything, always plan & think before diving into implementation 

## What this is

Minxstr (formerly Navix) is a Haskell backend that acts as a self-hosted fleet-management control
plane for NixOS machines. On startup it loads its config, bootstraps its own private PKI (via
`openssl` subprocesses) if needed, ensures its Postgres schema exists, and serves HTTPS with
Warp/WarpTLS. It tracks enrolled machines and the actions queued for them (wipe, rebuild, reboot,
rotate credentials, malware scan, etc.).

The endpoint agent lives in a separate repo (`navix-client`, https://github.com/xsj3n/navix-client).
The plan is to test the two together with NixOS VM tests (`pkgs.testers.runNixOSTest`), pulling the
client in as a flake input; this requires a NixOS module for each side (not written yet).

## Development environment

This project is developed inside a Nix flake dev shell — enter it with `nix develop` before running
any `cabal` commands. The shell's `shellHook` (in `flake.nix`) automatically initializes a local
Postgres cluster under `./database` (via `initdb`), starts it with `pg_ctl` (`PGDATA=./database`,
`PGHOST=/tmp`, so the unix socket lives in `/tmp`), and stops it when the shell exits. Postgres is
already running by the time you have a shell prompt.

`cabal.project.local` sets `tests: True`.

## Common commands

- Build: `cabal build`
- Build everything including tests: `cabal build all`
- Run the server: `cabal run Minxstr` (listens on `https://localhost:3000` by default)
- Run with a specific config: `cabal run Minxstr -- --config path/to/config.toml`
- Run all tests: `cabal test`
- Run a single test suite: `cabal test pki-test` or `cabal test log-test`

There are two test suites, each a plain `exitcode-stdio-1.0` executable rather than a unit-test
framework — they call into library code and exit non-zero on failure:
- `tests/pki/Test.hs` — runs `initPKI` then `verifyPKI` against a throwaway cert store in
  `./dist-newstyle/test-cert-store` (never touches the dev `./cert-store`).
- `tests/log/Test.hs` — writes one entry per log level and checks they land in the log file.

There is no test for the SQL files: they are embedded at compile time, so a missing file is a build
error. Integration/E2E tests (real Postgres, server + client in VMs) are planned but not written.

`hie.yaml` maps HLS cradles to four components: `lib:Minxstr`, `exe:Minxstr`, `test:pki-test`,
`test:log-test` — matching the four build targets in `Minxstr.cabal`. After adding a dependency to
`Minxstr.cabal`, run `cabal build` once so HLS can resolve it.

### Comm
- PREFER USING THE LSP PLUGIN AS OPPOSED TO RUNNING CABAL BUILD OR TEST
- Implement & run tests when implementing features 

## Configuration

`config.toml` (repo root) documents every key with its default. All keys are optional; anything
omitted falls back to `defaultConfiguration` in `Minxstr.Configuration`. The config path is resolved
in order: `--config PATH` argument, `MINXSTR_CONFIG` env var, `./config.toml`.

Sections: `[server]` (`port`), `[database]` (`host`, `port`, `user`, `name`, `pool_size`), `[pki]`
(`cert_store_dir`, `common_name`, `curve`, `root_cert_validity_days`, `tls_cert_validity_days`).
`database.host` may be an absolute directory (e.g. `/run/postgresql`) to connect over a unix socket.

Code should take its settings from the loaded config record, not hardcode paths or connection
details — the server is meant to run as a systemd service with a working directory like
`/var/lib/minxstr`, so nothing may assume the cwd is the repo. The remaining exception is
`Minxstr.Log`, which still writes to a hardcoded `./minxstr.log`.

## Architecture

The library (`src/Minxstr/`) is consumed by both the `Minxstr` executable (`app/Main.hs`) and the
test suites, so library code should stay side-effect-isolated from the executable's wiring where
possible.

- **`app/Main.hs`** — entrypoint and routing. Startup order: resolve + load config → `initPKI` if
  the cert store is missing/empty → `verifyPKI` (exit on failure) → `initDatabase` →
  `createConnectionPool` → `runTLS`. Routing dispatches on HTTP method + last path segment:
  `POST register`, `POST deregister`, `GET poll` (`poll` is `undefined`); anything else → 400.
- **`Minxstr.Configuration`** — config types (`MinxstrConfiguration`, `ServerConfig`,
  `DatabaseConfig`, `PKIConfig`), TOML codecs via `tomland` (each field parsed as optional, then
  merged over the defaults), `loadConfiguration`, `resolveConfigPath`.
- **`Minxstr.PKI`** — the private CA. All paths derive from `PKIConfig` (`rootCertPath cfg`,
  `tlsCertPath cfg`, …; layout: `<cert_store_dir>/root-{key,crt}.pem`,
  `<cert_store_dir>/transport/tls-{key,csr,crt}.pem`). `initPKI` runs `openssl` via `callProcess`
  (no shell, so paths are passed safely) to create an EC root key + self-signed root cert, then an EC TLS
  key/CSR (CN and SAN from `common_name`) signed by the root. `verifyPKI` validates the TLS cert
  chain against the store with `crypton-x509-validation`, using `common_name` as the service ID.
- **`Minxstr.TLS`** — Warp TLS / mutual-TLS scaffolding, separate from PKI generation.
  `mutualTLSSettings` and `onClientCertificateMutalTLS` exist but are not wired into `Main.hs`
  (which uses one-way `tlsSettings`). `onClientCertificateMutalTLS` accepts every client cert
  unconditionally — a stated placeholder.
- **`Minxstr.Poll`** — intended home for poll handling (`pollResponse`); currently `undefined`.
- **`Minxstr.Queries`** — all SQL. Queries live in `.sql` files under `queries/` and are embedded
  into the binary at compile time with `file-embed` (paths relative to the package root; the files
  are also listed under `extra-source-files`). Add a new query by creating the `.sql` file and an
  `$(embedStringFile ...)` binding here. `schemaQueries` splits the schema file on `--` lines into
  separate statements.
- **`Minxstr.DatabaseInterface`** — all Postgres access. `connectInfoFromConfig` builds libpq
  connection info from `DatabaseConfig`. `initDatabase` connects to the configured database (which
  must already exist) and runs `schemaQueries` in a transaction; every statement is
  `if not exists`, so it runs on every startup. `createConnectionPool` opens `pool_size` connections
  held in a `TVar` list; `withConnection` checks one out (STM `retry` when empty), runs the handler,
  commits/rolls back, and returns it. Exposes typed wrappers per query (`insertMachine`,
  `getTokenInfo`, `consumeToken`, `deleteMachineRecord`, …).
- **`Minxstr.DataSchema`** — Aeson and postgresql-simple instances for wire/DB types:
  `NixMachine`, `NixMachineEnrollment` (token + machine details), `TokenValidityInfo`,
  `PollResponse` (the set of actions a machine can be told to perform).
- **`Minxstr.Registration`** — `registerMachine` decodes a `NixMachineEnrollment` from the body
  (rejected if length is unknown, zero, or > 4028 bytes), hashes the enrollment token with SHA-256,
  validates it against `nix.enrollment_tokens` (must exist, be unexpired, unrevoked, unused), then
  inserts the machine. `deregisterMachine` decodes a `NixMachine` and deletes it by id.
  `generateToken` creates an `enr_`-prefixed random token and stores only its hash.
- **`Minxstr.Log`** — simple leveled logging appended to `./minxstr.log`. Not yet called from the
  server code.

## Database schema

`queries/init/table-creation.sql` defines the `nix` schema:
- `nix.machines` — `id` identity PK, `device_name` (unique index), `assigned_cert`,
  `hardware_fingerprint` (unique together with `assigned_cert`), `enabled`, `compliant`,
  `created_at`.
- `nix.machine_actions` — queued actions, FK `machine_id` → `machines(id)` (cascade delete),
  `action_type`, `payload`.
- `nix.machine_info` — FK `machine_id` → `machines(id)`, `assigned_user`.
- `nix.enrollment_tokens` — `token_hash` (bytea, unique), `created_at`, `expires_at`
  (default now + 1 hour), `used_at`, `revoked_at`.

All SQL identifiers (tables, columns, indexes) are snake_case. Haskell record fields stay camelCase:
`FromRow`/`ToRow` instances map columns **by position**, so a query's column order must match the
record's field order (e.g. `get-machine-by-device-name.sql` selects in `NixMachine` field order).
The schema file only uses `create ... if not exists`, so changing an existing table's shape requires
dropping it (dev: `drop schema nix cascade;`) — there are no migrations yet.

## Known gaps

These are known issues in the current code, not intended behavior:
- `withConnection` ignores the handler's `RegistrationStatus` and always responds 200 on a
  non-exceptional run (even for `TokenValidationFailure`/`MalformedRequest`); exceptions → 300.
- `withConnection` calls `commit`/`rollback` but never `begin`s a transaction.
- Registration never calls `consumeToken`, so enrollment tokens are not marked used.
- No NixOS module/systemd service exists yet; `packages.default` in `flake.nix` builds via
  `callCabal2nix` but runs the test suites at build time, which needs `openssl` in the sandbox.
