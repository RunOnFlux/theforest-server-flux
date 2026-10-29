#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t
# and scripts/ at /s.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 Xvfb wine wineboot wineserver pgrep pkill tail tar; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "wine is the pinned build" "0" "$(status bash -c 'wine --version | grep -q "wine-10.0"')"
check "flux-forest is on the PATH" "0" "$(status command -v flux-forest)"
check "flux-forest starts (usage)" "64" "$(status flux-forest)"
for script in flux-entrypoint.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cd repo && ./tests/test-flux.sh')"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" the exe; wine runs a stand-in that behaves like the server where it matters:
# it reads config.cfg, needs a display, prints the ready line, answers A2S on the query port with
# a player count it takes from a file, leaves within a second of SIGINT and SAVES NOTHING on quit
# (the real game saves on its interval and when the last player leaves).
mkdir -p /usr/local/bin /opt/standin
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/steamapps"
: >"${dir}/TheForestDedicatedServer.exe"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_556450.acf"
if [ -f /tmp/.installed ]; then echo "Success! App '556450' already up to date."; else touch /tmp/.installed; echo "Success! App '556450' fully installed."; fi
STUB
cat >/opt/standin/TheForestDedicatedServer.exe <<'GAME'
#!/usr/bin/env python3
# Named like the server so the supervisor finds it by `TheForestDedicatedServer.exe -batchmode`.
# Python, not bash: a job started with & from a script has SIGINT ignored, and bash cannot trap a
# signal ignored on entry. Wine sets its own handler, as this does (signal.signal resets it).
import os, signal, socket, struct, sys, time
args = sys.argv[1:]
cfgpath = args[args.index("-configfilepath") + 1].replace("Z:", "", 1).replace("\\", "/")
savepath = args[args.index("-savefolderpath") + 1].replace("Z:", "", 1).replace("\\", "/")
cfg = dict(line.split(" ", 1) for line in open(cfgpath).read().splitlines() if line and not line.startswith("//"))
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
print("WARNING: Shader Unsupported: 'Hidden/Noise' - All subshaders removed", flush=True)
print("NullReferenceException: Object reference not set to an instance of an object", flush=True)
print("  at UICamera.Update () [0x00000] in <filename unknown>:0 ", flush=True)
print("RenderTexture.Create failed: format unsupported - 2.", flush=True)
if not os.environ.get("DISPLAY") or os.environ.get("SteamAppId") != "242760" or "-batchmode" not in args:
    print("Failed to create batch mode window", flush=True)
    sys.exit(1)
os.makedirs(os.path.join(savepath, "Multiplayer"), exist_ok=True)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", int(cfg["serverQueryPort"])))
sock.settimeout(0.2)
print("Dedicated server info:", cfg["serverName"], flush=True)
print("Game autosave started", flush=True)
def cstr(x): return x.encode() + b"\0"
while True:
    try:
        data, addr = sock.recvfrom(1024)
        n = int(open("/tmp/standin-players").read()) if os.path.exists("/tmp/standin-players") else 0
        if data[4:5] == b"T":
            body = b"\x49\x11" + cstr(cfg["serverName"]) + cstr("Normal") + cstr("theforestDS") + cstr("The Forest") + b"\0\0" + bytes([n, int(cfg["serverPlayers"]), 0]) + b"dw\0\0" + cstr("0.11.3.0.0")
        else:
            body = b"\x44" + bytes([n]) + b"".join(b"\0" + cstr("P%d" % i) + struct.pack("<lf", 0, 5.0) for i in range(n))
        sock.sendto(b"\xff\xff\xff\xff" + body, addr)
    except socket.timeout:
        pass
GAME
chmod +x /usr/local/bin/steamcmd /opt/standin/TheForestDedicatedServer.exe
cat >/usr/local/bin/wine <<'STUB'
#!/bin/bash
shift
exec /opt/standin/TheForestDedicatedServer.exe "$@"
STUB
chmod +x /usr/local/bin/wine
export PATH="/usr/local/bin:${PATH}"
mkdir -p "${WINEPREFIX}/drive_c"

data=/mnt/theforest/data
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 FOREST_SERVER_NAME="Image Test" FOREST_MAX_PLAYERS=4 \
  FOREST_STEAM_PORT=31000 FOREST_GAME_PORT=31001 FOREST_QUERY_PORT=31002 FLUX_RESTART_WAIT_MINUTES=1
cfg() { sed -n "s/^$1 //p" "${data}/config.cfg"; }
state() { python3 -c 'import json;print(json.load(open("'"${data}"'/flux/state.json"))["'"$1"'"])'; }
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 30)"
check "on the virtual display" "0" "$(status pgrep -x Xvfb)"
check "the config has the name" "Image Test" "$(cfg serverName)"
check "and the ports" "31002" "$(cfg serverQueryPort)"
check "and the saves on the data volume" "0" "$(status test -d ${data}/saves/Multiplayer)"
check "shader and stack noise stays out of the container log" "0" "$(grep -c -E 'Shader Unsupported|NullReferenceException|UICamera|RenderTexture' /tmp/entry.log)"
check "but the game's lines reach it" "1" "$(grep -c 'Dedicated server info' /tmp/entry.log)"
check "the game log is on the install volume" "0" "$(status test -s /mnt/theforest/server/flux-logs/current.log)"
check "the whole output is in the game log" "1" "$(grep -c 'NullReferenceException' /mnt/theforest/server/flux-logs/current.log)"
check "status answers from A2S" "0 4" "$(flux-forest status | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["playerCount"],d["maxPlayers"])')"
echo 2 >/tmp/standin-players
check "players are counted" "2" "$(flux-forest players)"
check "and listed by name" "P0,P1" "$(flux-forest status | python3 -c 'import json,sys;print(",".join(p["name"] for p in json.load(sys.stdin)["players"]))')"

# A restore through the panel's command.
mkdir -p ${data}/saves/Multiplayer/Slot1
echo mine >${data}/saves/Multiplayer/Slot1/__RESUME__
flux-forest backup "test" force >/dev/null
backup="$(flux-forest backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
rm -rf "${data}/saves/Multiplayer/Slot1"
check "restore restarts the running server" "True" "$(flux-forest restore "${backup}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["restarting"])')"
check "and the second start has slot 1 back" "0" "$(status wait_for '[ "$(flux-forest status | python3 -c "import json,sys;print(json.load(sys.stdin)[\"generation\"])")" = 2 ] && test -f ${data}/saves/Multiplayer/Slot1/__RESUME__' 30)"
check "the restart was not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "an up-to-date install is not retried" "0" "$(grep -c 'steamcmd failed' /tmp/entry.log)"

# A panel restart with a new world: the slot is emptied at the start, in the new slot.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
mkdir -p ${data}/saves/Multiplayer/Slot2 && echo old >${data}/saves/Multiplayer/Slot2/__RESUME__
flux-forest new-world 2 Hard >/dev/null
flux-forest restart >/dev/null
check "a panel restart starts the third generation on slot 2" "0" "$(status wait_for '[ "$(flux-forest status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"],d[\"slot\"])")" = "running 3 2" ]' 30)"
check "with its old world gone" "1" "$(status test -e ${data}/saves/Multiplayer/Slot2/__RESUME__)"
check "and the difficulty in the config" "Hard" "$(cfg difficulty)"

# The daily restart / update restarts wait for an empty server.
echo 1 >/tmp/standin-players
check "wait_for_empty keeps waiting while someone plays" "1" "$(bash -c 'source /opt/flux/flux-lib.sh; n=$(python3 /opt/flux/fluxforest.py players); [ "$n" = "0" ]; echo $?')"
echo 0 >/tmp/standin-players
check "and stops waiting on an empty server" "0" "$(python3 /opt/flux/fluxforest.py players)"

# A crash: restarted in place.
wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
pkill -KILL -f '[T]heForestDedicatedServer\.exe -batchmode'
check "a crashed server is started again" "0" "$(status wait_for '[ "$(flux-forest status | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[\"state\"],d[\"generation\"])")" = "running 4" ]' 30)"

wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 20
start="$(date +%s)"
kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "inside Docker's 10 seconds" "0" "$(status test $(($(date +%s) - start)) -le 5)"
check "and says stopped" "stopped" "$(state state)"

# A port the server cannot use is not a crash: the state says what to change and nothing restarts.
FOREST_GAME_PORT=80 /opt/flux/flux-entrypoint.sh >/tmp/entry2.log 2>&1 &
entry2=$!
check "a bad port gives the needs-fix state" "0" "$(status wait_for 'grep -q "needs-fix" ${data}/flux/state.json 2>/dev/null' 20)"
check "that names the variable" "1" "$(grep -c 'FOREST_GAME_PORT=80' ${data}/flux/state.json)"
check "and keeps the supervisor alive" "0" "$(status kill -0 ${entry2})"
kill -TERM "${entry2}"
check "a stop ends it" "0" "$(status wait_for '! kill -0 ${entry2} 2>/dev/null' 10)"

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/mnt/theforest/server
fl_data=/mnt/theforest/data
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "${fl_data}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'The Forest server image by FluxCloud - https://runonflux.com' /tmp/entry.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/entry.log)" -ge 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
