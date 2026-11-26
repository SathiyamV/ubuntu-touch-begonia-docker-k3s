# Droidian for the Redmi Note 8 Pro: offline review (2026-11-26)
Nothing was flashed; the phone was not touched. Everything below was read from the downloaded image on the laptop.

**Image:** `droidian-UNOFFICIAL-phosh-phone-xiaomi_begonia-api29-arm64-next_20261115.zip`, 1,613,403,036 bytes, sha256 `42df741408b232ea6d13e4cc9d8086c7159cc7a5baf0f041ec1d53f5b90553de` (matches the published `SHA256SUMS`, which only proves the download is intact). Source: GitHub release `nightly` of `begonia-linux/droidian-xiaomi-begonia`, built by GitHub Actions, "UNOFFICIAL" community build. Files in `~/droidian-review/` (zip + notes; the extracted 4.9 GB root filesystem was deleted).

## What the flash script does (read in full: `flash_all.sh`)
It writes only four partitions with `fastboot flash`: **boot, dtbo, vbmeta, userdata**, then `fastboot reboot`.
- `dtbo.img` and `vbmeta.img` are **byte-identical** to the ones the Ubuntu Touch installer wrote to this phone (same sha256), so they change nothing.
- `boot.img` (28.6 MB): Android boot header v2, same `bootopt=64S3,32N2,64N2`, same device tree size; kernel 4.14-141 built in a CI container; ramdisk 16.6 MB. Command line adds `droidian.lvm.prefer`.
- `userdata.img` (4.3 GB sparse, 4.9 GB raw): an **LVM volume group** `droidian` with `droidian-persistent` (128 MiB), `droidian-reserved` (32 MiB) and `droidian-rootfs` (4.6 GiB ext4, Debian). **Flashing it erases the whole userdata partition**: Ubuntu Touch, Jellyfin data, AdGuard config, everything on the phone's data side.
- It does **not** touch `recovery`, the modem/baseband (`md1img`), or the identity/calibration partitions (`nvram`, `nvdata`, `nvcfg`, `protect1/2`, `persist`, `proinfo`).
- Refuses a device whose fastboot `product` is not `begonia`.

## Kernel
Extracted from the kernel image itself (`extract-ikconfig`): 4.14-141, built in a CI container. For Docker/k3s it has the same two gaps as Ubuntu Touch: **no `CGROUP_PIDS`, no `CFS_BANDWIDTH`**. It already includes `NETFILTER_XT_MATCH_ADDRTYPE`, `VXLAN`, `MACVLAN`, `DUMMY`, `POSIX_MQUEUE`, `BRIDGE_VLAN_FILTERING`, `EXT4_FS_POSIX_ACL`. So the custom-kernel work would still be needed; the kernel is delivered as a Debian package, which makes that cleaner than on Ubuntu Touch, but it is not Docker-ready out of the box. No Docker, containerd, podman or k3s is installed; `lxc` and `lxc-android` are.

## Security findings (root filesystem, read with `debugfs`, no root)
| Finding | Detail | What to do |
|---|---|---|
| Default login | User `droidian` (uid 32011, in group `sudo`) has a password set; README says the default passcode is `1234`. | Change at first boot, before anything else. |
| SSH on by default | `ssh.service` enabled; `sshd_config` has no `PasswordAuthentication no`, so password login works over the network. | Set a strong password, add key login, disable password login. |
| SSH host keys | Private host keys are present in the image, but `droidian-regenerate-ssh-keys.service` (runs `Before=ssh.service`, once) replaces them on first boot. | OK; verify with `ssh-keygen -lf` after first boot that they differ from the image's. |
| Unsigned apt source | `deb [trusted=yes] https://halhadus.github.io/droidian-packages stable main` (adaptation, kernel, camera packages): one person's GitHub Pages site, signature checking turned **off**. | Remove or replace it after first boot; understand that updates to the adaptation/kernel packages stop. |
| Official source | `droidian+http://releases.droidian.org/` suite `rolling`, `Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg`. | Fine. |
| Unneeded services | `cups`, `avahi-daemon`, `ModemManager`, `phosh` are enabled. | Disable cups/avahi on a server. |
| Provenance | Image and kernel are community CI output, not an official Droidian release (`UNOFFICIAL`, `next`, nightly). | Treat as unaudited. |

## Compared with Ubuntu Touch
Pros: Debian + `apt` (glibc, writable system; Jellyfin has an official arm64 Debian repository), kernel as a package, same hardware stack so the Android battery controls should be unchanged (not verified on this image).
Cons: same 4.14 kernel and same two missing cgroups; wipes everything; unofficial nightly with an unsigned third-party package source; default password + SSH.

## Open question
Whether this phone's bootloader accepts the Droidian `boot.img` is untested; its format matches what the Ubuntu Touch installer flashed (header v2, same offsets class), and flashing via `fastboot flash` is a different path from the `fastboot boot` that crashed on the postmarketOS image.
