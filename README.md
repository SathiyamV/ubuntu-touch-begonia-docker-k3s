# Docker + k3s kernel for Ubuntu Touch on the Redmi Note 8 Pro (begonia)

A small config change to the UBports `kernel-xiaomi-mt6785` kernel so that **Docker and k3s (Kubernetes) run natively** on
Ubuntu Touch 24.04 (Halium 10, kernel 4.14.141). Tested on one phone, on 2026-11-26. No source code was changed: only
kernel config options, a different `boot.img` command line, and install scripts.

> **Warning.** Flashing the `boot` partition can leave a phone that does not start. You need an **unlocked bootloader**
> and `fastboot`. Keep a copy of your stock `boot.img` first. This is only tested on `begonia` with the UBports build
> `4.14.141-g4c74d0e84`. An Ubuntu Touch OTA update overwrites `boot` and removes this kernel. Use at your own risk.

## What changed
Added to `begonia_user_defconfig` (all `=y`, no new modules; see `config/docker-k3s.config`):
`CGROUP_PIDS`, `CFS_BANDWIDTH`, `POSIX_MQUEUE`, `NETFILTER_XT_MATCH_{ADDRTYPE,MULTIPORT,RECENT,PHYSDEV}`, `VXLAN`, `DUMMY`, `MACVLAN`.
`POSIX_MQUEUE` is mandatory: `runc` always mounts `/dev/mqueue`, without it no container starts.
Boot command line gets `systemd.unified_cgroup_hierarchy=0` (cgroup v1), because the 4.14 kernel has no `cpu` controller
in cgroup v2. Ubuntu Touch's Android container, Wi-Fi, modem services and the battery readings all still worked.

Deliberately NOT enabled (they change widely shared structs the stock vendor Wi-Fi/BT/GPS modules rely on): `NF_TABLES`,
`IP_VS`, `BLK_CGROUP`. Layout check (clang `-fdump-record-layouts`, stock vs this build): the only structs that differ are
`cgroup`, `cgroup_root`, `css_set`, `user_struct`; none of the 9 vendor modules use them (`recipe/diff-names.txt`).

## Files
| path | what |
|---|---|
| *(GitHub Release)* `boot-cgv1-mq.img` | **the one to flash**: custom kernel + cgroup v1 + POSIX_MQUEUE |
| *(GitHub Release)* `boot-stock-ubuntu-touch-original.img` | the stock UBports `boot.img` from the author's phone, for rollback (use your own phone's backup if you can) |
| `config/` | final `.config`, the config fragment, the stock `/proc/config.gz` of the running phone |
| `recipe/` | toolchain env, `mkbootimg` arguments, layout probe, source commit |
| `scripts/` | `install-docker-on-phone.sh`, `install-k3s-on-phone.sh`, test and uninstall scripts |
| `SHA256SUMS` | checksums of everything |

## Build it yourself
Kernel source: `https://gitlab.com/ubports/community-ports/android10/xiaomi-redmi-note-8-pro/kernel-xiaomi-mt6785`, branch
`halium-10.0`, commit in `recipe/kernel-source-commit.txt`. Toolchain: Android clang r353983c + GCC 4.9 prebuilts (the
UBports device repo's `build.sh -c` downloads them). `make begonia_user_defconfig` reproduces the stock config exactly;
append `config/docker-k3s.config`, `make olddefconfig`, build with `CC=clang`, then repack with `mkbootimg`
(arguments in `recipe/mkbootimg-args-stock-layout.txt`, add `systemd.unified_cgroup_hierarchy=0` to `--cmdline`,
keep the stock ramdisk and dtb).

## Flash and roll back
```
fastboot flash boot boot-cgv1-mq.img && fastboot reboot      # install
fastboot flash boot boot-stock-ubuntu-touch-original.img      # roll back (Volume Down + Power for fastboot)
```
Note: `fastboot boot <image>` crashes this bootloader (LK) and silently falls back to the flashed kernel, so it cannot be
used for testing; always check with `cat /proc/version` and `zcat /proc/config.gz | grep CGROUP_PIDS`.

## Docker and k3s
Static Docker 29.10.0 (data in `/home`), k3s `v1.34.13+k3s1` (Kubernetes 1.35+ refuses cgroup v1). The root filesystem
stays read-only; k3s needs bind mounts from `/home` over `/var/lib/kubelet`, `/var/lib/cni`, `/var/log/pods`,
`/var/log/containers`, `/etc/rancher/node` (see `scripts/install-k3s-on-phone.sh`). The scripts use the placeholder `<PHONE_IP>` (your phone's Wi-Fi
address) and the interface `wlan0`: replace them first, e.g. `sed -i 's/<PHONE_IP>/192.168.1.50/g' scripts/*.sh`; the scripts refuse to run until you do.

## Licence
Kernel and config: GPL-2.0 (same as the Linux kernel); the ramdisk and device tree inside the images come unmodified from
UBports/Halium. Scripts: MIT.
