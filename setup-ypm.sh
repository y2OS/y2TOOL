#!/bin/sh
# ypm non-y2OS installer script

set -e

YPM_ROOT="/ypm"
YPM_DB="${YPM_ROOT}/db"
YPM_BIN_DEST="/usr/local/bin/ypm"
YPM_SOURCE_URL="https://raw.githubusercontent.com/y2OS/y2TOOL/main/ypm.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)." >&2
    exit 1
fi

for cmd in wget tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required dependency '$cmd' is missing." >&2
        exit 1
    fi
done

mkdir -p "${YPM_ROOT}" "${YPM_DB}"
chown -R root:root "${YPM_ROOT}"
chmod 755 "${YPM_ROOT}" "${YPM_DB}"

if wget -qO "${YPM_BIN_DEST}" "${YPM_SOURCE_URL}"; then
    chmod +x "${YPM_BIN_DEST}"
    echo "Success: ypm has been installed to ${YPM_BIN_DEST}"
    echo "You can now run 'sudo ypm' from your terminal."
else
    echo "Error: Failed to download ypm script from GitHub." >&2
    exit 1
fi
