#!/bin/sh

set -e

PKG_NAME="yservice"
PKG_VER="1.0"
BUILD_DIR="/tmp/ypm-build-${PKG_NAME}"

printf "==> Building %s-%s.ypm\n" "$PKG_NAME" "$PKG_VER"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/usr/bin"
mkdir -p "${BUILD_DIR}/etc/yservice"

# Compile the C source statically
gcc -static -O2 yservice.c -o "${BUILD_DIR}/usr/bin/yservice"
strip "${BUILD_DIR}/usr/bin/yservice"

# Create default conf.y template
cat << 'EOF' > "${BUILD_DIR}/etc/yservice/conf.y"
# /etc/yservice/conf.y — y2OS Service Manager Configuration
# Format: level:service_name:healthcheck_type:healthcheck_target
#
# Healthcheck types:
#   file    — check if a file/socket exists
#   process — check if a process is running (pidof)
#   command — run a command and check exit code (0 = healthy)
#
# Services within the same level boot in parallel.
# Levels are processed sequentially (0 → max).

0:udev:file:/proc/sys/kernel/hotplug
0:syslog:process:syslogd
1:network:command:ping -c 1 -w 1 1.1.1.1
EOF

# Create .ypm archive
cd "${BUILD_DIR}"
tar -czvf "/tmp/${PKG_NAME}-${PKG_VER}.ypm" usr etc

printf "\n==> Package created: /tmp/%s-%s.ypm\n" "$PKG_NAME" "$PKG_VER"
printf "    Build root: %s\n" "${BUILD_DIR}"
printf "    Contents:\n"
find usr etc -type f | sed 's/^/      /'
printf "\n==> Done.\n"
