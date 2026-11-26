#!/bin/bash
# Runs ON the phone as root: sudo bash /home/phablet/k3s-install/test-k3s.sh
# Tests an already-installed, running k3s and enables it at boot ONLY if every test passes.
set -eE
exec > >(tee /home/phablet/k3s-install/test.log) 2>&1
trap 'echo "!! script aborted at line $LINENO (exit $?)"' ERR
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
VER='v1.34.13+k3s1'
rollback() { echo "!! $1 - stopping k3s again"; systemctl disable k3s 2>/dev/null || true; /opt/k3s/killall.sh; exit 1; }
K="/opt/k3s/k3s kubectl --kubeconfig /home/k3s-data/k3s.yaml"
systemctl is-active -q k3s || { echo "k3s is not running"; exit 1; }
echo "---- node"; $K get node -o wide
echo "---- waiting for system pods"
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
echo "DONE. k3s $VER passed all tests and is enabled at boot."
echo "Use it:  sudo k3s kubectl --kubeconfig /home/k3s-data/k3s.yaml get pods -A"
