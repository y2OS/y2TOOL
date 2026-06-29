#!/bin/sh

PATH="/usr/share/ydisk/bin:$PATH"
export PATH

YDISK_VERSION="1.0"
YDISK_TMPDIR=""
YDISK_MOUNT_POINT=""
YDISK_DD_PID=""
YDISK_SELECTED_DEV=""
YDISK_BACKTITLE="ydisk $YDISK_VERSION — y2OS Storage Utility"

if [ "$(id -u)" -ne 0 ]; then
    printf "Error: ydisk must be run as root.\n" >&2
    exit 1
fi

YDISK_TMPDIR=$(mktemp -d /tmp/ydisk.XXXXXX) || {
    printf "Error: Failed to create temporary directory.\n" >&2
    exit 1
}

cleanup() {
    if [ -n "$YDISK_DD_PID" ]; then
        kill "$YDISK_DD_PID" 2>/dev/null
        wait "$YDISK_DD_PID" 2>/dev/null
    fi

    if [ -n "$YDISK_MOUNT_POINT" ] && grep -q "$YDISK_MOUNT_POINT" /proc/mounts 2>/dev/null; then
        umount -f "$YDISK_MOUNT_POINT" 2>/dev/null
    fi

    if [ -n "$YDISK_TMPDIR" ] && [ -d "$YDISK_TMPDIR" ]; then
        rm -rf "$YDISK_TMPDIR"
    fi

    clear 2>/dev/null
}

trap 'cleanup; printf "\nAborted by user.\n" >&2; exit 130' INT TERM HUP
trap 'cleanup' EXIT

sysfs_read() {
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null | tr -d '\n'
    else
        printf ""
    fi
}

sectors_to_gb() {
    _sectors="${1:-0}"
    echo "$_sectors" | awk '{ printf "%.2f", ($1 * 512) / 1073741824 }'
}

get_model() {
    _dev="$1"
    _model=""

    _model=$(sysfs_read "/sys/class/block/${_dev}/device/model")

    if [ -z "$_model" ]; then
        _model=$(sysfs_read "/sys/class/block/${_dev}/device/name")
    fi

    if [ -z "$_model" ]; then
        _model="Unknown Device"
    fi

    echo "$_model" | sed 's/[[:space:]]*$//'
}

get_mounted_parts() {
    grep -E "^/dev/${1}[p]?[0-9]+" /proc/mounts 2>/dev/null | awk '{print $1}'
}

auto_unmount_device() {
    _dev="$1"
    _fail=0
    _parts=$(get_mounted_parts "$_dev")

    if [ -z "$_parts" ]; then
        return 0
    fi

    echo "$_parts" | while IFS= read -r _part; do
        if [ -n "$_part" ]; then
            umount -f "$_part" 2>/dev/null
            if [ $? -ne 0 ]; then
                _fail=1
            fi
        fi
    done

    _remaining=$(get_mounted_parts "$_dev")
    if [ -n "$_remaining" ]; then
        return 1
    fi

    return 0
}

discover_devices() {
    _count=0
    _menu_items=""

    for _syspath in /sys/class/block/sd* /sys/class/block/nvme*; do
        [ -e "$_syspath" ] || continue

        _devname=$(basename "$_syspath")

        case "$_devname" in
            sd[a-z][0-9]*) continue ;;
            nvme*p[0-9]*)  continue ;;
        esac

        _size_sectors=$(sysfs_read "/sys/class/block/${_devname}/size")
        if [ -z "$_size_sectors" ] || [ "$_size_sectors" = "0" ]; then
            continue
        fi

        _size_gb=$(sectors_to_gb "$_size_sectors")
        _model=$(get_model "$_devname")
        _removable=$(sysfs_read "/sys/class/block/${_devname}/removable")

        if [ "$_removable" = "1" ]; then
            _rmtag="[Removable]"
        else
            _rmtag="[Fixed]"
        fi

        _mounts=$(get_mounted_parts "$_devname")
        if [ -n "$_mounts" ]; then
            _mnttag=" [Mounted]"
        else
            _mnttag=""
        fi

        _label="${_model} — ${_size_gb} GB ${_rmtag}${_mnttag}"
        _menu_items="${_menu_items} ${_devname} \"${_label}\""
        _count=$(( _count + 1 ))
    done

    if [ "$_count" -eq 0 ]; then
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "No Devices Found" \
               --msgbox "No suitable block devices were discovered.\n\nEnsure your USB or NVMe device is properly connected." 8 56
        return 1
    fi

    printf '%s' "$_menu_items" > "${YDISK_TMPDIR}/menu_items"
    printf '%s' "$_count" > "${YDISK_TMPDIR}/dev_count"
    return 0
}

warn_if_not_removable() {
    _dev="$1"
    _removable=$(sysfs_read "/sys/class/block/${_dev}/removable")

    if [ "$_removable" != "1" ]; then
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "⚠ WARNING: Non-Removable Device" \
               --defaultno \
               --yesno "\
The device /dev/${_dev} is NOT marked as removable by the kernel.\n\n\
This could be your system drive, an internal NVMe SSD, or a USB\n\
device whose enclosure does not report the removable flag.\n\n\
Writing to the wrong device will cause PERMANENT DATA LOSS.\n\n\
Are you ABSOLUTELY sure you want to continue with /dev/${_dev}?" 16 64
        return $?
    fi
    return 0
}

select_device() {
    discover_devices || return 1

    _items=$(cat "${YDISK_TMPDIR}/menu_items")
    _count=$(cat "${YDISK_TMPDIR}/dev_count")

    _menu_h=$(( _count + 1 ))
    if [ "$_menu_h" -gt 16 ]; then
        _menu_h=16
    fi

    _result=$(eval "dialog --backtitle \"$YDISK_BACKTITLE\" \
        --title 'Select Target Device' \
        --cancel-label 'Exit' \
        --menu 'Choose a block device to operate on:' \
        $(( _menu_h + 8 )) 70 ${_menu_h} \
        ${_items}" 3>&1 1>&2 2>&3)

    _rc=$?
    if [ $_rc -ne 0 ] || [ -z "$_result" ]; then
        return 1
    fi

    YDISK_SELECTED_DEV="$_result"

    warn_if_not_removable "$YDISK_SELECTED_DEV" || return 1

    _mounted=$(get_mounted_parts "$YDISK_SELECTED_DEV")
    if [ -n "$_mounted" ]; then
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Unmounting Partitions" \
               --infobox "Unmounting all partitions on /dev/${YDISK_SELECTED_DEV}..." 5 56
        sleep 1

        auto_unmount_device "$YDISK_SELECTED_DEV"
        if [ $? -ne 0 ]; then
            dialog --backtitle "$YDISK_BACKTITLE" \
                   --title "Unmount Failed" \
                   --msgbox "Could not unmount one or more partitions on /dev/${YDISK_SELECTED_DEV}.\n\nPlease close all programs using this device and try again." 9 56
            return 1
        fi

        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Unmount Successful" \
               --msgbox "All partitions on /dev/${YDISK_SELECTED_DEV} have been unmounted." 6 56
    fi

    return 0
}

select_action() {
    _dev="$1"
    _model=$(get_model "$_dev")
    _size_sectors=$(sysfs_read "/sys/class/block/${_dev}/size")
    _size_gb=$(sectors_to_gb "$_size_sectors")

    _action=$(dialog --backtitle "$YDISK_BACKTITLE" \
        --title "Action — /dev/${_dev}" \
        --cancel-label "Back" \
        --menu "Device: ${_model} (${_size_gb} GB)\n\nSelect an operation:" \
        14 60 2 \
        "format" "Format & Partition Device" \
        "flash"  "Flash ISO Image to Device" \
        3>&1 1>&2 2>&3)

    _rc=$?
    if [ $_rc -ne 0 ] || [ -z "$_action" ]; then
        return 1
    fi

    case "$_action" in
        format) do_format "$_dev" ;;
        flash)  do_flash "$_dev" ;;
    esac
}

do_format() {
    _dev="$1"

    _fs=$(dialog --backtitle "$YDISK_BACKTITLE" \
        --title "Select Filesystem" \
        --cancel-label "Back" \
        --menu "Choose the filesystem type for /dev/${_dev}:" \
        14 50 5 \
        "ext2"  "Linux ext2" \
        "ext3"  "Linux ext3 (journaled)" \
        "ext4"  "Linux ext4 (journaled)" \
        "fat32" "FAT32 (Windows/Mac compatible)" \
        "exfat" "exFAT (Large file support)" \
        3>&1 1>&2 2>&3)

    _rc=$?
    if [ $_rc -ne 0 ] || [ -z "$_fs" ]; then
        return 1
    fi

    dialog --backtitle "$YDISK_BACKTITLE" \
           --title "⚠ CONFIRM DESTRUCTIVE OPERATION" \
           --defaultno \
           --yesno "\
ALL DATA on /dev/${_dev} will be PERMANENTLY DESTROYED.\n\n\
  Device:     /dev/${_dev}\n\
  Filesystem: ${_fs}\n\n\
This operation CANNOT be undone.\n\nProceed?" 13 56
    if [ $? -ne 0 ]; then
        return 1
    fi

    dialog --backtitle "$YDISK_BACKTITLE" \
           --title "Wiping Partition Table" \
           --infobox "Zeroing first 10 MiB of /dev/${_dev}..." 5 52
    dd if=/dev/zero of="/dev/${_dev}" bs=1M count=10 2>"${YDISK_TMPDIR}/wipe_err.log"
    _wipe_rc=$?
    sync

    if [ "$_wipe_rc" -ne 0 ]; then
        _errmsg=$(cat "${YDISK_TMPDIR}/wipe_err.log" 2>/dev/null)
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: Wipe Failed" \
               --msgbox "Failed to wipe /dev/${_dev}.\n\nExit code: ${_wipe_rc}\n\n${_errmsg}" 12 60
        return 1
    fi

    dialog --backtitle "$YDISK_BACKTITLE" \
           --title "Creating Partition" \
           --infobox "Writing new partition table on /dev/${_dev}..." 5 55

    case "$_fs" in
        ext2|ext3|ext4)  _ptype="83" ;;
        fat32)           _ptype="0c" ;;
        exfat)           _ptype="07" ;;
        *)               _ptype="83" ;;
    esac

    printf ',,0x%s,*\n' "$_ptype" | sfdisk --force "/dev/${_dev}" \
        >"${YDISK_TMPDIR}/sfdisk_out.log" 2>&1
    _sfdisk_rc=$?

    if [ "$_sfdisk_rc" -ne 0 ]; then
        _errmsg=$(cat "${YDISK_TMPDIR}/sfdisk_out.log" 2>/dev/null)
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: Partitioning Failed" \
               --msgbox "sfdisk exited with code ${_sfdisk_rc}.\n\n${_errmsg}" 12 64
        return 1
    fi

    sleep 1

    case "$_dev" in
        nvme*) _part="/dev/${_dev}p1" ;;
        *)     _part="/dev/${_dev}1" ;;
    esac

    _wait=0
    while [ ! -b "$_part" ] && [ "$_wait" -lt 10 ]; do
        sleep 1
        _wait=$(( _wait + 1 ))
    done

    if [ ! -b "$_part" ]; then
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: Partition Missing" \
               --msgbox "Expected partition ${_part} did not appear after partitioning.\n\nThe kernel may not have re-read the partition table." 9 64
        return 1
    fi

    dialog --backtitle "$YDISK_BACKTITLE" \
           --title "Formatting" \
           --infobox "Creating ${_fs} filesystem on ${_part}..." 5 55

    case "$_fs" in
        ext2)
            mkfs.ext2 -F "$_part" >"${YDISK_TMPDIR}/mkfs_out.log" 2>&1
            ;;
        ext3)
            mkfs.ext3 -F "$_part" >"${YDISK_TMPDIR}/mkfs_out.log" 2>&1
            ;;
        ext4)
            mkfs.ext4 -F "$_part" >"${YDISK_TMPDIR}/mkfs_out.log" 2>&1
            ;;
        fat32)
            mkfs.vfat -F 32 "$_part" >"${YDISK_TMPDIR}/mkfs_out.log" 2>&1
            ;;
        exfat)
            mkfs.exfat "$_part" >"${YDISK_TMPDIR}/mkfs_out.log" 2>&1
            ;;
    esac
    _mkfs_rc=$?

    if [ "$_mkfs_rc" -ne 0 ]; then
        _errmsg=$(cat "${YDISK_TMPDIR}/mkfs_out.log" 2>/dev/null)
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: Format Failed" \
               --msgbox "mkfs exited with code ${_mkfs_rc}.\n\n${_errmsg}" 12 64
        return 1
    fi

    sync

    dialog --backtitle "$YDISK_BACKTITLE" \
           --title "Format Complete" \
           --msgbox "\
Device /dev/${_dev} has been successfully formatted.\n\n\
  Partition:  ${_part}\n\
  Filesystem: ${_fs}\n\n\
You may now safely remove or mount the device." 11 56

    return 0
}

do_flash() {
    _dev="$1"

    _iso=$(dialog --backtitle "$YDISK_BACKTITLE" \
        --title "ISO Image Path" \
        --cancel-label "Back" \
        --inputbox "Enter the absolute path to the ISO image:" \
        9 64 "" \
        3>&1 1>&2 2>&3)

    _rc=$?
    if [ $_rc -ne 0 ] || [ -z "$_iso" ]; then
        return 1
    fi

    if [ ! -f "$_iso" ]; then
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: File Not Found" \
               --msgbox "The specified file does not exist:\n\n${_iso}" 8 64
        return 1
    fi

    if [ ! -r "$_iso" ]; then
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: Permission Denied" \
               --msgbox "Cannot read the ISO file:\n\n${_iso}\n\nCheck file permissions." 9 64
        return 1
    fi

    _iso_bytes=$(wc -c < "$_iso" 2>/dev/null | tr -d ' ')
    _iso_mb=$(echo "$_iso_bytes" | awk '{ printf "%.1f", $1 / 1048576 }')
    _iso_basename=$(basename "$_iso")

    dialog --backtitle "$YDISK_BACKTITLE" \
           --title "⚠ CONFIRM DESTRUCTIVE OPERATION" \
           --defaultno \
           --yesno "\
ALL DATA on /dev/${_dev} will be PERMANENTLY DESTROYED.\n\n\
  Image:  ${_iso_basename} (${_iso_mb} MB)\n\
  Target: /dev/${_dev}\n\n\
This operation CANNOT be undone.\n\nProceed?" 13 60
    if [ $? -ne 0 ]; then
        return 1
    fi

    _dd_exit_file="${YDISK_TMPDIR}/dd_exit.tmp"
    _dd_err_file="${YDISK_TMPDIR}/dd_err.log"

    printf '' > "$_dd_exit_file"
    printf '' > "$_dd_err_file"

    (
        pv -n "$_iso" 2>&1 | \
        (
            dd of="/dev/${_dev}" bs=4M conv=fdatasync,fsync status=none 2>"$_dd_err_file"
            echo $? > "$_dd_exit_file"
        )
    ) 2>&1 | dialog --backtitle "$YDISK_BACKTITLE" \
                     --title "Flashing: ${_iso_basename}" \
                     --gauge "Writing image to /dev/${_dev}...\n\nSize: ${_iso_mb} MB — Do not remove the device." 10 64 0

    _dd_rc=""
    if [ -f "$_dd_exit_file" ]; then
        _dd_rc=$(cat "$_dd_exit_file" 2>/dev/null | tr -d '[:space:]')
    fi

    if [ -z "$_dd_rc" ]; then
        _dd_rc=1
    fi

    if [ "$_dd_rc" -eq 0 ]; then
        sync
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Flash Successful" \
               --msgbox "\
Image has been successfully written to /dev/${_dev}.\n\n\
  Image:  ${_iso_basename}\n\
  Size:   ${_iso_mb} MB\n\n\
You may now safely remove the device." 11 56
    else
        _errmsg=$(cat "$_dd_err_file" 2>/dev/null)
        if [ -z "$_errmsg" ]; then
            _errmsg="(no error output captured)"
        fi
        dialog --backtitle "$YDISK_BACKTITLE" \
               --title "Error: Flash Failed" \
               --msgbox "\
Failed to write image to /dev/${_dev}.\n\n\
Exit code: ${_dd_rc}\n\n\
${_errmsg}" 14 64
        return 1
    fi

    return 0
}

main() {
    while :; do
        select_device || break
        select_action "$YDISK_SELECTED_DEV"
    done
}

main
exit 0
