#!/bin/bash
# Runs ON the phone as root: sudo bash /home/phablet/k3s-install/install-k3s.sh
#
# Installs k3s v1.34.13+k3s1 (official static binary, checksum-verified) as a single-node Kubernetes.
#   Version 1.34 on purpose: Kubernetes 1.35+ refuses to start on cgroup v1, which this kernel needs.
#   binary  : /opt/k3s/k3s              (rootfs is read-only; remounted rw only while installing)
#   data    : /home/k3s-data            (+ bind mounts so /var/lib/kubelet, /var/lib/cni, /var/log/pods,
#                                        /var/log/containers, /etc/rancher/node live under /home/k3s-var)
#   network : flannel host-gw on wlan0, node IP <PHONE_IP>, traefik + servicelb DISABLED
#             (they would grab ports 80/443, i.e. your dashboard, and are not needed)
#   API     : https://<PHONE_IP>:6443 (client-certificate / token auth), kubeconfig /home/k3s-data/k3s.yaml
# Runs side by side with Docker (separate containerd). Enabled at boot ONLY if every test passes;
# if the house services stop answering, k3s is stopped and disabled again automatically.
set -e
# PHONE_IP check: edit <PHONE_IP> (your phone's Wi-Fi address) and the interface name (wlan0) in this script first.
grep -q '<PHONE''_IP>' "$0" && { echo "Edit <PHONE_IP> in $0 first (your phone's LAN address)."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
S=/home/phablet/k3s-install
VER='v1.34.13+k3s1'
[ -f $S/k3s-arm64 ] || { echo "missing $S/k3s-arm64"; exit 1; }
echo "bad32c0c798bce0e883216ed755bbfb3c6a9fbd9b9f1dee32a6be16d256ad033  $S/k3s-arm64" | sha256sum -c - || { echo "checksum mismatch - stopping"; exit 1; }

# ---- preflight
grep -q 'systemd.unified_cgroup_hierarchy=0' /proc/cmdline || { echo "not booted with cgroup v1 - stopping"; exit 1; }
for c in cpu pids memory devices freezer cpuset; do [ -d /sys/fs/cgroup/$c ] || { echo "cgroup v1 '$c' missing - stopping"; exit 1; }; done
for p in 6443 10250; do ss -lnt | grep -q ":$p " && { echo "port $p already in use - stopping"; exit 1; }; done
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); [ "$avail" -ge 1500 ] || { echo "only ${avail} MB RAM available - stopping"; exit 1; }
[ -e /opt/k3s/k3s ] && systemctl is-active -q k3s && { echo "k3s already running - use scripts/uninstall-k3s-on-phone.sh first"; exit 1; }
echo "preflight OK (cgroup v1, ports free, ${avail} MB RAM available)"

# ---- install files (rootfs rw for a moment)
mount -o remount,rw /
mkdir -p /opt/k3s /etc/rancher/k3s /etc/rancher/node /var/lib/kubelet /var/lib/cni /var/log/pods /var/log/containers
install -m 0755 $S/k3s-arm64 /opt/k3s/k3s
ln -sf /opt/k3s/k3s /usr/local/bin/k3s
ln -sf /opt/k3s/k3s /usr/local/bin/kubectl
mkdir -p /home/k3s-data /home/k3s-var/{kubelet,cni,log-pods,log-containers,rancher-node}
chmod 700 /home/k3s-data /home/k3s-var

cat > /etc/rancher/k3s/config.yaml <<'EOT'
node-name: redmi
node-ip: <PHONE_IP>
tls-san:
  - <PHONE_IP>
data-dir: /home/k3s-data
write-kubeconfig: /home/k3s-data/k3s.yaml
write-kubeconfig-mode: "0600"
flannel-backend: host-gw
flannel-iface: wlan0
secrets-encryption: true
disable:
  - traefik
  - servicelb
kubelet-arg:
  - "max-pods=60"
  - "system-reserved=memory=1500Mi"
EOT

cat > /opt/k3s/binds.sh <<'EOT'
#!/bin/bash
# bind the writable /home folders over the read-only system paths k3s/kubelet want to write to
M="/home/k3s-var/kubelet:/var/lib/kubelet /home/k3s-var/cni:/var/lib/cni /home/k3s-var/log-pods:/var/log/pods /home/k3s-var/log-containers:/var/log/containers /home/k3s-var/rancher-node:/etc/rancher/node"
case "$1" in
start) for m in $M; do s=${m%%:*}; t=${m##*:}; mountpoint -q $t || mount --bind $s $t; done
       mount --make-rshared /var/lib/kubelet ;;
stop)  for m in $M; do t=${m##*:}; mountpoint -q $t && umount -l $t; done; true ;;
esac
EOT
chmod 755 /opt/k3s/binds.sh

cat > /opt/k3s/killall.sh <<'EOT'
#!/bin/bash
# stop k3s and everything it started (containers keep running after "systemctl stop" by design)
systemctl stop k3s 2>/dev/null
pkill -f 'containerd-shim.*k3s' 2>/dev/null
sleep 2
for p in $(awk '{print $2}' /proc/mounts | grep -E '^(/run/k3s|/home/k3s-data|/var/lib/kubelet/|/run/netns)' | sort -r); do umount -l "$p" 2>/dev/null; done
ip link delete cni0 2>/dev/null; ip link delete flannel.1 2>/dev/null
true
EOT
chmod 755 /opt/k3s/killall.sh

cat > /etc/systemd/system/k3s-binds.service <<'EOT'
[Unit]
Description=Bind /home folders over read-only system paths for k3s
RequiresMountsFor=/home
Before=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/k3s/binds.sh start
ExecStop=/opt/k3s/binds.sh stop

[Install]
WantedBy=multi-user.target
EOT

cat > /etc/systemd/system/k3s.service <<'EOT'
[Unit]
Description=k3s (single-node Kubernetes)
Wants=network-online.target
After=network-online.target k3s-binds.service
Requires=k3s-binds.service

[Service]
Type=notify
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service 2>/dev/null'
ExecStart=/opt/k3s/k3s server
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=on-failure
RestartSec=5s
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload
mount -o remount,ro / || echo "WARNING: / is still READ-WRITE - run: sudo mount -o remount,ro /   (check nothing holds deleted files)"

# ---- start + tests
rollback() { echo "!! $1 - stopping k3s again"; systemctl disable k3s 2>/dev/null || true; /opt/k3s/killall.sh; exit 1; }
K="/opt/k3s/k3s kubectl --kubeconfig /home/k3s-data/k3s.yaml"
systemctl start k3s-binds
systemctl start k3s &
SP=$!
echo "k3s starting (first start unpacks and pulls images: up to ~5 minutes)..."
ok=0; for i in $(seq 1 90); do sleep 4; $K get node redmi 2>/dev/null | grep -qw Ready && { ok=1; break; }; done
[ $ok = 1 ] || { journalctl -u k3s --no-pager -n 30; rollback "node did not become Ready"; }
wait $SP 2>/dev/null || true
echo "---- node"; $K get node -o wide
echo "---- waiting for system pods (coredns, local-path-provisioner, metrics-server)"
for i in $(seq 1 60); do
  n=$($K get pods -n kube-system --no-headers 2>/dev/null | grep -vE 'Running|Completed' | wc -l)
  t=$($K get pods -n kube-system --no-headers 2>/dev/null | wc -l)
  [ "$t" -ge 3 ] && [ "$n" = 0 ] && break; sleep 4
done
$K get pods -A

# the rest of the house must still answer
for u in 127.0.0.1:80 127.0.0.1:3000 127.0.0.1:8096; do
  python3 - "$u" <<'PY' || rollback "$u stopped answering"
import sys, urllib.request as u, urllib.error
try: u.urlopen("http://" + sys.argv[1] + "/", timeout=8)
except urllib.error.HTTPError: pass
PY
done
ss -lun | grep -q ':53 ' || rollback "DNS port 53 vanished"
echo "house services still answer (dashboard, AdGuard, Jellyfin, DNS)"

fail=0
echo "---- test 1: run a pod with limits, cluster DNS and internet"
$K delete pod t1 --ignore-not-found >/dev/null 2>&1
$K apply -f - >/dev/null <<'EOT'
apiVersion: v1
kind: Pod
metadata: {name: t1}
spec:
  restartPolicy: Never
  containers:
  - name: t1
    image: busybox:stable
    resources: {limits: {cpu: 200m, memory: 64Mi}}
    command: ["sh","-c","nslookup kubernetes.default.svc.cluster.local | tail -3; wget -q -T 8 -O /dev/null http://example.com && echo wget-ok"]
EOT
ph=""; for i in $(seq 1 60); do sleep 3; ph=$($K get pod t1 -o jsonpath='{.status.phase}' 2>/dev/null); [ "$ph" = Succeeded -o "$ph" = Failed ] && break; done
out=$($K logs t1 2>&1); echo "$out"
if [ "$ph" = Succeeded ] && echo "$out" | grep -q wget-ok && echo "$out" | grep -q 'Address'; then echo PASS; else echo "phase=$ph"; $K describe pod t1 | tail -8; echo FAIL; fail=1; fi
$K delete pod t1 --ignore-not-found >/dev/null 2>&1

echo "---- test 2: Deployment + NodePort service reachable from the phone itself"
$K create deployment web --image=nginx:alpine --replicas=1 >/dev/null 2>&1 || true
$K expose deployment web --port=80 --type=NodePort >/dev/null 2>&1 || true
$K rollout status deployment/web --timeout=180s >/dev/null 2>&1 || true
np=$($K get svc web -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
code=""; for i in $(seq 1 15); do code=$(python3 -c "import urllib.request as u;print(u.urlopen('http://127.0.0.1:$np/',timeout=5).status)" 2>/dev/null) && break; sleep 3; done
if [ "$code" = 200 ]; then echo "nodePort $np -> HTTP 200"; echo PASS; else echo "nodePort=$np code=$code"; echo FAIL; fail=1; fi
$K delete svc web deployment web --ignore-not-found >/dev/null 2>&1

[ $fail = 0 ] || { echo "One or more tests FAILED - k3s is left running but NOT enabled at boot. Logs: journalctl -u k3s"; systemctl disable k3s 2>/dev/null; exit 1; }
systemctl enable k3s-binds k3s
echo
echo "---- resources now"; free -m | sed -n 2p; uptime
echo
echo "DONE. k3s $VER is running and enabled at boot."
echo "Use it:     sudo k3s kubectl --kubeconfig /home/k3s-data/k3s.yaml get pods -A"
echo "Stop it:    sudo bash /opt/k3s/killall.sh     Remove it: sudo bash /home/phablet/k3s-install/uninstall-k3s.sh"
