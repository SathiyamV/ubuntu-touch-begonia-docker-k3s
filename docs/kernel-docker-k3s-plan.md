# Native Docker + k3s on the Redmi (custom kernel): plan, risks, rollback

Status 2026-11-25: researched and prepared. **Nothing downloaded, built or flashed yet** (the download step was blocked by the permission system and needs your explicit yes).

## What we verified
- The port's kernel repo exists: `gitlab.com/ubports/porting/community-ports/android10/xiaomi-redmi-note-8-pro/kernel-xiaomi-mt6785`, branch `halium-10.0`. Its newest commit is **`4c74d0e8`** (2026-07-09), exactly the `g4c74d0e84` in `uname -r` on the phone. So we can rebuild the *same* source, plus extra options.
- Build recipe is in the device repo (`xiaomi-begonia`): defconfig `begonia_user_defconfig`, Android clang `r353983c` (Halium 10), prebuilt Halium ramdisk, output `boot.img`. Wrapper: `scripts/kernel-build.sh`. Options to add: `kernel/docker-k3s.config`.
- Bootloader is unlocked (`verifiedbootstate=orange`). Partitions include `boot`, `vbmeta`, `dtbo`, `userdata`; the root/data are LVM volumes, so changing `boot` does not touch your data.
- Laptop: 16 cores, 15 GB RAM, 26 GB free disk, has `fastboot`, `adb`, `mkbootimg`. Clang comes from the download, not the laptop.

## The risks (the honest list)
1. **Wi-Fi/Bluetooth/GPS modules are Xiaomi's stock ones** in `/android/vendor/lib/modules`, force-loaded. If the new kernel changes struct layouts they rely on, Wi-Fi can fail and the phone would boot *without SSH*. Mitigation: only built-in (`=y`) options, and **no `NF_TABLES`, no `IP_VS`** (those change `struct net`). Recovery: reflash the stock boot image over USB.
2. **cgroups:** Kubernetes needs the cgroup v2 controllers only on kernel 5.8+ (this is 4.14), and Docker on 4.14 also wants cgroup v1. Ubuntu Touch runs a pure cgroup v2 hierarchy (the Android container sits in it). So k3s/Docker need booting with the kernel argument `systemd.unified_cgroup_hierarchy=0` (hybrid/v1). That could upset the Android container (modem, Wi-Fi). **Not known to work**; it is stage 2 and is tested separately.
3. **OTA updates** replace `boot` with the stock kernel: Docker/k3s stops working until we reflash ours.
4. **Downtime:** a few minutes per test (server offline). The battery guard, Jellyfin, DNS (AdGuard!) are all down while it boots, so home DNS is down too.
5. Real danger is low (no modem/IMEI partitions are touched) but not zero. A boot loop is recoverable with fastboot as long as we keep a copy of the stock boot image.

## Stages, each with a gate
| Stage | What | Phone risk | Gate / rollback |
|---|---|---|---|
| 0 | Download (~2-4 GB), reproduce the stock config, compare with the phone's `/proc/config.gz` | none | nothing leaves the laptop |
| 0b | Build kernel with our options -> `boot.img` | none | check the new `.config` has every option `=y` |
| 1 | **Back up** the phone's `boot` partition (root script you run), then `fastboot boot new.img` (temporary boot; reboot = back to stock). Check Wi-Fi, SSH, services, `docker check-config` | low | if no Wi-Fi: power cycle, stock boots again |
| 2 | Same boot + cgroup v1/hybrid kernel argument | medium | same; phone returns to stock on reboot |
| 3 | Only if 1 and 2 are good: flash permanently, install Docker (static, rootful, data in `/home`), then k3s single-node (`--flannel-backend=host-gw`, data-dir in `/home`) | medium | reflash the saved stock `boot.img` |

## Already done meanwhile (no root, reversible)
Static Podman 6.2.0 was unpacked to `/home/phablet/podman` (sha256 and signature verified). It does **not** run containers on this kernel yet; each fix revealed another wall: it needs `newuidmap` for more than one user ID, `crun` needs the newer `open_tree` system call (kernel 5.2+), `devpts` option `gid=5` is invalid with one mapped ID, `pasta` cannot open `/dev/net/tun`, FUSE mounts inside a user namespace need kernel 4.18+. That is the reason for this kernel plan. Remove with: `rm -rf /home/phablet/podman /home/phablet/podman-data ~/.config/containers ~/bin/podman` (the storage files need `unshare -Ur rm -rf ...`).

## What I need from you
1. **"yes, download and build"** so I can run Stage 0/0b (~2-4 GB, runs build scripts from UBports GitLab on your laptop). Or run `scripts/kernel-build.sh clone` yourself and read the scripts first.
2. Later, before Stage 1: you run a root script on the phone that only *copies* the stock boot partition to a file; and you keep the phone connected by USB to the laptop.

## Alternative proposed by you (2026-11-25): move everything to postmarketOS
**Why it is attractive:** the begonia port (`device/testing/xiaomi-begonia`) uses kernel **6.16.4** (near-mainline) whose config already has pids/cpu cgroups, nf_tables, VXLAN, IP_VS, bridge, overlayfs. Docker and k3s would be normal Alpine packages instead of a kernel project. The root filesystem is writable (no OTA overwriting our work). The USB ethernet hub you own is CDC-ECM, a driver this kernel has (it is exactly what Ubuntu Touch's kernel lacks).

**Why it is risky (all unverified, from `docs/compatibility.md`):**
1. Internal Wi-Fi is unconfirmed upstream (only a community out-of-tree driver). Wired ethernet via the hub is the likely answer.
2. **Battery + temperature sensors and charge control.** Our protection (75% cap, thermal brake) relies on vendor knobs (`input_suspend`, `vbus_disable`). A mainline kernel may not expose a charger threshold or even the thermal zones. This phone already shut itself off at 60 C and has 65% battery wear, so running without a working cap or thermal monitoring is a safety question, not a convenience one.
3. Jellyfin's portable build is glibc; pmOS is Alpine (musl). Use Alpine's package, a glibc shim, or run Jellyfin in Docker (the arm64 image exists).
4. Everything now running (AdGuard, Jellyfin config/DB, Homer, scripts, systemd units) must be re-created; the phone's `userdata` is wiped. Back up `jellyfin-data`, `AdGuardHome.yaml`, filebrowser DBs first.
5. No prebuilt begonia images; we would build with `pmbootstrap` on the laptop (several GB, needs `sudo` for chroots). Earlier, the pmaports clone and the wiki were redirected to `nura.eco` hosts; confirm independently that this is the real postmarketOS before running their tools.

**Non-destructive evaluation first (nothing on the phone is changed):** build the pmOS kernel + initramfs on the laptop and boot it from RAM with `fastboot boot` (or `pmbootstrap flasher boot`). The initramfs gives a debug shell over USB networking. Check, with the hub plugged in: (a) `ip link` shows the hub's ethernet and gets a DHCP address, (b) `/sys/class/power_supply/*` shows battery capacity, temperature, charger, (c) `/sys/class/thermal/*` has real temperatures, (d) a charge-control file exists (`charge_control_end_threshold` or similar), (e) the external drive appears while charging. Reboot returns to Ubuntu Touch untouched.

**Decision rule:** if (a)-(c) pass and (d) exists, pmOS is the better server base: go. If (d) fails, we would need a different way to cap charging (for example a smart plug on a schedule), and I would recommend staying on Ubuntu Touch and doing the kernel project instead. If (a) fails, pmOS has no usable network and is a no-go.

## postmarketOS evaluation: OFFLINE result (2026-11-26, before touching the phone)
Source: `device/testing/linux-postmarketos-mediatek-mt6785/config-postmarketos-mediatek-mt6785.aarch64` (kernel 6.16.4, a mainline fork for MT6785), read after cloning pmaports with pmbootstrap 3.12.1 (config in `~/.config/pmbootstrap_v3.cfg`, work dir `~/.local/var/pmbootstrap`, tool in `~/pmos/pmbootstrap`).

| Need | Result in the config | Verdict |
|---|---|---|
| Containers: pids/cpu cgroups, nf_tables, addrtype, VXLAN, IP_VS, overlayfs, user namespaces | all present | **pass** |
| USB ethernet for the hub (CDC-ECM `1a86:5394`) | `USB_NET_CDCETHER=m`, plus NCM, RTL8152, AX88179 | **likely pass** (needs live test) |
| Internal Wi-Fi | cfg80211/mac80211 only; **no MediaTek Wi-Fi driver** | **not available**; wired only |
| Battery percentage | **no fuel-gauge/battery driver** in the config (only `CHARGER_MT6360` and an AUXADC) | **likely fail**: no capacity reading |
| Battery temperature | only SoC thermal (`MTK_LVTS_THERMAL`); battery NTC not exposed by any option seen | **likely fail** |
| Charge cap | mainline MT6360 charger driver; no threshold control seen | **unknown, likely fail** |

**Meaning:** postmarketOS would be a far better container host, but it would be a server on a worn battery (65% of design capacity, a 60 C shutdown on record) with **no battery level, no battery temperature and probably no charge limit**. The 75% cap and thermal brake we built could not run. Ethernet would be the only network (no Wi-Fi), so the phone could only live next to the router with the hub always attached.

**Not yet verified live** (the RAM-boot test would confirm or refute these). Steps for the live test: `pmbootstrap install` (needs your sudo password), phone into fastboot, `pmbootstrap flasher boot`, run `scripts/pmos-eval-checks.sh` in the debug shell.

## postmarketOS evaluation: LIVE result (2026-11-26)
- `fastboot boot` of the pmOS image was **accepted** (bootloader unlocked, product begonia): a RAM-only test boot works on this phone, and rebooting returned to Ubuntu Touch with nothing changed.
- After the boot the phone detached from fastboot (00:55:48) and **no USB device or network ever appeared on the laptop** for over 2 minutes: no USB gadget, hence no debug shell, hence no way to read battery/thermal/charge-control. Not proven why (the screen was not described); likely the USB port/role switching is not functional in that kernel or the boot stalled before the gadget started.
- Together with the offline result (no Wi-Fi driver, no fuel-gauge driver, no battery temperature), postmarketOS cannot be shown to support the battery safety we need, and it did not give us a way to test the hub ethernet either. **Status: no-go for now.** Recovery was a power-cycle; all 7 services, DNS, dashboard and Jellyfin verified afterwards.
- Left behind (can be deleted any time): `~/pmos/pmbootstrap`, `~/.local/var/pmbootstrap` (about 1 GB: pmaports clone + a chroot + a 460 MB rootfs image), `~/.config/pmbootstrap_v3.cfg`. `~/pmos/ut-fallback/` holds Ubuntu Touch's own boot/recovery images; keep it.

## postmarketOS test #2 (2026-11-26): why #1 was silent, and the corrected image
**Likely cause of the missing USB device in test #1:** the begonia device tree gives the USB controller (`mediatek,mt6785-mtu3`, `usb-role-switch`) a Type-C chip (`mediatek,mt6360-tcpc`, dual role) that must tell it "you are a device now". The driver is the module `tcpci_mt6360` (+ `typec`, `tcpm`, `tcpci`), and the startup image (initramfs) does not load it; the installed system would, a few seconds later (udev). With no role switch the port stays in host mode, no UDC exists, `setup_usb_network` logs "No UDC found, skipping gadget setup" and nothing appears on the laptop.
**Also found:** `mt6360-adc` (module) is the MT6360's ADC: it normally reports battery voltage, charge current and the battery thermistor, so "no battery temperature" was a premature conclusion from the config.
**Fix:** `scripts/pmos-patch-initramfs.py` copies those modules (and their dependencies) into the initramfs, adds them to `initramfs.load`, regenerates `modules.dep/alias/symbols` with `depmod`, and rewrites the cpio. Verified offline: the cpio round-trips byte-identically before patching; only the module index files and `initramfs.load` changed plus 9 new entries; `mkbootimg` with the same arguments rebuilds the original image byte for byte, so the new `~/pmos/test-images/pmos-begonia-typec.img` (22.5 MB, sha256 `28824299...7f3f`) differs only in ramdisk and command line (`quiet` removed so the screen shows messages).
**Still unproven:** that the kernel then actually switches to device mode; that the ADC exposes usable battery data.

## postmarketOS test #2 RESULT (2026-11-26 01:09): the bootloader crashed
- `fastboot boot pmos-begonia-typec.img` was accepted ("OKAY"), then ~50 s later the phone enumerated on the laptop as the **Ubuntu Touch** device (kernel 4.14, idVendor 0a9d/2717) and booted Ubuntu Touch by itself.
- The kernel command line of that boot says **`androidboot.bootreason=lk_crash`**: the phone's bootloader (LK, the MediaTek "little kernel") crashed while handling the image, so **postmarketOS's kernel never ran** and the USB-module fix could not be tested. All 7 services, battery 100% afterwards.
- Test #1 probably ended the same way (same symptom: detached from fastboot, nothing on USB); not provable now.
- Unknown why LK crashed: candidates are the image size (22.5 MB vs Ubuntu Touch's 17.4 MB), the header v2 layout/offsets, or `fastboot boot` simply being unsupported by this bootloader.
- Options: (1) control test: `fastboot boot` the known-good Ubuntu Touch `boot.img` (`~/pmos/ut-fallback/partitions/boot.img`); if LK also crashes the `boot` command is broken here; (2) flash the pmOS image to the `boot` partition for a test and reflash Ubuntu Touch's boot.img afterwards (writes a partition; recovery by fastboot); (3) stop and take the Ubuntu Touch kernel path.

## Ubuntu Touch custom kernel: build progress (2026-11-26, laptop only)
- Downloaded (2.3 GB): kernel `halium-10.0` @ `4c74d0e84` (same as the phone), Android clang r353983c, GCC 4.9 prebuilts. Helper env: `~/kernel-build/env.sh`.
- **Proof the toolchain is faithful:** `make begonia_user_defconfig` produces a `.config` with 4145 symbols that is **identical** to the phone's `/proc/config.gz` (0 differences).
- **Option set:** the first 23-option set stuck for 21 options, but it included options that change widely shared structures (`BLK_CGROUP` and `BLK_DEV_THROTTLING` touch `task_struct`/`bio`/`request_queue`, `CGROUP_NET_PRIO` touches `net_device`). The only modules in the whole system are 9 stock vendor modules (`bt_drv, fmradio_drv, fpsgo, gps_drv, met, udc_lib, wlan_drv_gen4m, wmt_chrdev_wifi, wmt_drv`, force-loaded); there are no kernel modules in `/lib/modules`. So the final set is **minimal**: `CGROUP_PIDS, CFS_BANDWIDTH, XT_MATCH_ADDRTYPE/MULTIPORT/RECENT/PHYSDEV, VXLAN, DUMMY, MACVLAN` (all `=y`, verified in the generated `.config`). The full set is parked in `kernel/docker-k3s-extended.config.disabled`.
- Kernel release string stays `4.14.141-g4c74d0e84`, so nothing keyed on the version (module dirs, `uname -r`) changes.
- Next: finish the build, compare each vendor module's required symbol CRCs with the new kernel's `Module.symvers` (any mismatch = risk), make `boot.img`, compare its structure with the stock `boot.img`.

## Ubuntu Touch custom kernel: BUILT and verified offline (2026-11-26)
**Artifacts (laptop, `~/kernel-build/out/`):** `boot-docker-k3s.img` (17,498,112 bytes, sha256 `5259bca1f939aa6a635ba7a4417d21b5342771bd8a748e1d83920ffd86323149`) and `boot-stock-ubuntu-touch.img` (the working original, sha256 `dd423ea4...dc86`). **Not flashed, not test-booted.**
**What was proven (all on the laptop):**
1. Source + toolchain are faithful: generated `.config` == the phone's `/proc/config.gz` (4145 symbols, 0 differences); the compiled device tree is byte-identical to the one in Ubuntu Touch's boot image.
2. The image recipe reproduces Ubuntu Touch's `boot.img` exactly (same size/layout; only the 20-byte content-id field differs, which the bootloader does not check). The new image differs from the working one only in the kernel; ramdisk, device tree, command line and header are identical.
3. Kernel release string unchanged: `4.14.141-g4c74d0e84`.
4. **Binary-compatibility with the stock vendor modules (Wi-Fi/BT/GPS/etc.):** the symbol-CRC comparison is too blunt (it flags 3,520 symbols because genksyms expands whole type graphs; the vendor modules mismatch massively against the stock build too and are force-loaded). The real test, compiling a probe against both configurations and dumping every struct layout (1,493 core structs: task_struct, net_device, sk_buff, net, sock, device, wiphy/cfg80211, mmc, usb gadget, perf_event ...): **only `cgroup`, `cgroup_root`, `css_set` differ** (`subsys[8]` -> `subsys[9]`, one more cgroup controller), and none of the 9 vendor modules references any cgroup symbol.
5. Score against Docker/Kubernetes requirements: core 26 options, missing 2 -> 0; limits/networking 13 options, missing 6 -> 0. Optional features deliberately left off: POSIX_MQUEUE, BLK_CGROUP/throttling, CGROUP_NET_PRIO/PERF/HUGETLB, BRIDGE_VLAN_FILTERING, IPVLAN, NF_TABLES, IP_VS.
**Still unproven (needs the phone):** that the bootloader accepts this image (the pmOS image crashed LK with `fastboot boot`; this one has Ubuntu Touch's exact structure and size, but only a test can show it), that Wi-Fi etc. come up, and the larger open problem for Docker/k3s: the cgroup layout (Ubuntu Touch uses the unified v2 hierarchy; kernel 4.14 offers only the memory controller there, so Docker/k3s need the cgroup v1 layout, set with a kernel argument and untested with the Android container).
**Privacy note:** the kernel banner embeds the build user and host of the maintainer's laptop (visible in `/proc/version`); rebuild with your own user/host if that matters to you.
**Plan:** test order agreed with the user: pmOS control + flash tests first (tomorrow), this kernel last. Test method for this one: `fastboot boot` of the new image first (RAM only; reboot restores), then only if good, `fastboot flash boot` with a saved stock image for rollback.
