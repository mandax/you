# Audit log: historical data for admins

Historical events (login attempts, admin actions, token exchanges, account changes, consent grants) are emitted as Telemetry events and written to newline-delimited JSON files. Accessible only to admins via the admin panel. Easy to store, backup, and read, with no database coupling.

## Decisions

### 1. Telemetry events for all audit data

Every auditable action emits a Telemetry event. Telemetry is already in the dependency tree (used by Phoenix, Ecto, and the dashboard). No new deps.

| Event | Payload | Emitted by |
|-------|---------|------------|
| `[:you, :audit, :login, :attempt]` | `user_id, email, result: :success \| :failure` | Login LiveView |
| `[:you, :audit, :login, :totp]` | `user_id, result: :success \| :failure` | 2FA step |
| `[:you, :audit, :admin, :action]` | `admin_user_id, action, target, details` | Admin LiveView |
| `[:you, :audit, :token, :exchange]` | `user_id, app_id, scopes` | IAM Server |
| `[:you, :audit, :token, :revoke]` | `user_id, jti` | IAM Server |
| `[:you, :audit, :account, :update]` | `user_id, field, old, new` | Settings controller |
| `[:you, :audit, :consent, :grant]` | `user_id, app_id, scopes` | Auth code flow |
| `[:you, :audit, :consent, :revoke]` | `user_id, app_id` | Consent management |

### 2. File-backed handler

A Telemetry handler writes each event as a JSON line to a file in a configurable directory. One file per event category (not per event type; categories group related events):

```
/var/log/you/
├── login.jsonl         # login attempts + 2FA
├── admin.jsonl         # admin actions
├── token.jsonl         # token exchanges + revocations
├── account.jsonl       # account changes
└── consent.jsonl       # consent grants + revocations
```

The directory is configured via `config :you, You.Audit, log_dir: "/var/log/you"`. Defaults to `"priv/log"` in dev, `/var/log/you` in prod.

### 3. Newline-delimited JSON (JSONL) format

Each line is a complete JSON object. Tools like `jq`, `grep`, `tail`, and `head` work natively:

```json
{"ts":"2026-05-28T18:00:00Z","event":"login:attempt","user_id":1,"email":"user@example.com","result":"success"}
{"ts":"2026-05-28T18:01:00Z","event":"admin:action","admin_user_id":1,"action":"promote","target":"user:2","details":"set is_admin=true"}
```

This is the same format used by systemd-journald, Docker, and most log aggregators. No binary protocol, no database schema. Backup is `cp -r /var/log/you /backup/`.

### 4. Admin-only access in the UI

The admin LiveView reads the log files directly and renders them in a paginated table:

- **Filters**: by event category, date range, user
- **Sort**: by timestamp descending (most recent first)
- **Pagination**: reads file backwards from the end (most recent lines first)
- **No DB**: reads from filesystem, not the database

The `You.Audit.Reader` module handles reading and filtering. It uses `File.stream!` with line-by-line iteration, without loading the whole file into memory. Admin LiveView polls every 30 seconds for new entries.

### 5. Log rotation

Files grow unbounded without rotation. The handler checks the file size before appending and rotates when it exceeds a configurable limit:

- Max file size: `config :you, You.Audit, max_file_size: "100MB"` (default)
- On rotation: rename `login.jsonl` → `login.2026-05-28T18:00:00Z.jsonl`, start a new file
- Cleanup: delete rotated files older than `retention_days: 90` (configurable)

Rotation is handled by the handler itself at write time, so no external cron job is needed.

## Status

Proposed

## Consequences

- `You.Audit.Handler` GenServer attached to Telemetry events on startup.
- `You.Audit.Reader` module for the admin LiveView to read and filter log files.
- Admin LiveView gets a new "Audit Log" section.
- No database migration, no new Ecto schema: purely file-based.
- Backup is a filesystem copy (`cp -r` or rsync). Restore is the reverse.
- Each auditable action site needs a `:telemetry.execute/3` call added.
