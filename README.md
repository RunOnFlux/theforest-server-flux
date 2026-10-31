# theforest-server-flux

The Forest dedicated server for Flux: `runonflux/theforest-server-flux`.

Endnight ships the dedicated server for Windows only (Steam app 556450, anonymous download, about 1.8 GB), so
the image runs it under Wine 10.0 staging-tkg (the Wine of our V Rising, Enshrouded and Sons of the Forest
images) on a virtual display (Xvfb: the Unity 5.6 player aborts with "Failed to create batch mode window" without
one, measured). Base `steamcmd/steamcmd:ubuntu-24`. PID 1 is a bash supervisor (`flux-entrypoint.sh`);
`flux-forest` (`fluxforest.py`) holds every decision about the game's files and is the hub's CLI. Written from
scratch: third-party The Forest images were reference only.

- SteamCMD update of the Windows build on every start (anonymous), retried with `validate`.
- `config.cfg` written from the environment and the hub's panel (the game reads it once, as it starts).
- **The game does not save on quit.** See "Saving and the stop".
- Crash restart in place (5 in an hour, then exit 42), game-update following, optional daily restart, both
  waiting for an empty server.
- Backups of the saves and config (start, every 6 h, before a restore / new world / delete), restore, five save
  slots, import/export of a slot, A2S status and players, a JSON status for the hub.
- **Settings the environment cannot fix are not a crash**: state `needs-fix`, nothing restarts.

## Volumes

| Path | What | Flux mount |
|---|---|---|
| `/mnt/theforest/server` | game install (1.8 GB), Wine prefix (`flux-wine`), game logs, `flux-logs/flux.log` (our supervisor log, 5 MB then one `.1`) | `ml:` (local, never synced) |
| `/mnt/theforest/data` | `saves/Multiplayer/Slot1..5`, `config.cfg`, `flux/` (state, backups, uploads) | `g:` primary |

## Ports (UDP)

`serverSteamPort` 8766, `serverGamePort` 27015, `serverQueryPort` 27016. Only 27015 (Bolt, where players connect)
and 27016 (Steam A2S: info AND players, no challenge round) are bound on the machine; 8766 is the Steam master
updater's port, published as the game's documentation asks. Each can be changed with `FOREST_STEAM_PORT`,
`FOREST_GAME_PORT`, `FOREST_QUERY_PORT` (1024-65535, all different). None is in the ranges Flux refuses.

## Environment

Empty = unset. A value is written to the file when the file is new or the value changed since the last start,
so the hub's panel edits survive restarts.

| Variable | Writes | Default |
|---|---|---|
| `FOREST_SERVER_NAME` | serverName (<= 60 chars) | `The Forest on Flux` |
| `FOREST_PASSWORD` | serverPassword (<= 40 chars) | none |
| `FOREST_ADMIN_PASSWORD` | serverPasswordAdmin (<= 40 chars): a player who joins with it is an admin | none |
| `FOREST_MAX_PLAYERS` | serverPlayers 2-100 (the game clamps it to 2..100 itself, `SteamDSConfig.minPlayersPerServer/maxPlayersPerServer`; 8 is only the co-op group size) | 8 |
| `FOREST_DIFFICULTY` | difficulty Peaceful/Normal/Hard (for a NEW world) | Normal |
| `FOREST_AUTOSAVE_MINUTES` | serverAutoSaveInterval 15-120 | 15 |
| `FOREST_SAVE_SLOT` | slot 1-5 | 1 |
| `FOREST_SETTINGS_JSON` | any other key, one JSON object (`{"veganMode": true}`), validated like the panel | none |
| `FOREST_RESTART_TIME` | daily restart `HH:MM` (TZ, UTC if unset), done on an empty server | none |
| `SKIP_UPDATE` | do not run SteamCMD (an install must exist) | off |
| `FLUX_STOP_GRACE` | seconds a stop may take before the game is killed | 4 |
| `FLUX_BACKUP_HOURS`, `FLUX_BACKUP_KEEP` | backup cadence and count | 6, 10 |
| `FLUX_RESTART_MAX_ATTEMPTS`, `FLUX_RESTART_WINDOW` | crash budget | 5 per 3600 s |

`initType` is always `Continue`: on a slot with nothing in it the game makes a new world ("Will force game to
new because ... CanResume False"), so a "new world" is "back up and empty the slot at the next start".

## Saving and the stop

Read off the game's code (build 3488796, `AutoSaveMode`, `SteamDSConfig`), then checked on a real server:

- it saves every `serverAutoSaveInterval` minutes (15 at the least: a smaller value is printed and used as 15)
  **while players are on**, and **once when the last player leaves**;
- a server nobody ever joined never saves;
- it does **not** save on quit (`OnApplicationQuit` only shuts Bolt down), and it has no console: the admin chat
  commands (`/kick`, `/ban`, `/save <slot>`, `/restart`, `/shutdown`) are typed in game by a player who joined
  with the admin password.

So a stop is immediate: SIGINT (a Ctrl+C under Wine) to the game, which leaves in a second or two, killed after
`FLUX_STOP_GRACE` (4 s) if it has not. Every PLANNED restart (the daily one, a game update) waits up to
`FLUX_RESTART_WAIT_MINUTES` (60) for an empty server, which is exactly when the game has just saved. A stop from
Docker with players on loses what happened since the last autosave. A `kill -9` loses the same and nothing more.
Measured on the real game: `docker stop` 2.9 s, game exit 58; once, a server that had run for 20 minutes needed the
4 s (then 8 s) kill, so the whole stop stays inside Docker's 10 s either way.

## For the hub

`flux-forest status` (state, generation, slot, ports, build, players via A2S, pending restart/restore),
`settings` / `set-settings '<json>'`, `saves`, `use-slot`, `new-world <slot> [difficulty]`, `delete-slot`,
`import-save <file> <slot>`, `export-save <slot> <file>`, `players`, `backups`, `backup`, `restore <name>`,
`restart`. States: `updating`, `starting`, `running`, `restarting`, `needs-fix` (message names the variable),
`crashed`, `stopped`. The game log is `/mnt/theforest/server/flux-logs/current.log`; the container's stdout carries
it too, without the Unity noise (a `RenderTexture.Create failed` every second or so, a NullReferenceException stack
from the UI). There is no ban list or admin list: bans live in the game's own PlayerPrefs file (`PlayerPrefsFile_<id>.dat` under
Unity's `persistentDataPath`, i.e. inside the Wine prefix on the local `ml:` volume), so they are NOT synced to a standby
node and are lost when the app moves (open item).

## Measured (build 3488796, Wine 10.0, 2026-10-29, 20-core host)

First start with the SteamCMD check and the Wine prefix about 100 s to `Game autosave started` (the line the
supervisor treats as ready: `AutoSaveMode` starts its timer when the world has loaded); later starts 40-60 s.
Idle empty server: **1.55 GiB RSS, flat over 10 minutes**, and about 1.9 cores in `docker stats` (the game thread
about 90 % of a core because the Null graphics device has no frame cap, plus Wine's threads; `targetFpsIdle`
makes no difference, measured; the server also runs, as `--cpus=2`, pinned at 2). Game log about 170 KB an hour.
Install 1.8 GB + about 0.9 GB for the Wine prefix. Image 1.37 GB.

**Not verified: anything with a player.** No game client was available, so the memory with players, a save written
by the game (the slot layout `Multiplayer/Slot<n>` is read off its code), a co-op save imported, and the admin
password flow are unmeasured. The hub tiers are sized from the idle figures and from how heavy the game is known
to get with a base.

## Versions

- 1.0.0: first release.
- 1.0.1: emptying a password in the deployment removes it; a value saved in the panel is not undone by the deployment's env (also before the first start); a restore puts the deployment's passwords back; a restart asked for while the server prepares no longer stops the game right after it starts; safety backups are capped (newest 20, `FLUX_BACKUP_KEEP_SAFETY`); a restore with a blank password env keeps a password set in the panel; a bad `FLUX_BACKUP_*` number is the default instead of a crash.
