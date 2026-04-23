/**
 * ChangeInfoIos - .deb Package Builder v3
 * Packages tweak sources and native launcher
 * + Substrate tweak filter + on-device build scripts
 * 
 * Usage: node build-deb.js
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

// ============================================================
// CONFIG
// ============================================================
const PACKAGE_ID = 'com.changeinfoios.tweak';
var PACKAGE_NAME = 'ChangeInfoIos';
var VERSION = '2.2.0';
var ARCH = 'iphoneos-arm64';
var DESCRIPTION = 'ChangeInfo device spoofer — native app + tweak sources';
var AUTHOR = 'Admin';
var SECTION = 'Tweaks';
var DEPENDS = 'mobilesubstrate, firmware (>= 15.0), clang, ldid';

const OUTPUT_DIR = path.join(__dirname, 'packages');
const TWEAK_DIR = path.join(__dirname, 'tweak');

// ============================================================
// TAR HELPERS
// ============================================================
function tarHeader(filename, content, mode, type) {
  mode = mode || '100644';
  type = type || '0';
  var header = Buffer.alloc(512, 0);
  var size = Buffer.isBuffer(content) ? content.length : Buffer.byteLength(content);
  header.write(filename, 0, Math.min(filename.length, 100), 'utf8');
  header.write(mode.padStart(7, '0') + '\0', 100, 8, 'utf8');
  header.write('0000000\0', 108, 8, 'utf8');
  header.write('0000000\0', 116, 8, 'utf8');
  header.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'utf8');
  var mt = Math.floor(Date.now() / 1000);
  header.write(mt.toString(8).padStart(11, '0') + '\0', 136, 12, 'utf8');
  header.write(type, 156, 1, 'utf8');
  header.write('ustar\0', 257, 6, 'utf8');
  header.write('00', 263, 2, 'utf8');
  header.write('root', 265, 4, 'utf8');
  header.write('wheel', 297, 5, 'utf8');
  header.write('        ', 148, 8, 'utf8');
  var ck = 0;
  for (var i = 0; i < 512; i++) ck += header[i];
  header.write(ck.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'utf8');
  return header;
}

function tarDir(d) {
  if (!d.endsWith('/')) d += '/';
  return tarHeader(d, Buffer.alloc(0), '40755', '5');
}

function tarFile(name, content, mode) {
  var data = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
  var hdr = tarHeader(name, data, mode || '100644', '0');
  var pad = (512 - (data.length % 512)) % 512;
  return Buffer.concat([hdr, data, Buffer.alloc(pad, 0)]);
}

function tarEnd(entries) {
  return Buffer.concat(entries.concat([Buffer.alloc(1024, 0)]));
}

// ============================================================
// AR HELPERS
// ============================================================
function arHeader() { return Buffer.from('!<arch>\n'); }

function arEntry(name, data) {
  var h = Buffer.alloc(60);
  h.write((name + '/').padEnd(16, ' '), 0, 16);
  h.write(Math.floor(Date.now() / 1000).toString().padEnd(12, ' '), 16, 12);
  h.write('0'.padEnd(6, ' '), 28, 6);
  h.write('0'.padEnd(6, ' '), 34, 6);
  h.write('100644'.padEnd(8, ' '), 40, 8);
  h.write(data.length.toString().padEnd(10, ' '), 48, 10);
  h.write('`\n', 58, 2);
  var pad = data.length % 2 === 0 ? Buffer.alloc(0) : Buffer.from('\n');
  return Buffer.concat([h, data, pad]);
}

// ============================================================
// PNG ICON GENERATOR
// ============================================================
function makePNG(w, h) {
  var rowSz = 1 + w * 4;
  var raw = Buffer.alloc(rowSz * h);
  for (var y = 0; y < h; y++) {
    var ro = y * rowSz;
    raw[ro] = 0;
    for (var x = 0; x < w; x++) {
      var px = ro + 1 + x * 4;
      var f = 1 - (y / h) * 0.4;
      var m = x / w;
      raw[px]   = Math.round((6 * (1 - m) + 139 * m) * f);
      raw[px+1] = Math.round((182 * (1 - m) + 92 * m) * f);
      raw[px+2] = Math.round((212 * (1 - m) + 246 * m) * f);
      raw[px+3] = 255;
      // Phone shape
      var cx = w/2, cy = h/2, dx = Math.abs(x-cx), dy = Math.abs(y-cy);
      if (dx < w*0.18 && dy < h*0.32) { raw[px]=255; raw[px+1]=255; raw[px+2]=255; raw[px+3]=230; }
      if (dx < w*0.14 && dy < h*0.24 && dy > h*0.06) { raw[px]=10; raw[px+1]=14; raw[px+2]=23; raw[px+3]=255; }
    }
  }
  var comp = zlib.deflateSync(raw);
  var ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8]=8; ihdr[9]=6; ihdr[10]=0; ihdr[11]=0; ihdr[12]=0;
  function chunk(type, d) {
    var len = Buffer.alloc(4); len.writeUInt32BE(d.length, 0);
    var tb = Buffer.from(type, 'ascii');
    var cd = Buffer.concat([tb, d]);
    var c = 0xFFFFFFFF;
    for (var i = 0; i < cd.length; i++) { c ^= cd[i]; for (var j=0;j<8;j++) c = (c>>>1)^(c&1?0xEDB88320:0); }
    c = (c ^ 0xFFFFFFFF) | 0;
    var cb = Buffer.alloc(4); cb.writeInt32BE(c, 0);
    return Buffer.concat([len, tb, d, cb]);
  }
  return Buffer.concat([
    Buffer.from([137,80,78,71,13,10,26,10]),
    chunk('IHDR', ihdr), chunk('IDAT', comp), chunk('IEND', Buffer.alloc(0))
  ]);
}

// ============================================================
// BUILD STANDALONE HTML from modular sources
// ============================================================
function buildStandaloneHTML() {
  const iosDir = path.join(__dirname, 'ios');
  const tweakDir = path.join(TWEAK_DIR);
  const outFile = path.join(tweakDir, 'mobile-app-standalone.html');

  // Read HTML template
  let html = fs.readFileSync(path.join(iosDir, 'app.html'), 'utf8');

  // Read CSS
  let css = fs.readFileSync(path.join(iosDir, 'app.css'), 'utf8');

  // Read JS modules in order
  const jsFiles = ['config-data.js', 'utils.js', 'profile.js', 'device.js', 'apps.js', 'server.js', 'init.js'];
  let jsContent = '';
  for (const file of jsFiles) {
    const filePath = path.join(iosDir, 'js', file);
    if (fs.existsSync(filePath)) {
      jsContent += '\n// ---- ' + file + ' ----\n' + fs.readFileSync(filePath, 'utf8') + '\n';
    }
  }

  // Replace CSS link with inline CSS
  html = html.replace('<link rel="stylesheet" href="app.css">', '<style>\n' + css + '\n</style>');

  // Replace script tags with inline scripts
  html = html.replace(/<script src="js\/[^"]+"><\/script>/g, function() {
    return '<script>\n' + jsContent + '\n</script>';
  });

  // Write output
  fs.writeFileSync(outFile, html);
  console.log('  Built standalone HTML: ' + (fs.statSync(outFile).size / 1024).toFixed(1) + ' KB');
  return outFile;
}

// ============================================================
// BUILD STANDALONE HTML from modular sources (ios/js/*.js)
// ============================================================
function getLocalIP() {
  const os = require('os');
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }
  return '127.0.0.1';
}

// ============================================================
// PLIST FILTER (for Substrate/ElleKit)
// ============================================================
function tweakPlist() {
  // Read from actual plist file for consistency
  var plistPath = path.join(TWEAK_DIR, 'ChangeInfoIos.plist');
  if (fs.existsSync(plistPath)) {
    return fs.readFileSync(plistPath, 'utf-8');
  }
  // Fallback: hook ALL apps via UIKit bundle
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '    <key>Filter</key>',
    '    <dict>',
    '        <key>Mode</key>',
    '        <string>Any</string>',
    '        <key>Bundles</key>',
    '        <array>',
    '            <string>com.apple.UIKit</string>',
    '        </array>',
    '        <key>Executables</key>',
    '        <array>',
    '            <string>SpringBoard</string>',
    '            <string>WebKitWebContent</string>',
    '            <string>WebKitNetworking</string>',
    '        </array>',
    '    </dict>',
    '</dict>',
    '</plist>'
  ].join('\n');
}

// ============================================================
// POSTINST - Fast install, build native app
// ============================================================
function postinst() {
  var P = '/var/mobile/Library/Preferences/com.changeinfoios.plist';
  var CI = '/var/mobile/ChangeInfoIos';
  return [
    '#!/bin/bash',
    '# ChangeInfoIos v' + VERSION + ' - Post Install',
    '',
    'export PATH="/usr/bin:/usr/sbin:/usr/libexec:/bin:/sbin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/usr/libexec:$PATH"',
    '',
    'echo "[postinst] Starting..."',
    'mkdir -p /var/mobile/Library/Preferences',
    'mkdir -p "' + CI + '"',
    '',
    '# Default config plist (fast)',
    'if [ ! -f "' + P + '" ]; then',
    '    cat > "' + P + '" << CFGEOF',
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '    <key>enabled</key>',
    '    <true/>',
    '</dict>',
    '</plist>',
    'CFGEOF',
    '    chmod 644 "' + P + '"',
    '    chown mobile:mobile "' + P + '"',
    'fi',
    '',
    '# Remove stale native bundles from any previous installs',
    'rm -rf /var/jb/Applications/ChangeInfoIos.app 2>/dev/null || true',
    'rm -rf /Applications/ChangeInfoIos.app 2>/dev/null || true',
    '',
    '# Find clang and SDK (try multiple paths)',
    'CLANG_PATH=""',
    'SDK_PATH=""',
    'for C in /usr/bin/clang /var/jb/usr/bin/clang clang; do',
    '    if command -v $C >/dev/null 2>&1; then',
    '        CLANG_PATH=$C',
    '        break',
    '    fi',
    'done',
    'for S in /var/jb/usr/share/SDKs/iphoneos.sdk /var/jb/SDKs/iphoneos.sdk /usr/share/SDKs/iphoneos.sdk "$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"; do',
    '    if [ -d "$S" ] && [ -n "$S" ]; then',
    '        SDK_PATH=$S',
    '        break',
    '    fi',
    'done',
    '',
    'if [ -n "$CLANG_PATH" ]; then',
    '    echo "[postinst] Building native app with clang: $CLANG_PATH"',
    '    [ -n "$SDK_PATH" ] && echo "[postinst] Using SDK: $SDK_PATH"',
    '    APP_DIR="/var/jb/Applications/ChangeInfoIos.app"',
    '    mkdir -p "$APP_DIR"',
    '    SDK_FLAG=""',
    '    [ -n "$SDK_PATH" ] && SDK_FLAG="-isysroot $SDK_PATH"',
    '    $CLANG_PATH -fobjc-arc -o "$APP_DIR/ChangeInfoIos" "' + CI + '/main.m" \\',
    '        -framework Foundation -framework UIKit -framework WebKit -framework MobileCoreServices \\',
    '        $SDK_FLAG -arch arm64',
    '    if [ -f "$APP_DIR/ChangeInfoIos" ]; then',
    '        echo "[postinst] Native app built successfully!"',
    '        cp -f "' + CI + '/mobile-app-standalone.html" "$APP_DIR/"',
    '        cp -f "' + CI + '/icon.png" "$APP_DIR/AppIcon60x60@2x.png"',
    '        cp -f "' + CI + '/icon.png" "$APP_DIR/AppIcon76x76@2x.png"',
    '        cp -f "' + CI + '/Info.plist" "$APP_DIR/Info.plist"',
    '        chmod 755 "$APP_DIR/ChangeInfoIos"',
    '        echo "[postinst] Native app installed at $APP_DIR"',
    '    else',
    '        echo "[postinst] WARN: clang compile failed"',
    '    fi',
    'else',
    '    echo "[postinst] WARN: clang not found; native app not rebuilt on device"',
    'fi',
    '',
    '# Refresh icon cache',
    'if command -v uicache >/dev/null 2>&1; then',
    '    uicache -a 2>/dev/null',
    'elif [ -x /var/jb/usr/bin/uicache ]; then',
    '    /var/jb/usr/bin/uicache -a 2>/dev/null',
    'fi',
    '',
    'echo "[postinst] v' + VERSION + ' installed successfully!"',
  ].join('\n');
}

function prerm() {
  return [
    '#!/bin/bash',
    'rm -rf /var/jb/Applications/ChangeInfoIos.app',
    'rm -rf /var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.dylib',
    'rm -rf /var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.plist',
    'rm -rf /var/mobile/ChangeInfoIos',
    'uicache -a 2>/dev/null || true',
    'echo "[ChangeInfoIos] Removed"',
  ].join('\n');
}

function extrainst() {
  return [
    '#!/bin/bash',
    'if [ "$1" = "configure" ] || [ "$1" = "abort-remove" ]; then',
    '    sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null || true',
    'fi',
  ].join('\n');
}

// ============================================================
// ON-DEVICE BUILD SCRIPT (optional - builds dylib if Theos available)
// ============================================================
function buildScript() {
  return [
    '#!/bin/bash',
    '# ChangeInfoIos - On-Device Build Script (Tweak + Native App)',
    '',
    'cd "$(dirname "$0")"',
    '',
    'echo "================================================"',
    'echo "  Building ChangeInfo Native App"',
    'echo "================================================"',
    '',
    '# Check clang',
    'CLANG=$(command -v clang 2>/dev/null || echo "")',
    'if [ -z "$CLANG" ]; then',
    '    # Try common rootless paths',
    '    for p in /var/jb/usr/bin/clang /usr/bin/clang; do',
    '        if [ -x "$p" ]; then CLANG="$p"; break; fi',
    '    done',
    'fi',
    '',
    'if [ -z "$CLANG" ]; then',
    '    echo "ERROR: clang not found. Install: apt install clang ldid"',
    '    exit 1',
    'fi',
    'echo "Using clang: $CLANG"',
    '',
    '# Find SDK',
    'SDK_FLAG=""',
    'for p in /var/jb/opt/theos "$HOME/theos" /opt/theos; do',
    '    if [ -d "$p" ]; then',
    '        for sdk in "$p"/sdks/iPhoneOS*.sdk; do',
    '            if [ -d "$sdk" ]; then SDK_FLAG="-isysroot $sdk"; break 2; fi',
    '        done',
    '    fi',
    'done',
    '',
    '# Find hooking lib for tweak',
    'HOOK=""',
    'for lib in libsubstrate libellekit libhooker; do',
    '    if [ -f "/var/jb/usr/lib/$lib.dylib" ]; then',
    '        HOOK="-L/var/jb/usr/lib -l${lib#lib}"; break',
    '    fi',
    'done',
    '',
    '# --- Step 1: Try to build Tweak (optional, may fail without Theos) ---',
    'echo "[1/3] Building Tweak (optional)..."',
    'THEOS_PATH=""',
    'for p in /var/jb/opt/theos "$HOME/theos" /opt/theos; do',
    '    if [ -d "$p" ]; then THEOS_PATH="$p"; break; fi',
    'done',
    '',
    'if [ -n "$THEOS_PATH" ] && [ -f "$THEOS_PATH/bin/logos.pl" ] && [ -f "Tweak.xm" ]; then',
    '    "$THEOS_PATH/bin/logos.pl" Tweak.xm > Tweak.mm 2>/dev/null',
    '    if [ -f "Tweak.mm" ]; then',
    '        clang++ -dynamiclib -o "ChangeInfoIos.dylib" Tweak.mm \\',
    '            -arch arm64 \\',
    '            -fobjc-arc -Wno-deprecated-declarations \\',
    '            -framework Foundation -framework UIKit \\',
    '            -framework CoreTelephony -framework CoreLocation \\',
    '            -framework SystemConfiguration -framework Security \\',
    '            -framework AdSupport -framework WebKit -framework IOKit \\',
    '            -framework CoreMotion -framework Metal -framework AppTrackingTransparency -framework MobileCoreServices \\',
    '            $HOOK $SDK_FLAG \\',
    '            -install_name "/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.dylib" 2>/dev/null',
    '        if [ -f "ChangeInfoIos.dylib" ]; then',
    '            cp -f "ChangeInfoIos.dylib" "/var/jb/Library/MobileSubstrate/DynamicLibraries/"',
    '            chmod 755 "/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.dylib"',
    '            echo "  Tweak compiled OK"',
    '        else',
    '            echo "  Tweak compile failed (non-fatal)"',
    '        fi',
    '    fi',
    'else',
    '    echo "  Skipped (Theos not found or Tweak.xm missing)"',
    'fi',
    '',
    '# --- Step 2: Build Native App (REQUIRED) ---',
    'echo "[2/3] Building Native App..."',
    'APP_DIR="/var/jb/Applications/ChangeInfoIos.app"',
    'mkdir -p "$APP_DIR"',
    '',
    '$CLANG -fobjc-arc -o "$APP_DIR/ChangeInfoIos" main.m \\',
    '    -framework Foundation -framework UIKit -framework WebKit -framework MobileCoreServices \\',
    '    $SDK_FLAG -arch arm64 2>&1',
    '',
    'if [ ! -f "$APP_DIR/ChangeInfoIos" ]; then',
    '    echo "FATAL: Native app compile failed!"',
    '    exit 1',
    'fi',
    '',
    '# Sign with entitlements (no-sandbox for root access)',
    'LDID=$(command -v ldid 2>/dev/null || echo "/var/jb/usr/bin/ldid")',
    'cat > "/tmp/ci_ent.xml" << ENTEOF',
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '    <key>platform-application</key><true/>',
    '    <key>com.apple.private.security.no-container</key><true/>',
    '    <key>com.apple.private.security.no-sandbox</key><true/>',
    '    <key>com.apple.lsapplicationworkspace.observer</key><true/>',
    '</dict>',
    '</plist>',
    'ENTEOF',
    '$LDID -S/tmp/ci_ent.xml "$APP_DIR/ChangeInfoIos" 2>/dev/null || echo "ldid sign failed (non-fatal)"',
    'rm -f /tmp/ci_ent.xml',
    '',
    '# --- Step 3: Assemble App Bundle ---',
    'echo "[3/3] Assembling App Bundle..."',
    'cp -f mobile-app-standalone.html "$APP_DIR/"',
    'if [ -f "icon.png" ]; then',
    '    cp -f icon.png "$APP_DIR/AppIcon60x60@2x.png"',
    '    cp -f icon.png "$APP_DIR/AppIcon76x76@2x.png"',
    'fi',
    '',
    'cat > "$APP_DIR/Info.plist" << PLISTEOF',
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '    <key>CFBundleExecutable</key>',
    '    <string>ChangeInfoIos</string>',
    '    <key>CFBundleIdentifier</key>',
    '    <string>com.changeinfoios.app</string>',
    '    <key>CFBundleName</key>',
    '    <string>HIOS Faker</string>',
    '    <key>CFBundleDisplayName</key>',
    '    <string>HIOS Faker</string>',
    '    <key>CFBundlePackageType</key>',
    '    <string>APPL</string>',
    '    <key>CFBundleShortVersionString</key>',
    '    <string>2.2.0</string>',
    '    <key>CFBundleVersion</key>',
    '    <string>2.2.0</string>',
    '    <key>LSRequiresIPhoneOS</key>',
    '    <true/>',
    '    <key>CFBundleIcons</key>',
    '    <dict>',
    '        <key>CFBundlePrimaryIcon</key>',
    '        <dict>',
    '            <key>CFBundleIconFiles</key>',
    '            <array>',
    '                <string>AppIcon60x60</string>',
    '                <string>AppIcon76x76</string>',
    '            </array>',
    '            <key>UIPrerenderedIcon</key>',
    '            <true/>',
    '        </dict>',
    '    </dict>',
    '    <key>UILaunchStoryboardName</key>',
    '    <string></string>',
    '</dict>',
    '</plist>',
    'PLISTEOF',
    '',
    'chown -R root:wheel "$APP_DIR"',
    'chmod 755 "$APP_DIR/ChangeInfoIos"',
    '',
    '# Refresh icon cache (synchronous!)',
    'echo "Refreshing icon cache..."',
    'if command -v uicache &> /dev/null; then',
    '    uicache -p "$APP_DIR" 2>/dev/null',
    'elif [ -x "/var/jb/usr/bin/uicache" ]; then',
    '    /var/jb/usr/bin/uicache -p "$APP_DIR" 2>/dev/null',
    'else',
    '    echo "WARNING: uicache not found, icon may not appear until respring"',
    'fi',
    '',
    'echo ""',
    'echo "================================================"',
    'echo "  DONE! ChangeInfo app is ready."',
    'echo "================================================"',
  ].join('\n');
}

function nativeToolsScript() {
  return [
    '#!/bin/bash',
    '# Install minimum tools for native ChangeInfo build',
    'set -e',
    'echo "[native-tools] updating package lists..."',
    'apt-get update',
    'echo "[native-tools] installing clang + ldid..."',
    'apt-get install -y clang ldid',
    'echo "[native-tools] done. Reinstall package or run:"',
    'echo "  bash /var/mobile/ChangeInfoIos/build-on-device.sh"',
  ].join('\n');
}

// ============================================================
// THEOS MAKEFILE
// ============================================================
function makefile() {
  return [
    '# ChangeInfoIos - Theos Makefile',
    '# THEOS_PACKAGE_SCHEME=rootless make package',
    '',
    'PACKAGE_VERSION = ' + VERSION,
    'ARCHS = arm64 arm64e',
    'TARGET := iphone:clang:16.5:15.0',
    'INSTALL_TARGET_PROCESSES = SpringBoard',
    '',
    'include $(THEOS)/makefiles/common.mk',
    '',
    'TWEAK_NAME = ' + PACKAGE_NAME,
    PACKAGE_NAME + '_FILES = Tweak.xm',
    PACKAGE_NAME + '_CFLAGS = -fobjc-arc -Wno-deprecated-declarations',
    PACKAGE_NAME + '_FRAMEWORKS = UIKit Foundation CoreTelephony CoreLocation SystemConfiguration Security AdSupport WebKit IOKit CoreMotion Metal AppTrackingTransparency',
    PACKAGE_NAME + '_PRIVATE_FRAMEWORKS = MobileGestalt',
    PACKAGE_NAME + '_LDFLAGS = -lsubstrate',
    '',
    'include $(THEOS_MAKE_PATH)/tweak.mk',
  ].join('\n');
}

// ============================================================
// NATIVE APP INFO PLIST (for bundle embedded in .deb)
// ============================================================
function infoPlistForBundle() {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '    <key>CFBundleExecutable</key>',
    '    <string>ChangeInfoIos</string>',
    '    <key>CFBundleIdentifier</key>',
    '    <string>com.changeinfoios.app</string>',
    '    <key>CFBundleName</key>',
    '    <string>HIOS Faker</string>',
    '    <key>CFBundleDisplayName</key>',
    '    <string>HIOS Faker</string>',
    '    <key>CFBundlePackageType</key>',
    '    <string>APPL</string>',
    '    <key>CFBundleShortVersionString</key>',
    '    <string>' + VERSION + '</string>',
    '    <key>CFBundleVersion</key>',
    '    <string>1</string>',
    '    <key>LSRequiresIPhoneOS</key>',
    '    <true/>',
    '    <key>UILaunchStoryboardName</key>',
    '    <string></string>',
    '    <key>CFBundleIcons</key>',
    '    <dict>',
    '        <key>CFBundlePrimaryIcon</key>',
    '        <dict>',
    '            <key>CFBundleIconFiles</key>',
    '            <array>',
    '                <string>AppIcon60x60</string>',
    '                <string>AppIcon76x76</string>',
    '            </array>',
    '            <key>UIPrerenderedIcon</key>',
    '            <true/>',
    '        </dict>',
    '    </dict>',
    '</dict>',
    '</plist>'
  ].join('\n');
}

// ============================================================
// BUILD .DEB
// ============================================================
function build() {
  console.log('');
  console.log('========================================================');
  console.log('  ChangeInfoIos - .deb Builder v3 (Native App)');
  console.log('========================================================');
  console.log('');

  if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

  // 1. Source files
  console.log('[1/6] Reading sources...');
  var tweakSrc = '';
  var tweakPath = path.join(TWEAK_DIR, 'Tweak.xm');
  if (fs.existsSync(tweakPath)) {
    tweakSrc = fs.readFileSync(tweakPath, 'utf-8');
    console.log('  Tweak.xm: ' + tweakSrc.length + ' bytes');
  }
  var mainSrc = '';
  var mainPath = path.join(TWEAK_DIR, 'main.m');
  if (fs.existsSync(mainPath)) {
    mainSrc = fs.readFileSync(mainPath, 'utf-8');
    console.log('  main.m: ' + mainSrc.length + ' bytes');
  }

  // 2. Icons
  console.log('[2/6] Generating icons...');
  var icon = null;
  var iconPath = path.join(__dirname, 'icon.png');
  if (fs.existsSync(iconPath)) {
    var imgData = fs.readFileSync(iconPath);
    // Check if it's a valid PNG
    if (imgData.length > 8 && imgData[0] === 0x89 && imgData[1] === 0x50 && imgData[2] === 0x4E && imgData[3] === 0x47) {
      icon = imgData;
      console.log('  Icon: using icon.png (' + icon.length + ' bytes)');
    }
  }
  if (!icon) {
    icon = makePNG(120, 120);
    console.log('  Icon: 120x120 PNG generated (' + icon.length + ' bytes)');
  }
  var iconB64 = icon.toString('base64');
  console.log('  Icon size: ' + icon.length + ' bytes');

  // 3. control.tar.gz
  console.log('[3/6] Building control...');
  var ctrl = [
    'Package: ' + PACKAGE_ID,
    'Name: ' + PACKAGE_NAME,
    'Version: ' + VERSION,
    'Architecture: ' + ARCH,
    'Description: ' + DESCRIPTION,
    'Maintainer: ' + AUTHOR,
    'Author: ' + AUTHOR,
    'Section: ' + SECTION,
    'Depends: ' + DEPENDS,
    'Tag: role::enduser',
    ''
  ].join('\n');
  var ctrlGz = zlib.gzipSync(tarEnd([
    tarFile('./control', ctrl),
    tarFile('./postinst', postinst(), '100755'),
    tarFile('./prerm', prerm(), '100755'),
    tarFile('./extrainst_', extrainst(), '100755'),
  ]));
  console.log('  control.tar.gz: ' + ctrlGz.length + ' bytes');

  // 4. data.tar.gz
  console.log('[4/6] Building data...');
  // Build standalone HTML from modular sources first
  buildStandaloneHTML();
  // Read the standalone HTML for native app bundle embedding
  var standaloneHTML = '';
  var standaloneHTMLPath = path.join(TWEAK_DIR, 'mobile-app-standalone.html');
  if (fs.existsSync(standaloneHTMLPath)) {
    standaloneHTML = fs.readFileSync(standaloneHTMLPath, 'utf-8');
    
    // Inject user credentials (SHA256 hashed) for offline validation
    var usersFile = path.join(__dirname, 'data', 'users.json');
    var usersDB = [];
    if (fs.existsSync(usersFile)) {
      try {
        var users = JSON.parse(fs.readFileSync(usersFile, 'utf-8'));
        users.forEach(function(u) {
          usersDB.push({
            u: u.username,
            h: u.password, // Already SHA256(password + salt)
            a: u.active !== false
          });
        });
        console.log('  Users embedded: ' + usersDB.length + ' accounts');
      } catch(e) {
        console.log('  Warning: Could not read users.json:', e.message);
      }
    }
    standaloneHTML = standaloneHTML.replace('__USERS_PLACEHOLDER__', JSON.stringify(usersDB));
    const serverIp = getLocalIP();
    standaloneHTML = standaloneHTML.replace("'__CI_SERVER__'", "'" + 'http://' + serverIp + ':3456' + "'");
    console.log('  -> Injected server URL: http://' + serverIp + ':3456');
    console.log('  Standalone HTML: ' + standaloneHTML.length + ' bytes');
  }

  var entries = [
    // --- Tweak filter plist ---
    tarDir('./var'),
    tarDir('./var/jb'),
    tarDir('./var/jb/Library'),
    tarDir('./var/jb/Library/MobileSubstrate'),
    tarDir('./var/jb/Library/MobileSubstrate/DynamicLibraries'),
    tarFile('./var/jb/Library/MobileSubstrate/DynamicLibraries/' + PACKAGE_NAME + '.plist', tweakPlist()),

    // --- Native App Bundle (if clang available, compiled by postinst) ---
    tarDir('./var/jb/Applications'),
    tarDir('./var/jb/Applications/ChangeInfoIos.app'),
    tarFile('./var/jb/Applications/ChangeInfoIos.app/mobile-app-standalone.html', standaloneHTML || '<!-- empty -->'),
    tarFile('./var/jb/Applications/ChangeInfoIos.app/AppIcon60x60@2x.png', icon),
    tarFile('./var/jb/Applications/ChangeInfoIos.app/AppIcon76x76@2x.png', icon),
    tarFile('./var/jb/Applications/ChangeInfoIos.app/Info.plist', infoPlistForBundle()),
    // Note: main.m binary is compiled on-device by postinst

    // --- Source files for reference + manual build ---
    tarDir('./var/mobile/ChangeInfoIos'),
    tarFile('./var/mobile/ChangeInfoIos/Tweak.xm', tweakSrc || '// empty'),
    tarFile('./var/mobile/ChangeInfoIos/main.m', mainSrc || '// empty'),
    tarFile('./var/mobile/ChangeInfoIos/build-on-device.sh', buildScript(), '100755'),
    tarFile('./var/mobile/ChangeInfoIos/install-native-tools.sh', nativeToolsScript(), '100755'),
    tarFile('./var/mobile/ChangeInfoIos/Makefile', makefile()),
    tarFile('./var/mobile/ChangeInfoIos/mobile-app-standalone.html', standaloneHTML || '<!-- empty -->'),
    tarFile('./var/mobile/ChangeInfoIos/Info.plist', infoPlistForBundle()),
    tarFile('./var/mobile/ChangeInfoIos/icon.png', icon),

    // --- Prefs dir ---
    tarDir('./var/mobile/Library/Preferences'),
  ];
  var dataGz = zlib.gzipSync(tarEnd(entries));
  console.log('  data.tar.gz: ' + dataGz.length + ' bytes');

  // 5. Assemble .deb
  console.log('[5/6] Assembling .deb...');
  var deb = Buffer.concat([
    arHeader(),
    arEntry('debian-binary', Buffer.from('2.0\n')),
    arEntry('control.tar.gz', ctrlGz),
    arEntry('data.tar.gz', dataGz),
  ]);

  // 6. Write
  var fname = PACKAGE_ID + '_' + VERSION + '_' + ARCH + '.deb';
  var fpath = path.join(OUTPUT_DIR, fname);
  fs.writeFileSync(fpath, deb);

  console.log('[6/6] Done!');
  console.log('');
  console.log('========================================================');
  console.log('  FILE: ' + fname);
  console.log('  SIZE: ' + (deb.length / 1024).toFixed(1) + ' KB');
  console.log('  PATH: ' + fpath);
  console.log('========================================================');
  console.log('');
  console.log('  Cai dat:');
  console.log('  1. Copy .deb vao iPhone');
  console.log('  2. Sileo hoac dpkg -i <file>.deb');
  console.log('  3. Respring -> Icon "HIOS Faker" xuat hien!');
  console.log('  4. Mo icon -> xem trang trang thai (KHONG crash!)');
  console.log('  5. Optional: SSH > bash /var/mobile/ChangeInfoIos/build-on-device.sh');
  console.log('');

  return fpath;
}

// RUN
var result = build();
var dname = path.basename(result);
var deploy = [
  '#!/bin/bash',
  'IP=${1:-localhost}',
  'PORT=${2:-2222}',
  'DEB="' + dname + '"',
  'scp -P $PORT "packages/$DEB" root@$IP:/var/mobile/',
  'ssh -p $PORT root@$IP "dpkg -i /var/mobile/$DEB && sbreload 2>/dev/null || killall -9 SpringBoard"',
].join('\n');
fs.writeFileSync(path.join(__dirname, 'deploy-deb.sh'), deploy);
console.log('Deploy: deploy-deb.sh');
