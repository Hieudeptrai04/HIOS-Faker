/**
 * ChangeInfoIos - Frontend Application v2
 * With Authentication, Selective Random, Admin Panel, Auto-Clear
 */

// ============================================================
// STATE
// ============================================================
let currentProfile = null;
let isConnected = false;
let authToken = localStorage.getItem('auth_token') || null;
let currentUser = null;

// ============================================================
// API HELPER (with auth)
// ============================================================
async function api(endpoint, options = {}) {
  const headers = {};
  if (authToken) headers['X-Auth-Token'] = authToken;
  if (options.body) headers['Content-Type'] = 'application/json';

  const res = await fetch(`/api${endpoint}`, {
    method: options.method || 'GET',
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

  const data = await res.json();

  if (res.status === 401) {
    // Token expired / invalid
    authToken = null;
    localStorage.removeItem('auth_token');
    showLoginScreen();
    throw new Error('Phiên đăng nhập hết hạn');
  }

  if (!res.ok) throw new Error(data.error || 'Request failed');
  return data;
}

// ============================================================
// AUTH / LOGIN
// ============================================================
async function doLogin() {
  const username = document.getElementById('login-user').value.trim();
  const password = document.getElementById('login-pass').value;
  const errorEl = document.getElementById('login-error');

  if (!username || !password) {
    errorEl.textContent = 'Nhập tài khoản và mật khẩu';
    return;
  }

  const btn = document.getElementById('btn-login');
  btn.disabled = true;
  btn.textContent = 'Đang đăng nhập...';
  errorEl.textContent = '';

  try {
    const result = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    }).then(r => r.json());

    if (result.success) {
      authToken = result.token;
      currentUser = result.user;
      localStorage.setItem('auth_token', authToken);
      showAppScreen();
      showToast('success', `✅ Xin chào, ${currentUser.username}!`);
    } else {
      errorEl.textContent = result.error || 'Đăng nhập thất bại';
    }
  } catch (e) {
    errorEl.textContent = 'Lỗi kết nối server';
  }

  btn.disabled = false;
  btn.textContent = 'Đăng Nhập';
}

async function doLogout() {
  try { await api('/auth/logout', { method: 'POST' }); } catch (e) {}
  authToken = null;
  currentUser = null;
  localStorage.removeItem('auth_token');
  showLoginScreen();
}

function showLoginScreen() {
  document.getElementById('login-screen').style.display = 'flex';
  document.getElementById('app-container').style.display = 'none';
}

function showAppScreen() {
  document.getElementById('login-screen').style.display = 'none';
  document.getElementById('app-container').style.display = 'flex';

  // Update UI
  document.getElementById('user-display').textContent = `👤 ${currentUser?.username || 'User'} (${currentUser?.role || 'user'})`;

  // Show admin tab if admin
  if (currentUser?.role === 'admin') {
    document.getElementById('nav-admin').style.display = 'flex';
    document.getElementById('admin-divider').style.display = 'block';
  } else {
    document.getElementById('nav-admin').style.display = 'none';
    document.getElementById('admin-divider').style.display = 'none';
  }

  initApp();
}

// Enter key to login
document.getElementById('login-pass')?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') doLogin();
});
document.getElementById('login-user')?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') document.getElementById('login-pass').focus();
});

// ============================================================
// TAB NAVIGATION
// ============================================================
function switchTab(tabName) {
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));

  const navBtn = document.querySelector(`[data-tab="${tabName}"]`);
  const tabPanel = document.getElementById(`tab-${tabName}`);
  if (navBtn) navBtn.classList.add('active');
  if (tabPanel) tabPanel.classList.add('active');

  if (tabName === 'profiles') loadProfiles();
  if (tabName === 'logs') refreshLogs();
  if (tabName === 'admin') loadAdminUsers();
}

document.querySelectorAll('.nav-item').forEach(btn => {
  btn.addEventListener('click', () => switchTab(btn.dataset.tab));
});

// ============================================================
// SSH CONNECTION
// ============================================================
async function connectSSH() {
  const btn = document.getElementById('btn-connect');
  btn.disabled = true;
  btn.innerHTML = '<div class="spinner"></div> Kết nối...';

  try {
    const result = await api('/ssh/connect', {
      method: 'POST',
      body: {
        host: document.getElementById('ssh-host').value,
        port: document.getElementById('ssh-port').value,
        username: document.getElementById('ssh-user').value,
        password: document.getElementById('ssh-pass').value,
      }
    });
    isConnected = true;
    updateConnectionUI(true, result.deviceInfo);
    showToast('success', '✅ Kết nối thành công!');
    // Auto-load installed apps when connected
    loadInstalledApps();
  } catch (e) {
    showToast('error', `❌ ${e.message}`);
    updateConnectionUI(false);
  }
  btn.disabled = false;
  btn.innerHTML = '➡️ Kết Nối';
}

async function disconnectSSH() {
  await api('/ssh/disconnect', { method: 'POST' });
  isConnected = false;
  updateConnectionUI(false);
  showToast('info', '🔌 Ngắt kết nối');
}

function updateConnectionUI(connected, deviceInfo) {
  const indicator = document.getElementById('conn-indicator');
  const statusDot = document.getElementById('status-dot');
  const statusText = document.getElementById('status-text');
  const btnConnect = document.getElementById('btn-connect');
  const btnDisconnect = document.getElementById('btn-disconnect');
  const infoCard = document.getElementById('device-info-card');

  if (connected) {
    indicator.classList.add('online');
    statusDot.classList.remove('offline'); statusDot.classList.add('online');
    statusText.textContent = deviceInfo?.iosVersion ? `iOS ${deviceInfo.iosVersion}` : 'Đã kết nối';
    btnConnect.style.display = 'none';
    btnDisconnect.style.display = 'flex';
    infoCard.style.display = 'block';
    if (deviceInfo) {
      document.getElementById('device-info-content').innerHTML = `
        <div class="info-grid">
          <div class="info-row"><span class="info-row-label">iOS</span><span class="info-row-value">${deviceInfo.iosVersion || 'N/A'}</span></div>
          <div class="info-row"><span class="info-row-label">Machine</span><span class="info-row-value">${deviceInfo.machine || 'N/A'}</span></div>
          <div class="info-row"><span class="info-row-label">Jailbreak</span><span class="info-row-value text-green">${deviceInfo.jailbreakType || 'N/A'}</span></div>
          <div class="info-row"><span class="info-row-label">Tweak</span><span class="info-row-value ${deviceInfo.tweakInstalled ? 'text-green' : 'text-red'}">${deviceInfo.tweakInstalled ? '✅' : '❌'}</span></div>
        </div>`;
    }
  } else {
    indicator.classList.remove('online');
    statusDot.classList.add('offline'); statusDot.classList.remove('online');
    statusText.textContent = 'Chưa kết nối';
    btnConnect.style.display = 'flex';
    btnDisconnect.style.display = 'none';
    infoCard.style.display = 'none';
  }
}

// ============================================================
// ★ SELECTIVE RANDOM SYSTEM
// ============================================================
const PARAM_SECTIONS = [
  {
    id: 'sec-identity', title: '🔐 Device Identity', badge: 'Layer 1-2', badgeClass: 'badge-red',
    params: [
      { key: 'UniqueDeviceID', label: 'UDID' }, { key: 'SerialNumber', label: 'Serial' },
      { key: 'UniqueChipID', label: 'ECID' }, { key: 'ProductType', label: 'Product Type' },
      { key: 'HardwareModel', label: 'HW Model' }, { key: 'MarketingName', label: 'Marketing' },
      { key: 'ModelNumber', label: 'Model Number' }, { key: 'BoardId', label: 'Board ID' },
      { key: 'ChipID', label: 'Chip ID' }, { key: 'deviceName', label: 'Device Name' },
      { key: 'identifierForVendor', label: 'IDFV' }, { key: 'IOPlatformUUID', label: 'Platform UUID' },
    ]
  },
  {
    id: 'sec-telephony', title: '📞 Telephony / SIM', badge: 'Layer 3-4', badgeClass: 'badge-orange',
    params: [
      { key: 'InternationalMobileEquipmentIdentity', label: 'IMEI' },
      { key: 'InternationalMobileEquipmentIdentity2', label: 'IMEI 2' },
      { key: 'MobileEquipmentIdentifier', label: 'MEID' },
      { key: 'IntegratedCircuitCardIdentity', label: 'ICCID' },
      { key: 'PhoneNumber', label: 'Phone' }, { key: 'carrierName', label: 'Carrier' },
      { key: 'carrierMCC', label: 'MCC' }, { key: 'carrierMNC', label: 'MNC' },
      { key: 'carrierISO', label: 'ISO' }, { key: 'carrierRadioAccess', label: 'Radio' },
    ]
  },
  {
    id: 'sec-network', title: '🌐 Network / MAC', badge: 'Layer 5', badgeClass: 'badge-green',
    params: [
      { key: 'WiFiAddress', label: 'WiFi MAC' }, { key: 'BluetoothAddress', label: 'BT MAC' },
      { key: 'EthernetAddress', label: 'ETH MAC' }, { key: 'wifiSSID', label: 'WiFi SSID' },
      { key: 'wifiBSSID', label: 'WiFi BSSID' }, { key: 'localIP', label: 'Local IP' },
    ]
  },
  {
    id: 'sec-software', title: '💻 Software', badge: 'Layer 2', badgeClass: 'badge-blue',
    params: [
      { key: 'systemVersion', label: 'iOS Version' }, { key: 'BuildVersion', label: 'Build' },
      { key: 'FirmwareVersion', label: 'Firmware' }, { key: 'BasebandVersion', label: 'Baseband' },
      { key: 'RegionCode', label: 'Region' }, { key: 'RegionInfo', label: 'Region Info' },
    ]
  },
  {
    id: 'sec-advertising', title: '📊 Advertising', badge: 'Layer 6', badgeClass: 'badge-purple',
    params: [
      { key: 'advertisingIdentifier', label: 'IDFA' },
      { key: 'isAdvertisingTrackingEnabled', label: 'Tracking' },
    ]
  },
  {
    id: 'sec-hardware', title: '🔧 Hardware / sysctl', badge: 'Layer 7', badgeClass: 'badge-cyan',
    params: [
      { key: 'hw_machine', label: 'hw.machine' }, { key: 'hw_model', label: 'hw.model' },
      { key: 'hw_memsize', label: 'hw.memsize' }, { key: 'hw_physicalcpu', label: 'hw.cpucores' },
      { key: 'kern_hostname', label: 'kern.host' }, { key: 'kern_osversion', label: 'kern.osver' },
    ]
  },
  {
    id: 'sec-screen', title: '📱 Screen', badge: 'Layer 9', badgeClass: 'badge-yellow',
    params: [
      { key: 'screenWidth', label: 'Width' }, { key: 'screenHeight', label: 'Height' },
      { key: 'screenScale', label: 'Scale' }, { key: 'nativeScreenWidth', label: 'Native W' },
      { key: 'nativeScreenHeight', label: 'Native H' },
    ]
  },
  {
    id: 'sec-storage', title: '💾 Storage / Battery', badge: 'Layer 2', badgeClass: 'badge-orange',
    params: [
      { key: 'TotalDiskCapacity', label: 'Disk Total' }, { key: 'DiskUsage', label: 'Disk Used' },
      { key: 'BatteryCurrentCapacity', label: 'Battery' }, { key: 'DeviceColor', label: 'Color' },
    ]
  },
  {
    id: 'sec-locale', title: '🌍 Locale / Timezone', badge: 'Layer 12', badgeClass: 'badge-green',
    params: [
      { key: 'localeIdentifier', label: 'Locale' }, { key: 'localeCountryCode', label: 'Country' },
      { key: 'localeCurrencyCode', label: 'Currency' }, { key: 'timezoneName', label: 'Timezone' },
    ]
  },
  {
    id: 'sec-iokit', title: '🔌 IOKit', badge: 'Layer 3', badgeClass: 'badge-blue',
    params: [
      { key: 'IOPlatformSerialNumber', label: 'IO Serial' }, { key: 'IOPlatformUUID', label: 'IO UUID' },
      { key: 'IODeviceTreeMLBSerial', label: 'MLB Serial' },
    ]
  },
  {
    id: 'sec-zalo', title: '💬 Zalo Optimized', badge: 'BONUS', badgeClass: 'badge-red',
    params: [
      { key: 'zalo_fakeWebViewUA', label: 'WebView UA' }, { key: 'zalo_canvasNoiseSeed', label: 'Canvas Seed' },
      { key: 'zalo_metalGPU', label: 'Metal GPU' }, { key: 'zalo_timingOffset', label: 'Timing' },
      { key: 'keychainFakeDeviceToken', label: 'KC Token' },
    ]
  },
];

// Build selective random checkboxes
function buildRandomCheckboxes() {
  const container = document.getElementById('random-checkboxes');
  if (!container) return;

  let html = '';
  for (const section of PARAM_SECTIONS) {
    html += `
      <div class="random-section">
        <div class="random-section-header" onclick="toggleRandomSection('${section.id}')">
          <input type="checkbox" checked data-section="${section.id}"
                 onclick="event.stopPropagation(); toggleSectionCheckboxes('${section.id}', this.checked)">
          <span class="section-title">${section.title}</span>
          <span class="section-badge ${section.badgeClass}">${section.badge}</span>
          <span class="section-count">${section.params.length} mục</span>
        </div>
        <div class="random-section-body" id="rnd-body-${section.id}">
    `;
    for (const p of section.params) {
      html += `
        <label class="random-param-check">
          <input type="checkbox" checked class="rnd-check" data-key="${p.key}" data-section="${section.id}">
          <span>${p.label}</span>
        </label>
      `;
    }
    html += '</div></div>';
  }
  container.innerHTML = html;
}

function toggleRandomSection(sectionId) {
  const body = document.getElementById(`rnd-body-${sectionId}`);
  body.style.display = body.style.display === 'none' ? 'grid' : 'none';
}

function toggleSectionCheckboxes(sectionId, checked) {
  document.querySelectorAll(`.rnd-check[data-section="${sectionId}"]`).forEach(cb => {
    cb.checked = checked;
  });
}

function selectAllRandom() {
  document.querySelectorAll('.rnd-check').forEach(cb => cb.checked = true);
  document.querySelectorAll('[data-section]').forEach(cb => { if (cb.classList.contains('rnd-check') === false) cb.checked = true; });
}

function deselectAllRandom() {
  document.querySelectorAll('.rnd-check').forEach(cb => cb.checked = false);
  document.querySelectorAll('[data-section]').forEach(cb => { if (cb.classList.contains('rnd-check') === false) cb.checked = false; });
}

function getSelectedRandomKeys() {
  const keys = [];
  document.querySelectorAll('.rnd-check:checked').forEach(cb => {
    keys.push(cb.dataset.key);
  });
  return keys;
}

// ★ Generate with selective random
async function generateSelective() {
  try {
    const selectedKeys = getSelectedRandomKeys();
    const options = {};
    const deviceSel = document.getElementById('gen-device').value;
    const iosSel = document.getElementById('gen-ios').value;
    const carrierSel = document.getElementById('gen-carrier').value;
    const nameSel = document.getElementById('gen-name').value;

    if (deviceSel) options.productType = deviceSel;
    if (iosSel) options.iosVersion = iosSel;
    if (carrierSel) options.carrierRegion = carrierSel;
    if (nameSel) options.deviceName = nameSel;

    const result = await api('/generate-selective', {
      method: 'POST',
      body: { selectedKeys, options }
    });
    currentProfile = result.profile;
    renderDeviceInfo(currentProfile);
    showToast('success', `🎲 Random ${selectedKeys.length} mục: ${currentProfile.MarketingName}`);
    setTimeout(() => switchTab('device'), 500);
  } catch (e) {
    showToast('error', `❌ ${e.message}`);
  }
}

// ★ Generate + Deploy all in one (with progress overlay)
async function generateAndDeploy() {
  try {
    const selectedKeys = getSelectedRandomKeys();
    const options = {};
    const deviceSel = document.getElementById('gen-device').value;
    const iosSel = document.getElementById('gen-ios').value;
    const carrierSel = document.getElementById('gen-carrier').value;
    const nameSel = document.getElementById('gen-name').value;
    if (deviceSel) options.productType = deviceSel;
    if (iosSel) options.iosVersion = iosSel;
    if (carrierSel) options.carrierRegion = carrierSel;
    if (nameSel) options.deviceName = nameSel;

    showDeployProgress('Random + Deep Wipe + Deploy');

    // Step 1: Generate
    updateDeployProgress('Generating new device profile...', 10);
    addDeployStep('Generating random parameters...');
    const result = await api('/generate-selective', {
      method: 'POST',
      body: { selectedKeys, options }
    });
    currentProfile = result.profile;
    renderDeviceInfo(currentProfile);
    addDeployStep(`Profile: ${currentProfile.MarketingName} - iOS ${currentProfile.systemVersion}`, 'success');

    // Step 2: Deploy with deep wipe
    updateDeployProgress('Deep wiping app data + deploying...', 25);
    addDeployStep('Starting deep wipe + deploy...');
    const deployResult = await api('/deploy/full', { method: 'POST' });

    // Show server-reported steps
    if (deployResult.steps) {
      for (const s of deployResult.steps) {
        addDeployStep(`[${s.elapsed}] ${s.message}`, 'success');
      }
    }
    if (deployResult.clearResults) {
      for (const cr of deployResult.clearResults) {
        const status = cr.verified ? 'VERIFIED CLEAN' : cr.status;
        addDeployStep(`${cr.app}: ${status}`, cr.status === 'error' ? 'error' : 'success');
      }
    }

    updateDeployProgress(`Done in ${deployResult.totalTime || '?'}!`, 100);
    addDeployStep(`Completed: ${currentProfile.MarketingName} - iOS ${currentProfile.systemVersion}`, 'success');
    showToast('success', `✅ Done in ${deployResult.totalTime}! ${currentProfile.MarketingName}`);
    hideDeployProgress(3000);
  } catch (e) {
    addDeployStep(e.message, 'error');
    updateDeployProgress('Failed!', 100);
    showToast('error', `❌ ${e.message}`);
    hideDeployProgress(3000);
  }
}

// ============================================================
// AUTO-CLEAR APPS CONFIG
// ============================================================
function updateAutoClearApps() {
  const checks = document.querySelectorAll('#auto-clear-checks input[type="checkbox"]');
  const apps = [];
  checks.forEach(cb => { if (cb.checked) apps.push(cb.value); });
  api('/auto-clear-apps', { method: 'POST', body: { apps } }).catch(() => {});
}

function addCustomClearApp() {
  const input = document.getElementById('custom-clear-bundle');
  const bundleId = input.value.trim();
  if (!bundleId) return;

  const container = document.getElementById('auto-clear-checks');
  const label = document.createElement('label');
  label.className = 'checkbox-item';
  label.innerHTML = `<input type="checkbox" value="${bundleId}" checked onchange="updateAutoClearApps()"><span>📦 ${bundleId}</span>`;
  container.appendChild(label);
  input.value = '';
  updateAutoClearApps();
}

// ============================================================
// RENDER DEVICE INFO
// ============================================================
function renderDeviceInfo(profile) {
  const container = document.getElementById('params-container');
  if (!profile) {
    container.innerHTML = `<div class="empty-state"><div class="empty-icon">📱</div><h3>Chưa có profile</h3><p>Vào Random để tạo</p><button class="btn btn-primary" onclick="switchTab('random')">🎲 Random</button></div>`;
    return;
  }

  let html = '';
  for (const section of PARAM_SECTIONS) {
    html += `<div class="params-section" id="${section.id}">
      <div class="params-section-header" onclick="toggleSection('${section.id}')">
        <h3>${section.title} <span class="section-badge ${section.badgeClass}">${section.badge}</span></h3>
        <span class="section-toggle">▼</span>
      </div>
      <div class="params-section-body">`;
    for (const param of section.params) {
      const value = profile[param.key] !== undefined ? profile[param.key] : '';
      const dv = formatValue(value);
      html += `<div class="param-item">
        <span class="param-label">${param.label}</span>
        <input class="param-value" type="text" value="${escapeHtml(String(dv))}" data-key="${param.key}" onchange="updateParam('${param.key}', this.value)">
        <button class="param-btn" onclick="copyValue('${param.key}')" title="Copy">📋</button>
      </div>`;
    }
    html += '</div></div>';
  }
  container.innerHTML = html;
}

function formatValue(v) {
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number' && v > 1000000000) return `${(v / 1073741824).toFixed(1)} GB`;
  return v;
}

function toggleSection(id) { document.getElementById(id).classList.toggle('collapsed'); }

async function updateParam(key, value) {
  try {
    if (value === 'true') value = true;
    else if (value === 'false') value = false;
    else if (/^\d+$/.test(value)) value = parseInt(value);
    const result = await api('/update-param', { method: 'POST', body: { key, value } });
    currentProfile = result.profile;
  } catch (e) { showToast('error', e.message); }
}

function copyValue(key) {
  if (!currentProfile) return;
  navigator.clipboard.writeText(String(currentProfile[key] || '')).then(() => showToast('info', `📋 Copied: ${key}`));
}

// ============================================================
// DEPLOY
// ============================================================
async function deployConfigOnly() {
  if (!currentProfile) { showToast('warning', '⚠️ Chưa có profile'); return; }
  try {
    await api('/deploy/push-config', { method: 'POST' });
    showToast('success', '✅ Config pushed');
  } catch (e) { showToast('error', `❌ ${e.message}`); }
}

async function deployFull() {
  if (!currentProfile) { showToast('warning', '⚠️ Chưa có profile'); return; }
  try {
    showDeployProgress('Deep Wipe + Deploy + Respring');
    updateDeployProgress('Starting deep wipe...', 10);
    addDeployStep('Initiating deep wipe + deploy...');

    const result = await api('/deploy/full', { method: 'POST' });

    if (result.steps) {
      for (const s of result.steps) {
        addDeployStep(`[${s.elapsed}] ${s.message}`, 'success');
      }
    }
    if (result.clearResults) {
      for (const cr of result.clearResults) {
        const status = cr.verified ? 'VERIFIED CLEAN' : cr.status;
        addDeployStep(`${cr.app}: ${status}`, cr.status === 'error' ? 'error' : 'success');
      }
    }

    updateDeployProgress(`Done in ${result.totalTime || '?'}!`, 100);
    addDeployStep('Device is respringing...', 'success');
    showToast('success', `✅ Hoàn tất trong ${result.totalTime}! Device đang respring...`);
    hideDeployProgress(3000);
  } catch (e) {
    addDeployStep(e.message, 'error');
    updateDeployProgress('Failed!', 100);
    showToast('error', `❌ ${e.message}`);
    hideDeployProgress(3000);
  }
}

// ============================================================
// PROFILES
// ============================================================
async function loadProfiles() {
  try {
    const list = await api('/profiles');
    const container = document.getElementById('profiles-list');
    if (!list || list.length === 0) {
      container.innerHTML = '<div class="empty-state"><div class="empty-icon">💾</div><h3>Chưa có</h3></div>';
      return;
    }
    container.innerHTML = list.map(p => `
      <div class="profile-card">
        <div class="profile-name">${escapeHtml(p.name)}</div>
        <div class="profile-meta">
          <span>📱 <span class="highlight">${p.marketing || '?'}</span> — iOS ${p.iosVersion || '?'}</span>
          <span>📅 ${new Date(p.createdAt).toLocaleDateString('vi-VN')}</span>
        </div>
        <div class="profile-actions">
          <button class="btn btn-primary btn-sm" onclick="loadProfile('${escapeHtml(p.name)}')">📂 Load</button>
          <button class="btn btn-accent btn-sm" onclick="loadAndDeploy('${escapeHtml(p.name)}')">🚀 Deploy</button>
          <a class="btn btn-outline btn-sm" href="/api/profiles/export/${encodeURIComponent(p.name)}?token=${authToken}" download>📤</a>
          <button class="btn btn-danger btn-sm" onclick="deleteProfile('${escapeHtml(p.name)}')">🗑️</button>
        </div>
      </div>
    `).join('');
  } catch (e) { console.error(e); }
}

function saveCurrentProfile() {
  if (!currentProfile) { showToast('warning', '⚠️ Chưa có profile'); return; }
  openModal('💾 Lưu Profile', `
    <div class="form-group">
      <label>Tên Profile</label>
      <input type="text" id="save-profile-name" placeholder="VD: iPhone13_Viettel_01" autofocus>
    </div>
  `, `
    <button class="btn btn-outline" onclick="closeModal()">Hủy</button>
    <button class="btn btn-primary" onclick="doSaveProfile()">💾 Lưu</button>
  `);
}

async function doSaveProfile() {
  const name = document.getElementById('save-profile-name').value.trim();
  if (!name) { showToast('warning', 'Nhập tên!'); return; }
  try {
    await api('/profiles/save', { method: 'POST', body: { name, profile: currentProfile } });
    showToast('success', `💾 Saved: ${name}`);
    closeModal();
  } catch (e) { showToast('error', e.message); }
}

async function loadProfile(name) {
  try {
    const result = await api('/profiles/load', { method: 'POST', body: { name } });
    currentProfile = result.profile;
    renderDeviceInfo(currentProfile);
    showToast('success', `📂 Loaded: ${name}`);
    switchTab('device');
  } catch (e) { showToast('error', e.message); }
}

async function loadAndDeploy(name) {
  try {
    const result = await api('/profiles/load', { method: 'POST', body: { name } });
    currentProfile = result.profile;
    renderDeviceInfo(currentProfile);
    showToast('info', `📂 Loaded: ${name}, deploying...`);
    await api('/deploy/full', { method: 'POST' });
    showToast('success', '✅ Deploy hoàn tất!');
  } catch (e) { showToast('error', e.message); }
}

async function deleteProfile(name) {
  if (!confirm(`Xóa "${name}"?`)) return;
  try {
    await api('/profiles/delete', { method: 'POST', body: { name } });
    loadProfiles();
  } catch (e) { showToast('error', e.message); }
}

async function importProfile(event) {
  const file = event.target.files[0];
  if (!file) return;
  const formData = new FormData();
  formData.append('file', file);
  try {
    const res = await fetch('/api/profiles/import', {
      method: 'POST',
      headers: { 'X-Auth-Token': authToken },
      body: formData,
    }).then(r => r.json());
    if (res.success) { showToast('success', '📥 Imported!'); loadProfiles(); }
  } catch (e) { showToast('error', e.message); }
  event.target.value = '';
}

// ============================================================
// CLEAR DATA
// ============================================================
async function clearApp(bundleId) {
  if (!bundleId) { showToast('warning', 'Nhập Bundle ID!'); return; }
  if (!isConnected) { showToast('warning', '⚠️ Chưa kết nối!'); return; }
  try {
    showDeployProgress(`Deep Wipe: ${bundleId}`);
    updateDeployProgress('Wiping app data...', 20);
    addDeployStep(`Starting deep wipe for ${bundleId}...`);

    const result = await api('/clear-app', { method: 'POST', body: { bundleId } });

    if (result.results) {
      for (const r of result.results) {
        addDeployStep(r, 'success');
      }
    }
    const status = result.verified ? 'VERIFIED CLEAN' : 'Cleared';
    updateDeployProgress(`${status}!`, 100);
    addDeployStep(`${bundleId}: ${status}`, 'success');
    showToast('success', `✅ ${status}: ${bundleId}`);
    hideDeployProgress(2500);
  } catch (e) {
    addDeployStep(e.message, 'error');
    updateDeployProgress('Failed!', 100);
    showToast('error', e.message);
    hideDeployProgress(2000);
  }
}

// Global installed apps cache
let installedApps = [];

// Known app names for friendly display
const APP_NAMES = {
  'com.vng.zalo': { name: 'Zalo', icon: '💬' },
  'com.zing.zalo': { name: 'Zalo', icon: '💬' },
  'com.zhiliaoapp.musically': { name: 'TikTok', icon: '🎵' },
  'com.facebook.Facebook': { name: 'Facebook', icon: '📘' },
  'com.facebook.Messenger': { name: 'Messenger', icon: '💬' },
  'ph.telegra.Telegraph': { name: 'Telegram', icon: '✈️' },
  'com.burbn.instagram': { name: 'Instagram', icon: '📷' },
  'com.twitter.twitter': { name: 'Twitter/X', icon: '🐦' },
  'com.atebits.Tweetie2': { name: 'Twitter/X', icon: '🐦' },
  'com.google.chrome.ios': { name: 'Chrome', icon: '🌐' },
  'com.apple.mobilesafari': { name: 'Safari', icon: '🧭' },
  'com.spotify.client': { name: 'Spotify', icon: '🎧' },
  'com.google.Gmail': { name: 'Gmail', icon: '📧' },
  'com.viber.app': { name: 'Viber', icon: '📱' },
  'com.skype.skype': { name: 'Skype', icon: '📞' },
  'com.whatsapp.WhatsApp': { name: 'WhatsApp', icon: '📱' },
  'com.google.Maps': { name: 'Google Maps', icon: '🗺️' },
  'com.ss.iphone.ugc.Aweme': { name: 'TikTok (CN)', icon: '🎵' },
  'com.shopee.ShopeePH': { name: 'Shopee', icon: '🛒' },
  'com.lazada.iphone': { name: 'Lazada', icon: '🛍️' },
  'com.tencent.xin': { name: 'WeChat', icon: '💚' },
  'jp.naver.line': { name: 'LINE', icon: '💬' },
  'com.snapchat.snapchat': { name: 'Snapchat', icon: '👻' },
  'com.linkedin.LinkedIn': { name: 'LinkedIn', icon: '💼' },
  'com.pinterest': { name: 'Pinterest', icon: '📌' },
  'com.reddit.Reddit': { name: 'Reddit', icon: '🔴' },
  'com.discord': { name: 'Discord', icon: '🎮' },
};

function getAppDisplay(bundleId) {
  const known = APP_NAMES[bundleId];
  if (known) return known;
  // Extract readable name from bundle ID
  const parts = bundleId.split('.');
  const name = parts[parts.length - 1] || bundleId;
  return { name, icon: '📦' };
}

async function loadInstalledApps() {
  if (!isConnected) { showToast('warning', '⚠️ Chưa kết nối!'); return; }

  const container = document.getElementById('apps-list');
  container.innerHTML = '<div class="apps-loading"><div class="spinner"></div> Đang quét app trên thiết bị...</div>';

  try {
    const apps = await api('/installed-apps');
    installedApps = apps;

    if (!apps.length) {
      container.innerHTML = '<p class="text-muted">Không tìm thấy app nào</p>';
      return;
    }

    // Sort: known apps first, then alphabetically
    const sorted = [...apps].sort((a, b) => {
      const aKnown = APP_NAMES[a] ? 0 : 1;
      const bKnown = APP_NAMES[b] ? 0 : 1;
      if (aKnown !== bKnown) return aKnown - bKnown;
      return a.localeCompare(b);
    });

    let html = `
      <div class="apps-toolbar">
        <span class="apps-count">${sorted.length} app</span>
        <div class="apps-toolbar-actions">
          <button class="btn btn-outline btn-xs" onclick="toggleAllApps(true)">☑ Chọn tất cả</button>
          <button class="btn btn-outline btn-xs" onclick="toggleAllApps(false)">☐ Bỏ chọn</button>
          <button class="btn btn-danger btn-sm" onclick="wipeSelectedApps()">🧹 Wipe đã chọn</button>
        </div>
      </div>
      <div class="apps-search">
        <input type="text" id="apps-search-input" placeholder="Tìm app..." oninput="filterAppsList()">
      </div>
      <div class="apps-checkbox-list" id="apps-checkbox-list">
    `;

    for (const bundleId of sorted) {
      const display = getAppDisplay(bundleId);
      html += `
        <label class="app-checkbox-item" data-bundle="${escapeHtml(bundleId)}">
          <input type="checkbox" value="${escapeHtml(bundleId)}" class="app-wipe-check">
          <span class="app-icon">${display.icon}</span>
          <span class="app-info">
            <span class="app-name">${escapeHtml(display.name)}</span>
            <span class="app-bundle">${escapeHtml(bundleId)}</span>
          </span>
          <button class="btn btn-danger btn-xs app-wipe-single" onclick="event.preventDefault();event.stopPropagation();clearApp('${escapeHtml(bundleId)}')">🧹</button>
        </label>
      `;
    }

    html += '</div>';
    container.innerHTML = html;

    // Also update the auto-clear section with real apps
    updateAutoClearFromDevice(sorted);

  } catch (e) {
    container.innerHTML = `<p class="text-red">Lỗi: ${e.message}</p>`;
  }
}

function filterAppsList() {
  const query = (document.getElementById('apps-search-input')?.value || '').toLowerCase();
  const items = document.querySelectorAll('.app-checkbox-item');
  items.forEach(item => {
    const bundle = item.getAttribute('data-bundle').toLowerCase();
    const display = getAppDisplay(item.getAttribute('data-bundle'));
    const match = bundle.includes(query) || display.name.toLowerCase().includes(query);
    item.style.display = match ? '' : 'none';
  });
}

function toggleAllApps(checked) {
  document.querySelectorAll('.app-wipe-check').forEach(cb => {
    if (cb.closest('.app-checkbox-item').style.display !== 'none') {
      cb.checked = checked;
    }
  });
}

async function wipeSelectedApps() {
  const selected = [];
  document.querySelectorAll('.app-wipe-check:checked').forEach(cb => selected.push(cb.value));

  if (selected.length === 0) {
    showToast('warning', '⚠️ Chưa chọn app nào!');
    return;
  }

  showDeployProgress(`Deep Wipe ${selected.length} app(s)`);
  updateDeployProgress(`Wiping ${selected.length} app(s)...`, 5);

  let done = 0;
  for (const bundleId of selected) {
    const display = getAppDisplay(bundleId);
    try {
      addDeployStep(`Wiping ${display.icon} ${display.name} (${bundleId})...`);
      const result = await api('/clear-app', { method: 'POST', body: { bundleId } });
      done++;
      const pct = Math.round((done / selected.length) * 90) + 5;
      updateDeployProgress(`${done}/${selected.length} done`, pct);
      if (result.results) {
        for (const r of result.results) addDeployStep(r, 'success');
      }
      const status = result.verified ? 'VERIFIED CLEAN' : 'Cleared';
      addDeployStep(`${display.icon} ${display.name}: ${status}`, 'success');
    } catch (e) {
      addDeployStep(`${display.icon} ${display.name}: FAILED - ${e.message}`, 'error');
      done++;
    }
  }

  updateDeployProgress(`Done! ${done} app(s) wiped`, 100);
  addDeployStep(`Completed: ${done}/${selected.length} apps wiped`, 'success');
  showToast('success', `✅ Wiped ${done} app(s)!`);
  hideDeployProgress(3000);
}

// Update auto-clear checkboxes with real device apps
function updateAutoClearFromDevice(apps) {
  const container = document.getElementById('auto-clear-checks');
  if (!container || !apps.length) return;

  // Keep any existing checked values
  const existingChecked = new Set();
  container.querySelectorAll('input[type="checkbox"]:checked').forEach(cb => existingChecked.add(cb.value));

  // Default apps always shown at top
  const defaults = ['com.vng.zalo', 'com.zing.zalo'];
  defaults.forEach(d => existingChecked.add(d));

  // Build new checkbox list combining defaults + device apps
  const allBundles = new Set([...defaults, ...apps]);

  let html = '';
  for (const bundleId of allBundles) {
    const display = getAppDisplay(bundleId);
    const checked = existingChecked.has(bundleId) ? 'checked' : '';
    html += `<label class="checkbox-item"><input type="checkbox" value="${escapeHtml(bundleId)}" ${checked} onchange="updateAutoClearApps()"><span>${display.icon} ${escapeHtml(display.name)}</span></label>`;
  }
  container.innerHTML = html;
}

// ============================================================
// ADMIN PANEL
// ============================================================
async function loadAdminUsers() {
  try {
    const users = await api('/admin/users');
    const tbody = document.getElementById('admin-users-body');
    tbody.innerHTML = users.map(u => `
      <tr>
        <td><strong>${escapeHtml(u.username)}</strong></td>
        <td><span class="role-${u.role}">${u.role}</span></td>
        <td>${u.maxDevices}</td>
        <td>${u.expiresAt ? new Date(u.expiresAt).toLocaleDateString('vi-VN') : '♾️ Vĩnh viễn'}</td>
        <td><span class="${u.active ? 'status-active' : 'status-inactive'}">${u.active ? '✅ Active' : '❌ Inactive'}</span></td>
        <td class="text-muted">${escapeHtml(u.note || '-')}</td>
        <td>
          <div style="display:flex;gap:4px">
            <button class="btn btn-outline btn-xs" onclick="editUser('${u.id}','${escapeHtml(u.username)}')">✏️</button>
            <button class="btn btn-danger btn-xs" onclick="deleteUser('${u.id}','${escapeHtml(u.username)}')">🗑️</button>
          </div>
        </td>
      </tr>
    `).join('');
  } catch (e) { showToast('error', e.message); }
}

function openCreateUser() {
  openModal('➕ Tạo Tài Khoản', `
    <div class="form-group"><label>Username</label><input type="text" id="new-user-name"></div>
    <div class="form-group"><label>Password</label><input type="password" id="new-user-pass"></div>
    <div class="form-row">
      <div class="form-group"><label>Role</label><select id="new-user-role"><option value="user">User</option><option value="admin">Admin</option></select></div>
      <div class="form-group"><label>Max Devices</label><input type="number" id="new-user-devices" value="5"></div>
    </div>
    <div class="form-group"><label>Hết hạn (để trống = vĩnh viễn)</label><input type="date" id="new-user-expires"></div>
    <div class="form-group"><label>Ghi chú</label><input type="text" id="new-user-note" placeholder="VD: Khách hàng A"></div>
  `, `
    <button class="btn btn-outline" onclick="closeModal()">Hủy</button>
    <button class="btn btn-primary" onclick="doCreateUser()">➕ Tạo</button>
  `);
}

async function doCreateUser() {
  try {
    const expires = document.getElementById('new-user-expires').value;
    const result = await api('/admin/users', {
      method: 'POST',
      body: {
        username: document.getElementById('new-user-name').value,
        password: document.getElementById('new-user-pass').value,
        role: document.getElementById('new-user-role').value,
        maxDevices: parseInt(document.getElementById('new-user-devices').value) || 5,
        expiresAt: expires ? new Date(expires).toISOString() : null,
        note: document.getElementById('new-user-note').value,
      }
    });
    if (result.success) { showToast('success', '✅ Đã tạo!'); closeModal(); loadAdminUsers(); }
    else showToast('error', result.error);
  } catch (e) { showToast('error', e.message); }
}

async function deleteUser(id, name) {
  if (!confirm(`Xóa user "${name}"?`)) return;
  try {
    const result = await api(`/admin/users/${id}`, { method: 'DELETE' });
    if (result.success) { showToast('info', `Đã xóa: ${name}`); loadAdminUsers(); }
    else showToast('error', result.error);
  } catch (e) { showToast('error', e.message); }
}

function editUser(id, name) {
  openModal(`✏️ Sửa: ${name}`, `
    <div class="form-group"><label>Password mới (để trống = không đổi)</label><input type="password" id="edit-user-pass"></div>
    <div class="form-row">
      <div class="form-group"><label>Max Devices</label><input type="number" id="edit-user-devices" value="5"></div>
      <div class="form-group"><label>Active</label><select id="edit-user-active"><option value="true">✅ Active</option><option value="false">❌ Inactive</option></select></div>
    </div>
    <div class="form-group"><label>Hết hạn</label><input type="date" id="edit-user-expires"></div>
  `, `
    <button class="btn btn-outline" onclick="closeModal()">Hủy</button>
    <button class="btn btn-primary" onclick="doEditUser('${id}')">💾 Lưu</button>
  `);
}

async function doEditUser(id) {
  try {
    const updates = {
      active: document.getElementById('edit-user-active').value === 'true',
      maxDevices: parseInt(document.getElementById('edit-user-devices').value),
    };
    const pass = document.getElementById('edit-user-pass').value;
    if (pass) updates.password = pass;
    const expires = document.getElementById('edit-user-expires').value;
    if (expires) updates.expiresAt = new Date(expires).toISOString();

    await api(`/admin/users/${id}`, { method: 'PUT', body: updates });
    showToast('success', '✅ Updated'); closeModal(); loadAdminUsers();
  } catch (e) { showToast('error', e.message); }
}

// ============================================================
// LOGS
// ============================================================
async function refreshLogs() {
  try {
    const list = await api('/logs');
    const container = document.getElementById('logs-container');
    if (!list?.length) { container.innerHTML = '<div class="empty-state"><h3>Chưa có logs</h3></div>'; return; }
    container.innerHTML = list.map(l => {
      const t = new Date(l.time).toLocaleTimeString('vi-VN');
      const icons = { info: 'ℹ️', success: '✅', error: '❌', warning: '⚠️' };
      return `<div class="log-entry"><span class="log-time">${t}</span><span class="log-type ${l.type}">${icons[l.type]||'ℹ️'}</span><span class="log-message">${escapeHtml(l.message)}</span></div>`;
    }).join('');
  } catch (e) {}
}

async function clearLogs() {
  await api('/logs/clear', { method: 'POST' });
  document.getElementById('logs-container').innerHTML = '';
}

// ============================================================
// MODAL / TOAST / UTILS
// ============================================================
function openModal(title, body, footer) {
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = body;
  document.getElementById('modal-footer').innerHTML = footer || '';
  document.getElementById('modal-overlay').classList.add('active');
}

function closeModal() { document.getElementById('modal-overlay').classList.remove('active'); }
document.getElementById('modal-overlay')?.addEventListener('click', e => { if (e.target === e.currentTarget) closeModal(); });

function showToast(type, msg) {
  const c = document.getElementById('toast-container');
  const t = document.createElement('div');
  t.className = `toast ${type}`;
  t.textContent = msg;
  c.appendChild(t);
  setTimeout(() => t.remove(), 3000);
}

// ============================================================
// DEPLOY PROGRESS OVERLAY
// ============================================================
function showDeployProgress(title = 'Deep Wipe + Deploy') {
  // Remove existing overlay if any
  hideDeployProgress();

  const overlay = document.createElement('div');
  overlay.id = 'deploy-progress-overlay';
  overlay.innerHTML = `
    <div class="deploy-progress-box">
      <h3>${title}</h3>
      <div class="deploy-progress-bar-wrap">
        <div class="deploy-progress-bar" id="deploy-bar"></div>
      </div>
      <div class="deploy-progress-status" id="deploy-status">Initializing...</div>
      <div class="deploy-progress-steps" id="deploy-steps"></div>
      <div class="deploy-progress-timer" id="deploy-timer">0.0s</div>
    </div>
  `;
  document.body.appendChild(overlay);

  // Start timer
  const startTime = Date.now();
  overlay._timer = setInterval(() => {
    const el = document.getElementById('deploy-timer');
    if (el) el.textContent = ((Date.now() - startTime) / 1000).toFixed(1) + 's';
  }, 100);
}

function updateDeployProgress(status, percent) {
  const bar = document.getElementById('deploy-bar');
  const statusEl = document.getElementById('deploy-status');
  if (bar) bar.style.width = percent + '%';
  if (statusEl) statusEl.textContent = status;
}

function addDeployStep(msg, type = 'info') {
  const container = document.getElementById('deploy-steps');
  if (!container) return;
  const icon = type === 'success' ? '✅' : type === 'error' ? '❌' : '⏳';
  const step = document.createElement('div');
  step.className = `deploy-step deploy-step-${type}`;
  step.textContent = `${icon} ${msg}`;
  container.appendChild(step);
  container.scrollTop = container.scrollHeight;
}

function hideDeployProgress(delay = 2000) {
  setTimeout(() => {
    const overlay = document.getElementById('deploy-progress-overlay');
    if (overlay) {
      clearInterval(overlay._timer);
      overlay.remove();
    }
  }, delay);
}

function escapeHtml(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

// ============================================================
// INIT
// ============================================================
async function initApp() {
  // Load device & iOS lists
  try {
    const devices = await api('/devices');
    const sel = document.getElementById('gen-device');
    if (sel.options.length <= 1) {
      devices.forEach(d => {
        const opt = document.createElement('option');
        opt.value = d.productType;
        opt.textContent = `${d.marketing} (${d.productType})`;
        sel.appendChild(opt);
      });
    }
  } catch (e) {}

  try {
    const versions = await api('/ios-versions');
    const sel = document.getElementById('gen-ios');
    if (sel.options.length <= 1) {
      versions.forEach(v => {
        const opt = document.createElement('option');
        opt.value = v.version;
        opt.textContent = `iOS ${v.version} (${v.buildVersion})`;
        sel.appendChild(opt);
      });
    }
  } catch (e) {}

  // Build random checkboxes
  buildRandomCheckboxes();

  // Check current profile
  try {
    const r = await api('/current-profile');
    if (r.profile) { currentProfile = r.profile; renderDeviceInfo(currentProfile); }
  } catch (e) {}

  // Check SSH
  try {
    const s = await api('/ssh/status');
    if (s.connected) { isConnected = true; updateConnectionUI(true, s.deviceInfo); }
  } catch (e) {}

  refreshLogs();
}

// Check auth on page load
(async function checkAuth() {
  if (authToken) {
    try {
      const r = await fetch('/api/auth/check', { headers: { 'X-Auth-Token': authToken } }).then(r => r.json());
      if (r.success) {
        currentUser = r.user;
        showAppScreen();
        return;
      }
    } catch (e) {}
  }
  showLoginScreen();
})();
