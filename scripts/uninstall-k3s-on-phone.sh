#!/bin/bash
# Runs ON the phone as root: sudo bash /home/phablet/k3s-install/uninstall-k3s.sh
# Stops k3s and removes it. Your cluster data in /home/k3s-data and /home/k3s-var is kept unless you pass --wipe.
set -e
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
systemctl disable k3s k3s-binds 2>/dev/null || true
[ -x /opt/k3s/killall.sh ] && /opt/k3s/killall.sh
systemctl stop k3s-binds 2>/dev/null || true
mount -o remount,rw /
rm -rf /opt/k3s /usr/local/bin/k3s /usr/local/bin/kubectl /etc/systemd/system/k3s.service /etc/systemd/system/k3s-binds.service /etc/rancher/k3s
rmdir /var/lib/kubelet /var/lib/cni /var/log/pods /var/log/containers /etc/rancher/node /etc/rancher 2>/dev/null || true
systemctl daemon-reload
systemctl restart docker 2>/dev/null || true   # releases deleted-but-open files so / can go read-only
mount -o remount,ro / || echo "WARNING: / still read-write; run: sudo mount -o remount,ro /"
if [ "$1" = "--wipe" ]; then rm -rf /home/k3s-data /home/k3s-var; echo "data wiped"; else echo "data kept in /home/k3s-data and /home/k3s-var (rm -rf them to reclaim space)"; fi
echo "k3s removed."
