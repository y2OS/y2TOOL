# y2TOOL

y2TOOL is a repository created to host packages for the y2OS ecosystem

## Tools

### `y2-install`
A `dialog`-based TUI tool that performs the installation of the y2OS system.
- **Features:** Disk partitioning (fdisk), file system creation (ext4/vfat), Limine bootloader integration, keyboard and language configuration, Nix daemon and D-Bus installation, user/password management.
- **Dependencies:** `dialog`, `fdisk`, `limine`, `busybox` (or compatible coreutils tools).

### `ywifi`
A networking tool that allows you to manage Wi-Fi and Ethernet connections via the terminal.
- **Features:** Dynamic network interface detection, IP configuration via DHCP, connecting to encrypted/unencrypted Wi-Fi networks, connection status verification.
- **Dependencies:** The following packages must be installed on the system for this tool to work:
  - `dialog` (for the interface)
  - `wpa_supplicant` and `wpa_cli` (for Wi-Fi management)
  - `udhcpc` (for IP address assignment)
  - `iproute2` (to bring up network interfaces—`ip` command)

### `ypm`
A shell-based package manager that installs and manages packages on the system in an isolated manner via symbolic links (symlinks).
- **Features:** Multi-version support (switch active version with `use`), clean up old versions (`max`), preserve versions (`save`), and download and install `tar.gz` files directly from GitHub.
- **Dependencies:** `wget`, `tar`.

For more information, visit https://github.com/y2OS/ypm

### `setup-ypm.sh`
ypm supports non-y2OS distributions. Please note that this is experimental and there is no guarantee that it will work on every system.

- To run the script:
  - Download it
  - Navigate to the directory where the file is located
  - Grant execution permission with the command `chmod +x setup-ypm.sh`
  - Run it with the command `sudo ./setup-ypm.sh`

For more information, visit https://github.com/y2OS/ypm

### `ydisk`
A `dialog`-based TUI storage utility designed for disk partitioning, formatting, and ISO image flashing.
- **Features:** Automated sysfs-based kernel hardware discovery (SCSI/SATA/NVMe), non-removable disk safety gates, multi-filesystem formatting (`ext2/3/4`, `fat32`, `exfat`) via `sfdisk`, and robust non-blocking ISO flashing using `pv` and `dd` with strict process exit code validation.
- **Dependencies:** `dialog`, `pv`, `dd`, `sfdisk`, and native filesystem tools (`mkfs.ext*`, `mkfs.vfat`, `mkfs.exfat`).

---

## License

This repository is licensed under the Apache License 2.0
