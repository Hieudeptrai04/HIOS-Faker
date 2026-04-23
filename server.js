/**
 * ChangeInfoIos - Web Server v2
 * Express server with Authentication, Auto-Clear, Selective Random
 */

const express = require('express');
const path = require('path');
const multer = require('multer');
const SSHManager = require('./lib/ssh-manager');
const ProfileManager = require('./lib/profile-manager');
const AuthManager = require('./lib/auth-manager');
const paramGen = require('./lib/param-generator');

const app = express();
const PORT = 3456;

// Middleware
app.use(express.json({ limit: '5mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

// CORS
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Content-Type, X-Auth-Token');
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

const upload = multer({ storage: multer.memoryStorage() });

// Instances
const ssh = new SSHManager();
const profiles = new ProfileManager();
const auth = new AuthManager();

// Current state per user (simplified - single user for now)
let currentProfile = null;
let logs = [];
let autoClearApps = ['com.vng.zalo', 'com.apple.mobilesafari']; // Default auto-clear Zalo and Safari

function addLog(type, message) {
  const entry = { time: new Date().toISOString(), type, message };
  logs.unshift(entry);
  if (logs.length > 500) logs.pop();
  return entry;
}

// ============================================================
// AUTH MIDDLEWARE
// ============================================================
function requireAuth(req, res, next) {
  const token = req.headers['x-auth-token'] || req.query.token;
  const session = auth.validateToken(token);
  if (!session) {
    return res.status(401).json({ success: false, error: 'Chưa đăng nhập hoặc phiên hết hạn' });
  }
  req.session = session;
  req.authToken = token;
  next();
}

function requireAdmin(req, res, next) {
  if (req.session.role !== 'admin') {
    return res.status(403).json({ success: false, error: 'Cần quyền admin' });
  }
  next();
}

// ============================================================
// AUTH ROUTES (No auth required)
// ============================================================
app.post('/api/auth/login', (req, res) => {
  const { username, password } = req.body;
  const result = auth.login(username, password);
  if (result.success) {
    addLog('success', `User "${username}" logged in`);
  } else {
    addLog('warning', `Login failed for "${username}": ${result.error}`);
  }
  res.json(result);
});

app.post('/api/auth/logout', (req, res) => {
  const token = req.headers['x-auth-token'];
  if (token) auth.logout(token);
  res.json({ success: true });
});

app.get('/api/auth/check', (req, res) => {
  const token = req.headers['x-auth-token'];
  const session = auth.validateToken(token);
  if (session) {
    res.json({ success: true, user: session });
  } else {
    res.json({ success: false });
  }
});

app.post('/api/auth/change-password', requireAuth, (req, res) => {
  const { oldPassword, newPassword } = req.body;
  res.json(auth.changePassword(req.authToken, oldPassword, newPassword));
});

// ============================================================
// ADMIN ROUTES
// ============================================================
app.get('/api/admin/users', requireAuth, requireAdmin, (req, res) => {
  res.json(auth.listUsers(req.authToken));
});

app.post('/api/admin/users', requireAuth, requireAdmin, (req, res) => {
  res.json(auth.createUser(req.authToken, req.body));
});

app.put('/api/admin/users/:id', requireAuth, requireAdmin, (req, res) => {
  res.json(auth.updateUser(req.authToken, req.params.id, req.body));
});

app.delete('/api/admin/users/:id', requireAuth, requireAdmin, (req, res) => {
  res.json(auth.deleteUser(req.authToken, req.params.id));
});

// ============================================================
// LICENSE KEY ROUTES (Admin only - for generating offline keys)
// ============================================================
app.post('/api/admin/license/generate', requireAuth, requireAdmin, (req, res) => {
  const result = auth.generateSimpleKey(req.authToken, req.body || {});
  if (result.success) addLog('success', `License key generated: ${result.key}`);
  res.json(result);
});

app.get('/api/admin/licenses', requireAuth, requireAdmin, (req, res) => {
  res.json(auth.listLicenses(req.authToken));
});

app.post('/api/admin/license/revoke', requireAuth, requireAdmin, (req, res) => {
  const { key } = req.body;
  res.json(auth.revokeLicense(req.authToken, key));
});

// ============================================================
// SSH ROUTES (Auth required)
// ============================================================
app.post('/api/ssh/connect', requireAuth, async (req, res) => {
  try {
    const { host, port, username, password } = req.body;
    const config = {};
    if (host) config.host = host;
    if (port) config.port = parseInt(port);
    if (username) config.username = username;
    if (password) config.password = password;

    addLog('info', `[${req.session.username}] Connecting to ${config.host || 'localhost'}:${config.port || 2222}...`);
    const result = await ssh.connect(config);
    addLog('success', `[${req.session.username}] Connected! ${result.deviceInfo?.iosVersion || ''}`);
    res.json(result);
  } catch (e) {
    addLog('error', `Connection failed: ${e.message}`);
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/ssh/disconnect', requireAuth, (req, res) => {
  const result = ssh.disconnect();
  addLog('info', `[${req.session.username}] Disconnected`);
  res.json(result);
});

app.get('/api/ssh/status', requireAuth, (req, res) => {
  res.json(ssh.getStatus());
});

app.post('/api/ssh/exec', requireAuth, async (req, res) => {
  try {
    const result = await ssh.exec(req.body.command);
    res.json({ success: true, ...result });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/ssh/respring', requireAuth, async (req, res) => {
  try {
    addLog('info', 'Triggering respring...');
    const result = await ssh.respring();
    addLog('success', 'Respring triggered');
    res.json(result);
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ============================================================
// PROFILE ROUTES (Auth required)
// ============================================================
app.get('/api/profiles', requireAuth, (req, res) => {
  res.json(profiles.list());
});

app.post('/api/profiles/save', requireAuth, (req, res) => {
  try {
    const { name, profile } = req.body;
    const result = profiles.save(name, profile || currentProfile);
    addLog('success', `Profile "${name}" saved by ${req.session.username}`);
    res.json(result);
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/profiles/load', requireAuth, (req, res) => {
  try {
    const data = profiles.load(req.body.name);
    currentProfile = data.profile;
    addLog('success', `Profile "${req.body.name}" loaded`);
    res.json({ success: true, profile: currentProfile });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/profiles/delete', requireAuth, (req, res) => {
  try {
    profiles.delete(req.body.name);
    res.json({ success: true });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.get('/api/profiles/export/:name', requireAuth, (req, res) => {
  try {
    const json = profiles.exportProfile(req.params.name);
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Content-Disposition', `attachment; filename="${req.params.name}.json"`);
    res.send(json);
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.post('/api/profiles/import', requireAuth, upload.single('file'), (req, res) => {
  try {
    const json = req.file.buffer.toString('utf-8');
    const result = profiles.importProfile(json, req.body.name);
    res.json(result);
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ============================================================
// PARAMETER ROUTES (Auth required)
// ============================================================

// Full random generate
app.post('/api/generate', requireAuth, (req, res) => {
  try {
    currentProfile = paramGen.generateFullProfile(req.body || {});
    addLog('success', `Full random: ${currentProfile.MarketingName} - iOS ${currentProfile.systemVersion}`);
    res.json({ success: true, profile: currentProfile });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ★ SELECTIVE RANDOM - Only randomize checked fields
app.post('/api/generate-selective', requireAuth, (req, res) => {
  try {
    const { selectedKeys, options } = req.body;
    // selectedKeys = array of param keys to randomize
    // options = { productType, iosVersion, carrierRegion, etc. }

    // Generate a fresh full profile for random values
    const freshProfile = paramGen.generateFullProfile(options || {});

    if (!currentProfile) {
      // If no existing profile, use the full fresh one
      currentProfile = freshProfile;
    } else {
      // Only update selected keys
      if (selectedKeys && selectedKeys.length > 0) {
        for (const key of selectedKeys) {
          if (freshProfile[key] !== undefined) {
            currentProfile[key] = freshProfile[key];
          }
        }
        currentProfile._generated = new Date().toISOString();
      } else {
        // No keys selected = random all
        currentProfile = freshProfile;
      }
    }

    addLog('success', `Selective random: ${selectedKeys ? selectedKeys.length : 'ALL'} params updated`);
    res.json({ success: true, profile: currentProfile });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.get('/api/current-profile', requireAuth, (req, res) => {
  res.json({ profile: currentProfile });
});

app.post('/api/update-param', requireAuth, (req, res) => {
  try {
    const { key, value } = req.body;
    if (!currentProfile) currentProfile = paramGen.generateFullProfile();
    currentProfile = paramGen.updateSingleParam(currentProfile, key, value);
    res.json({ success: true, profile: currentProfile });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.get('/api/devices', (req, res) => {
  res.json(paramGen.getDeviceList());
});

app.get('/api/ios-versions', (req, res) => {
  res.json(paramGen.getIOSVersionList());
});

app.get('/api/carriers', (req, res) => {
  res.json(paramGen.getCarrierList());
});

// ============================================================
// DEPLOY ROUTES - ★ AUTO CLEAR DATA ON DEPLOY
// ============================================================

// Get/Set auto-clear apps list
app.get('/api/auto-clear-apps', requireAuth, (req, res) => {
  res.json({ apps: autoClearApps });
});

app.post('/api/auto-clear-apps', requireAuth, (req, res) => {
  autoClearApps = req.body.apps || [];
  res.json({ success: true, apps: autoClearApps });
});

// Push config only
app.post('/api/deploy/push-config', requireAuth, async (req, res) => {
  try {
    if (!currentProfile) return res.status(400).json({ success: false, error: 'Chưa có profile' });

    const plistContent = paramGen.profileToPlist(currentProfile);
    addLog('info', 'Pushing config...');
    const result = await ssh.pushConfig(plistContent);
    addLog('success', `Config pushed to ${result.path}`);
    res.json(result);
  } catch (e) {
    addLog('error', `Push failed: ${e.message}`);
    res.status(500).json({ success: false, error: e.message });
  }
});

// ★ DEPLOY WITH AUTO-CLEAR + RESPRING (deep wipe)
app.post('/api/deploy/full', requireAuth, async (req, res) => {
  try {
    if (!currentProfile) return res.status(400).json({ success: false, error: 'Chưa có profile' });

    const startTime = Date.now();
    const results = [];
    const steps = [];

    const logStep = (phase, msg) => {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      const entry = { phase, message: msg, elapsed: `${elapsed}s` };
      steps.push(entry);
      addLog('info', `[${elapsed}s] ${phase}: ${msg}`);
    };

    // Step 1: Deep wipe data for all configured apps
    if (autoClearApps.length > 0) {
      logStep('CLEAR', `Starting deep wipe for ${autoClearApps.length} app(s)...`);

      for (const bundleId of autoClearApps) {
        try {
          logStep('CLEAR', `Wiping ${bundleId}...`);
          const clearResult = await ssh.clearAppData(bundleId, (stepMsg) => {
            logStep('CLEAR', `[${bundleId}] ${stepMsg}`);
          });
          results.push({
            app: bundleId,
            status: clearResult.verified ? 'verified_clean' : 'cleared',
            details: clearResult.results,
            verified: clearResult.verified,
          });
          logStep('CLEAR', `✅ ${bundleId} wiped (${clearResult.results.length} operations)`);
        } catch (e) {
          results.push({ app: bundleId, status: 'error', error: e.message });
          logStep('CLEAR', `⚠️ ${bundleId} failed: ${e.message}`);
        }
      }
    }

    // Step 2: Wait for filesystem sync after heavy deletion
    logStep('SYNC', 'Waiting for filesystem sync...');
    await new Promise(r => setTimeout(r, 2000));

    // Step 3: Push new config
    logStep('CONFIG', 'Pushing new device config...');
    const plistContent = paramGen.profileToPlist(currentProfile);
    await ssh.pushConfig(plistContent);
    logStep('CONFIG', '✅ Config pushed');

    // Step 4: Clear UIKit snapshot caches (system-wide)
    logStep('SYSTEM', 'Clearing system snapshot caches...');
    try {
      await ssh.exec('rm -rf /var/mobile/Library/Caches/com.apple.UIKit.pboard 2>/dev/null; rm -rf /var/mobile/Library/Caches/TCC 2>/dev/null; true');
    } catch (e) { /* ignore */ }

    // Step 5: Wait before respring to let filesystem settle
    logStep('SYNC', 'Preparing respring...');
    await new Promise(r => setTimeout(r, 1500));

    // Step 6: Respring
    logStep('RESPRING', 'Triggering respring...');
    try {
      await ssh.respring();
      logStep('RESPRING', '✅ Respring triggered');
    } catch (e) {
      logStep('RESPRING', `Respring: ${e.message} (có thể đã thành công)`);
    }

    const totalTime = ((Date.now() - startTime) / 1000).toFixed(1);
    addLog('success', `✅ Full deploy completed in ${totalTime}s - ${results.length} app(s) wiped`);

    res.json({
      success: true,
      message: `Deep wipe + Deploy + Respring completed in ${totalTime}s`,
      totalTime: `${totalTime}s`,
      clearResults: results,
      steps,
    });
  } catch (e) {
    addLog('error', `Deploy failed: ${e.message}`);
    res.status(500).json({ success: false, error: e.message });
  }
});

// ============================================================
// CLEAR DATA ROUTES (Auth required)
// ============================================================
app.post('/api/clear-app', requireAuth, async (req, res) => {
  try {
    const { bundleId } = req.body;
    addLog('info', `Clearing ${bundleId}...`);
    const result = await ssh.clearAppData(bundleId);
    addLog('success', `Cleared: ${result.results.join(', ')}`);
    res.json(result);
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

app.get('/api/installed-apps', requireAuth, async (req, res) => {
  try {
    const apps = await ssh.getInstalledApps();
    res.json(apps);
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ============================================================
// LOGS
// ============================================================
app.get('/api/logs', requireAuth, (req, res) => {
  res.json(logs);
});

app.post('/api/logs/clear', requireAuth, (req, res) => {
  logs = [];
  res.json({ success: true });
});

// ============================================================
// START
// ============================================================
app.listen(PORT, () => {
  addLog('info', `Server started on port ${PORT}`);
  console.log(`
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     ██████╗██╗  ██╗ █████╗ ███╗   ██╗ ██████╗            ║
║    ██╔════╝██║  ██║██╔══██╗████╗  ██║██╔════╝            ║
║    ██║     ███████║███████║██╔██╗ ██║██║  ███╗           ║
║    ██║     ██╔══██║██╔══██║██║╚██╗██║██║   ██║           ║
║    ╚██████╗██║  ██║██║  ██║██║ ╚████║╚██████╔╝           ║
║     ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝            ║
║                                                           ║
║           ChangeInfoIos - Device Spoofer v2               ║
║          iOS 15-16.7 | Rootless Jailbreak                 ║
║                                                           ║
║    Dashboard:  http://localhost:${PORT}                      ║
║    Admin:      admin / admin123                           ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
  `);
});
