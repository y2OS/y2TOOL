#!/bin/sh
# y2OS Installer

if ! command -v dialog >/dev/null 2>&1; then
    echo "Error: 'dialog' is not installed."
    exit 1
fi

HOST_NAME=$(dialog --clear --title "System Settings" --inputbox "Enter Hostname (e.g., y2os-pc):" 10 50 "" 2>&1 >/dev/tty)
[ $? -ne 0 ] && exit 0

ROOT_PASS=$(dialog --clear --title "System Settings" --insecure --passwordbox "Enter Root Password:" 10 50 2>&1 >/dev/tty)
[ $? -ne 0 ] && exit 0

USER_NAME=$(dialog --clear --title "System Settings" --inputbox "Enter New Username:" 10 50 "" 2>&1 >/dev/tty)
[ $? -ne 0 ] && exit 0

USER_PASS=$(dialog --clear --title "System Settings" --insecure --passwordbox "Enter password for '$USER_NAME':" 10 50 2>&1 >/dev/tty)
[ $? -ne 0 ] && exit 0

KEY_INPUT=$(dialog --clear --title "System Settings" --inputbox "Enter Keyboard Layout (e.g., trq, trf, en):" 10 50 "" 2>&1 >/dev/tty)
[ $? -ne 0 ] && exit 0

set --
for dev in $(cat /proc/partitions | awk 'NR>2 {print $4}' | grep -E '^[hs]d[a-z]$|^vd[a-z]$|^nvme[0-9]n[0-9]$'); do
    SIZE_SECTORS=$(cat /sys/block/$dev/size)
    SIZE_GB=$((SIZE_SECTORS * 512 / 1024 / 1024 / 1024))
    set -- "$@" "/dev/$dev" "${SIZE_GB} GB"
done

if [ $# -eq 0 ]; then
    dialog --msgbox "No physical disks found!" 8 40
    exit 1
fi

TARGET_DISK=$(dialog --clear --title "Disk Selection" --menu "Select TARGET DISK for installation:" 15 50 5 "$@" 2>&1 >/dev/tty)
[ -z "$TARGET_DISK" ] && exit 0

dialog --title "WARNING: DATA DESTRUCTION" --yesno "Target: $TARGET_DISK\n\nALL DATA ON THIS DISK WILL BE DESTROYED!\n\nDo you want to proceed?" 10 50
if [ $? -ne 0 ]; then
    dialog --infobox "Installation aborted." 5 30
    sleep 2
    clear
    exit 0
fi

dialog --infobox "Starting installation on $TARGET_DISK...\nPlease wait, this may take a few minutes." 5 60

if echo "$TARGET_DISK" | grep -q "nvme"; then
    PART_EFI="${TARGET_DISK}p1"
    PART_ROOT="${TARGET_DISK}p2"
else
    PART_EFI="${TARGET_DISK}1"
    PART_ROOT="${TARGET_DISK}2"
fi

dmesg -n 1 

exec 3>&1 4>&2

LOG="/var/log/y2install.log"
exec >"$LOG" 2>&1

dd if=/dev/zero of="$TARGET_DISK" bs=1M count=1
printf "o\nn\np\n1\n\n+100M\nt\nc\nn\np\n2\n\n\nw\n" | fdisk "$TARGET_DISK"

mkfs.vfat "$PART_EFI"
mkfs.ext4 -q "$PART_ROOT"

ROOT_PARTUUID=$(blkid "$PART_ROOT" | grep -o 'PARTUUID="[^"]*"' | cut -d'"' -f2)
EFI_UUID=$(blkid "$PART_EFI" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)

if [ -z "$ROOT_PARTUUID" ]; then
    KERNEL_ROOT="root=$PART_ROOT"
else
    KERNEL_ROOT="root=PARTUUID=$ROOT_PARTUUID"
fi

mkdir -p /mnt/target
mount -t ext4 "$PART_ROOT" /mnt/target

mkdir -p /mnt/target/boot/efi
mount -t vfat "$PART_EFI" /mnt/target/boot/efi

for dir in bin boot etc lib lib64 root sbin usr var ypm; do
    if [ -d "/$dir" ]; then
        cp -a "/$dir" /mnt/target/
    fi
done

chown -R root:root /mnt/target
mkdir -p /mnt/target/dev /mnt/target/proc /mnt/target/sys /mnt/target/tmp /mnt/target/mnt /mnt/target/home
mknod -m 666 /mnt/target/dev/null c 1 3
mknod -m 600 /mnt/target/dev/console c 5 1

mkdir -p /mnt/target/boot/efi/EFI/BOOT
cp /mnt/target/boot/BOOTX64.EFI /mnt/target/boot/efi/EFI/BOOT/BOOTX64.EFI
cp /mnt/target/boot/bzImage /mnt/target/boot/efi/EFI/BOOT/bzImage

cat <<EOF > /mnt/target/boot/efi/EFI/BOOT/limine.conf
timeout: 3

/y2OS by YsFsystem (UEFI)
    protocol: linux
    kernel_path: boot():/EFI/BOOT/bzImage
    cmdline: $KERNEL_ROOT rw rootwait devtmpfs.mount=1 init=/sbin/init console=tty1 loglevel=7 rootfstype=ext4
EOF

if [ -n "$ROOT_PARTUUID" ]; then
    echo "PARTUUID=$ROOT_PARTUUID  /          ext4  defaults  0  1" > /mnt/target/etc/fstab
else
    echo "$PART_ROOT             /          ext4  defaults  0  1" > /mnt/target/etc/fstab
fi

if [ -n "$EFI_UUID" ]; then
    echo "UUID=$EFI_UUID        /boot/efi  vfat  defaults  0  2" >> /mnt/target/etc/fstab
else
    echo "$PART_EFI             /boot/efi  vfat  defaults  0  2" >> /mnt/target/etc/fstab
fi

echo "$HOST_NAME" > /mnt/target/etc/hostname

if [ "$KEY_INPUT" = "trq" ]; then
    TTY_MAP="trq"
    X11_MAP="tr"
    X11_VAR=""
elif [ "$KEY_INPUT" = "trf" ]; then
    TTY_MAP="trf"
    X11_MAP="tr"
    X11_VAR="f"
else
    TTY_MAP="$KEY_INPUT"
    X11_MAP="$KEY_INPUT"
    X11_VAR=""
fi

sed -i "/Sanal Dosya Sistemlerini/i \\
# Set Hostname\\
if [ -f /etc/hostname ]; then\\
    /bin/hostname -F /etc/hostname\\
fi\\
\\
# Set Keyboard Layout\\
/usr/bin/loadkeys $TTY_MAP 2>/dev/null\\
\\
# D-Bus Daemon\\
mkdir -p /var/run/dbus\\
if [ ! -f /var/lib/dbus/machine-id ]; then\\
    /usr/bin/dbus-uuidgen > /var/lib/dbus/machine-id\\
fi\\
/usr/bin/dbus-daemon --system --fork\\
\\
# Nix Daemon\\
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt\\
/usr/bin/nix-daemon > /var/log/nix-daemon.log 2>&1 &\\
" /mnt/target/etc/init.d/rcS

mkdir -p /mnt/target/etc/X11/xorg.conf.d
cat <<EOF > /mnt/target/etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$X11_MAP"
    Option "XkbVariant" "$X11_VAR"
EndSection
EOF

mkdir -p /mnt/target/etc
echo "/bin/sh" > /mnt/target/etc/shells
echo "/bin/zsh" >> /mnt/target/etc/shells

chroot /mnt/target /bin/sh -c "echo 'root:$ROOT_PASS' | chpasswd"
chroot /mnt/target /bin/sh -c "addgroup -S wheel 2>/dev/null"
mkdir -p /mnt/target/home/$USER_NAME

chroot /mnt/target /bin/sh -c "adduser -D -h /home/$USER_NAME -s /bin/zsh $USER_NAME"
chroot /mnt/target /bin/sh -c "echo '$USER_NAME:$USER_PASS' | chpasswd"
chroot /mnt/target /bin/sh -c "addgroup $USER_NAME wheel"

sed -i 's|-n -l /bin/sh ||g' /mnt/target/etc/inittab

cat <<EOF > /mnt/target/home/$USER_NAME/.zprofile
#!/bin/zsh
export TERM=xterm-256color
if [ "\$(tty)" = "/dev/tty1" ]; then
    exec /bin/startx
fi
EOF

if [ -f /mnt/target/etc/skel/.zshrc ]; then
    cp /mnt/target/etc/skel/.zshrc /mnt/target/home/$USER_NAME/.zshrc
fi

if [ -f /mnt/target/etc/skel/.xinitrc ]; then
    cp /mnt/target/etc/skel/.xinitrc /mnt/target/home/$USER_NAME/.xinitrc
    sed -i '/exec .*dwm/i \
pulseaudio --start &\
' /mnt/target/home/$USER_NAME/.xinitrc
fi

chroot /mnt/target /bin/sh -c "chown -R $USER_NAME:$USER_NAME /home/$USER_NAME"

for group in audio video input cdrom disk lp kvm; do
    chroot /mnt/target /bin/sh -c "addgroup -S $group 2>/dev/null"
    chroot /mnt/target /bin/sh -c "addgroup $USER_NAME $group 2>/dev/null"
done

chroot /mnt/target /bin/sh -c "chmod 4755 /bin/busybox"
chroot /mnt/target /bin/sh -c "chmod 4755 /ypm/doas/6.8.2/bin/doas"
chroot /mnt/target /bin/sh -c "chmod 4755 /ypm/xorg/1.22/bin/Xorg"

cat <<EOF > /mnt/target/etc/doas.conf
permit :wheel
EOF
chroot /mnt/target /bin/sh -c "chown root:root /etc/doas.conf"
chroot /mnt/target /bin/sh -c "chmod 0400 /etc/doas.conf"

chroot /mnt/target /bin/sh -c "addgroup -S nixbld 2>/dev/null"
for i in $(seq 1 10); do
    chroot /mnt/target /bin/sh -c "adduser -S -D -H -h /var/empty -s /bin/false -G nixbld nixbld$i 2>/dev/null"
done

sync
umount /mnt/target/boot/efi
umount /mnt/target

exec 1>&3 2>&4

dmesg -n 7 

dialog --title "Installation Complete" --yesno "y2OS has been successfully installed!\n\nDo you want to reboot the system now?" 8 50
if [ $? -eq 0 ]; then
    clear
    reboot
else
    clear
fi
