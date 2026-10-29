#!/bin/bash
# PID 1, and the supervisor of The Forest server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first, and a server that ends on its
# own is followed by the next one in place:
#
#   - every start: SteamCMD update (the Windows build, anonymous), a backup of the saves, then
#     config.cfg from the environment and the panel (fluxforest.py apply), then the server under
#     Wine on a virtual display (the Unity player refuses to start without one, measured)
#   - THE GAME HAS NO SAVE ON QUIT AND NO CONSOLE (measured in its code, build 3488796): it saves
#     every serverAutoSaveInterval minutes (15 at the least) while players are on, and ONCE when the
#     last player leaves. So a stop is immediate (SIGINT, the process is gone in well under a
#     second) and every PLANNED restart waits for an empty server, which is exactly when the game has
#     just saved. A stop from Docker with players on loses what happened since the last autosave.
#   - a new build on Steam: an outdated server refuses players on the new client, so it is
#     restarted onto it, as soon as nobody is playing or after FLUX_UPDATE_WAIT_MINUTES
#   - FOREST_RESTART_TIME: a daily restart at that time (in TZ, UTC when unset), on an empty server
#     if one comes within FLUX_RESTART_WAIT_MINUTES
#   - the server ending on its own: a new generation in the same container; FLUX_RESTART_MAX_ATTEMPTS
#     unplanned ones inside FLUX_RESTART_WINDOW seconds end the container with 42
#   - a backup of the saves on start (unless one is under an hour old) and every FLUX_BACKUP_HOURS,
#     kept on the data volume (flux/backups), and a backup restored when the panel asked for one
#   - the panel's restart (flux-forest restart) is a marker: the supervisor stops the server for it
#
# Same shape as runonflux/sotf-server-flux and runonflux/vrising-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. The game has nothing to save on
# the way out (it does not save on quit), so there is nothing to wait for but a clean disconnect of
# the players: SIGINT is answered within a second or two when the server was just started and in
# well under 10 s otherwise (measured: one run took longer than 8 s), and Docker's own deadline on
# Flux is ten seconds. FLUX_STOP_GRACE (4 s) is then a kill, which loses nothing the game would not
# have lost anyway.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-4}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
export FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-60}"
# The line the game prints once the world is loaded and players can join ("Game autosave started":
# AutoSaveMode starts its timer when Scene.FinishGameLoad is set).
FLUX_READY_LINE="${FLUX_READY_LINE:-Game autosave started}"

s="${FLUX_SERVER_DIR}"
forest() { python3 /opt/flux/fluxforest.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${FLUX_SAVES}" "${FLUX_STATE_DIR}" "${FLUX_GAME_LOG_DIR}"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_STATE_DIR}/flux.log"
flux_banner "The Forest"

if ! restart_at="$(flux_restart_time "${FOREST_RESTART_TIME:-}")"; then
  flux_log "WARN FOREST_RESTART_TIME='${FOREST_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, wine ${FLUX_WINE_VERSION:-unknown})"

game_pid=""
tail_pid=""
watch_pid=""
backup_pid=""
cap_pid=""
terminating=0
generation=0
restart_history=()
xvfb_pid=""

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: shutting down, no restart will follow$(players_note)"
  stop_game
}
trap term_handler TERM INT

# What a stop costs, for the log: the game saves only on its interval and when the last player
# leaves, so with players on the world is as old as the last autosave.
players_note() {
  local n
  n="$(forest players 2>/dev/null)"
  if [ -n "${n}" ] && [ "${n}" != "0" ]; then
    printf ' (%s player(s) online: the world is as of the last autosave)' "${n}"
  fi
}

# SIGINT to the game (a Ctrl+C under Wine): the process is gone in well under a second.
stop_game() {
  local pid
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] && kill -INT "${pid}" 2>/dev/null
}

# The virtual display. One for the container's life; started again if it died.
ensure_display() {
  if [ -n "${xvfb_pid}" ] && kill -0 "${xvfb_pid}" 2>/dev/null; then
    return 0
  fi
  rm -f "/tmp/.X${FLUX_DISPLAY#:}-lock"
  Xvfb "${FLUX_DISPLAY}" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
  xvfb_pid=$!
  sleep 1
  kill -0 "${xvfb_pid}" 2>/dev/null
}

# The Wine prefix, on the install volume (local to the node, made again on a new one).
ensure_prefix() {
  [ -d "${WINEPREFIX}/drive_c" ] && return 0
  flux_log "creating the Wine prefix (once per node)"
  mkdir -p "${WINEPREFIX}"
  DISPLAY="${FLUX_DISPLAY}" wineboot --init >/dev/null 2>&1
  wineserver -w 2>/dev/null
  [ -d "${WINEPREFIX}/drive_c" ]
}

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  forest state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, Windows build)"
  # No `validate` on the first attempt: it re-hashes the whole 3.4 GB install on every start. An
  # install that is actually broken fails the first attempt, and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # app_info_update + a second app_update: SteamCMD answers "Missing configuration" to a first
    # app_update of this app on a fresh SteamCMD (measured 2026-10-18), and stops there.
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "${s}" +login anonymous \
      +app_info_update 1 +app_update "${FLUX_STEAM_APP}" +app_update "${FLUX_STEAM_APP}" ${validate} +quit \
      >/tmp/steamcmd.log 2>&1 &
    wait $!
    # "fully installed" after a download, "already up to date" otherwise.
    if [ -f "${s}/${FLUX_GAME_EXE}" ] && grep -qE "fully installed|already up to date" /tmp/steamcmd.log; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -aE 'ERROR|Error|error' /tmp/steamcmd.log | tail -2 | tr '\n' ' ')retrying in 5s with validate"
    sleep 5 &
    wait $!
  done
  if [ -f "${s}/${FLUX_GAME_EXE}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# A backup (fluxforest.py backup: what goes in, what is skipped and what is kept). $2 = force.
backup_world() {
  local line
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(forest backup "$1" ${2:+"$2"} 2>&1)
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    backup_world "every ${FLUX_BACKUP_HOURS}h"
  done
}

request_restart() {
  [ -f "${FLUX_RESTART_MARKER}" ] && return 0
  printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
  flux_log "$1: restarting the server"
}

# shellcheck disable=SC2329  # run in the background below
# The current game log, capped at FLUX_GAME_LOG_MAX_BYTES: its last 5 MB go to a rotated file and
# the live one is emptied in place (the game keeps writing it).
log_capper() {
  local current size
  current="$(flux_game_log)"
  while true; do
    sleep 60
    size="$(stat -c %s "${current}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt "${FLUX_GAME_LOG_MAX_BYTES}" ] 2>/dev/null; then
      tail -c 5242880 "${current}" >"${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log" 2>/dev/null
      : >"${current}"
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
      flux_log "the game log reached $((size / 1048576)) MB: rotated"
    fi
  done
}

# Waits for an empty server for up to $1 minutes, checking every minute.
wait_for_empty() {
  local until=$(($(date -u +%s) + $1 * 60)) n
  while [ "$(date -u +%s)" -lt "${until}" ]; do
    n="$(forest players 2>/dev/null)"
    [ "${n}" = "0" ] && return 0
    sleep 60
  done
  return 0
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once the world is up, then follows Steam for a newer build and keeps
# the daily restart.
watcher() {
  local line build public last_check now next_restart=""
  last_check="$(date -u +%s)"
  while IFS= read -r line; do
    if [[ "${line}" == *"${FLUX_READY_LINE}"* ]]; then
      forest state running
      flux_log "the server is up (generation ${generation})"
      break
    fi
  done < <(tail -n +1 -F "$(flux_game_log)" 2>/dev/null)
  if [ -n "${restart_at}" ]; then
    next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
    forest note nextRestart "${next_restart}"
  else
    forest note nextRestart
  fi
  forest note updateWaiting
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      public="$(steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! forest update-skip "${public}"; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it when the server is empty, at most ${FLUX_UPDATE_WAIT_MINUTES} min from now"
        forest note updateWaiting "${public}"
        wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}"
        forest update-target "${public}"
        request_restart "planned: game update ${build} -> ${public}"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      flux_log "daily restart (${restart_at} ${TZ:-UTC}): waiting up to ${FLUX_RESTART_WAIT_MINUTES} min for an empty server"
      wait_for_empty "${FLUX_RESTART_WAIT_MINUTES}"
      request_restart "planned: the daily restart (${restart_at} ${TZ:-UTC})"
      exit 0
    fi
  done
}

# shellcheck disable=SC2329  # run in the background below
# The game's console onto the container's output, without the lines Unity prints for a GPU the
# server does not have (the full output stays in the game log).
log_follower() {
  local line
  while IFS= read -r line; do
    flux_noise <<<"${line}" || printf '%s\n' "${line}"
  done < <(tail -n 0 -F "$1" 2>/dev/null)
}

start_generation() {
  local line current
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"
  # A state left by the container that was here before (a kill, a node reboot) is stale from now on.
  forest state updating "Preparing the server"

  update_server || return 1
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(forest update-check 2>&1)
  [ "${terminating}" = "1" ] && return 2
  # A restore the panel asked for, before anything reads the server's files.
  while IFS= read -r line; do flux_log "restore: ${line#\# }"; done < <(forest do-restore 2>&1)
  backup_world "start"

  local applied
  if applied="$(forest apply 2>/tmp/flux-apply.err)"; then
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
  else
    while IFS= read -r line; do [ -n "${line}" ] && flux_log "config: ${line#\# }"; done <<<"${applied}"
    printf '%s\n' "${applied}" >/tmp/flux-apply.out
    flux_log "ERROR the settings could not be applied: $(grep -h ERROR <<<"${applied}" | tr '\n' ' ')$(tail -3 /tmp/flux-apply.err | tr '\n' ' ')"
    return 3
  fi

  if ! ensure_display; then
    flux_log "ERROR the virtual display (Xvfb) did not start"
    return 1
  fi
  if ! ensure_prefix; then
    flux_log "ERROR the Wine prefix could not be created"
    return 1
  fi

  current="$(flux_game_log)"
  if [ -s "${current}" ]; then
    mv "${current}" "${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log"
  fi
  : >"${current}"
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  forest state starting "Loading the world"
  flux_banner "The Forest"
  flux_log "starting the server (generation ${generation})"

  log_follower "${current}" &
  tail_pid=$!

  (
    cd "${s}" || exit 1
    export DISPLAY="${FLUX_DISPLAY}" SteamAppId="${FLUX_GAME_APP_ID}" SteamGameId="${FLUX_GAME_APP_ID}"
        # -batchmode -nographics: no window, no GPU. The config file is ours (written by `apply`) and the
    # saves go to the data volume. stdin closed: the server has no console.
    exec wine "${s}/${FLUX_GAME_EXE}" -batchmode -nographics \
      -configfilepath "$(flux_wine_path "${FLUX_CONFIG}")" \
      -savefolderpath "$(flux_wine_path "${FLUX_SAVES}")\\" </dev/null >>"${current}" 2>&1
  ) &
  game_pid=$!

  watcher &
  watch_pid=$!
  backupper &
  backup_pid=$!
  log_capper &
  cap_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${tail_pid}" "${watch_pid}" "${backup_pid}" "${cap_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  tail_pid="" watch_pid="" backup_pid="" cap_pid=""
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
  # Whatever Wine left behind for this generation (services.exe, explorer.exe, the crash handler).
  wineserver -k 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A stop or restart asked for is SIGINT (stop_game); the game gets
# FLUX_STOP_GRACE seconds, then it is killed.
wait_for_generation() {
  local asked_at=0 now signalled=0
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 0.5 &
    wait $!
    if [ "${signalled}" = "0" ] && [ "${terminating}" = "0" ] && [ -f "${FLUX_RESTART_MARKER}" ] \
      && [ "$(date -u +%s)" -ge "$(flux_marker_not_before "${FLUX_RESTART_MARKER}")" ]; then
      signalled=1
      stop_game
    fi
    if [ "${terminating}" = "1" ] || [ "${signalled}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        pkill -KILL -f "${FLUX_GAME_PATTERN}" 2>/dev/null
        break
      fi
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

# The environment holds a port the server cannot use: restarting cannot fix it and exiting would
# only make the platform restart the same container, so the state says what to change and the
# container waits (no restart budget used) for a stop or the panel's restart.
wait_for_fix() {
  local why
  why="$(grep -ah 'ERROR' /tmp/flux-apply.out 2>/dev/null | head -1 | sed 's/^# ERROR //')"
  forest state needs-fix "${why:-The settings in the environment cannot be used}. Change it in the app's deployment settings; the server starts after a redeploy."
  flux_log "not restarting: ${why}. Waiting for a redeploy."
  while [ "${terminating}" = "0" ] && [ ! -f "${FLUX_RESTART_MARKER}" ]; do
    sleep 2 &
    wait $!
  done
  rm -f "${FLUX_RESTART_MARKER}"
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    forest state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "3" ]; then
    wait_for_fix
    continue
  fi
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    forest state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    forest state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(head -1 "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    forest state stopped
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      forest state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  forest state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
