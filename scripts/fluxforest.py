#!/usr/bin/env python3
"""Every decision about The Forest server's files, and the hub's commands.

    fluxforest.py apply                write config.cfg from the environment and the panel, carry out a
                                       pending new world; "# " notes on stdout (the entrypoint logs them)
    fluxforest.py state <state> [msg]  record what the supervisor is doing (flux/state.json)

    flux-forest status                 state, players (A2S), the save slot, build (one JSON document)
    flux-forest settings               config.cfg as the panel edits it, with the defaults and the rules
    flux-forest set-settings '<json>'  {"serverName": "...", "difficulty": "Hard", "veganMode": true, ...}
                                       validated key by key; written at once, read on the next start
    flux-forest saves                  the save slots 1 to 5: which exist, size, age
    flux-forest use-slot <n>           play slot n from the next start (a new world is made if it is empty)
    flux-forest new-world <n> [diff]   a NEW world in slot n on the next start (whatever is in that slot
                                       is backed up first, then cleared)
    flux-forest delete-slot <n>        delete a slot that is not the one being played
    flux-forest import-save <zip> <n>  a save brought from elsewhere (a co-op host's slot folder, zipped)
                                       into an EMPTY slot n
    flux-forest export-save <n> <out>  slot n as one .zip (what import-save takes back)
    flux-forest restart                stop and start the server again (applies the above)
    flux-forest backups                the backups in flux/backups (name, size, date, why, slots)
    flux-forest restore <backup>       restore one on the next start (the server is restarted now),
                                       after a safety backup of what is there

    fluxforest.py backup <why> [force] make a backup (the supervisor); skipped when the newest is
                                       younger than FLUX_BACKUP_MIN_AGE_MINUTES unless forced
    fluxforest.py do-restore           apply a pending restore (the supervisor, before a start)
    fluxforest.py note <key> [value]   a field of flux/state.json (nextRestart, updateWaiting)
    fluxforest.py update-target <b>    remember the build a planned update restart is for
    fluxforest.py update-check         after the update step: a target not reached is remembered
    fluxforest.py update-skip <b>      exit 0 when that build failed less than 6 hours ago
    fluxforest.py players              the A2S player count, or nothing when the server is silent

THE GAME (Steam app 556450, build 3488796) reads config.cfg once, as it starts ("key value" lines,
the keys of the file it writes for itself: serverIP, serverSteamPort, ...), and its saves go to
<saveFolderPath>/Multiplayer/Slot<n>/ (SaveSlotUtils.GetUserPath, read off the game's code). It has
no console and no RCON; its admin commands (/kick, /ban, /save, /restart, /shutdown) are typed in the
in-game chat by a player who logged in with the admin password. It saves every serverAutoSaveInterval
minutes (15 at the least) while players are on, and once when the last player leaves; it does NOT
save when it quits. So the panel can write the file and restart the server, nothing more.

ENVIRONMENT APPLIES WHEN IT CHANGES. A deploy's FOREST_* value is written into the file on the first
start, and again whenever it is DIFFERENT from the value last applied (flux/env-applied.json): a
redeploy with a new name renames the server, while a name changed in the panel afterwards is not
undone by the same old env on every restart. The ports are the exception: they are written on every
start, because the server must bind exactly the ports Flux publishes.
"""

import json
import os
import re
import shutil
import socket
import struct
import sys
import tarfile
import tempfile
import time
import zipfile

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/theforest/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/theforest/data")
SAVES = os.environ.get("FLUX_SAVES", os.path.join(DATA_DIR, "saves"))
CONFIG_FILE = os.environ.get("FLUX_CONFIG", os.path.join(DATA_DIR, "config.cfg"))
MODE_DIR = os.path.join(SAVES, "Multiplayer")
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
ENV_APPLIED_FILE = os.path.join(STATE_DIR, "env-applied.json")
NEW_WORLD_FILE = os.path.join(STATE_DIR, "new-world.json")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
RESTORE_FILE = os.path.join(STATE_DIR, "restore-pending.json")
UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "update-target.json")
UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "update-failed.json")
UPDATE_FAILED_SKIP = 6 * 3600
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
STEAM_APP = os.environ.get("FLUX_STEAM_APP", "556450")
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}-forest\.tar\.gz$")
# A save archive bigger than this, once unpacked, is refused (a real one is tens of MB).
IMPORT_MAX_BYTES = int(os.environ.get("FLUX_IMPORT_MAX_BYTES", str(512 * 1024 * 1024)))

# The game has five slots, folders named Slot1 .. Slot5.
SLOTS = (1, 2, 3, 4, 5)
SLOT_RE = re.compile(r"^Slot([1-5])$")
# After "Game autosave started" a stop is worth asking for straight away: there is nothing to wait
# for, the game does not save on quit. Only a few seconds so the process is past its start-up.
SETTLE_SECONDS = 5

DIFFICULTIES = ["Peaceful", "Normal", "Hard"]

# What the game writes into the config it makes for itself (Server.cfg template, in its order),
# with the values this image starts from.
CONFIG_DEFAULTS = {
    "serverIP": "0.0.0.0",
    "serverSteamPort": 8766,
    "serverGamePort": 27015,
    "serverQueryPort": 27016,
    "serverName": "The Forest on Flux",
    "serverPlayers": 8,
    "enableVAC": False,
    "serverPassword": "",
    "serverPasswordAdmin": "",
    "serverSteamAccount": "",
    "serverAutoSaveInterval": 15,
    "difficulty": "Normal",
    "initType": "Continue",
    "slot": 1,
    "showLogs": True,
    "serverContact": "",
    "veganMode": False,
    "vegetarianMode": False,
    "resetHolesMode": False,
    "treeRegrowMode": False,
    "allowBuildingDestruction": True,
    "allowEnemiesCreativeMode": False,
    "allowCheats": False,
    "realisticPlayerDamage": False,
    "saveFolderPath": "",
    "targetFpsIdle": 5,
    "targetFpsActive": 60,
}
BOOL_KEYS = {k for k, v in CONFIG_DEFAULTS.items() if isinstance(v, bool)}

# What the panel may change, and how each value is checked. ("text", max length), ("int", (lo, hi)),
# ("bool", None), ("choice", [...]). The hidden ones are the image's: ports, folder, slot, init type.
RULES = {
    "serverName": ("text", 60),
    "serverPlayers": ("int", (2, 100)),
    "enableVAC": ("bool", None),
    "serverPassword": ("text", 40),
    "serverPasswordAdmin": ("text", 40),
    "serverAutoSaveInterval": ("int", (15, 120)),
    "difficulty": ("choice", DIFFICULTIES),
    "serverContact": ("text", 80),
    "veganMode": ("bool", None),
    "vegetarianMode": ("bool", None),
    "resetHolesMode": ("bool", None),
    "treeRegrowMode": ("bool", None),
    "allowBuildingDestruction": ("bool", None),
    "allowEnemiesCreativeMode": ("bool", None),
    "allowCheats": ("bool", None),
    "realisticPlayerDamage": ("bool", None),
    "targetFpsIdle": ("int", (1, 60)),
    "targetFpsActive": ("int", (10, 144)),
}
# Chosen by the deployment, not the panel.
MANAGED = ("serverIP", "serverSteamPort", "serverGamePort", "serverQueryPort", "saveFolderPath",
           "initType", "slot", "serverSteamAccount", "showLogs")


# ------------------------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, indent=2):
    """Written beside and renamed, so a cut-off write never leaves half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.chmod(tmp, 0o666)
    os.replace(tmp, path)


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def env_int(name, default, minimum):
    """An integer setting from the environment: a bad value is the default, a small one the minimum
    (a 0 or a word must not make a backup delete itself or a restore fail)."""
    try:
        return max(minimum, int(str(os.environ.get(name, "")).strip() or default))
    except ValueError:
        return default


def env_set(name):
    """A variable counts only with a value: the marketplace writes every declared parameter, the
    ones left blank as NAME=, and a blank one must not wipe what the panel set."""
    return str(os.environ.get(name, "")).strip() != ""


def clean_text(value, limit):
    """One line of printable text."""
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(value)).strip()[:limit]


# ------------------------------------------------------------------------------------------------
# Values
# ------------------------------------------------------------------------------------------------

def coerce(rule, value):
    """(value, None) in the type the file holds, or (None, why)."""
    kind, arg = rule
    if kind == "text":
        if not isinstance(value, (str, int, float)) or isinstance(value, bool):
            return None, "must be text"
        return clean_text(value, arg), None
    if kind == "bool":
        if isinstance(value, bool):
            return value, None
        if str(value).strip().lower() in ("true", "1", "yes", "on"):
            return True, None
        if str(value).strip().lower() in ("false", "0", "no", "off"):
            return False, None
        return None, "must be on or off"
    if kind == "int":
        try:
            n = int(str(value).strip())
        except ValueError:
            return None, "must be a whole number"
        lo, hi = arg
        if not lo <= n <= hi:
            return None, f"must be from {lo} to {hi}"
        return n, None
    if kind == "choice":
        for choice in arg:
            if str(value).strip().lower() == choice.lower():
                return choice, None
        return None, f"must be one of {', '.join(arg)}"
    return None, "unknown rule"


def slot_dir(slot):
    return os.path.join(MODE_DIR, f"Slot{int(slot)}")


def slot_number(value):
    try:
        n = int(str(value).strip())
    except ValueError:
        return None
    return n if n in SLOTS else None


# ------------------------------------------------------------------------------------------------
# config.cfg ("key value" per line)
# ------------------------------------------------------------------------------------------------

def parse_config(text):
    """{key: value} from the file's text, each value in the type of its default. A line the game
    would not understand ("// comment", blank) is skipped."""
    config = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        key, _, value = line.partition(" ")
        if key not in CONFIG_DEFAULTS:
            continue
        value = value.strip()
        default = CONFIG_DEFAULTS[key]
        if isinstance(default, bool):
            config[key] = value.lower() in ("on", "true", "1", "yes")
        elif isinstance(default, int):
            try:
                config[key] = int(value)
            except ValueError:
                config[key] = default
        else:
            config[key] = value
    return config


def render_config(config):
    """The file as the game reads it, in its own key order."""
    lines = ["// The Forest dedicated server. Written by the Flux image at every start; the panel edits it."]
    for key, default in CONFIG_DEFAULTS.items():
        value = config.get(key, default)
        if isinstance(default, bool):
            value = "on" if value else "off"
        lines.append(f"{key} {value}")
    return "\n".join(lines) + "\n"


def load_config():
    """(config, existed): the file as the game reads it with the defaults filling the gaps."""
    try:
        with open(CONFIG_FILE, encoding="utf-8-sig") as f:
            text = f.read()
        existed = True
    except OSError:
        text, existed = "", False
    config = dict(CONFIG_DEFAULTS)
    config.update(parse_config(text))
    return config, existed


def save_config(config):
    write_text(CONFIG_FILE, render_config(config))


def env_ports(notes):
    """The three ports from the environment, or None (with a note) when they cannot be used."""
    ports = {}
    for key, name, default in (("serverSteamPort", "FOREST_STEAM_PORT", 8766),
                               ("serverGamePort", "FOREST_GAME_PORT", 27015),
                               ("serverQueryPort", "FOREST_QUERY_PORT", 27016)):
        raw = os.environ.get(name, "").strip() or str(default)
        try:
            n = int(raw)
        except ValueError:
            notes.append(f"ERROR {name}={raw!r} is not a port")
            return None
        if not 1024 <= n <= 65535:
            notes.append(f"ERROR {name}={n} is not a port from 1024 to 65535")
            return None
        ports[key] = n
    if len(set(ports.values())) != 3:
        notes.append(f"ERROR the Steam, game and query ports must differ: {ports}")
        return None
    return ports


# The FOREST_* variables that seed the file, and the key each one writes.
ENV_KEYS = {
    "FOREST_SERVER_NAME": "serverName",
    "FOREST_PASSWORD": "serverPassword",
    "FOREST_ADMIN_PASSWORD": "serverPasswordAdmin",
    "FOREST_MAX_PLAYERS": "serverPlayers",
    "FOREST_DIFFICULTY": "difficulty",
    "FOREST_AUTOSAVE_MINUTES": "serverAutoSaveInterval",
    "FOREST_SAVE_SLOT": "slot",
}
SECRET_KEYS = ("serverPassword", "serverPasswordAdmin")


def merge_settings(config, change):
    """Writes the settings in `change` into `config`; returns {key: why} for the ones refused.
    Shared by the panel and FOREST_SETTINGS_JSON."""
    errors = {}
    for key, value in change.items():
        if key in RULES:
            v, why = coerce(RULES[key], value)
            if why:
                errors[key] = why
            else:
                config[key] = v
        elif key in MANAGED:
            errors[key] = "is set by the deployment, not here"
        else:
            errors[key] = "is not a setting the game has"
    return errors


def apply_env(config, notes, created):
    """Each FOREST_* value that is set, written when the file is new or the value differs from the
    one last applied (see the module's notes)."""
    applied = read_json(ENV_APPLIED_FILE, {})
    applied = applied if isinstance(applied, dict) else {}
    changed = False
    for name, key in ENV_KEYS.items():
        if not env_set(name):
            # A password that was set and is now emptied in the deployment is removed: the marketplace
            # writes NAME= for a blank one, and without this the old password stayed in the file while
            # the connect card said there was none. A blank on a first deploy changes nothing.
            if key in SECRET_KEYS and name in os.environ and applied.get(name):
                config[key] = ""
                applied[name] = ""
                notes.append(f"{key} = (none) ({name} emptied)")
                changed = True
            continue
        raw = os.environ[name]
        if not created and applied.get(name) == raw:
            continue
        if key == "slot":
            slot = slot_number(raw)
            if slot is None:
                notes.append(f"WARN {name}={raw!r}: a slot is a number from 1 to 5; kept {config.get(key)!r}")
            else:
                config[key] = slot
                notes.append(f"slot = {slot} ({name})")
            applied[name] = raw
            changed = True
            continue
        value, why = coerce(RULES[key], raw)
        if why:
            notes.append(f"WARN {name}={raw!r}: {key} {why}; kept {config.get(key)!r}")
        else:
            config[key] = value
            shown = ("(set)" if value else "(none)") if key in SECRET_KEYS else value
            notes.append(f"{key} = {shown} ({name}{', new file' if created else ', changed'})")
        applied[name] = raw
        changed = True
    # FOREST_SETTINGS_JSON: every other setting as one JSON object, e.g. {"veganMode": true}
    raw = os.environ.get("FOREST_SETTINGS_JSON", "").strip()
    if raw and (created or applied.get("FOREST_SETTINGS_JSON") != raw):
        try:
            change = json.loads(raw)
            if not isinstance(change, dict):
                raise ValueError("not an object")
        except ValueError as e:
            notes.append(f"WARN FOREST_SETTINGS_JSON is not a JSON object ({e}); ignored")
            change = {}
        for key, why in merge_settings(config, change).items():
            notes.append(f"WARN FOREST_SETTINGS_JSON: {key} {why}; skipped")
        if change:
            notes.append(f"FOREST_SETTINGS_JSON applied ({', '.join(sorted(change))})")
        applied["FOREST_SETTINGS_JSON"] = raw
        changed = True
    if changed:
        write_json(ENV_APPLIED_FILE, applied)


def apply_config(notes):
    config, existed = load_config()
    created = not existed
    if created:
        notes.append("config.cfg written with the image's defaults")
    apply_env(config, notes, created)
    ports = env_ports(notes)
    if ports is None:
        return None
    config.update(ports)
    # The server binds what serverIP says: anything but all interfaces would not be reachable
    # through Docker's port publishing. Continue on an empty slot makes a new world (the game logs
    # "Will force game to new because ... CanResume False"), and on a full one resumes it.
    config["serverIP"] = "0.0.0.0"
    config["initType"] = "Continue"
    config["showLogs"] = True
    config["saveFolderPath"] = "Z:" + SAVES.replace("/", "\\") + "\\"
    apply_new_world(config, notes)
    os.makedirs(MODE_DIR, exist_ok=True)
    save_config(config)
    notes.append(f"slot {config['slot']}, {config['difficulty']}, up to {config['serverPlayers']} players, "
                 f"ports steam {config['serverSteamPort']} game {config['serverGamePort']} query {config['serverQueryPort']}")
    return config


def apply_new_world(config, notes):
    """A new world the panel asked for: the slot it goes in, its difficulty; the slot is backed up and
    emptied, and the game makes a fresh world there (initType Continue on an empty slot does that)."""
    pending = read_json(NEW_WORLD_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(NEW_WORLD_FILE)
    except OSError:
        pass
    slot = slot_number(pending.get("slot"))
    if slot is None:
        notes.append(f"WARN the pending new world has no usable slot: {pending!r}")
        return
    config["slot"] = slot
    if pending.get("difficulty"):
        value, why = coerce(RULES["difficulty"], pending["difficulty"])
        if not why:
            config["difficulty"] = value
    d = slot_dir(slot)
    if os.path.isdir(d) and os.listdir(d):
        for line in make_backup(f"before a new world in slot {slot}", force=True):
            notes.append(line)
        shutil.rmtree(d, ignore_errors=True)
        notes.append(f"slot {slot} emptied for a new world")
    else:
        notes.append(f"slot {slot} is empty: a new world will be made there")


# ------------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------------

def load_state():
    data = read_json(STATE_FILE, {})
    return data if isinstance(data, dict) else {}


def cmd_state(args):
    state = load_state()
    new = args[0] if args else "unknown"
    if new == "starting" and state.get("state") != "starting":
        state["generation"] = int(state.get("generation") or 0) + 1
    state["state"] = new
    state["message"] = args[1] if len(args) > 1 else ""
    state["since"] = int(time.time())
    if new == "running":
        state["runningSince"] = int(time.time())
    write_json(STATE_FILE, state)


def cmd_note(args):
    if not args:
        fail("usage: note <key> [value]", 64)
    state = load_state()
    if len(args) > 1 and args[1] != "":
        state[args[0]] = int(args[1]) if args[1].isdigit() else args[1]
    else:
        state.pop(args[0], None)
    write_json(STATE_FILE, state)


# ------------------------------------------------------------------------------------------------
# A2S: who is on, asked of the server itself on its query port (measured: it answers A2S_INFO and
# A2S_PLAYER with no challenge; the name field is the server name, "theforestDS" the folder, the map
# "Normal"/the difficulty)
# ------------------------------------------------------------------------------------------------

A2S_INFO = b"\xff\xff\xff\xffTSource Engine Query\x00"
A2S_PLAYER = b"\xff\xff\xff\xffU"


def _cstring(data, at):
    end = data.index(b"\x00", at)
    return data[at:end].decode("utf-8", "replace"), end + 1


def parse_info(body):
    """An A2S_INFO reply without its 4-byte header -> dict. ValueError otherwise."""
    if len(body) < 2 or body[0] != 0x49:
        raise ValueError("not an A2S_INFO reply")
    at = 2
    name, at = _cstring(body, at)
    game_map, at = _cstring(body, at)
    _folder, at = _cstring(body, at)
    game, at = _cstring(body, at)
    at += 2
    players, max_players, bots = body[at], body[at + 1], body[at + 2]
    at += 3
    _server_type, _env, visibility, _vac = body[at:at + 4]
    at += 4
    version, at = _cstring(body, at)
    return {"name": name, "map": game_map, "game": game, "players": players, "maxPlayers": max_players,
            "bots": bots, "password": bool(visibility), "version": version}


def parse_players(body):
    """An A2S_PLAYER reply without its header -> [{"name", "seconds"}]."""
    if len(body) < 2 or body[0] != 0x44:
        raise ValueError("not an A2S_PLAYER reply")
    count = body[1]
    at = 2
    players = []
    for _ in range(count):
        at += 1
        name, at = _cstring(body, at)
        _score, seconds = struct.unpack_from("<lf", body, at)
        at += 8
        players.append({"name": name, "seconds": int(seconds)})
    return players


def a2s(port, request, host="127.0.0.1", timeout=2.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sent = request if request != A2S_PLAYER else request + b"\xff\xff\xff\xff"
        for _ in range(3):
            sock.sendto(sent, (host, port))
            data, _ = sock.recvfrom(4096)
            if data[:4] != b"\xff\xff\xff\xff":
                raise ValueError("split or malformed reply")
            body = data[4:]
            if body[:1] == b"\x41" and len(body) >= 5:
                sent = (request if request != A2S_PLAYER else A2S_PLAYER) + body[1:5]
                continue
            return body
        raise ValueError("challenged too often")
    finally:
        sock.close()


def query_port():
    config, _ = load_config()
    try:
        return int(config.get("serverQueryPort") or os.environ.get("FOREST_QUERY_PORT") or 27016)
    except (TypeError, ValueError):
        return 27016


def query(port=None):
    """(info, players) from the server, or (None, None) when it does not answer."""
    port = port or query_port()
    try:
        info = parse_info(a2s(port, A2S_INFO))
    except (OSError, ValueError, IndexError, struct.error):
        return None, None
    try:
        players = parse_players(a2s(port, A2S_PLAYER))
    except (OSError, ValueError, IndexError, struct.error):
        players = None
    return info, players


def cmd_players(_args):
    info, _ = query()
    if info is not None:
        print(info["players"])


# ------------------------------------------------------------------------------------------------
# Saves
# ------------------------------------------------------------------------------------------------

def slot_summary(d):
    """What is in a slot folder: files, bytes, the newest file's time."""
    info = {"exists": False}
    if not os.path.isdir(d):
        return info
    files = size = newest = 0
    for root, _dirs, names in os.walk(d):
        for name in names:
            try:
                st = os.stat(os.path.join(root, name))
            except OSError:
                continue
            files += 1
            size += st.st_size
            newest = max(newest, int(st.st_mtime))
    if files:
        info.update({"exists": True, "files": files, "size": size, "modified": newest})
    return info


def list_slots():
    return [{"slot": n, **slot_summary(slot_dir(n))} for n in SLOTS]


def running_slot():
    """The slot the server is playing now (the one it started with), or None when it is not up."""
    state = load_state()
    return state.get("slot") if state.get("state") in ("running", "starting") else None


def cmd_saves(_args):
    config, _ = load_config()
    pending = read_json(NEW_WORLD_FILE)
    out({"slots": list_slots(), "active": config.get("slot"), "difficulty": config.get("difficulty"),
         "running": running_slot(), "newWorld": pending if isinstance(pending, dict) else None,
         "slotCount": len(SLOTS)})


def cmd_use_slot(args):
    slot = slot_number(args[0]) if args else None
    if slot is None:
        fail("a slot is a number from 1 to 5")
    config, _ = load_config()
    config["slot"] = slot
    save_config(config)
    try:
        os.remove(NEW_WORLD_FILE)
    except OSError:
        pass
    out({"ok": True, "slot": slot, "restartNeeded": True})


def cmd_new_world(args):
    slot = slot_number(args[0]) if args else None
    if slot is None:
        fail("a slot is a number from 1 to 5")
    difficulty = None
    if len(args) > 1 and args[1]:
        difficulty, why = coerce(RULES["difficulty"], args[1])
        if why:
            fail(f"difficulty {why}")
    write_json(NEW_WORLD_FILE, {"slot": slot, "difficulty": difficulty, "asked": int(time.time())})
    out({"ok": True, "slot": slot, "restartNeeded": True})


def cmd_delete_slot(args):
    slot = slot_number(args[0]) if args else None
    if slot is None:
        fail("a slot is a number from 1 to 5")
    config, _ = load_config()
    up = load_state().get("state") in ("running", "starting")
    if slot == running_slot() or (up and slot == config.get("slot")):
        fail("That is the slot the server plays. Switch to another slot first.")
    d = slot_dir(slot)
    if not os.path.isdir(d):
        fail("That slot is already empty.")
    for line in make_backup(f"before deleting slot {slot}", force=True):
        print(line, file=sys.stderr)
    shutil.rmtree(d)
    out({"ok": True, "slot": slot})


def _safe_members(z):
    """The archive's files, refusing paths that leave the folder and archives that are too big."""
    total = 0
    members = []
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        if info.is_dir():
            continue
        if name.startswith("/") or ".." in name.split("/"):
            raise ValueError(f"unsafe path in the archive: {name}")
        total += info.file_size
        if total > IMPORT_MAX_BYTES:
            raise ValueError("the archive is too big to be a save")
        members.append((info, name))
    return members


TRANSFER_DIRS = ("uploads", "exports")
TRANSFER_MAX_AGE = 3600


def prune_transfers(keep=None):
    """The panel's uploads and exports are on the synced data volume, so a leftover (a failed upload,
    a download taken) is replicated for nothing: remove what is older than an hour, never `keep`."""
    keep = os.path.abspath(keep) if keep else None
    cutoff = time.time() - TRANSFER_MAX_AGE
    for sub in TRANSFER_DIRS:
        base = os.path.join(STATE_DIR, sub)
        try:
            names = os.listdir(base)
        except OSError:
            continue
        for name in names:
            path = os.path.join(base, name)
            try:
                if os.path.abspath(path) != keep and os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                    os.remove(path)
            except OSError:
                pass


def drop_upload(src):
    """The uploaded zip is of no use once an import has been tried: the panel uploads again on a retry."""
    try:
        if os.path.abspath(os.path.dirname(src)) == os.path.join(os.path.abspath(STATE_DIR), "uploads"):
            os.remove(src)
    except OSError:
        pass


def slot_root(names):
    """The folder INSIDE the archive that holds one world: the single `Slot<n>` folder (under
    Multiplayer/ if it is there), or the archive's top level / only top-level folder. Returns the
    prefix ("" or "a/b/"), or raises ValueError when it cannot tell."""
    slots = {}
    for n in names:
        parts = n.split("/")
        for i, part in enumerate(parts[:-1]):
            if SLOT_RE.match(part):
                slots.setdefault("/".join(parts[:i + 1]) + "/", set()).add(parts[i - 1] if i else "")
                break
    if slots:
        multi = [p for p in slots if "Multiplayer" in slots[p]]
        pool = multi or list(slots)
        if len(pool) != 1:
            raise ValueError("the archive holds more than one save slot: zip just the one to bring")
        return pool[0]
    tops = {n.split("/")[0] for n in names if "/" in n}
    if len(tops) == 1 and all("/" in n for n in names):
        return next(iter(tops)) + "/"
    return ""


def cmd_import_save(args):
    if len(args) < 2:
        fail("usage: import-save <zip> <slot>", 64)
    src, slot = args[0], slot_number(args[1])
    prune_transfers(keep=src)
    if slot is None:
        drop_upload(src)
        fail("a slot is a number from 1 to 5")
    d = slot_dir(slot)
    config, _ = load_config()
    up = load_state().get("state") in ("running", "starting")
    if slot == running_slot() or (up and slot == config.get("slot")):
        drop_upload(src)
        fail("That is the slot the server plays. Pick another empty slot, import there, then switch to it.")
    if os.path.isdir(d) and os.listdir(d):
        drop_upload(src)
        fail("That slot already has a world. Pick an empty slot (or delete that one first).")
    shutil.rmtree(d, ignore_errors=True)
    count = 0
    try:
        with zipfile.ZipFile(src) as z:
            members = _safe_members(z)
            names = [n for _, n in members]
            if not names:
                raise ValueError("the archive is empty")
            prefix = slot_root(names)
            os.makedirs(d, exist_ok=True)
            for info, name in members:
                if not name.startswith(prefix):
                    continue
                rel = name[len(prefix):]
                if not rel:
                    continue
                dest = os.path.join(d, *rel.split("/"))
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with z.open(info) as fin, open(dest, "wb") as fout:
                    shutil.copyfileobj(fin, fout)
                count += 1
        if not count:
            raise ValueError("no save found in the archive")
    except (OSError, ValueError, zipfile.BadZipFile) as e:
        shutil.rmtree(d, ignore_errors=True)
        drop_upload(src)
        fail(str(e) if isinstance(e, ValueError) else f"the file is not a usable zip: {e}")
    try:
        os.remove(src)
    except OSError:
        pass
    out({"ok": True, "slot": slot, **slot_summary(d)})


def cmd_export_save(args):
    if len(args) < 2:
        fail("usage: export-save <slot> <out.zip>", 64)
    slot = slot_number(args[0])
    if slot is None or not slot_summary(slot_dir(slot)).get("exists"):
        fail("That slot has no world.")
    dest = args[1]
    prune_transfers(keep=dest)
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    base = slot_dir(slot)
    with zipfile.ZipFile(dest + ".part", "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, names in os.walk(base):
            for name in sorted(names):
                path = os.path.join(root, name)
                z.write(path, f"Slot{slot}/" + os.path.relpath(path, base).replace(os.sep, "/"))
    os.replace(dest + ".part", dest)
    os.chmod(dest, 0o666)
    out({"ok": True, "slot": slot, "file": dest, "size": os.path.getsize(dest)})


# ------------------------------------------------------------------------------------------------
# Settings (the panel's form)
# ------------------------------------------------------------------------------------------------

def rules_json(rules):
    return {k: {"type": kind, **({"choices": arg} if kind == "choice" else {}),
                **({"min": arg[0], "max": arg[1]} if kind == "int" else {}),
                **({"max": arg} if kind == "text" else {})} for k, (kind, arg) in rules.items()}


def cmd_settings(_args):
    config, existed = load_config()
    shown = {k: config[k] for k in CONFIG_DEFAULTS if k not in ("saveFolderPath",)}
    out({"config": shown, "exists": existed, "defaults": CONFIG_DEFAULTS, "rules": rules_json(RULES),
         "envOwned": sorted(k for k in ENV_KEYS if env_set(k)),
         "ports": {k: config.get(k) for k in ("serverSteamPort", "serverGamePort", "serverQueryPort")}})


def cmd_set_settings(args):
    if not args:
        fail("usage: set-settings '<json>'", 64)
    try:
        change = json.loads(args[0])
    except ValueError:
        fail("the settings are not JSON")
    if not isinstance(change, dict):
        fail("the settings must be a JSON object")
    config, _ = load_config()
    errors = merge_settings(config, change)
    if errors:
        out({"ok": False, "error": "Some settings were not accepted.", "fields": errors})
        sys.exit(1)
    save_config(config)
    # A value the owner saved here counts as applied for the env that also sets it, so the same old
    # env does not put its value back at the next start (before the first start it would otherwise).
    applied = read_json(ENV_APPLIED_FILE, {})
    applied = applied if isinstance(applied, dict) else {}
    marked = False
    for name, key in ENV_KEYS.items():
        if key in change and name in os.environ and (env_set(name) or applied.get(name)):
            # (a blank env that had a value is recorded as blank, so the next start does not
            # remove the password the owner has just saved)
            applied[name] = os.environ[name] if env_set(name) else ""
            marked = True
    if marked:
        write_json(ENV_APPLIED_FILE, applied)
    out({"ok": True, "restartNeeded": True})


# ------------------------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------------------------

def installed_build():
    path = os.path.join(SERVER_DIR, "steamapps", f"appmanifest_{STEAM_APP}.acf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def cmd_status(_args):
    state = load_state()
    config, _ = load_config()
    info, players = (None, None)
    if state.get("state") == "running":
        info, players = query(int(config.get("serverQueryPort") or 27016))
    result = {
        "state": state.get("state") or "unknown",
        "message": state.get("message") or "",
        "since": state.get("since"),
        "runningSince": state.get("runningSince"),
        "generation": int(state.get("generation") or 0),
        "slot": state.get("slot"),
        "configSlot": config.get("slot"),
        "difficulty": config.get("difficulty"),
        "serverName": config.get("serverName"),
        "maxPlayers": config.get("serverPlayers"),
        "autosaveMinutes": config.get("serverAutoSaveInterval"),
        "passworded": bool(config.get("serverPassword")),
        "ports": {k: config.get(k) for k in ("serverSteamPort", "serverGamePort", "serverQueryPort")},
        "build": installed_build(),
        "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
        "query": info is not None,
        "playerCount": info["players"] if info else None,
        "players": players if players is not None else ([] if info else None),
        "nextRestart": state.get("nextRestart"),
        "updateWaiting": state.get("updateWaiting"),
        "restartPending": os.path.exists(RESTART_MARKER),
        "restorePending": os.path.exists(RESTORE_FILE),
        "newWorldPending": read_json(NEW_WORLD_FILE),
        "lastBackup": (list_backups() or [{}])[0].get("time"),
    }
    out(result)


def cmd_clear_stale_restart(_args):
    """Called right before the game starts: a restart asked for while the server was preparing is
    already covered (the game reads its config only now), unless a restore or a new world was asked
    for after this generation looked for them. Those keep their restart."""
    if os.path.exists(RESTORE_FILE) or os.path.exists(NEW_WORLD_FILE):
        return
    try:
        os.remove(RESTART_MARKER)
    except OSError:
        pass


def cmd_restart(_args):
    state = load_state()
    if state.get("state") not in ("running", "starting", "updating", "restarting"):
        fail("The server is not running.")
    if not os.path.exists(RESTART_MARKER):
        not_before = 0
        if state.get("state") == "running" and state.get("runningSince"):
            not_before = int(state["runningSince"]) + SETTLE_SECONDS
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: from the panel\nnotbefore={not_before}\n")
    out({"ok": True, "restarting": True})


# ------------------------------------------------------------------------------------------------
# Backups: config.cfg and saves/ as one .tar.gz
# ------------------------------------------------------------------------------------------------

def load_index():
    data = read_json(BACKUP_INDEX, {})
    return data if isinstance(data, dict) else {}


def list_backups():
    index = load_index()
    rows = []
    if os.path.isdir(BACKUP_DIR):
        for name in sorted(os.listdir(BACKUP_DIR), reverse=True):
            if not BACKUP_NAME_RE.match(name):
                continue
            path = os.path.join(BACKUP_DIR, name)
            st = os.stat(path)
            meta = index.get(name, {})
            rows.append({"name": name, "size": st.st_size, "time": int(meta.get("time") or st.st_mtime),
                         "why": meta.get("why") or "", "slots": meta.get("slots") or [], "keep": bool(meta.get("keep"))})
    return rows


def prune_backups(keep):
    """The newest `keep` are kept, plus every one marked keep (made before a restore or a new world),
    plus the newest made while the server was up: a crash loop that backs up on every start can
    never rotate the last good world away."""
    rows = list_backups()
    index = load_index()
    kept = 0
    safety = 0
    safety_max = env_int("FLUX_BACKUP_KEEP_SAFETY", 20, 1)
    good_seen = False
    for row in rows:
        meta = index.get(row["name"], {})
        if meta.get("keep"):
            # Safety copies are never rotated out by the regular count, but there is a ceiling (newest
            # first), or every restore, delete and new world would add a full copy for good.
            safety += 1
            if safety > safety_max:
                try:
                    os.remove(os.path.join(BACKUP_DIR, row["name"]))
                except OSError:
                    pass
                index.pop(row["name"], None)
            continue
        if not good_seen and meta.get("good"):
            good_seen = True
            continue
        kept += 1
        if kept > keep:
            try:
                os.remove(os.path.join(BACKUP_DIR, row["name"]))
            except OSError:
                pass
            index.pop(row["name"], None)
    write_json(BACKUP_INDEX, index)


def make_backup(why, force=False):
    """Returns the notes. Skipped when there is nothing to back up, or the newest is younger
    than FLUX_BACKUP_MIN_AGE_MINUTES (unless forced)."""
    notes = []
    if not any(s.get("exists") for s in list_slots()):
        return ["# backup skipped: nothing saved yet"]
    min_age = env_int("FLUX_BACKUP_MIN_AGE_MINUTES", 60, 0) * 60
    rows = list_backups()
    if not force and rows and time.time() - rows[0]["time"] < min_age:
        return [f"# backup skipped: the newest is {int((time.time() - rows[0]['time']) / 60)} min old"]
    os.makedirs(BACKUP_DIR, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-forest.tar.gz"
    while os.path.exists(os.path.join(BACKUP_DIR, name)):
        time.sleep(1)
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-forest.tar.gz"
    path = os.path.join(BACKUP_DIR, name)
    with tarfile.open(path + ".part", "w:gz") as t:
        if os.path.exists(CONFIG_FILE):
            t.add(CONFIG_FILE, arcname="forest/config.cfg")
        if os.path.isdir(MODE_DIR):
            t.add(MODE_DIR, arcname="forest/Multiplayer")
    os.replace(path + ".part", path)
    index = load_index()
    state = load_state()
    index[name] = {"time": int(time.time()), "why": why, "slots": [s["slot"] for s in list_slots() if s.get("exists")],
                   "keep": why.startswith("before"), "good": state.get("state") == "running"}
    write_json(BACKUP_INDEX, index)
    prune_backups(env_int("FLUX_BACKUP_KEEP", 10, 1))
    notes.append(f"# backup {name} ({why}, {os.path.getsize(path) // 1024} KB)")
    return notes


def cmd_backup(args):
    why = args[0] if args else "by hand"
    for line in make_backup(why, force=len(args) > 1 and args[1] == "force"):
        print(line)


def cmd_backups(_args):
    out({"backups": list_backups()})


def cmd_restore(args):
    name = os.path.basename(args[0]) if args else ""
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("No such backup.")
    write_json(RESTORE_FILE, {"name": name, "asked": int(time.time())})
    state = load_state()
    running = state.get("state") in ("running", "starting", "updating")
    if running and not os.path.exists(RESTART_MARKER):
        with open(RESTART_MARKER, "w", encoding="utf-8") as f:
            f.write(f"requested: restore {name}\nnotbefore=0\n")
    out({"ok": True, "restarting": running, "name": name})


def reassert_env_passwords():
    """After a restore, the passwords are the deployment's again: the connect card reads them from the
    env, and an older backup holds whatever they were then."""
    config, _ = load_config()
    applied = read_json(ENV_APPLIED_FILE, {})
    applied = applied if isinstance(applied, dict) else {}
    for name, key in ENV_KEYS.items():
        if key not in SECRET_KEYS or name not in os.environ:
            continue
        raw = os.environ[name]
        if raw.strip():
            value, why = coerce(RULES[key], raw)
            if why:
                continue
        elif applied.get(name):
            value = ""  # it was set by the deployment and has been emptied there
        else:
            continue  # blank and never set by the deployment: a panel password stays
        config[key] = value
        applied[name] = raw
    save_config(config)
    write_json(ENV_APPLIED_FILE, applied)


def cmd_do_restore(_args):
    pending = read_json(RESTORE_FILE)
    if not isinstance(pending, dict):
        return
    try:
        os.remove(RESTORE_FILE)
    except OSError:
        pass
    name = os.path.basename(str(pending.get("name", "")))
    path = os.path.join(BACKUP_DIR, name)
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(path):
        print(f"# WARN the backup to restore is gone: {name}")
        return
    for line in make_backup(f"before restoring {name}", force=True):
        print(line)
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = tempfile.mkdtemp(dir=DATA_DIR, prefix=".flux-restore-")
    try:
        with tarfile.open(path) as t:
            for member in t.getmembers():
                if member.name.startswith("/") or ".." in member.name.split("/") or not member.name.startswith("forest"):
                    raise ValueError(f"unsafe path {member.name}")
                if not (member.isfile() or member.isdir()):
                    raise ValueError(f"not a file: {member.name}")
            t.extractall(tmp)  # noqa: S202 - every member checked above
        restored = os.path.join(tmp, "forest")
        if os.path.isdir(os.path.join(restored, "Multiplayer")):
            shutil.rmtree(MODE_DIR, ignore_errors=True)
            os.makedirs(os.path.dirname(MODE_DIR), exist_ok=True)
            shutil.move(os.path.join(restored, "Multiplayer"), MODE_DIR)
        if os.path.isfile(os.path.join(restored, "config.cfg")):
            shutil.copyfile(os.path.join(restored, "config.cfg"), CONFIG_FILE)
            reassert_env_passwords()
        print(f"# restored {name}")
    except (OSError, ValueError, tarfile.TarError) as e:
        print(f"# WARN the restore of {name} failed: {e}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------------------------------------------------------
# Game updates that did not install
# ------------------------------------------------------------------------------------------------

def cmd_update_target(args):
    if args:
        write_json(UPDATE_TARGET_FILE, {"build": args[0], "time": int(time.time())})


def cmd_update_check(_args):
    target = read_json(UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(UPDATE_TARGET_FILE)
    except OSError:
        pass
    build = installed_build()
    if build != str(target.get("build")):
        write_json(UPDATE_FAILED_FILE, {"build": str(target.get("build")), "time": int(time.time())})
        print(f"# WARN the update to build {target.get('build')} did not install (still {build}); not retried for 6 hours")


def cmd_update_skip(args):
    failed = read_json(UPDATE_FAILED_FILE)
    if isinstance(failed, dict) and args and str(failed.get("build")) == args[0] \
            and time.time() - float(failed.get("time") or 0) < UPDATE_FAILED_SKIP:
        sys.exit(0)
    sys.exit(1)


# ------------------------------------------------------------------------------------------------

def cmd_apply(_args):
    notes = []
    os.makedirs(SAVES, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    config = apply_config(notes)
    # The game looks for its own (client) App ID next to the exe.
    try:
        if os.path.isdir(SERVER_DIR):
            write_text(os.path.join(SERVER_DIR, "steam_appid.txt"), os.environ.get("FLUX_GAME_APP_ID", "242760"))
    except OSError as e:
        notes.append(f"WARN steam_appid.txt: {e}")
    for line in notes:
        print(f"# {line}")
    if config is None:
        sys.exit(2)
    state = load_state()
    state["slot"] = config.get("slot")
    write_json(STATE_FILE, state)
    prune_transfers()


COMMANDS = {
    "apply": cmd_apply, "state": cmd_state, "note": cmd_note, "status": cmd_status,
    "settings": cmd_settings, "set-settings": cmd_set_settings, "saves": cmd_saves,
    "use-slot": cmd_use_slot, "new-world": cmd_new_world, "delete-slot": cmd_delete_slot,
    "import-save": cmd_import_save, "export-save": cmd_export_save, "restart": cmd_restart, "clear-stale-restart": cmd_clear_stale_restart,
    "backups": cmd_backups, "restore": cmd_restore, "backup": cmd_backup, "do-restore": cmd_do_restore,
    "update-target": cmd_update_target, "update-check": cmd_update_check,
    "update-skip": cmd_update_skip, "players": cmd_players,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 64
    COMMANDS[argv[1]](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
