W=~/kernel-build/work/downloads; K=$W/kernel-xiaomi-mt6785
CL=$(ls -d $W/linux-x86/clang-*/bin | head -1)
export PATH=$CL:$W/aarch64-linux-android-4.9/bin:$W/arm-linux-androideabi-4.9/bin:$PATH ARCH=arm64 CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi- CLANG_TRIPLE=aarch64-linux-gnu-
