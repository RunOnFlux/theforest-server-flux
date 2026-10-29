# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

A **Docker image repo**, not an application: The Forest dedicated server for Flux,
`runonflux/theforest-server-flux`. The server is **Windows-only** (Steam app 556450, anonymous), a
Unity 5.6 player, so it runs under Wine 10.0 staging-tkg (pinned by checksum) on Xvfb, like
`~/work/sotf-server-flux` (its sibling by the same studio), `~/work/vrising-server-flux` and
`~/work/enshrouded-server-flux`. Written from scratch; third-party The Forest images were reference only.

**PID 1 is `flux-entrypoint.sh`, never the game.** The game is a child, so a stop reaches us first.

## Commands

```bash
./tests/test-flux.sh                                       # unit tests (flux-lib.sh, fluxforest.py)
docker build --build-arg FLUX_IMAGE_VERSION=1.0.0 -t theforest-server-flux:local .
./tests/test-image.sh theforest-server-flux:local          # the scripts INSIDE the image, stand-in steamcmd + server
docker run --rm -v "$PWD:/m" -w /m koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh .github/ci/*.sh
```

A change to what the image does bumps `VERSION` and adds a line under "Versions" in the README.
A real-game test needs the install volume (1.8 GB): see README "Measured".

## The files

- `scripts/flux-entrypoint.sh`: per generation SteamCMD (Windows build), backup, `flux-forest apply`, Xvfb,
  Wine prefix, server; watcher (ready line, Steam build follow, daily restart), backupper, log capper.
- `scripts/fluxforest.py`: every rule about the server's files and the hub's commands.
- `scripts/flux-lib.sh`: helpers; sourcing it must stay side-effect free.
- `tests/image/in-container.sh`: stand-in server (a Python script named `TheForestDedicatedServer.exe`; Python
  because bash cannot trap a SIGINT that is ignored on entry in a background job).

## Things that will bite you

- **The game does NOT save on quit and has no console.** It saves every `serverAutoSaveInterval` minutes
  (15 at the least; a smaller value is silently raised to 15) while players are on, and ONCE when the last player
  leaves (`AutoSaveMode.Update`, `isUsingDummyPlayer`). A server nobody ever joined never saves. So a stop is
  immediate (SIGINT: gone in a second or two, exit 58; the supervisor kills after FLUX_STOP_GRACE, 4 s) and planned restarts wait for an empty server. Do not
  copy Sons of the Forest's "saves on every stop" logic or copy.
- **Xvfb is required**: without a display Unity aborts with "Failed to create batch mode window".
- **Ports**: UDP 27015 is the game (Bolt) port and 27016 answers A2S (info AND players, no challenge). 8766 is the
  Steam master updater's port and is never bound on the machine. Publish all three.
- **`serverAutoSaveInterval` below 15** is printed as 15. The panel refuses it.
- **`serverPlayers` is clamped to 2..100 by the game** (SteamDSConfig), not 8: no player cap beyond the game's own. A value of 1 is raised to 2.
- **Saves**: `<saveFolderPath>/Multiplayer/Slot1..Slot5/` (read off the game's code, `SaveSlotUtils.GetUserPath`; not seen
  on disk because a save needs a joined player). A slot with nothing in it plus `initType Continue` makes a new
  world ("Will force game to new because ... CanResume False"), so `initType` is always Continue and a new world
  is "back up and empty the slot at the next start".
- **Bans** are in the game's own PlayerPrefs file (key `BanList`), not editable offline: not a panel feature.
  In-game admin commands (`/kick <steamId>`, `/ban <steamId>`, `/save <slot>`, `/restart`, `/shutdown`) are typed in
  chat by a player who joined with the admin password (the join token carries it, `AdminAuthed`).
- **The log is noisy**: a `RenderTexture.Create failed` every second or so, a NullReferenceException stack from the
  UI each second. `flux_noise` keeps them out of the container output; the game log keeps everything.
- **Empty env = unset.** Flux stops a container with Docker's default 10 seconds.
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced data volume.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`).
