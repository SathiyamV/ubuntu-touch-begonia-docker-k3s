#!/bin/bash
# Laptop: build a begonia kernel with Docker/k3s options, using the UBports/Halium build tooling.
# NOTHING here touches the phone. Output: ~/kernel-build/out/boot.img (+ the .config used).
# Steps (run one at a time):  ./kernel-build.sh clone | check | build
set -euo pipefail
W=~/kernel-build; PROJ=~/projects/redmi-homelab
case "${1:-}" in
clone)   # ~2-4 GB: device repo, kernel source (halium-10.0, depth 1), Android clang r353983c + gcc 4.9 prebuilts
  mkdir -p $W && cd $W
  [ -d xiaomi-begonia ] || git clone --depth 1 https://gitlab.com/ubports/porting/community-ports/android10/xiaomi-redmi-note-8-pro/xiaomi-begonia.git
  cd xiaomi-begonia && ./build.sh -b $W/work -o $W/out -c ;;
check)   # prove the toolchain reproduces the RUNNING kernel's config before we change anything
  cd $W/xiaomi-begonia && source ./deviceinfo
  K=$W/work/downloads/kernel-xiaomi-mt6785; echo "kernel source commit: $(git -C $K rev-parse --short HEAD) (phone runs g4c74d0e84)"
  echo "now: generate stock .config and diff it against the phone's /proc/config.gz (see docs/kernel-docker-k3s-plan.md)";;
build)   # append our options, then build kernel + boot.img
  cd $W/xiaomi-begonia && source ./deviceinfo
  K=$W/work/downloads/kernel-xiaomi-mt6785
  D=$K/arch/arm64/configs/$deviceinfo_kernel_defconfig
  cp -n $D $D.orig
  cp $D.orig $D; { echo; cat $PROJ/kernel/docker-k3s.config | grep -v '^#' | grep -v '^$'; } >> $D
  ./build.sh -b $W/work -o $W/out ;;
*) echo "usage: $0 clone|check|build"; exit 1;;
esac
