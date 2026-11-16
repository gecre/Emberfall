# Emberfall Server

## Scope

Accounts and cloud saves for Emberfall, alongside the existing local save. The
local save (`user://emberfall_save.json`) is still written on every save, so the
game remains playable offline and on a server outage. Online mode adds:

- username/password registration and login
- up to ten server-side characters per account (create, list, delete)
- cloud persistence of the full `GameState` save blob
- server-side validation of stats, inventory, equipment and skills
- rate limiting, bans/mutes, and a per-save gold-gain cap
- an offline queue: a cloud save that fails is parked on disk and replayed the
  next time the character is loaded

Real-time multiplayer (stage sync, shared combat) is **not** part of v1. The old
ENet host/join code in `Network` is untouched and remains unused by the online
account flow.

## Stack (as implemented)

- Node.js 22.5+ (developed on Node 26) + Express 5
- SQLite through Node's built-in `node:sqlite` (no native module compilation)
- `bcryptjs` password hashing (10 rounds)
- `jsonwebtoken` stateless tokens, 7-day expiry
- Client: Godot 4.7 GDScript (`api_client.gd`, autoloaded as `Api`)

```
server/
  package.json
  src/
    index.js          # Express app + startup
    config.js         # env config, JWT secret, paths
    db.js             # schema, item/skill catalog, query helpers
    auth.js           # bcrypt + JWT
    api.js            # REST routes
    validate.js       # credentials + character save validation
    middleware.js     # bearer auth, rate limiting, logging
    backup.js         # snapshot / verify / restore helpers
    admin.js          # CLI for bans/mutes, account inspection and backups
  data/               # created at runtime (gitignored)
    emberfall.sqlite
    emberfall.sqlite-wal
    emberfall.sqlite-shm
    jwt_secret.txt
    backups/          # database snapshots
  test/
    api_test.js                # server-only API test
    backup_test.js             # backup / restore test
    run_godot_online_test.ps1  # boots a throwaway server + Godot client tests
```

## Running

```
cd server
npm install
npm start          # http://0.0.0.0:7575/api
```

Environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `7575` | Listen port |
| `HOST` | `0.0.0.0` | Bind address (use `127.0.0.1` for local-only) |
| `EMBERFALL_DB` | `server/data/emberfall.sqlite` | Database path |
| `EMBERFALL_DATA_DIR` | `server/data` | Data directory |
| `EMBERFALL_JWT_SECRET` | generated file | Token signing secret |
| `EMBERFALL_TOKEN_TTL` | `7d` | Token lifetime |
| `EMBERFALL_MAX_GOLD_GAIN` | `100000` | Lowest gold-gain allowance per save |
| `EMBERFALL_GOLD_PER_SECOND` | `250000` | Gold a player may earn per second of play |
| `EMBERFALL_GOLD_WINDOW_SECONDS` | `600` | Seconds between saves that count towards the allowance |
| `EMBERFALL_MAX_CHARACTERS` | `10` | Characters allowed per account |
| `EMBERFALL_DISCOVERY_PORT` | `7576` | UDP port for the discovery broadcast |
| `EMBERFALL_BACKUP_DIR` | `server/data/backups` | Where snapshots are written |
| `EMBERFALL_BACKUP_KEEP` | `10` | Snapshots kept when pruning |
| `EMBERFALL_ADMIN` | `1` | Set to `0` to turn the admin dashboard off |
| `EMBERFALL_ADMIN_KEY` | generated file | Key for the admin dashboard |
| `EMBERFALL_QUIET` | unset | Set to `1` to silence request logs |

## Admin dashboard

The server serves a small dashboard at `http://127.0.0.1:7575/admin` for
managing accounts, characters and snapshots without touching the CLI.

```
http://127.0.0.1:7575/admin
```

It has five tabs: **Accounts** (ban, mute, set a password, delete),
**Characters** (view the full save, delete), **Items** (search the 728-entry
catalog), **SQL** (a read-only query box) and **Backups** (take, verify and
restore snapshots).

The dashboard is deliberately restricted:

- it is mounted **before** the permissive CORS middleware, so it never gets
  `Access-Control-Allow-Origin: *` and cannot be read from another origin;
- it refuses any request that does not come from loopback;
- every data route needs the admin key in an `X-Admin-Key` header, which
  blocks a random web page from poking it through the browser.

The key is generated once into `server/data/admin_key.txt` and printed in the
server log at startup:

```
[server] Admin dashboard:  http://127.0.0.1:7575/admin
[server] Admin key:       267ce922769128f5d34bd63d72b55dd5
```

Because the dashboard runs inside the server, it can restore a snapshot
**without a server restart**: the handle on the database is closed, the file is
swapped and the database is reopened against the restored file. The swap is
synchronous, so no request can interleave with it.

Set `EMBERFALL_ADMIN=0` to turn the dashboard off entirely before putting the
server on a public network.

## Admin CLI

```
cd server
node src/admin.js list                      # every account with ban/mute state
node src/admin.js characters <username>     # the account's characters
node src/admin.js ban <username> <reason>
node src/admin.js unban <username>
node src/admin.js mute <username> <reason>
node src/admin.js unmute <username>
node src/admin.js setpassword <username> <newpassword> [--allow-short]
node src/admin.js setusername <username> <newusername>
node src/admin.js renamecharacter <username> <oldname> <newname>
node src/admin.js delete <username>
node src/admin.js backup                    # snapshot the database
node src/admin.js backups                   # list snapshots
node src/admin.js verify <file>             # check a snapshot is restorable
node src/admin.js restore <file>            # restore a snapshot
node src/admin.js query "<sql>"             # run a read-only SQL query
```

Node.js is not on the PATH by default on this machine, so `tools\db.bat` wraps
the CLI and finds `node.exe` itself:

```
tools\db.bat list
tools\db.bat query "SELECT id, name, level FROM characters"
tools\db.bat backup
```

The CLI opens the same database file as the API, so point it at the same
`EMBERFALL_DB` / `EMBERFALL_DATA_DIR`. Banned accounts get `403` on every
authenticated route.

Passwords are stored as bcrypt hashes and can never be read back — only
replaced with `setpassword`. The 6 character minimum that registration
enforces is kept for `setpassword` as well, but `--allow-short` overrides it
for an existing account.

`setusername` renames an account. The account id does not change, so its
characters and any issued session tokens stay attached to it. The new name is
checked against the same 3-20 character rule as registration and may not
collide with another account.

`renamecharacter` renames one of an account's characters. The name lives in the
character row *and* inside the save blob as `player_name`, so the blob is
rewritten as well — otherwise the next cloud save would push the old name
back to the server.

`delete` removes the account and, through the `ON DELETE CASCADE` on
`characters.account_id`, its characters. It asks for confirmation first; pass
`--yes` to skip the prompt (needed for scripts).

### Querying

`query` opens the database **read-only**, so it can never modify anything.
Only `SELECT`, `WITH`, `PRAGMA` and `EXPLAIN` are accepted:

```
node src/admin.js query "SELECT id, username, banned FROM accounts"
node src/admin.js query "SELECT c.name, c.level, a.username
                          FROM characters c JOIN accounts a ON a.id = c.account_id"
node src/admin.js query "SELECT * FROM items LIMIT 5" --snapshot <backup-file>
```

`--snapshot` runs the query against a snapshot instead of the live database,
which is how you check what a backup actually contains without restoring it.

## Backups

The database runs in **WAL mode**, which has one consequence that matters:
`emberfall.sqlite` on its own is *not* a complete copy of the data while the
server is running. Everything written since the last checkpoint still lives in
the `-wal` sidecar, and the main file can be far behind. Copying it by hand
silently rolls the database back.

Snapshots are therefore taken with `VACUUM INTO`, which writes a fresh,
self-contained file that includes the committed WAL content and is safe to run
against a live server.

```
node src/admin.js backup               # server/data/backups/emberfall-<stamp>.sqlite
node src/admin.js backup --keep 5      # snapshot, then keep only the 5 newest
node src/admin.js backup --out D:\eb   # snapshot somewhere else
```

Every snapshot gets a `.json` manifest next to it recording when it was taken,
where it came from and the row counts it contains.

### Restoring

```
node src/admin.js restore server\data\backups\emberfall-2026-11-12_09-50-20-959.sqlite
```

The restore:

1. verifies the snapshot (`PRAGMA integrity_check` plus a table check),
2. snapshots the *current* database as `...-prerestore.sqlite`, so the restore
   can be undone,
3. replaces the live database file and deletes its `-wal`/`-shm` sidecars — a
   stale WAL would replay old pages on top of the restored file,
4. puts the database back into WAL mode and verifies the result.

**The server must be stopped while a restore runs.** The CLI asks the running
API server whether it has the same database open (using a fingerprint of the
database path reported by `GET /api/health`) and refuses to restore if it
does. `--force` skips that check.

### Scheduling

`backup` is safe to run against a live server, so it can be run on a timer:

```powershell
# every night at 3am
$action = New-ScheduledTaskAction -Execute "C:\Program Files\nodejs\node.exe" `
    -Argument "src/admin.js backup" -WorkingDirectory "C:\Game Creation\helmetheroes\server"
Register-ScheduledTask -TaskName "Emberfall backup" -Action $action -Trigger (New-ScheduledTaskTrigger -Daily -At 3am)
```

Old snapshots are pruned automatically, newest kept, oldest dropped. Note that
snapshots live inside `server/data/`, which is gitignored — copy them
somewhere else (another disk, a cloud folder) if the machine can fail.

## Client configuration

`Api` resolves its base URL in this order (last wins):

1. `http://127.0.0.1:7575/api` (default)
2. `user://emberfall_server.json` -> `{"base_url": "https://example.com/api"}`
3. `EMBERFALL_API_URL` environment variable

The login screen shows the active server URL and has a **Play Offline** button.
On a successful online login:

1. Client registers/logs in and receives a JWT.
2. Client lists characters. If the account has none, the current local save (or
   a fresh character) is uploaded as the account's first character. The name of
   that character is the hero name from the local save; if it is already taken
   the client falls back to the account name and then to a numbered variant.
3. Otherwise the character list opens: pick a character to play, create another
   one (name + class), or delete one (with a confirmation).
4. `GameState.apply_character()` loads the server blob.
5. Gameplay saves write the local file immediately and queue a cloud save after
   a short debounce. Failed cloud saves retry; the local file is never at risk.
6. A cloud save that still fails is parked in `user://emberfall_pending_save.json`
   and replayed automatically the next time that character is loaded.

Returning to the main menu keeps the session, so the character list opens
straight away instead of asking for the password again. **Log out** clears the
token.

## Database schema

**accounts**: id, username (unique, case-insensitive), password_hash, banned,
ban_reason, muted, mute_reason, created_at, last_login

**characters**: id, account_id, name (unique), class, level, xp, gold,
current_stage, unlocked_stage, hp, mp, skill_points, special_skill_points,
play_time, inventory/equipment/attributes/skills/quests JSON, data JSON
(full save blob), updated_at

**items**: name, price, sell, slot, type, level — populated from
`Emberfall/data/items.json` at startup (728 entries).

**bans / mutes**: account_id, reason, expires_at, created_by, created_at.

## API

- `GET /api/health` — liveness + item count + database fingerprint
- `POST /api/register` — `{username, password}` -> `{token, account, characters}`
- `POST /api/login` — `{username, password}` -> `{token, account, characters}`
- `GET /api/me` — current account (Bearer token required)
- `GET /api/characters` — list character summaries
- `POST /api/characters` — `{name, class, data}` create character
- `GET /api/characters/:id` — full character including `data`
- `PUT /api/characters/:id` — `{data}` full save (validated)
- `DELETE /api/characters/:id` — permanently remove a character
- `GET /api/items` — item catalog summary

All character routes require `Authorization: Bearer <token>` and are scoped to
the authenticated account. The design's separate gold/item mutation endpoints
are intentionally deferred: `PUT /characters/:id` is the single authoritative
save path, so there is only one code path to validate.

## Discovery

The server answers a short UDP broadcast on port 7576
(`EMBERFALL_DISCOVERY_PORT`). A client sends `EMBERFALL_DISCOVER` to the
broadcast address and to `10.0.2.2` (the alias the Android emulator uses for
the host), and the server replies with the addresses it can be reached on:

```json
{ "service": "emberfall-server", "base_urls": ["http://192.168.0.108:7575/api"] }
```

The client then asks `/api/health` on every address and keeps the first one
that answers, so a phone finds the computer without an address being typed.

## Validation / anti-cheat

`validate.js` rejects a save when:

- the body is larger than 512 KB or is not an object
- level/xp/gold/stage/points/hp/mp/play_time are out of sane numeric bounds
- `unlocked_stage < current_stage`
- inventory has more than 40 entries, unknown item names, bad quantities, or
  more than 100,000 total items
- equipment uses an unknown slot or unknown item name
- skills reference unknown skill names or have invalid levels
- a single save increases gold by more than the allowance for one save
  (first creation is exempt so local saves can be imported)

### Gold allowance

A flat cap per save breaks normal play as soon as the monsters are worth more
than the cap, so the allowance is computed per save:

```
allowance = max(EMBERFALL_MAX_GOLD_GAIN,
                 sold_items_value + elapsed_seconds * EMBERFALL_GOLD_PER_SECOND)
```

- `sold_items_value` is what the items that left the inventory are worth,
  using the wiki sell price (or 35% of the shop price). Selling items is the
  only way to add a large amount of gold at once, and it is counted exactly.
- `elapsed_seconds` is the time since the stored save, capped at
  `EMBERFALL_GOLD_WINDOW_SECONDS`. It covers gold from monster kills.
- The floor `EMBERFALL_MAX_GOLD_GAIN` keeps a small allowance for the first
  minutes of a new character.

The gold of the stored character and the inventory of the stored save are the
server's own data, so a client cannot raise its allowance by lying about them.

Rate limits: login 5/min, register 5/min, saves 90/min, all per IP/account.
Banned accounts get `403` on every authenticated route.

## Tests

```
cd server
npm test                                                   # server API, admin CLI and backup tests
powershell -ExecutionPolicy Bypass -File test\run_godot_online_test.ps1
```

The three server suites each run in a throwaway data directory, so they never
touch the real database:

- `test/api_test.js` — the REST API
- `test/admin_test.js` — the admin CLI (ban, mute, setpassword, delete)
- `test/backup_test.js` — snapshot, verify, restore and pruning
- `test/admin_web_test.js` — the admin dashboard

The Godot tests run against a throwaway server:

- `tools/online_test.tscn` — registers a real account, creates a character,
  saves, reloads, checks the gold round-trip, verifies that a cheat save is
  rejected, creates and deletes a second character, and checks that a failed
  save is parked on disk and replayed.
- `tools/character_select_test.tscn` — drives the real main menu: registers
  through the UI, returns to the menu, opens the character list, creates a
  second character, deletes it again and logs out.

## Next steps

- WebSocket stage/combat sync for real-time play (the `Network` ENet scaffold is
  still present and can be reused or replaced).
- Password reset and email verification.
- Server-side leaderboards and a shared item shop.
- The character list only shows one account's characters; a shared roster or
  party system would need its own endpoints.
