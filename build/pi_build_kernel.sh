#!/bin/sh
# Build the 4.14 kernel image and the WiFi modules on lain0.
cd /home/mjoan/k/linux-xlnx || exit 1
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
KCFLAGS="-march=armv7-a+mp"

echo "=== zImage $(date) ==="
make -j4 KCFLAGS="$KCFLAGS" zImage || exit 1
echo "=== cfg80211 $(date) ==="
make -j4 KCFLAGS="$KCFLAGS" M=net/wireless modules || exit 1
echo "=== brcmfmac $(date) ==="
make -j4 KCFLAGS="$KCFLAGS" M=drivers/net/wireless/broadcom/brcm80211 modules || exit 1
echo "=== BUILD_DONE $(date) ==="
