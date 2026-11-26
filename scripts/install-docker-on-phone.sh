#!/bin/bash
# Runs ON the phone as root: sudo bash /home/phablet/docker-install/install-docker.sh
#
# Installs Docker (official static build 29.10.0, checksum-verified on the laptop) on the phone.
# Needs the custom kernel + cgroup v1 boot (systemd.unified_cgroup_hierarchy=0) - checked below.
#   binaries : /opt/docker            (rootfs is remounted rw for a moment, then ro again)
#   data     : /home/docker-data      (images/containers go to the big /home volume, not the rootfs)
#   service  : docker.service         (started now; ENABLED AT BOOT only if the tests below pass)
# Nothing is changed for AdGuard/Jellyfin/Homer. If any of them stops answering afterwards,
# Docker is stopped and disabled again automatically.
set -e
# PHONE_IP check: edit <PHONE_IP> (your phone's Wi-Fi address) and the interface name (wlan0) in this script first.
grep -q '<PHONE''_IP>' "$0" && { echo "Edit <PHONE_IP> in $0 first (your phone's LAN address)."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
S=/home/phablet/docker-install
[ -f $S/docker-29.10.0.tgz ] || { echo "missing $S/docker-29.10.0.tgz"; exit 1; }
echo "6e5159e8b5615e0c0c2954a2a1a2a12bc65f5d9b603595dba24a10cb367408cd  $S/docker-29.10.0.tgz" | sha256sum -c - || { echo "checksum mismatch - stopping"; exit 1; }

# ---- preflight: kernel features and cgroup v1 controllers
grep -q 'systemd.unified_cgroup_hierarchy=0' /proc/cmdline || { echo "not booted with cgroup v1 - stopping"; exit 1; }
for c in cpu pids memory devices freezer cpuset; do
  [ -d /sys/fs/cgroup/$c ] || { echo "cgroup v1 controller '$c' not mounted - stopping"; exit 1; }
done
zcat /proc/config.gz | grep -q '^CONFIG_CGROUP_PIDS=y' || { echo "kernel lacks CGROUP_PIDS - stopping"; exit 1; }
echo "preflight OK: cgroup v1 + custom kernel"

# ---- install
systemctl stop docker 2>/dev/null || true   # re-run safe: no deleted-but-open files may keep / busy
mount -o remount,rw /
rm -rf /opt/docker.new; mkdir -p /opt/docker.new
tar -xzf $S/docker-29.10.0.tgz -C /opt/docker.new --strip-components=1 --no-same-owner
[ -x /opt/docker.new/dockerd ] || { echo "dockerd missing in archive"; mount -o remount,ro /; exit 1; }
rm -rf /opt/docker; mv /opt/docker.new /opt/docker
chown -R root:root /opt/docker
for b in docker dockerd containerd ctr runc docker-init docker-proxy containerd-shim-runc-v2; do ln -sf /opt/docker/$b /usr/local/bin/$b; done
mkdir -p /home/docker-data /etc/docker
chmod 711 /home/docker-data
cat > /etc/docker/daemon.json <<'EOT'
{
  "data-root": "/home/docker-data",
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-address-pools": [ { "base": "172.30.0.0/16", "size": 24 } ],
  "bip": "172.29.0.1/24"
}
EOT
cat > /etc/systemd/system/docker.service <<'EOT'
[Unit]
Description=Docker Engine (static build, custom kernel + cgroup v1)
After=network-online.target
Wants=network-online.target

[Service]
Environment=PATH=/opt/docker:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/docker/dockerd
Restart=on-failure
RestartSec=5
Delegate=yes
KillMode=process
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload
mount -o remount,ro / || echo "WARNING: / is still READ-WRITE - run: sudo systemctl restart docker && sudo mount -o remount,ro /"

# ---- start + tests
rollback() { echo "!! $1 - stopping Docker again"; systemctl disable docker 2>/dev/null || true; systemctl stop docker 2>/dev/null || true; exit 1; }
systemctl start docker
ok=0; for i in $(seq 1 30); do sleep 1; /opt/docker/docker info >/dev/null 2>&1 && { ok=1; break; }; done
[ $ok = 1 ] || { journalctl -u docker --no-pager -n 25; rollback "dockerd did not come up"; }
echo "---- docker info (key lines)"
/opt/docker/docker info 2>&1 | grep -E "Server Version|Storage Driver|Cgroup Driver|Cgroup Version|Docker Root Dir|Kernel Version|WARNING|Runtimes" || true

# the rest of the house must still answer
for u in 127.0.0.1:80 127.0.0.1:3000 127.0.0.1:8096; do
  python3 - "$u" <<'PY' || rollback "$u stopped answering"
import sys, urllib.request as u
try: u.urlopen("http://" + sys.argv[1] + "/", timeout=8)
except urllib.error.HTTPError: pass
PY
done
ss -lun | grep -q ':53 ' || rollback "DNS port 53 vanished"
echo "house services still answer (dashboard, AdGuard, Jellyfin, DNS)"

D=/opt/docker/docker
fail=0
echo "---- test 1: run a container (pulls hello-world from Docker Hub)"
out=$($D run --rm hello-world 2>&1) && echo "$out" | grep -q "Hello from Docker" && echo "PASS" || { echo "$out" | tail -4; echo "FAIL"; fail=1; }
echo "---- test 2: resource limits (the cgroups we added the kernel for)"
out=$($D run --rm --cpus 0.5 --memory 64m --pids-limit 50 busybox:stable sh -c \
  'echo limits-ok; cat /sys/fs/cgroup/pids/pids.max /sys/fs/cgroup/cpu/cpu.cfs_quota_us /sys/fs/cgroup/memory/memory.limit_in_bytes' 2>&1) \
  && echo "$out" | tail -4 && echo "PASS" || { echo "$out" | tail -4; echo "FAIL"; fail=1; }
echo "---- test 3: container -> internet and name resolution (NAT)"
out=$($D run --rm busybox:stable sh -c 'nslookup example.com <PHONE_IP> | tail -3; wget -q -O /dev/null -T 8 http://example.com && echo wget-ok' 2>&1) \
  && echo "$out" | grep -q wget-ok && echo "$out" | tail -3 && echo "PASS" || { echo "$out" | tail -4; echo "FAIL"; fail=1; }
[ $fail = 0 ] || { echo "One or more tests FAILED - Docker is left running but NOT enabled at boot."; systemctl disable docker 2>/dev/null || true; exit 1; }
systemctl enable docker
echo
echo "DONE. Docker is installed, running and enabled at boot."
echo "Use it with:  sudo docker ps      (no 'docker' group on purpose: that group = root on the phone)"
echo "Remove it:    sudo systemctl disable --now docker; then rm -rf /opt/docker /usr/local/bin/{docker,dockerd,containerd,ctr,runc,docker-init,docker-proxy,containerd-shim-runc-v2} /etc/docker /etc/systemd/system/docker.service /home/docker-data (rootfs needs mount -o remount,rw /)"
