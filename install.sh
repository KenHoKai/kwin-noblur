#!/usr/bin/env bash
# KWin NoBlur installer
# Arch Linux and Arch-based distributions, x86_64.

set -Eeuo pipefail

REPO_URL="https://github.com/KenHoKai/kwin-noblur.git"
RELEASE_TAG="kwin-noblur-6.8.2-2"
BACKUP_DIR="${HOME}/kwin-backup"

WORK_DIR=""
BACKUP_STAGE=""

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${BACKUP_STAGE:-}" && -d "$BACKUP_STAGE" ]]; then
        rm -rf -- "$BACKUP_STAGE"
    fi

    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------
# System checks
# --------------------------------------------------

(( EUID != 0 )) ||
    die "Do not run this installer as root."

[[ "$(uname -m)" == "x86_64" ]] ||
    die "Only x86_64 is supported."

command -v pacman >/dev/null 2>&1 ||
    die "This installer requires Arch Linux or an Arch-based distribution."

[[ -r /dev/tty ]] ||
    die "Run this installer from an interactive terminal."

command -v sudo >/dev/null 2>&1 ||
    die "sudo is required."

sudo -v ||
    die "Could not obtain sudo privileges."

# --------------------------------------------------
# Dependencies
# --------------------------------------------------

info "Checking build dependencies..."

sudo pacman -S --needed git base-devel zstd

command -v git >/dev/null 2>&1 ||
    die "Git is unavailable."

command -v makepkg >/dev/null 2>&1 ||
    die "makepkg is unavailable."

command -v zstd >/dev/null 2>&1 ||
    die "Zstandard is unavailable."

# --------------------------------------------------
# Installation options
# --------------------------------------------------

printf '\n'
printf 'KWin NoBlur\n'
printf '%s\n' '----------------------------------------'
printf '1) Build and install (default; no backup)\n'
printf '2) Back up installed KWin, then build and install\n'
printf '%s\n\n' '----------------------------------------'

read -r -p "Choose [1/2] (default: 1): " choice </dev/tty

choice="${choice:-1}"

[[ "$choice" == "1" || "$choice" == "2" ]] ||
    die "Invalid choice."

if [[ "$choice" == "2" && -e "$BACKUP_DIR" ]]; then
    die "Backup destination already exists: $BACKUP_DIR. Move or rename it first."
fi

# --------------------------------------------------
# Download released source
# --------------------------------------------------

WORK_DIR="$(mktemp -d -t kwin-noblur.XXXXXX)"
SOURCE_DIR="$WORK_DIR/source"

info "Downloading KWin NoBlur ${RELEASE_TAG}..."

git -c advice.detachedHead=false clone \
    --depth 1 \
    --single-branch \
    --branch "$RELEASE_TAG" \
    "$REPO_URL" \
    "$SOURCE_DIR" ||
    die "Could not download the release."

PKGBUILD_DIR="$SOURCE_DIR/packaging/arch"

[[ -f "$PKGBUILD_DIR/PKGBUILD" ]] ||
    die "PKGBUILD not found."

[[ -f "$PKGBUILD_DIR/.SRCINFO" ]] ||
    die ".SRCINFO not found."

cd "$PKGBUILD_DIR"

grep -qx 'pkgname=kwin-noblur' PKGBUILD ||
    die "Unexpected package name."

grep -qx 'pkgver=6.8.2' PKGBUILD ||
    die "Unexpected package version."

grep -qx 'pkgrel=2' PKGBUILD ||
    die "Unexpected package release revision."

# --------------------------------------------------
# Optional KWin backup
# --------------------------------------------------

if [[ "$choice" == "2" ]]; then

    KWIN_PACKAGE=""

    for candidate in kwin-noblur kwin; do
        if pacman -Q "$candidate" >/dev/null 2>&1; then
            KWIN_PACKAGE="$candidate"
            break
        fi
    done

    [[ -n "$KWIN_PACKAGE" ]] ||
        die "No installed KWin package was found."

    info "Preparing backup of $KWIN_PACKAGE..."

    BACKUP_STAGE="$(mktemp -d "$HOME/.kwin-backup.tmp.XXXXXX")"

    pacman -Q "$KWIN_PACKAGE" \
        > "$BACKUP_STAGE/package-version.txt"

    pacman -Qlq "$KWIN_PACKAGE" |
        sed 's#^/##' \
        > "$BACKUP_STAGE/file-list.txt"

    [[ -s "$BACKUP_STAGE/file-list.txt" ]] ||
        die "The KWin package file list is empty."

    archive="$BACKUP_STAGE/${KWIN_PACKAGE}-files.tar.zst"
    partial="$archive.partial"

    file_count="$(wc -l < "$BACKUP_STAGE/file-list.txt")"

    info "Backing up $file_count package entries."
    info "Progress: one dot per 100 archived entries."

    if ! sudo tar \
        --create \
        --file=- \
	--directory=/ \
	--no-recursion \
	--files-from="$BACKUP_STAGE/file-list.txt" \
        --numeric-owner \
        --acls \
        --xattrs \
        --checkpoint=100 \
        --checkpoint-action=dot \
        | zstd -q -T0 -1 -o "$partial"; then

        die "Backup failed. Temporary files will be cleaned up."
    fi

    zstd -t "$partial" ||
        die "Backup archive verification failed."

    mv -- "$partial" "$archive"

    cat > "$BACKUP_STAGE/README.txt" <<README
KWin NoBlur - KWin backup

Original installed package:
$(cat "$BACKUP_STAGE/package-version.txt")

Backup archive:
${KWIN_PACKAGE}-files.tar.zst

Backup location:
${BACKUP_DIR}

The archive contains package-owned files, permissions,
ownership, ACLs and extended attributes.

Manual file restoration:

sudo tar --zstd -xpf \
"${BACKUP_DIR}/${KWIN_PACKAGE}-files.tar.zst" \
-C / --numeric-owner --same-owner --same-permissions

Note:
This restores files but does not roll back pacman's package database.
Your personal KDE configuration is not included.
README

    mv -- "$BACKUP_STAGE" "$BACKUP_DIR"
    BACKUP_STAGE=""

    info "Backup completed successfully."
    info "Backup location: $BACKUP_DIR"
fi

# --------------------------------------------------
# Build and install
# --------------------------------------------------

printf '\n'

info "Starting KWin NoBlur package build."
info "Build directory: $PKGBUILD_DIR"

makepkg -si

# --------------------------------------------------
# Verify installation
# --------------------------------------------------

printf '\n'

pacman -Q kwin-noblur ||
    die "Could not verify the installed KWin NoBlur package."

info "KWin NoBlur installation completed."

warn "Review pacman's installation transaction carefully."
warn "Log out and back in, or reboot, to replace the running KWin session."

if [[ "$choice" == "2" ]]; then
    info "Your KWin backup is stored at: $BACKUP_DIR"
fi
