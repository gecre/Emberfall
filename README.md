# Emberfall

A single-player, stage-based side-scroller rebuilt using data scraped from the Helmet Heroes Wiki (`EmberfallWiki.xlsx`, formerly `HelmetHeroesWiki.xlsx`). The project targets **Godot 4.7** and uses
procedurally drawn placeholder art, so no external art assets are required.

The game can run fully offline or with accounts and cloud saves through the
optional Node.js server in `server/` (see [Online play](#online-play)).

## Running

1. Open `project.godot` with Godot 4.7.
2. Press **F5**. The main menu is the entry scene.
3. Choose **New Game** (or **Continue** if a save exists).

Save data is stored in `user://emberfall_save.json`.

## Controls

| Action | Keys |
| --- | --- |
| Move | `A` / `D` or Left / Right |
| Jump | `W` / Up |
| Attack | `Space` |
| Interact (NPC, portal) | `E` |
| Inventory & equipment | `I` |
| Pause menu | `Esc` |
| Use consumable slots 1–5 | `1` … `5` |
| Rage | `R` |
| Block (hold) | `V` |

`Rage` and `Block` require the matching learned skills; mobile players get a
touch joystick, ATK/JUMP buttons and a contextual PICK UP control instead.

## What is implemented

- **140 stages** identified from `GreenMiniStageBox` (numbers 1â€“145 with gaps at
  51, 64, 99, 110 and 133).
- **728 items** with equipment slots, stats, prices and shop assignments.
- **88 monsters** with wiki health/power/speed converted through balance curves,
  including bosses and drop tables.
- **109 NPCs** that open shops, heal the player, or show their wiki quote.
- **41 skills** loaded from the wiki (data available for future skill trees).
- Combat: melee swings with reach, critical hits, knockback, invulnerability
  frames, floating damage numbers, death and respawn.
- Loot: gold and item drops with magnet-style pickup, labeled item drops,
  drop notifications, XP and level-ups.
- Progression: inventory, equipment, hotbar consumables, buying/selling,
  stage unlocking, save/load and stage select.
- Skills: upgradeable skill panel, skill points, cooldowns, rage and block.
- Mobile: virtual joystick, action buttons, contextual loot pickup, touch
  inventory menus and a Pause button.
- Online (optional): account registration/login, a character list with
  create/delete, cloud saves and an offline replay queue, with local saves
  retained as an offline cache.
- Procedural presentation: biome palettes, parallax-like layers, ground,
  platforms, trees, rocks, portals, NPCs and player/monster silhouettes.

## Data pipeline

`tools/convert_wiki_data.ps1` unpacks the workbook, parses the relevant sheets,
and writes the runtime database to `Emberfall/data/`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools/convert_wiki_data.ps1
```

| File | Contents |
| --- | --- |
| `items.json` | Equipment, consumables, materials and pets |
| `monsters.json` | Stats, drops, locations and tiers |
| `stages.json` | Stage identity, NPCs, monsters, links |
| `npcs.json` | Services, locations, missions and quotes |
| `skills.json` | Skill definitions |
| `crafting.json` | Empty placeholder (the wiki recipe sheet has no parsed materials) |
| `meta.json` | Counts and generation metadata |

Stage identity comes from `GreenMiniStageBox`; `StageInfoBox` numbering is
inconsistent and is not used for stage IDs. The enemy column is
`GreenMiniStageBox.monsters`.

## Project layout

```
project.godot                              Autoloads, input map, window settings
Emberfall/
  data/                                    Generated JSON database
  scenes/
	interface/main_menu.tscn               Title screen
	interface/hud.tscn                     Standalone HUD scene
	player/player.tscn                     Player rig
	entities/monster.tscn                  Monster rig
	entities/loot.tscn                     Pickup rig
	world/npc.tscn                         NPC rig
	world/portal.tscn                      Stage gate rig
	world/world.tscn                       Stage scene (Stage + HUD)
  scripts/
	systems/game_data.gd                   Data loading and balance formulas
	systems/game_state.gd                  Progression, inventory, save/load
	player/player.gd                       Platformer controller and combat
	entities/monster.gd                    Monster AI, stats and drops
	entities/loot_pickup.gd                Gold/item pickup
	world/stage.gd                         Procedural stage builder
	world/npc.gd                           Shops, healing and dialogue
	world/portal.gd                        Stage transitions
	ui/hud.gd                              HUD, panels and shops
	ui/main_menu.gd                        Title screen
	ui/touch_controls.gd                   Mobile joystick/buttons/loot picker
	systems/api_client.gd                  REST client for cloud saves
tools/convert_wiki_data.ps1                Excel â†’ JSON converter
tools/online_test.tscn                     Client/server integration test
tools/character_select_test.tscn           Main-menu account flow test
tools/start_online_dev.ps1                 Starts the API + the game
tools/db.bat                                Admin CLI for the database
tools/test_all.ps1                         Runs every test suite
server/                                   Optional Node.js account + save server
```

## Online play

The optional `server/` backend provides accounts and cloud saves. It is not
required: leave it stopped and use **Play Offline** to keep using
`user://emberfall_save.json`.

```
cd server
npm install
npm start
```

The API listens on `http://127.0.0.1:7575/api` by default. The game reads the
base URL from `user://emberfall_server.json` (`{"base_url": "..."}`) or the
`EMBERFALL_API_URL` environment variable; the login screen shows which server it
will contact and lets you type a different address (**Server: ...** under the
sign-in box), which is what a phone needs.

After signing in you get a character list: play a character, create another one
(name + class) or delete one. On the very first login an existing local save is
uploaded as the account's character, so progress is not lost. The local save is
still written on every save, so a server outage never costs you anything; a
cloud save that fails is parked on disk and replayed on the next login.

### Playing on a phone

The Android build talks to the same server, so the phone and the computer have
to be on the same Wi-Fi network.

**The game finds the server by itself.** On start-up it looks for a server on
the network and remembers the address it found, so nothing has to be typed.
The **Server: ...** button under the sign-in box shows the address in use and
opens a small panel with **SAVE**, **DEFAULT** and **FIND SERVER** for when
the address has to be changed by hand.

The search works like this:

- the emulator reaches the computer through `10.0.2.2` (and Genymotion through
  `10.0.3.2`), so both are tried first;
- every other server on the network answers a short broadcast and says which
  address it has, which is how a phone finds the computer;
- the address that answers `/api/health` first is used.

1. Build the APK and install it on the phone:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_android.ps1
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_android.ps1 -Install
   ```

   The APK is written to `..\Export\EmberFall.apk`. `-Install` pushes it to a
   phone connected over USB (turn on USB debugging first).

2. On the computer, start the server so it listens on the network:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\start_online_dev.ps1 -NoGame -Lan
   ```

   `-Lan` binds the API to every network interface and prints the address to
   type on the phone, for example `http://192.168.0.108:7575/api`. Without it
   the API only listens on `127.0.0.1`, which a phone cannot reach.

   Windows Firewall has to allow Node.js on private networks as well.

The Android export preset keeps `permissions/internet=true`; without that
permission Android refuses every network request and the game reports
"Could not reach the server". `build_android.ps1` sets the option again before
every export, because an open Godot editor writes its own copy of
`export_presets.cfg` and can drop it.

### Admin dashboard

Double-click **`ADMIN.bat`** in the project folder. It starts the API server
if it is not already running and opens the dashboard in your browser:

```
http://127.0.0.1:7575/admin
```

**Accounts** (ban, mute, set a password, delete), **Characters** (view the full
save, delete), **Items** (search the catalog), **SQL** (read-only queries) and
**Backups** (take, verify and restore snapshots — restoring works without
stopping the server).

The key is printed in the server log at startup and stored in
`server\data\admin_key.txt`. The dashboard only answers requests from this
machine, and turns off entirely with `EMBERFALL_ADMIN=0`.

### Command line

`node src/admin.js` inside `server/` does the same things without a browser.
Node.js is not on the PATH on this machine, so use the wrapper:

```
tools\db.bat list                      # every account
tools\db.bat ban <username> <reason>   # ban an account
tools\db.bat setpassword <user> <pass> # replace a password
tools\db.bat setusername <user> <name> # rename an account
tools\db.bat renamecharacter <user> <old> <new>
tools\db.bat query "SELECT ..."        # read-only SQL query
tools\db.bat backup                    # snapshot the database
tools\db.bat restore <file>            # restore a snapshot
```

The database runs in WAL mode, so `emberfall.sqlite` on its own is not a
complete copy while the server is running — use `backup` rather than copying
the file by hand.

See `SERVER_DESIGN.md` for the schema, API and anti-cheat rules.

### Tests

```
powershell -ExecutionPolicy Bypass -File tools\test_all.ps1
```

Runs everything: the server API test, the admin CLI test, the backup/restore
test, the Godot client/server tests and the offline regression scenes. The
individual pieces are:

```
cd server
npm test                                                   # server API, admin CLI, backup and dashboard tests
powershell -ExecutionPolicy Bypass -File test\run_godot_online_test.ps1
```

The first runs the four server suites; the second boots a throwaway server and
runs the Godot client tests (`tools/online_test.tscn` and
`tools/character_select_test.tscn`).

### Trying it by hand

Double-click one of these in the project folder:

| File | What it does |
| --- | --- |
| `PLAY.bat` | Starts the game only (local save, no server) |
| `PLAY ONLINE.bat` | Starts the API server *and* the game (close the game to stop the server) |
| `ADMIN.bat` | Starts the API server and opens the admin dashboard |

`PLAY ONLINE.bat` prints the server URL and writes the API log to
`server\data\server.log`. From the command line the same thing is:

```
powershell -ExecutionPolicy Bypass -File tools\start_online_dev.ps1
```

In the game: **CREATE ACCOUNT** -> the first character is created automatically
-> back in the menu you get the character list, where you can play, create
another character or delete one. **LOG OUT** ends the session, **PLAY OFFLINE**
plays without the server.

## Balance notes

Raw wiki values span several orders of magnitude (monster health reaches
35,000,000). The recreation keeps relative difficulty with:

- `hp = max(8, round(sqrt(health) * 7))`
- `damage = max(1, round(sqrt(power) * 2.2))`
- `speed = clamp(45 + speed * 9, 40, 170)`
- XP is doubled and gold tripled; death costs 50% of carried gold.

## Known limitations

- Art, audio and animation are procedural placeholders.
- Crafting, fishing, pets, guilds, missions and PvP are not implemented.
- Online v1 covers accounts and cloud saves only; there is no real-time
  multiplayer yet. An account may own up to ten characters.
- The HUD stage list only shows stages unlocked through play.
