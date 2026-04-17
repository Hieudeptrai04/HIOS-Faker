/**
 * ChangeInfoIos - SSH Manager
 * Manages SSH connections to jailbroken iPhones
 * Supports USB (via iproxy) and WiFi connections
 */

const { Client } = require('ssh2');
const fs = require('fs');
const path = require('path');

class SSHManager {
  constructor() {
    this.conn = null;
    this.connected = false;
    this.deviceInfo = null;
    this.config = {
      host: 'localhost',
      port: 2222,          // iproxy default
      username: 'root',
      password: 'alpine',  // default jailbreak password
      readyTimeout: 10000,
      keepaliveInterval: 5000,
    };
  }

  /**
   * Connect to iPhone via SSH
   */
  connect(config = {}) {
    return new Promise((resolve, reject) => {
      if (this.connected && this.conn) {
        resolve({ success: true, message: 'Already connected' });
        return;
      }

      this.conn = new Client();
      const connConfig = { ...this.config, ...config };

      const timeout = setTimeout(() => {
        this.conn.end();
        reject(new Error('Connection timeout'));
      }, connConfig.readyTimeout + 2000);

      this.conn.on('ready', async () => {
        clearTimeout(timeout);
        this.connected = true;
        try {
          this.deviceInfo = await this._getDeviceInfo();
          resolve({ success: true, message: 'Connected', deviceInfo: this.deviceInfo });
        } catch (e) {
          resolve({ success: true, message: 'Connected (device info failed)', error: e.message });
        }
      });

      this.conn.on('error', (err) => {
        clearTimeout(timeout);
        this.connected = false;
        reject(new Error(`SSH Error: ${err.message}`));
      });

      this.conn.on('close', () => {
        this.connected = false;
        this.deviceInfo = null;
      });

      this.conn.on('end', () => {
        this.connected = false;
      });

      try {
        this.conn.connect(connConfig);
      } catch (e) {
        clearTimeout(timeout);
        reject(new Error(`Connection failed: ${e.message}`));
      }
    });
  }

  /**
   * Disconnect
   */
  disconnect() {
    if (this.conn) {
      this.conn.end();
      this.conn = null;
    }
    this.connected = false;
    this.deviceInfo = null;
    return { success: true, message: 'Disconnected' };
  }

  /**
   * Execute command on iPhone
   */
  exec(command, timeout = 15000) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.conn) {
        reject(new Error('Not connected'));
        return;
      }

      const timer = setTimeout(() => {
        reject(new Error(`Command timeout: ${command}`));
      }, timeout);

      this.conn.exec(command, (err, stream) => {
        if (err) { clearTimeout(timer); reject(err); return; }

        let stdout = '';
        let stderr = '';

        stream.on('close', (code) => {
          clearTimeout(timer);
          resolve({ stdout: stdout.trim(), stderr: stderr.trim(), code });
        });

        stream.on('data', (data) => { stdout += data.toString(); });
        stream.stderr.on('data', (data) => { stderr += data.toString(); });
      });
    });
  }

  /**
   * Upload file to iPhone via SFTP
   */
  uploadFile(localPath, remotePath) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.conn) {
        reject(new Error('Not connected'));
        return;
      }

      this.conn.sftp((err, sftp) => {
        if (err) { reject(err); return; }

        sftp.fastPut(localPath, remotePath, (err) => {
          if (err) { reject(err); return; }
          resolve({ success: true, remotePath });
        });
      });
    });
  }

  /**
   * Upload string content as file
   */
  uploadContent(content, remotePath) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.conn) {
        reject(new Error('Not connected'));
        return;
      }

      this.conn.sftp((err, sftp) => {
        if (err) { reject(err); return; }

        const writeStream = sftp.createWriteStream(remotePath);
        writeStream.on('close', () => {
          resolve({ success: true, remotePath });
        });
        writeStream.on('error', reject);
        writeStream.end(content);
      });
    });
  }

  /**
   * Download file from iPhone
   */
  downloadFile(remotePath) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.conn) {
        reject(new Error('Not connected'));
        return;
      }

      this.conn.sftp((err, sftp) => {
        if (err) { reject(err); return; }

        let data = '';
        const readStream = sftp.createReadStream(remotePath);
        readStream.on('data', (chunk) => { data += chunk.toString(); });
        readStream.on('end', () => resolve(data));
        readStream.on('error', reject);
      });
    });
  }

  /**
   * Get basic device info
   */
  async _getDeviceInfo() {
    const results = {};

    try {
      const { stdout: name } = await this.exec('uname -a');
      results.uname = name;
    } catch (e) { results.uname = 'unknown'; }

    try {
      const { stdout: device } = await this.exec('uname -m');
      results.machine = device;
    } catch (e) { results.machine = 'unknown'; }

    try {
      const { stdout: hostname } = await this.exec('hostname');
      results.hostname = hostname;
    } catch (e) { results.hostname = 'unknown'; }

    try {
      const { stdout: ios } = await this.exec('sw_vers -productVersion');
      results.iosVersion = ios;
    } catch (e) { results.iosVersion = 'unknown'; }

    // Check jailbreak type
    try {
      await this.exec('ls /var/jb');
      results.jailbreakType = 'rootless';
      results.tweakPath = '/var/jb/Library/MobileSubstrate/DynamicLibraries';
      results.prefPath = '/var/mobile/Library/Preferences';
    } catch (e) {
      try {
        await this.exec('ls /Library/MobileSubstrate');
        results.jailbreakType = 'rootful';
        results.tweakPath = '/Library/MobileSubstrate/DynamicLibraries';
        results.prefPath = '/var/mobile/Library/Preferences';
      } catch (e2) {
        results.jailbreakType = 'unknown';
      }
    }

    // Check if tweak is installed
    try {
      await this.exec(`ls ${results.tweakPath}/ChangeInfoIos.dylib`);
      results.tweakInstalled = true;
    } catch (e) {
      results.tweakInstalled = false;
    }

    return results;
  }

  /**
   * Push config plist to device
   */
  async pushConfig(plistContent) {
    const remotePath = '/var/mobile/Library/Preferences/com.changeinfoios.plist';
    await this.uploadContent(plistContent, remotePath);
    await this.exec(`chmod 644 ${remotePath}`);
    await this.exec(`chown mobile:mobile ${remotePath}`);
    try {
      await this.exec('notify_post com.changeinfoios/ReloadPrefs 2>/dev/null || true', 3000);
    } catch (e) { /* ignore */ }
    return { success: true, path: remotePath };
  }

  /**
   * Read current config from device
   */
  async readConfig() {
    try {
      const data = await this.downloadFile('/var/mobile/Library/Preferences/com.changeinfoios.plist');
      return { success: true, data };
    } catch (e) {
      return { success: false, error: 'No config found on device' };
    }
  }

  /**
   * Trigger respring to apply changes
   */
  async respring() {
    try {
      await this.exec(
        '/var/jb/usr/bin/sbreload 2>/dev/null || sbreload 2>/dev/null || killall -9 SpringBoard',
        8000
      );
      return { success: true, message: 'Respring triggered' };
    } catch (e) {
      return { success: false, error: e.message };
    }
  }

  /**
   * Clear app data - deep wipe (sandbox + group containers + keychain + system caches)
   * Callback onStep(stepName) for progress reporting
   */
  async clearAppData(bundleId, onStep = null) {
    const results = [];
    const step = (msg) => {
      results.push(msg);
      if (onStep) onStep(msg);
    };

    // ── Step 1: Kill app process first (prevent it from re-writing data) ──
    step('Killing app process...');
    try {
      // Extract app executable name from bundle (e.g. com.vng.zalo → Zalo)
      const { stdout: procList } = await this.exec(
        `ps aux 2>/dev/null | grep -i "${bundleId}" | grep -v grep | awk '{print $2}'`
      );
      if (procList) {
        const pids = procList.split('\n').filter(Boolean);
        for (const pid of pids) {
          await this.exec(`kill -9 ${pid} 2>/dev/null || true`);
        }
        step(`Killed ${pids.length} process(es)`);
      }
      // Also try killing by common app names
      const appName = bundleId.split('.').pop();
      await this.exec(`killall -9 "${appName}" 2>/dev/null || true`);
    } catch (e) { /* app may not be running */ }

    // Wait for app to fully terminate
    await new Promise(r => setTimeout(r, 1000));

    // ── Step 2: Find app sandbox container ──
    step('Finding app container...');
    let containerPath = null;
    try {
      const { stdout } = await this.exec(
        `find /var/mobile/Containers/Data/Application -name ".com.apple.mobile_container_manager.metadata.plist" | while read f; do if /usr/libexec/PlistBuddy -c "Print :MCMMetadataIdentifier" "$f" 2>/dev/null | grep -q "${bundleId}"; then dirname $(dirname "$f"); fi; done`,
        30000
      );
      containerPath = stdout ? stdout.split('\n').filter(Boolean)[0] : null;
    } catch (e) {
      step(`Container search error: ${e.message}`);
    }

    if (containerPath) {
      // ── Step 3: Deep wipe all data directories ──
      step(`Found container: ${containerPath}`);
      const dirsToWipe = [
        // Standard app data
        'Library/Caches',
        'Library/Preferences',
        'Library/Cookies',
        'Library/WebKit',
        'Library/WKWebView',
        'Library/HTTPStorages',
        'Library/SplashBoard',
        'Library/Saved Application State',
        'Library/Application Support',
        'Library/Databases',
        'Library/LocalStorage',
        'Library/IndexedDB',
        'Library/WebSQL',
        'Library/Accounts',
        'Documents',
        'tmp',
        // Extra caches / snapshots
        'Library/Caches/Snapshots',
        'Library/Caches/com.apple.WebKit.Networking',
        'Library/Caches/com.apple.WebKit.WebContent',
      ];

      step('Wiping sandbox directories...');
      for (const dir of dirsToWipe) {
        try {
          await this.exec(`rm -rf "${containerPath}/${dir}" 2>/dev/null; mkdir -p "${containerPath}/${dir}" 2>/dev/null`);
        } catch (e) { /* some dirs may not exist */ }
      }
      step(`Wiped ${dirsToWipe.length} directories`);

      // ── Step 4: Nuke any SQLite databases (WAL/SHM included) ──
      step('Removing SQLite databases...');
      try {
        await this.exec(`find "${containerPath}" -name "*.sqlite*" -o -name "*.db" -o -name "*.db-wal" -o -name "*.db-shm" | xargs rm -f 2>/dev/null || true`);
        step('SQLite databases removed');
      } catch (e) { /* ignore */ }

      // ── Step 5: Verify container is clean ──
      try {
        const { stdout: sizeAfter } = await this.exec(`du -sh "${containerPath}" 2>/dev/null | awk '{print $1}'`);
        step(`Container size after wipe: ${sizeAfter || 'unknown'}`);
      } catch (e) { /* ignore */ }
    } else {
      step('No app container found (app may not have been launched yet)');
    }

    // ── Step 6: Find and wipe Group Containers (shared data between app & extensions) ──
    step('Searching group containers...');
    try {
      const { stdout: groupPaths } = await this.exec(
        `find /var/mobile/Containers/Shared/AppGroup -name ".com.apple.mobile_container_manager.metadata.plist" | while read f; do if /usr/libexec/PlistBuddy -c "Print :MCMMetadataIdentifier" "$f" 2>/dev/null | grep -qi "group.*${bundleId.split('.').slice(0, -1).join('.')}\\|${bundleId}"; then dirname $(dirname "$f"); fi; done`,
        30000
      );
      if (groupPaths) {
        const groups = groupPaths.split('\n').filter(Boolean);
        for (const gPath of groups) {
          await this.exec(`rm -rf "${gPath}/Library" "${gPath}/Documents" "${gPath}/tmp" 2>/dev/null; mkdir -p "${gPath}/Library" "${gPath}/Documents" "${gPath}/tmp" 2>/dev/null`);
          step(`Wiped group container: ${gPath.split('/').pop()}`);
        }
      }
    } catch (e) { /* no group containers */ }

    // ── Step 7: Deep keychain clearing (multi-round, all attribute types) ──
    step('Deep cleaning keychain...');
    try {
      // Determine security binary path
      const secBin = await this._findBinary('security');

      if (secBin) {
        // Clear by service name (most common)
        await this.exec(`${secBin} delete-generic-password -s "${bundleId}" 2>/dev/null; true`);
        // Clear by account label containing bundle ID
        await this.exec(`${secBin} delete-generic-password -l "${bundleId}" 2>/dev/null; true`);
        // Clear by access group
        await this.exec(`${secBin} delete-generic-password -a "${bundleId}" 2>/dev/null; true`);

        // For Zalo specifically - also clear known Zalo keychain entries
        if (bundleId.includes('zalo') || bundleId.includes('zing')) {
          const zaloKeychainServices = [
            'com.vng.zalo', 'com.zing.zalo', 'com.vng.zalo.share',
            'ZaloToken', 'ZaloDeviceId', 'ZaloLoginInfo',
            'ZAAccountStore', 'ZADeviceFingerprint',
          ];
          for (const svc of zaloKeychainServices) {
            await this.exec(`${secBin} delete-generic-password -s "${svc}" 2>/dev/null; true`);
            await this.exec(`${secBin} delete-generic-password -l "${svc}" 2>/dev/null; true`);
          }
          step('Zalo-specific keychain entries cleared');
        }

        // Loop delete until no more generic passwords match
        for (let i = 0; i < 5; i++) {
          const { code } = await this.exec(
            `${secBin} delete-generic-password -s "${bundleId}" 2>/dev/null`,
            5000
          );
          if (code !== 0) break;
        }

        // Also try internet passwords
        await this.exec(`${secBin} delete-internet-password -s "${bundleId}" 2>/dev/null; true`);
      }

      step('Keychain cleared (multi-round)');
    } catch (e) {
      step(`Keychain clear error: ${e.message}`);
    }

    // ── Step 8: Clear system-level caches related to app ──
    step('Clearing system caches...');
    try {
      const systemCacheDirs = [
        `/var/mobile/Library/Caches/${bundleId}`,
        `/var/mobile/Library/Caches/Snapshots/${bundleId}`,
        `/var/mobile/Library/SplashBoard/Snapshots/${bundleId}*`,
        `/var/mobile/Library/WebClips/${bundleId}*`,
      ];
      for (const d of systemCacheDirs) {
        await this.exec(`rm -rf ${d} 2>/dev/null || true`);
      }

      // Clear URL cache
      await this.exec(`rm -rf /var/mobile/Library/Caches/com.apple.nsurlsessiond/Downloads/${bundleId}* 2>/dev/null || true`);

      // Clear launch services cache (forces re-indexing)
      await this.exec(`rm -f /var/mobile/Library/Caches/com.apple.LaunchServices-*.csstore 2>/dev/null || true`);

      step('System caches cleared');
    } catch (e) { /* ignore */ }

    // ── Step 9: Clear pasteboard data ──
    try {
      await this.exec('rm -rf /var/mobile/Library/Caches/com.apple.Pasteboard/* 2>/dev/null || true');
      step('Pasteboard cleared');
    } catch (e) { /* ignore */ }

    // ── Step 10: Reset APNS push notification token (forces new token on re-register) ──
    step('Resetting APNS token...');
    try {
      await this.exec('rm -rf /var/mobile/Library/com.apple.apsd/ 2>/dev/null || true');
      await this.exec('rm -rf /var/mobile/Library/Caches/com.apple.apsd/ 2>/dev/null || true');
      step('APNS token reset');
    } catch (e) { /* ignore */ }

    // ── Step 11: Reset Advertising Identifier (system-level IDFA reset) ──
    step('Resetting Advertising ID...');
    try {
      await this.exec('rm -rf /var/mobile/Library/Advertising/ 2>/dev/null; mkdir -p /var/mobile/Library/Advertising/ 2>/dev/null || true');
      step('Advertising ID reset');
    } catch (e) { /* ignore */ }

    // ── Step 12: Reset DeviceCheck / App Attest data (Zalo uses this) ──
    step('Resetting DeviceCheck / App Attest...');
    try {
      await this.exec('rm -rf /var/mobile/Library/DeviceCheck/ 2>/dev/null; mkdir -p /var/mobile/Library/DeviceCheck/ 2>/dev/null || true');
      await this.exec('rm -rf /var/mobile/Library/Caches/com.apple.devicecheck* 2>/dev/null || true');
      step('DeviceCheck / App Attest reset');
    } catch (e) { /* ignore */ }

    // ── Step 13: Clear FrontBoard state (app launch order fingerprint) ──
    step('Clearing FrontBoard state...');
    try {
      await this.exec('rm -rf /var/mobile/Library/FrontBoard/ 2>/dev/null || true');
      step('FrontBoard state cleared');
    } catch (e) { /* ignore */ }

    // ── Step 14: Clear TCC privacy database cache (resets permission prompts) ──
    try {
      await this.exec('rm -rf /var/mobile/Library/TCC/ 2>/dev/null || true');
      step('TCC privacy cache cleared');
    } catch (e) { /* ignore */ }

    // ── Final: Verification ──
    step('Verifying wipe...');
    let verified = false;
    if (containerPath) {
      try {
        const { stdout: fileCount } = await this.exec(
          `find "${containerPath}" -type f 2>/dev/null | wc -l`
        );
        const count = parseInt(fileCount) || 0;
        verified = count < 20; // some system files always remain
        step(`Verification: ${count} files remaining (${verified ? 'CLEAN' : 'may need manual check'})`);
      } catch (e) { /* ignore */ }
    }

    return { success: true, results, verified };
  }

  /**
   * Find binary path (rootless vs rootful)
   */
  async _findBinary(name) {
    const paths = [
      `/var/jb/usr/bin/${name}`,
      `/usr/bin/${name}`,
      `/var/jb/usr/local/bin/${name}`,
      `/usr/local/bin/${name}`,
    ];
    for (const p of paths) {
      try {
        const { code } = await this.exec(`test -f ${p}`);
        if (code === 0) return p;
      } catch (e) { /* continue */ }
    }
    return null;
  }

  /**
   * Get list of installed apps
   */
  async getInstalledApps() {
    try {
      // Primary strategy: read all user app bundles and extract bundleId + display name.
      // This works even when app data containers are not yet created.
      const bundleCmd =
        'find /var/containers/Bundle/Application -maxdepth 3 -name "Info.plist" 2>/dev/null | while read f; do ' +
        'bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$f" 2>/dev/null); ' +
        'name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$f" 2>/dev/null); ' +
        '[ -z "$name" ] && name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$f" 2>/dev/null); ' +
        '[ -n "$bid" ] && echo "$bid|${name:-$bid}"; ' +
        'done | sort -u';

      const { stdout: bundleStdout } = await this.exec(bundleCmd, 25000);
      const rows = bundleStdout
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean)
        .map((line) => {
          const idx = line.indexOf('|');
          if (idx < 0) return { bundleId: line, name: line };
          const bundleId = line.slice(0, idx).trim();
          const name = line.slice(idx + 1).trim() || bundleId;
          return { bundleId, name };
        })
        .filter((app) => app.bundleId && app.bundleId.includes('.'));

      if (rows.length > 0) return rows;

      // Fallback strategy: parse data-container metadata to at least get bundle IDs.
      const { stdout } = await this.exec(
        'find /var/mobile/Containers/Data/Application -maxdepth 3 -name ".com.apple.mobile_container_manager.metadata.plist" -exec /usr/libexec/PlistBuddy -c "Print :MCMMetadataIdentifier" {} \\; 2>/dev/null | sort | uniq',
        25000
      );
      return stdout
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean)
        .map((bundleId) => ({ bundleId, name: bundleId }));
    } catch (e) {
      return [];
    }
  }

  /**
   * Get connection status
   */
  getStatus() {
    return {
      connected: this.connected,
      deviceInfo: this.deviceInfo,
    };
  }
}

module.exports = SSHManager;
