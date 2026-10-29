# The Forest dedicated server image for Flux.
#
# Written from scratch. Endnight ships the dedicated server for Windows only (Steam app 556450,
# anonymous), so it runs under Wine on a virtual display (the Unity 5.6 player will not start
# without one), installed and updated with SteamCMD on every start, under a supervisor that writes
# config.cfg from the environment and the hub's panel, follows game updates, restarts daily if
# asked, keeps backups, and gives the hub a JSON status, the save slots and the settings. The game
# saves on an interval and when the last player leaves, never on quit: see README.md.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# Wine 10.0 staging-tkg from Kron4ek/Wine-Builds, the Wine our V Rising and Enshrouded images run:
# it has fsync and esync. Upstream Wine (WineHQ, Debian) sends every thread wait of a Windows
# server through wineserver; TKG builds from 10.16 on and WineHQ 11 are ntsync-only, which needs
# /dev/ntsync, a device Flux cannot pass into a container. The wow64 build is 64-bit only, like
# the server. PINNED by version AND checksum: moving Wine is a deliberate change, tested with a
# real server, never a side effect of a rebuild.
ARG WINE_VERSION=10.0
ARG WINE_TKG_SHA256=fe9b45a6ac181c7fe6290ea83e3a6d4abb8ca08d79236ffd95ede5413a9faa80

# The libraries Wine loads for a headless server under Xvfb (X11, fonts, TLS, Kerberos for
# winbind), the same set as runonflux/vrising-server-flux. python3 (not -minimal): flux-forest needs
# json, zipfile and tarfile.
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils procps tzdata python3 xvfb winbind \
        libx11-6 libxext6 libxrender1 libxi6 libxrandr2 libxcursor1 libxcomposite1 libxfixes3 \
        libxinerama1 libxxf86vm1 libxkbcommon0 libgl1 libglu1-mesa libfreetype6 libfontconfig1 \
        libgnutls30t64 libunwind8 libudev1 libdbus-1-3 libkrb5-3 libgssapi-krb5-2 libpng16-16t64 && \
    pkg="wine-${WINE_VERSION}-staging-tkg-amd64-wow64" && \
    curl -fsSL -o "/tmp/${pkg}.tar.xz" \
      "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/${pkg}.tar.xz" && \
    echo "${WINE_TKG_SHA256}  /tmp/${pkg}.tar.xz" | sha256sum -c - && \
    tar -xJf "/tmp/${pkg}.tar.xz" -C /opt && mv "/opt/${pkg}" /opt/wine && rm "/tmp/${pkg}.tar.xz" && \
    test -x /opt/wine/bin/wine && \
    apt-get remove -y --purge xz-utils && apt-get autoremove -y && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/fluxforest.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxforest.py && \
    ln -s /opt/flux/fluxforest.py /usr/local/bin/flux-forest

# SteamCMD's self-update, done once here instead of on every container start; the weekly
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

# The Wine prefix is NOT baked in (Wine copies its DLLs into it, over a GB on every node's pull):
# the supervisor makes it on the first start, on the install volume (local, never synced).
# WINEDEBUG=-all: Wine's own channels are noise. mscoree/mshtml off: no Mono or Gecko prompt
# while the prefix is made. fsync needs futex_waitv (Linux 5.16+, allowed by Docker's default
# seccomp profile); where it is missing Wine falls back to esync, then to wineserver.
ENV PATH=/opt/wine/bin:${PATH} \
    WINEPREFIX=/mnt/theforest/server/flux-wine \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEFSYNC=1 \
    WINEESYNC=1 \
    FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_WINE_VERSION=${WINE_VERSION}

VOLUME ["/mnt/theforest/server", "/mnt/theforest/data"]

# Steam port, game port (Bolt) and query port (Steam A2S), all UDP. Only 27015 and 27016 are bound
# on the machine (measured); 8766 is the Steam master updater's port and is published as the
# game's documentation asks.
EXPOSE 8766/udp 27015/udp 27016/udp

# The first start downloads about 1.8 GB and makes the Wine prefix. FluxOS does not act on
# health; this is for anyone running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD pgrep -f "[T]heForestDedicatedServer\.exe -batchmode" >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
