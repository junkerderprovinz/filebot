# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
#
# FileBot for Unraid on LinuxServer.io's baseimage-selkies: the FileBot desktop
# app streamed to the browser as H.264 video.
#
# FileBot is commercial software. The image installs it unmodified from the
# official FileBot apt repository and ships no license; every user activates
# their own key (see init-filebot).
#
# Repository:  https://github.com/junkerderprovinz/filebot
# License:     AGPL-3.0-only (this wrapper); FileBot has its own license
#
# ubunturesolute is Ubuntu 26.04, the release the official FileBot images are
# built on, so the package set below matches theirs.
ARG BASE_TAG=ubunturesolute@sha256:cdb423bb9c9a41c1224cbee81784615ac4d469460f9e80881b23baf62ac2c1c3
FROM ghcr.io/linuxserver/baseimage-selkies:${BASE_TAG}

LABEL maintainer="junkerderprovinz"
LABEL org.opencontainers.image.title="filebot"
LABEL org.opencontainers.image.description="FileBot for Unraid with a Selkies web desktop: rename movies, shows and music in your browser, no VNC client"
LABEL org.opencontainers.image.source="https://github.com/junkerderprovinz/filebot"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.vendor="junkerderprovinz"

# TITLE feeds the PWA manifest; SELKIES_UI_TITLE is the visible tab/sidebar
# title of the Selkies web client. Selkies will not start with basic auth on and
# no password, so SELKIES_ENABLE_BASIC_AUTH=false keeps the no-login default;
# the base's nginx still enforces HTTP basic auth once a real
# CUSTOM_USER/PASSWORD is set.
#
# RESTART_APP=true turns on the base image's svc-watchdog, which runs the
# openbox autostart again whenever the application disappears; otherwise
# closing FileBot leaves an empty black desktop until the container restarts.
# The watchdog finds the process by matching the autostart command line, which
# is why rootfs/defaults/autostart does not `exec` the launch.
ENV TITLE="FileBot" \
    SELKIES_UI_TITLE="FileBot" \
    SELKIES_ENABLE_BASIC_AUTH="false" \
    RESTART_APP="true" \
    FILEBOT_THEME="Darcula"

# Swing ignores the X DPI that Selkies raises for a HiDPI browser while the
# GTK file dialog follows it, so the two would come out at different sizes.
# Streaming at the browser's CSS size with the DPI fixed at 96 keeps them equal.
ENV SELKIES_USE_CSS_SCALING="true" \
    SELKIES_SCALING_DPI="96"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The same helpers the official FileBot image installs: chromaprint for
# AcoustID music matching, the archive tools behind "Extract", mkvtoolnix and
# AtomicParsley for tagging, ffmpeg for media probing. zenity gives FileBot a
# file dialog that needs no JavaFX. MediaInfo comes from MediaArea's own
# repository because FileBot 5.3 needs 26.05 or newer, ahead of Ubuntu's.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openjdk-21-jre libjna-java \
        libchromaprint-tools \
        unzip unrar 7zip 7zip-rar xz-utils \
        ffmpeg mkvtoolnix atomicparsley \
        zenity dbus-x11 \
        fontconfig fonts-noto-core fonts-noto-cjk fonts-dejavu-core \
        gnupg curl ca-certificates; \
    curl -fsSL -o /tmp/mediaarea.deb https://mediaarea.net/repo/deb/repo-mediaarea_1.0-27_all.deb; \
    dpkg -i /tmp/mediaarea.deb; \
    rm -f /tmp/mediaarea.deb; \
    curl -fsSL https://raw.githubusercontent.com/filebot/plugins/master/gpg/maintainer.pub \
        | gpg --dearmor --output /usr/share/keyrings/filebot.gpg; \
    echo "deb [arch=all signed-by=/usr/share/keyrings/filebot.gpg] https://get.filebot.net/deb/ universal main" \
        > /etc/apt/sources.list.d/filebot.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mediainfo filebot; \
    # The libjna-java package installs into a multiarch path the JVM does not
    # search (https://bugs.launchpad.net/ubuntu/+source/libjna-java/+bug/2000863).
    ln -s /usr/lib/*-linux-gnu*/jni /usr/lib/jni; \
    fc-cache -f >/dev/null 2>&1 || true; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY rootfs/ /

# rootfs/ ships svc-xorg/dependencies.d/init-dpi so the DPI oneshot settles
# the DPI before Xvfb starts. If a base bump renamed that service, the COPY
# above would create /etc/s6-overlay/s6-rc.d/svc-xorg as a service directory
# with a dependency and no `type` file, s6-rc-compile would abort and every
# container exit at boot while the build stayed green. Checking for the base's
# own `type` file turns that into a build error instead.
RUN set -eux; \
    t=/etc/s6-overlay/s6-rc.d/svc-xorg/type; \
    [ -f "$t" ] || { echo "ERROR: $t missing, the selkies base renamed or dropped svc-xorg; re-point rootfs/etc/s6-overlay/s6-rc.d/svc-xorg/dependencies.d/init-dpi at the new service"; exit 1; }

# The base's openbox maximises every window, which suits the main window but
# blows FileBot's dialogs and the zenity file dialog up to full screen. A later
# rule wins in openbox, so these go after the base's catch-all. The main window
# also loses its title bar, since the browser tab already names it; dialogs
# keep theirs so they can be moved and closed.
RUN set -eux; \
    rc=/etc/xdg/openbox/rc.xml; \
    grep -q '<application class="\*"><maximized>yes</maximized></application>' "$rc"; \
    sed -i 's|</applications>|  <application type="dialog"><maximized>no</maximized></application>\n  <application class="zenity"><maximized>no</maximized><size><width>1100</width><height>700</height></size><position force="yes"><x>center</x><y>center</y></position></application>\n  <application class="net-filebot-Main" type="normal"><decor>no</decor></application>\n</applications>|' "$rc"

# Init-log banner: single source at .github/assets/banner-raw.txt (CR stripped
# so a Windows checkout can't break it). Also blank the base's own adduser
# branding banner so the log shows only our print-banner.sh block.
COPY .github/assets/banner-raw.txt /usr/local/share/banner-raw.txt
RUN tr -d '\r' < /usr/local/share/banner-raw.txt > /usr/local/share/banner.txt; \
    rm -f /usr/local/share/banner-raw.txt; \
    : > /etc/s6-overlay/s6-rc.d/init-adduser/branding 2>/dev/null || true

COPY .github/assets/icon.png /usr/share/selkies/www/icon.png

RUN chmod +x /usr/local/bin/print-banner.sh \
             /usr/local/bin/filebot \
             /etc/s6-overlay/s6-rc.d/init-dpi/run \
             /etc/s6-overlay/s6-rc.d/init-filebot/run \
             /etc/s6-overlay/s6-rc.d/svc-filebot-ready/run \
             /etc/s6-overlay/s6-rc.d/svc-filebot-amc/run \
             /defaults/autostart \
             /defaults/startwm.sh

EXPOSE 3001
VOLUME /config
