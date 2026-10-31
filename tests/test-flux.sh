#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxforest.py's file handling. No Docker, no
# Steam, no Wine, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export TZ=UTC

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Inputs ------------------------------------------------------------------------------------
check "8766 is a port" "8766" "$(flux_port 8766 1)"
check "empty takes the default" "27016" "$(flux_port '' 27016)"
check "a leading zero is not octal" "9700" "$(flux_port 09700 1)"
check "port 80 is refused" "1" "$(status flux_port 80 1)"
check "a word is not a port" "1" "$(status flux_port abc 1)"
check "distinct ports" "0" "$(status flux_ports_distinct 8766 27016 9700)"
check "a port used twice" "1" "$(status flux_ports_distinct 8766 8766 9700)"
check "restart time 5:00" "05:00" "$(flux_restart_time 5:00)"
check "restart time off" "" "$(flux_restart_time off)"
check "restart time 24:00 refused" "1" "$(status flux_restart_time 24:00)"
# 2026-10-11 12:00 UTC = 1791720000
check "next 05:00 after noon is tomorrow" "$((1791720000 - 43200 + 86400 + 18000))" "$(flux_next_daily 1791720000 05:00)"
check "next 13:30 after noon is today" "$((1791720000 + 5400))" "$(flux_next_daily 1791720000 13:30)"
check "the wine path of a folder" 'Z:\mnt\theforest\data\userdata' "$(flux_wine_path /mnt/theforest/data/userdata)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts drop out of the window" "950 990" "$(flux_restarts_in_window 1000 100 800 950 990)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "a game update does not count" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "a panel restart does not count" "1" "$(status flux_restart_counts 'requested: from the panel')"
check "prune keeps the newest" "c d" "$(flux_files_to_prune 2 a b c d | tr '\n' ' ' | sed 's/ $//')"
check "marker notbefore" "123" "$(printf 'x\nnotbefore=123\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"
check "marker without notbefore" "0" "$(printf 'x\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"

# --- Log noise ---------------------------------------------------------------------------------
check "shader warnings are noise" "0" "$(status flux_noise <<<"WARNING: Shader Unsupported: 'Hidden/X' - All subshaders removed")"
check "blank lines are noise" "0" "$(status flux_noise <<<"   ")"
check "the ready line is not noise" "1" "$(status flux_noise <<<"Dedicated server loaded.")"
check "a save is not noise" "1" "$(status flux_noise <<<"#DSL Autosave complete. Time: 2026-10-18 21:35:27 Slot: 2")"

# --- Steam builds ------------------------------------------------------------------------------
printf '"AppState"\n{\n\t"appid"\t\t"556450"\n\t"buildid"\t\t"20228410"\n}\n' >"${tmp}/manifest.acf"
check "installed build" "20228410" "$(flux_installed_build "${tmp}/manifest.acf")"
check "public build from app_info" "20300000" "$(printf '%s\n' '"556450"' '{' '"depots"' '{' '"branches"' '{' '"public"' '{' '"buildid"		"20300000"' '}' | flux_public_build)"

# --- fluxforest.py -------------------------------------------------------------------------------
data="${tmp}/data"
server="${tmp}/server"
mkdir -p "${server}/steamapps"
cp "${tmp}/manifest.acf" "${server}/steamapps/appmanifest_556450.acf"
forest() { # VAR=value... command args: fluxforest.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" HOME="${tmp}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" \
    FLUX_RESTART_MARKER="${tmp}/restart-marker" "${vars[@]}" python3 scripts/fluxforest.py "$@"
}
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d if not isinstance(d,(dict,list)) else json.dumps(d))' "$1"; }
cfgfile="${data}/config.cfg"
cfg() { sed -n "s/^$1 //p" "${cfgfile}"; }
slots="${data}/saves/Multiplayer"
P=(FOREST_STEAM_PORT=31000 FOREST_GAME_PORT=31001 FOREST_QUERY_PORT=31002)

forest apply >"${tmp}/apply.out"
check "apply writes a config the game accepts" "The Forest on Flux" "$(cfg serverName)"
check "with the game's key order (IP first)" "serverIP" "$(sed -n '2p' "${cfgfile}" | cut -d' ' -f1)"
check "on all interfaces" "0.0.0.0" "$(cfg serverIP)"
check "booleans are on/off as the game spells them" "off" "$(cfg allowCheats)"
check "building destruction defaults on" "on" "$(cfg allowBuildingDestruction)"
check "init type is always Continue" "Continue" "$(cfg initType)"
check "the save folder is the data volume, as Wine sees it" "Z:\\tmp\\" "$(cfg saveFolderPath | cut -c1-7)"
check "and steam_appid.txt next to the exe" "242760" "$(cat "${server}/steam_appid.txt")"
check "the default ports" "8766 27015 27016" "$(cfg serverSteamPort) $(cfg serverGamePort) $(cfg serverQueryPort)"

forest FOREST_SERVER_NAME="Forest One" FOREST_MAX_PLAYERS=4 FOREST_DIFFICULTY=hard FOREST_PASSWORD=pw FOREST_ADMIN_PASSWORD=adm "${P[@]}" apply >"${tmp}/apply.out"
check "env sets the name" "Forest One" "$(cfg serverName)"
check "env sets max players" "4" "$(cfg serverPlayers)"
check "env's difficulty is spelled as the game spells it" "Hard" "$(cfg difficulty)"
check "env sets both passwords" "pw adm" "$(cfg serverPassword) $(cfg serverPasswordAdmin)"
check "env sets the ports" "31000 31001 31002" "$(cfg serverSteamPort) $(cfg serverGamePort) $(cfg serverQueryPort)"
check "the log never prints a password" "0" "$(grep -c -E 'pw|adm' "${tmp}/apply.out")"

forest set-settings '{"serverName": "Panel Name", "serverPlayers": 6}' >/dev/null
forest FOREST_SERVER_NAME="Forest One" FOREST_MAX_PLAYERS=4 FOREST_DIFFICULTY=hard "${P[@]}" apply >/dev/null
check "the same env does not undo the panel" "Panel Name 6" "$(cfg serverName) $(cfg serverPlayers)"
forest FOREST_SERVER_NAME="Forest Two" FOREST_MAX_PLAYERS=4 "${P[@]}" apply >/dev/null
check "a changed env value applies" "Forest Two" "$(cfg serverName)"
check "an empty env value leaves the file" "Hard" "$(forest FOREST_DIFFICULTY= "${P[@]}" apply >/dev/null; cfg difficulty)"
check "ports that clash are refused" "2" "$(status forest FOREST_GAME_PORT=31000 FOREST_QUERY_PORT=31000 apply)"
check "a port below 1024 is refused" "2" "$(status forest FOREST_GAME_PORT=80 apply)"
forest "${P[@]}" apply >/dev/null

# Settings, validated.
check "a bad max players is refused" "1" "$(status forest set-settings '{"serverPlayers": 101}')"
check "and says which" "must be from 2 to 100" "$(forest set-settings '{"serverPlayers": 101}' | jget fields.serverPlayers)"
check "the game clamps to 2, so 1 is refused" "1" "$(status forest set-settings '{"serverPlayers": 1}')"
check "and there is no cap of 8" "0" "$(status forest set-settings '{"serverPlayers": 16}')"
check "an autosave under the game's minimum is refused" "1" "$(status forest set-settings '{"serverAutoSaveInterval": 5}')"
check "an unknown key is refused" "1" "$(status forest set-settings '{"Foo": 1}')"
check "ports are not the panel's" "1" "$(status forest set-settings '{"serverGamePort": 1234}')"
check "neither is the save folder" "1" "$(status forest set-settings '{"saveFolderPath": "x"}')"
check "a bad difficulty is refused" "1" "$(status forest set-settings '{"difficulty": "Impossible"}')"
forest set-settings '{"veganMode": true, "allowCheats": "on", "difficulty": "peaceful", "serverAutoSaveInterval": 30}' >/dev/null
check "toggles are written on/off" "on on" "$(cfg veganMode) $(cfg allowCheats)"
check "a difficulty is normalised" "Peaceful" "$(cfg difficulty)"
check "the autosave interval is written" "30" "$(cfg serverAutoSaveInterval)"
check "settings lists the rules" "100" "$(forest settings | jget rules.serverPlayers.max)"
check "settings does not show the folder" "False" "$(forest settings | python3 -c 'import json,sys;print("saveFolderPath" in json.load(sys.stdin)["config"])')"
check "a password with a line break stays one line" "ab" "$(forest set-settings '{"serverPassword": "a\nb"}' >/dev/null; cfg serverPassword | tr -d ' ')"
check "the file is the game's: one key per line" "27" "$(grep -c -E '^[a-zA-Z]+ ' "${cfgfile}")"
forest "${P[@]}" apply >/dev/null
check "the panel's values survive an apply" "30" "$(cfg serverAutoSaveInterval)"

# A file written by hand or by the game is read back.
printf '// comment\nserverName Hand Made\nserverPlayers 3\nenableVAC on\nunknownKey 1\n' >"${cfgfile}"
check "a hand-written file is read" "Hand Made 3 True" "$(forest settings | python3 -c 'import json,sys;c=json.load(sys.stdin)["config"];print(c["serverName"],c["serverPlayers"],c["enableVAC"])')"
forest "${P[@]}" apply >/dev/null
check "and completed with the defaults" "off" "$(cfg allowCheats)"
check "keeping what it had" "Hand Made" "$(cfg serverName)"

# Saves.
mkslot() { # slot, hours (a stand-in save folder)
  mkdir -p "${slots}/Slot$1/Sub"
  printf 'save %s\n' "$2" >"${slots}/Slot$1/__RESUME__"
  printf 'x%s\n' "$2" >"${slots}/Slot$1/Sub/data.bin"
}
mkslot 1 30
mkslot 3 100
check "saves lists the five slots" "5" "$(forest saves | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["slots"]))')"
check "which exist" "1,3" "$(forest saves | python3 -c 'import json,sys;print(",".join(str(s["slot"]) for s in json.load(sys.stdin)["slots"] if s["exists"]))')"
check "with the file count" "2" "$(forest saves | jget slots.2.files)"
check "the active slot" "1" "$(forest saves | jget active)"
check "a slot out of range is refused" "1" "$(status forest use-slot 6)"
forest use-slot 3 >/dev/null
check "use-slot moves the config" "3" "$(cfg slot)"
forest "${P[@]}" apply >/dev/null
check "and an apply keeps it" "3" "$(cfg slot)"
check "the active slot cannot be deleted while up" "1" "$(echo '{"state":"running","slot":3}' >"${data}/flux/state.json"; status forest delete-slot 3)"
check "another can" "0" "$(status forest delete-slot 1)"
check "and is gone" "1" "$(status test -d "${slots}/Slot1")"
check "after a backup" "1" "$(grep -c 'before deleting slot 1' "${data}/flux/backups/index.json")"
rm -f "${data}/flux/state.json"

# A new world: the slot's world is backed up, then cleared, on the next apply.
forest new-world 3 Peaceful >/dev/null
check "new-world does nothing until the next start" "0" "$(status test -f "${slots}/Slot3/__RESUME__")"
forest "${P[@]}" apply >"${tmp}/apply.out"
check "the next start clears the slot" "1" "$(status test -e "${slots}/Slot3")"
check "after a backup" "1" "$(grep -c 'before a new world in slot 3' "${data}/flux/backups/index.json")"
check "with the difficulty asked for" "Peaceful" "$(cfg difficulty)"
check "and the file says Continue" "Continue" "$(cfg initType)"
check "an empty slot is announced" "1" "$(forest new-world 4 >/dev/null; forest "${P[@]}" apply | grep -c 'slot 4 is empty')"

# Every key of the file from the environment: FOREST_SETTINGS_JSON, FOREST_SAVE_SLOT, FOREST_AUTOSAVE_MINUTES.
forest "${P[@]}" FOREST_SAVE_SLOT=2 FOREST_AUTOSAVE_MINUTES=45 FOREST_SETTINGS_JSON='{"treeRegrowMode":true,"nope":1}' apply >"${tmp}/env.out"
check "env slot" "2" "$(cfg slot)"
check "env autosave minutes" "45" "$(cfg serverAutoSaveInterval)"
check "env settings JSON" "on" "$(cfg treeRegrowMode)"
check "an unknown key is skipped with a warning" "1" "$(grep -c 'nope is not a setting the game has; skipped' "${tmp}/env.out")"
forest set-settings '{"serverAutoSaveInterval": 90}' >/dev/null
forest "${P[@]}" FOREST_SAVE_SLOT=2 FOREST_AUTOSAVE_MINUTES=45 FOREST_SETTINGS_JSON='{"treeRegrowMode":true,"nope":1}' apply >/dev/null
check "an unchanged env does not undo the panel" "90" "$(cfg serverAutoSaveInterval)"
forest "${P[@]}" FOREST_SETTINGS_JSON='not json' apply >"${tmp}/env.out"
check "a broken FOREST_SETTINGS_JSON is a warning, not a stop" "1" "$(grep -c 'WARN FOREST_SETTINGS_JSON is not a JSON object' "${tmp}/env.out")"
check "a bad slot in the env is a warning" "1" "$(forest "${P[@]}" FOREST_SAVE_SLOT=9 apply | grep -c 'a slot is a number')"
forest set-settings '{"serverAutoSaveInterval": 15}' >/dev/null

# Import and export.
mkslot 5 12
forest export-save 5 "${tmp}/out/slot5.zip" >/dev/null
check "export makes a zip of the slot folder" "Slot5/Sub/data.bin Slot5/__RESUME__" "$(python3 -c 'import zipfile,sys;print(" ".join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))' "${tmp}/out/slot5.zip")"
cp "${tmp}/out/slot5.zip" "${tmp}/up.zip"
check "import into a slot with a world is refused" "1" "$(status forest import-save "${tmp}/up.zip" 5)"
check "a slot folder imports into an empty slot" "2" "$(forest import-save "${tmp}/up.zip" 4 | jget files)"
check "and is the same world" "save 12" "$(cat "${slots}/Slot4/__RESUME__")"
check "the upload is removed" "1" "$(status test -e "${tmp}/up.zip")"
# A client's whole path: <id>/Multiplayer/Slot1/... with a neighbouring slot that must be ignored.
python3 - "${tmp}/client.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("76561198000000001/Multiplayer/Slot1/__RESUME__", "mine")
    z.writestr("76561198000000001/SinglePlayer/Slot1/__RESUME__", "single")
PY
check "a client's folder tree imports its Multiplayer slot" "mine" "$(forest import-save "${tmp}/client.zip" 2 >/dev/null; cat "${slots}/Slot2/__RESUME__")"
python3 - "${tmp}/two.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("Slot1/a", "1")
    z.writestr("Slot2/a", "2")
PY
check "two slots in one archive are refused" "1" "$(status forest import-save "${tmp}/two.zip" 1)"
python3 -c 'import zipfile,sys
with zipfile.ZipFile(sys.argv[1],"w") as z: z.writestr("one/__RESUME__","x")' "${tmp}/top.zip"
check "an only top-level folder is the slot" "x" "$(forest import-save "${tmp}/top.zip" 1 >/dev/null; cat "${slots}/Slot1/__RESUME__")"
python3 -c 'import zipfile,sys
zipfile.ZipFile(sys.argv[1],"w").close()' "${tmp}/empty.zip"
check "an empty zip is refused" "1" "$(status forest import-save "${tmp}/empty.zip" 3)"
check "and leaves the slot empty" "1" "$(status test -e "${slots}/Slot3")"
python3 -c 'import zipfile,sys
with zipfile.ZipFile(sys.argv[1],"w") as z: z.writestr("../../evil/x","x")' "${tmp}/evil.zip"
check "a path out of the folder is refused" "1" "$(status forest import-save "${tmp}/evil.zip" 3)"
mkdir -p "${data}/flux/uploads" "${data}/flux/exports"
cp "${tmp}/evil.zip" "${data}/flux/uploads/failed.zip"
check "a failed import in the uploads folder removes the upload" "1" "$(status forest import-save "${data}/flux/uploads/failed.zip" 3 >/dev/null; status test -e "${data}/flux/uploads/failed.zip")"
echo '{"state": "running", "slot": 3}' >"${data}/flux/state.json"
cp "${tmp}/out/slot5.zip" "${tmp}/active.zip"
check "the slot the server plays is refused" "1" "$(status forest import-save "${tmp}/active.zip" 3)"
forest state running
touch -d '2 hours ago' "${data}/flux/uploads/old.zip" "${data}/flux/exports/old.zip"
touch "${data}/flux/uploads/new.zip" "${data}/flux/exports/new.zip"
forest export-save 5 "${data}/flux/exports/slot5.zip" >/dev/null
check "an hour-old upload and export are pruned" "1 1" "$(status test -e "${data}/flux/uploads/old.zip") $(status test -e "${data}/flux/exports/old.zip")"
check "a fresh one and the export being made are kept" "0 0 0" "$(status test -e "${data}/flux/uploads/new.zip") $(status test -e "${data}/flux/exports/new.zip") $(status test -e "${data}/flux/exports/slot5.zip")"

# State, status and restart.
forest state starting
check "starting moves the generation" "1" "$(forest status | jget generation)"
forest state running
check "running is running" "running" "$(forest status | jget state)"
check "no query answer means unknown players, not zero" "None" "$(forest status | jget playerCount)"
check "status has the build" "20228410" "$(forest status | jget build)"
check "restart leaves a marker" "True" "$(forest restart | jget restarting)"
check "the marker waits for the world to settle" "1" "$(grep -c '^notbefore=[1-9]' "${tmp}/restart-marker")"
rm -f "${tmp}/restart-marker"
forest state stopped
check "restart refuses a stopped server" "1" "$(status forest restart)"

# Backups and restore.
forest state running
rm -rf "${data}/flux/backups"
forest backup "test" force >/dev/null
check "a backup is made" "1" "$(forest backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))')"
check "a second within the hour is skipped" "1" "$(forest backup "again" >/dev/null; forest backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))')"
name="$(forest backups | jget backups.0.name)"
check "the backup lists its slots" "True" "$(forest backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"][0]["slots"]) > 0)')"
rm -rf "${slots}/Slot5"
check "restore of a running server asks for a restart" "True" "$(forest restore "${name}" | jget restarting)"
rm -f "${tmp}/restart-marker"
sleep 1
forest do-restore >/dev/null
check "do-restore brings the slot back" "0" "$(status test -f "${slots}/Slot5/__RESUME__")"
check "after a safety backup" "1" "$(grep -c 'before restoring' "${data}/flux/backups/index.json")"
check "restore refuses a name that is not a backup" "1" "$(status forest restore ../../etc/passwd)"

# Passwords and the env (1.0.1).
forest "${P[@]}" FOREST_PASSWORD=pw1 FOREST_ADMIN_PASSWORD=adm1 apply >/dev/null
check "a password is set from the env" "pw1 adm1" "$(cfg serverPassword) $(cfg serverPasswordAdmin)"
forest "${P[@]}" FOREST_PASSWORD= FOREST_ADMIN_PASSWORD= apply >"${tmp}/apply.out"
check "emptying the env removes the join password" "" "$(cfg serverPassword | tr -d ' ')"
check "and the admin password" "" "$(cfg serverPasswordAdmin | tr -d ' ')"
check "without printing it" "0" "$(grep -c -E 'pw1|adm1' "${tmp}/apply.out")"
forest "${P[@]}" FOREST_PASSWORD= apply >/dev/null
check "a blank that was never set changes nothing" "" "$(cfg serverPassword | tr -d ' ')"
forest "${P[@]}" FOREST_SERVER_NAME="Deploy Name" apply >/dev/null
forest set-settings '{"serverName": "Panel Name"}' >/dev/null
forest "${P[@]}" FOREST_SERVER_NAME="Deploy Name" apply >/dev/null
check "a value saved in the panel survives the same env" "Panel Name" "$(cfg serverName)"
forest "${P[@]}" FOREST_SERVER_NAME="Renamed" apply >/dev/null
check "and a changed env still wins" "Renamed" "$(cfg serverName)"

# A panel save before the first start is not undone by the deploy's env.
rm -rf "${tmp}/fresh"
fresh() { local vars=(); while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" HOME="${tmp}" FLUX_DATA_DIR="${tmp}/fresh" FLUX_SERVER_DIR="${server}" FLUX_RESTART_MARKER="${tmp}/restart-marker" "${vars[@]}" python3 scripts/fluxforest.py "$@"; }
fresh FOREST_MAX_PLAYERS=6 set-settings '{"serverPlayers": 20}' >/dev/null
fresh "${P[@]}" FOREST_MAX_PLAYERS=6 apply >/dev/null
check "a Max Players saved before the first start is kept" "20" "$(sed -n 's/^serverPlayers //p' "${tmp}/fresh/config.cfg")"

# A restore puts the deployment's passwords back, whatever the older backup held.
forest "${P[@]}" FOREST_PASSWORD=old apply >/dev/null
forest state running
rm -rf "${data}/flux/backups"
forest backup "pw test" force >/dev/null
bname="$(forest backups | jget backups.0.name)"
forest "${P[@]}" FOREST_PASSWORD=current apply >/dev/null
forest restore "${bname}" >/dev/null
forest "${P[@]}" FOREST_PASSWORD=current do-restore >/dev/null
check "restoring an older backup keeps the current join password" "current" "$(cfg serverPassword | tr -d ' ')"

# Safety copies have a ceiling.
rm -rf "${data}/flux/backups"
for i in 1 2 3 4; do FLUX_BACKUP_KEEP_SAFETY=2 forest FLUX_BACKUP_KEEP_SAFETY=2 backup "before test ${i}" force >/dev/null; done
check "only the newest safety copies are kept" "2" "$(forest backups | python3 -c 'import json,sys;print(len([b for b in json.load(sys.stdin)["backups"] if b["keep"]]))')"

# Review round 2 of 1.0.1.
forest "${P[@]}" FOREST_PASSWORD= apply >/dev/null
forest set-settings '{"serverPassword": "panelpw"}' >/dev/null
rm -rf "${data}/flux/backups"
forest state running
forest backup "pw panel" force >/dev/null
pname="$(forest backups | jget backups.0.name)"
forest restore "${pname}" >/dev/null
forest "${P[@]}" FOREST_PASSWORD= do-restore >/dev/null
check "a restore with a blank env keeps a password set in the panel" "panelpw" "$(cfg serverPassword | tr -d ' ')"
forest "${P[@]}" FOREST_PASSWORD=abc apply >/dev/null
forest "${P[@]}" FOREST_PASSWORD= set-settings '{"serverPassword": "saved"}' >/dev/null
forest "${P[@]}" FOREST_PASSWORD= apply >/dev/null
check "a password saved while the env was emptied is not removed at the next start" "saved" "$(cfg serverPassword | tr -d ' ')"
rm -rf "${data}/flux/backups"
forest backup "regular" force >/dev/null
for i in 1 2 3; do forest FLUX_BACKUP_KEEP_SAFETY=2 backup "before safe ${i}" force >/dev/null; done
check "the safety cap drops the oldest, not the newest" "before safe 2,before safe 3" "$(forest backups | python3 -c 'import json,sys;print(",".join(sorted(b["why"] for b in json.load(sys.stdin)["backups"] if b["keep"])))')"
check "a regular backup is not touched by the safety cap" "1" "$(forest backups | python3 -c 'import json,sys;print(len([b for b in json.load(sys.stdin)["backups"] if not b["keep"]]))')"
check "a bad cap is the default, not a crash" "0" "$(status forest FLUX_BACKUP_KEEP_SAFETY=abc backup "before bad" force)"
check "and a cap of 0 is 1, so the newest safety copy survives" "1" "$(forest FLUX_BACKUP_KEEP_SAFETY=0 backup "before zero" force >/dev/null; forest backups | python3 -c 'import json,sys;print(len([b for b in json.load(sys.stdin)["backups"] if b["keep"] and b["why"]=="before zero"]))')"
printf 'requested: test\nnotbefore=0\n' >"${tmp}/restart-marker"
forest clear-stale-restart
check "a stale restart request is dropped right before the game starts" "1" "$(status test -e "${tmp}/restart-marker")"
printf 'requested: test\nnotbefore=0\n' >"${tmp}/restart-marker"
forest state running
forest restore "$(forest backups | jget backups.0.name)" >/dev/null
printf 'requested: test\nnotbefore=0\n' >"${tmp}/restart-marker"
forest clear-stale-restart
check "but not when a restore is waiting for it" "0" "$(status test -e "${tmp}/restart-marker")"
forest do-restore >/dev/null

# Update bookkeeping.
forest update-target 20300000
forest update-check >/dev/null
check "a target not reached is remembered" "0" "$(status forest update-skip 20300000)"
check "another build is not skipped" "1" "$(status forest update-skip 20400000)"

# A2S parsing (replies as the server sends them).
check "A2S_INFO parses" "Forest|0|8|True" "$(python3 -c '
import sys; sys.path.insert(0, "scripts"); import fluxforest
body = b"\x49\x11" + b"Forest\x00map\x00theforestDS\x00The Forest\x00" + b"\x00\x00" + bytes([0, 8, 0]) + b"dw\x01\x00" + b"1.0\x00"
d = fluxforest.parse_info(body); print("%s|%d|%d|%s" % (d["name"], d["players"], d["maxPlayers"], d["password"]))')"
check "A2S_PLAYER parses" "Ana:120" "$(python3 -c '
import sys, struct; sys.path.insert(0, "scripts"); import fluxforest
body = b"\x44\x01" + b"\x00Ana\x00" + struct.pack("<lf", 0, 120.5)
print(",".join("%s:%d" % (p["name"], p["seconds"]) for p in fluxforest.parse_players(body)))')"

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
