#!/bin/bash
# ChangeInfoIos - Deploy Script
# Build .deb + copy to iPhone + install

IP="${1:-192.168.1.4}"
PORT="${2:-22}"
DEB_FILE="packages/com.changeinfoios.tweak_2.2.0_iphoneos-arm64.deb"

echo "================================================"
echo "  ChangeInfoIos Deploy"
echo "================================================"
echo "  iPhone IP: $IP"
echo "  Port: $PORT"
echo ""

# Step 1: Build .deb
echo "[1/4] Building .deb..."
node build-deb.js
if [ $? -ne 0 ]; then
    echo "ERROR: Build failed!"
    exit 1
fi
echo ""

# Step 2: Check .deb exists
if [ ! -f "$DEB_FILE" ]; then
    echo "ERROR: .deb not found: $DEB_FILE"
    echo "Available packages:"
    ls -la packages/ 2>/dev/null || echo "No packages/ directory"
    exit 1
fi
echo "[2/4] .deb found: $DEB_FILE ($(du -h "$DEB_FILE" | cut -f1))"
echo ""

# Step 3: Copy to iPhone via SCP
echo "[3/4] Copying to iPhone..."
scp -P $PORT "$DEB_FILE" root@$IP:/var/mobile/
if [ $? -ne 0 ]; then
    echo "ERROR: SCP failed! Check:"
    echo "  - iPhone IP is correct: $IP"
    echo "  - SSH is enabled on iPhone (Settings > SSH)"
    echo "  - Password is correct (default: alpine)"
    echo ""
    echo "Test connection manually:"
    echo "  ssh root@$IP -p $PORT"
    exit 1
fi
echo ""

# Step 4: Install on iPhone
echo "[4/4] Installing on iPhone..."
ssh -p $PORT root@$IP "dpkg -i /var/mobile/com.changeinfoios.tweak_2.2.0_iphoneos-arm64.deb && sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null || echo 'Respring may be needed manually'"
if [ $? -ne 0 ]; then
    echo "ERROR: Install failed!"
    exit 1
fi

echo ""
echo "================================================"
echo "  DONE!"
echo "================================================"
echo "  App 'HIOS Faker' should appear on Home Screen"
echo "  Respring in progress..."
