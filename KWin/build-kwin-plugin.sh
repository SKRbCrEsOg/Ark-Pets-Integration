#!/usr/bin/env bash
#
# Copyright (c) 2024-2025, Litwak913
# At GPL-3.0 License
#
# Builds the ArkPets KWin integration plugin against the KWin that is installed on THIS machine.
#
# Why this has to happen locally
# ------------------------------
# A KWin plugin links against libkwin and against KWin's own C++ classes. That is not a stable
# ABI: KWin adds and removes members between releases, and libkwin exports only part of what the
# headers declare - for example KWin::LayerShellV1Window has no exported symbols at all, so
# anything that touches it through the class type fails to link. A plugin built against one KWin
# therefore has no guarantee of loading into another; the .so in the releases is only a
# convenience build for the maintainer's KWin version.
#
# Building here reads the local headers and the local libkwin, so the result matches by
# construction. This script additionally verifies that afterwards: every KWin symbol the plugin
# leaves undefined must actually be exported by the libkwin on this machine. That check is what
# catches a stale or mismatched kwin-dev, which is the usual way this build goes wrong.
#
# Usage: ./build-kwin-plugin.sh [options]
#
#   --source <dir>     Build from an existing Ark-Pets-Integration checkout
#                      (default: this script's directory, or a fresh clone if run standalone)
#   --build-dir <dir>  Build directory (default: <source>/KWin/build)
#   --jobs <n>         Parallel jobs (default: number of CPUs)
#   --install          Install into the Qt plugin directory and ask KWin to load it
#   --install-deps     Run the detected package-manager command for the missing dependencies
#   --verify-only      Skip the build; only check an existing .so against the local libkwin
#   --clean            Remove the build directory first
#   -h, --help         Show this help

set -o pipefail

readonly PLUGIN_NAME="ArkPetsIntegration2"
readonly REPO_URL="https://github.com/SKRbCrEsOg/Ark-Pets-Integration.git"
readonly PLUGIN_REL_PATH="bin/kwin/plugins/${PLUGIN_NAME}.so"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR=""
BUILD_DIR=""
JOBS="$( (nproc 2>/dev/null || echo 2) )"
DO_INSTALL=0
DO_INSTALL_DEPS=0
VERIFY_ONLY=0
DO_CLEAN=0

C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
fi

log()  { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
dim()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()   { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%sWARN:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)       SOURCE_DIR="${2:?}"; shift 2 ;;
        --build-dir)    BUILD_DIR="${2:?}"; shift 2 ;;
        --jobs|-j)      JOBS="${2:?}"; shift 2 ;;
        --install)      DO_INSTALL=1; shift ;;
        --install-deps) DO_INSTALL_DEPS=1; shift ;;
        --verify-only)  VERIFY_ONLY=1; shift ;;
        --clean)        DO_CLEAN=1; shift ;;
        -h|--help)      usage ;;
        *)              die "unknown option: $1 (try --help)" ;;
    esac
done

# --- Distribution detection ---------------------------------------------------------------
# Only used to print the right package names. The build itself is package-manager agnostic.
DISTRO_ID=""; DISTRO_LIKE=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"; DISTRO_LIKE="${ID_LIKE:-}"
fi

deps_for_distro() {
    case "$DISTRO_ID $DISTRO_LIKE" in
        *debian*|*ubuntu*|*linuxmint*|*pop*)
            echo "cmake g++ make extra-cmake-modules qt6-base-dev kwin-dev pkg-config libdrm-dev binutils" ;;
        *arch*|*manjaro*|*endeavouros*)
            echo "cmake gcc make extra-cmake-modules qt6-base kwin pkgconf libdrm binutils" ;;
        *fedora*|*rhel*|*centos*)
            echo "cmake gcc-c++ make extra-cmake-modules qt6-qtbase-devel kwin-devel pkgconf-pkg-config libdrm-devel binutils" ;;
        *opensuse*|*suse*)
            echo "cmake gcc-c++ make extra-cmake-modules qt6-base-devel kwin6-devel pkgconf libdrm-devel binutils" ;;
        *gentoo*)
            echo "dev-build/cmake sys-devel/gcc kde-frameworks/extra-cmake-modules dev-qt/qtbase kwin dev-util/pkgconf x11-libs/libdrm sys-devel/binutils" ;;
        *void*)
            echo "cmake gcc make extra-cmake-modules qt6-base-devel kwin-devel pkg-config libdrm-devel binutils" ;;
        *)
            echo "" ;;
    esac
}

deps_install_hint() {
    local pkgs="$1" cmd=""
    case "$DISTRO_ID $DISTRO_LIKE" in
        *debian*|*ubuntu*|*linuxmint*|*pop*) cmd="sudo apt-get install -y $pkgs" ;;
        *arch*|*manjaro*|*endeavouros*)      cmd="sudo pacman -S --needed $pkgs" ;;
        *fedora*)                            cmd="sudo dnf install -y $pkgs" ;;
        *rhel*|*centos*)                     cmd="sudo dnf install -y $pkgs" ;;
        *opensuse*|*suse*)                   cmd="sudo zypper install -y $pkgs" ;;
        *gentoo*)                            cmd="sudo emerge --ask $pkgs" ;;
        *void*)                              cmd="sudo xbps-install -S $pkgs" ;;
        *)                                   cmd="" ;;
    esac
    printf '%s' "$cmd"
}

# --- KWin detection -----------------------------------------------------------------------
KWIN_BIN=""
for cand in kwin_wayland kwin_x11 kwin; do
    if command -v "$cand" >/dev/null 2>&1; then KWIN_BIN="$cand"; break; fi
done

KWIN_VERSION=""
for cand in kwin_wayland kwin_x11; do
    if command -v "$cand" >/dev/null 2>&1; then
        KWIN_VERSION="$("$cand" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        [[ -n "$KWIN_VERSION" ]] && break
    fi
done

find_libkwin() {
    local p
    # Ask the linker first, then fall back to the usual library directories.
    if command -v ldconfig >/dev/null 2>&1; then
        p="$(ldconfig -p 2>/dev/null | awk '/libkwin\.so\.6 /{print $NF; exit}')"
        [[ -n "$p" && -e "$p" ]] && { printf '%s' "$p"; return; }
    fi
    for p in /usr/lib/*/libkwin.so.6 /usr/lib/libkwin.so.6 /usr/lib64/libkwin.so.6 \
             /usr/lib/*/libkwin.so /usr/lib/libkwin.so; do
        [[ -e "$p" ]] && { printf '%s' "$p"; return; }
    done
}

LIBKWIN="$(find_libkwin)"

log "Environment"
if [[ -n "$KWIN_VERSION" ]]; then
    info "KWin (running binary): $KWIN_BIN $KWIN_VERSION"
else
    dim  "KWin binary not found on PATH; continuing, the build only needs the dev files"
fi
if [[ -n "$LIBKWIN" ]]; then
    info "libkwin: $LIBKWIN"
else
    warn "libkwin.so.6 was not found - the ABI check will be skipped"
fi

# The cmake package is what find_package(KWin) needs.
KWIN_CMAKE_DIR=""
for d in /usr/lib/*/cmake/KWin /usr/lib/cmake/KWin /usr/lib64/cmake/KWin /usr/local/lib/cmake/KWin; do
    if [[ -f "$d/KWinConfig.cmake" ]]; then KWIN_CMAKE_DIR="$d"; break; fi
done
if [[ -n "$KWIN_CMAKE_DIR" ]]; then
    info "KWin cmake package: $KWIN_CMAKE_DIR"
else
    dim  "KWin cmake package: not found yet"
fi

# Dev/runtime mismatch is the single most common cause of a plugin that builds but will not
# load, so surface it before spending time on the build.
if command -v dpkg >/dev/null 2>&1; then
    dev_v="$(dpkg-query -W -f='${Version}' kwin-dev 2>/dev/null)"
    lib_v="$(dpkg-query -W -f='${Version}' libkwin6 2>/dev/null)"
    if [[ -n "$dev_v" && -n "$lib_v" ]]; then
        if [[ "$dev_v" == "$lib_v" ]]; then
            info "kwin-dev / libkwin6 versions agree ($dev_v)"
        else
            warn "kwin-dev ($dev_v) and libkwin6 ($lib_v) differ - the build may not load"
        fi
    fi
elif command -v rpm >/dev/null 2>&1; then
    dev_v="$(rpm -q --qf '%{VERSION}-%{RELEASE}' kwin-devel 2>/dev/null)"
    lib_v="$(rpm -q --qf '%{VERSION}-%{RELEASE}' kwin-libs 2>/dev/null)"
    [[ -n "$dev_v" && "$dev_v" != *"not installed"* ]] && info "kwin-devel: $dev_v"
    [[ -n "$lib_v" && "$lib_v" != *"not installed"* ]] && info "kwin-libs: $lib_v"
fi

# --- Dependency check ---------------------------------------------------------------------
missing=()
for t in cmake c++ nm; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done

PKGS="$(deps_for_distro)"
if (( ${#missing[@]} > 0 )); then
    warn "missing tools: ${missing[*]}"
fi
if [[ -z "$KWIN_CMAKE_DIR" ]]; then
    warn "the KWin development package does not appear to be installed"
fi

if [[ -n "$PKGS" ]]; then
    HINT="$(deps_install_hint "$PKGS")"
    if [[ -n "$HINT" ]]; then
        if (( ${#missing[@]} > 0 )) || [[ -z "$KWIN_CMAKE_DIR" ]]; then
            log "This machine looks like ${DISTRO_ID:-an unknown distribution}"
            if (( DO_INSTALL_DEPS == 1 )); then
                info "running: $HINT"
                eval "$HINT" || die "dependency installation failed"
            else
                info "install what is missing with:"
                printf '        %s\n' "$HINT"
                info "or re-run this script with --install-deps"
                die "missing build dependencies"
            fi
        fi
    fi
else
    if (( ${#missing[@]} > 0 )) || [[ -z "$KWIN_CMAKE_DIR" ]]; then
        log "Unrecognised distribution (${DISTRO_ID:-unknown}); install these yourself:"
        dim  "cmake, a C++20 compiler, extra-cmake-modules, Qt6 base development files,"
        dim  "the KWin development package (KWinConfig.cmake + headers), pkg-config, libdrm, binutils"
        die "missing build dependencies"
    fi
fi

# --- Locate or fetch the sources ----------------------------------------------------------
if [[ -z "$SOURCE_DIR" ]]; then
    if [[ -f "$SCRIPT_DIR/CMakeLists.txt" ]]; then
        SOURCE_DIR="$SCRIPT_DIR"
    else
        SOURCE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/arkpets-integration"
    fi
fi

if [[ -f "$SOURCE_DIR/CMakeLists.txt" ]]; then
    log "Sources: $SOURCE_DIR"
else
    log "Sources: fetching Ark-Pets-Integration into $SOURCE_DIR"
    command -v git >/dev/null 2>&1 || die "git is required to fetch the sources"
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        git -C "$SOURCE_DIR" pull --ff-only || die "could not update $SOURCE_DIR"
    else
        mkdir -p "$(dirname "$SOURCE_DIR")"
        git clone --depth 1 "$REPO_URL" "$SOURCE_DIR" || die "could not clone $REPO_URL"
    fi
fi

[[ -f "$SOURCE_DIR/CMakeLists.txt" ]] || die "$SOURCE_DIR does not look like the KWin plugin source"

if [[ -z "$BUILD_DIR" ]]; then
    BUILD_DIR="$SOURCE_DIR/build"
fi
PLUGIN_SO="$BUILD_DIR/$PLUGIN_REL_PATH"

if (( DO_CLEAN == 1 )); then
    log "Cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# --- ABI verification ---------------------------------------------------------------------
# Every KWin symbol the plugin leaves undefined must be exported by the libkwin on this machine.
# This is the check that catches a mismatched or incomplete kwin-dev package, and the reason the
# script does not simply trust that the build succeeded.
verify_abi() {
    local so="$1"
    if [[ ! -f "$so" ]]; then
        warn "no plugin at $so; nothing to verify"
        return 1
    fi
    if [[ -z "$LIBKWIN" || ! -e "$LIBKWIN" ]]; then
        warn "libkwin not found; cannot verify the ABI"
        return 2
    fi
    command -v nm >/dev/null 2>&1 || { warn "nm not available; cannot verify the ABI"; return 2; }

    local needed have missing_syms count
    needed="$(nm -D --undefined-only "$so" 2>/dev/null | awk '{print $NF}' | grep '^_ZN4KWin' | sort -u)"
    count="$(printf '%s\n' "$needed" | grep -c . || true)"
    if [[ "$count" -eq 0 ]]; then
        warn "the plugin references no KWin symbols at all - that is suspicious"
        return 1
    fi
    have="$(nm -D --defined-only "$LIBKWIN" 2>/dev/null | awk '{print $NF}' | sort -u)"
    missing_syms="$(comm -23 <(printf '%s\n' "$needed") <(printf '%s\n' "$have"))"

    log "ABI check against $LIBKWIN"
    info "$count KWin symbol(s) required by the plugin"
    if [[ -z "$missing_syms" ]]; then
        ok "all of them are exported - the plugin matches this KWin"
        return 0
    fi
    warn "these required symbols are NOT exported by the libkwin on this machine:"
    printf '        %s\n' $missing_syms
    dim  "the plugin was most likely built against a different KWin, or kwin-dev is out of date"
    return 1
}

if (( VERIFY_ONLY == 1 )); then
    verify_abi "$PLUGIN_SO"
    exit $?
fi

# --- Configure and build ------------------------------------------------------------------
log "Configuring"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr >/dev/null || die "cmake configuration failed"

log "Building with $JOBS job(s)"
cmake --build "$BUILD_DIR" -j "$JOBS" || die "build failed"

[[ -f "$PLUGIN_SO" ]] || die "the build finished but $PLUGIN_SO is missing"

log "Built"
info "$PLUGIN_SO"
info "size $(stat -c%s "$PLUGIN_SO" 2>/dev/null || stat -f%z "$PLUGIN_SO") bytes, sha256 $(sha256sum "$PLUGIN_SO" 2>/dev/null | cut -c1-16)"

verify_abi "$PLUGIN_SO" || die "the built plugin does not match this machine's KWin"

# --- Install ------------------------------------------------------------------------------
if (( DO_INSTALL == 1 )); then
    QTPLUG=""
    if command -v qtpaths6 >/dev/null 2>&1; then
        QTPLUG="$(qtpaths6 --query QT_INSTALL_PLUGINS 2>/dev/null)"
    fi
    if [[ -z "$QTPLUG" ]]; then
        for d in /usr/lib/*/qt6/plugins /usr/lib/qt6/plugins /usr/lib64/qt6/plugins; do
            [[ -d "$d" ]] && { QTPLUG="$d"; break; }
        done
    fi
    [[ -n "$QTPLUG" ]] || die "could not locate the Qt 6 plugin directory"
    DEST="$QTPLUG/kwin/plugins"
    log "Installing into $DEST (needs sudo)"
    sudo install -d -m755 "$DEST" || die "could not create $DEST"
    sudo install -m644 "$PLUGIN_SO" "$DEST/${PLUGIN_NAME}.so" || die "could not install the plugin"
    ok "installed $DEST/${PLUGIN_NAME}.so"

    if command -v qdbus6 >/dev/null 2>&1; then
        # Unload first so a replaced file is actually picked up, then load the new one.
        qdbus6 org.kde.KWin /Plugins org.kde.KWin.Plugins.UnloadPlugin "$PLUGIN_NAME" >/dev/null 2>&1 || true
        if qdbus6 org.kde.KWin /Plugins org.kde.KWin.Plugins.LoadPlugin "$PLUGIN_NAME" >/dev/null 2>&1; then
            ok "asked the running KWin to load $PLUGIN_NAME"
        else
            warn "could not load the plugin at runtime; log out and back in once"
        fi
    fi
else
    log "Not installed (pass --install to do it)"
    dim "manual equivalent:"
    dim "  sudo install -m644 '$PLUGIN_SO' \"\$(qtpaths6 --query QT_INSTALL_PLUGINS)/kwin/plugins/${PLUGIN_NAME}.so\""
    dim "  qdbus6 org.kde.KWin /Plugins org.kde.KWin.Plugins.LoadPlugin ${PLUGIN_NAME}"
fi

log "Done"
