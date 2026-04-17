#!/bin/bash
IP=${1:-localhost}
PORT=${2:-2222}
DEB="com.changeinfoios.tweak_2.2.0_iphoneos-arm64.deb"
scp -P $PORT "packages/$DEB" root@$IP:/var/mobile/
ssh -p $PORT root@$IP "dpkg -i /var/mobile/$DEB && sbreload 2>/dev/null || killall -9 SpringBoard"