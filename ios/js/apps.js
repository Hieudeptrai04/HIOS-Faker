// ============================================================
// APPS - App list, wipe, backup, installed apps management
// ============================================================

var CI_PICK_DEVICES_KEY = 'ci_pick_devices';
var CI_PICK_IOS_KEY = 'ci_pick_ios';

function isValidBundleId(s) {
  if (!s || typeof s !== 'string') return false;
  s = s.trim();
  if (s.length < 6 || s.indexOf('.') < 0) return false;
  if (s.indexOf('..') >= 0) return false;
  return /^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z0-9][a-zA-Z0-9.-]+$/.test(s);
}

function normalizeAppDisplayName(app) {
  var bid = (app && ((app.bundleId || app.bundle_id) || '') || '').trim();
  var nm = (app && (app.name || '') || '').trim();
  if (!nm) nm = bid;
  var s = nm;
  if (s.indexOf('.') > 0 && /^[a-zA-Z0-9_.-]+$/.test(s)) {
    var parts = s.split('.');
    var tail = parts[parts.length - 1] || s;
    tail = tail.replace(/[_-]+/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/\s+/g, ' ').trim();
    if (tail) nm = tail.charAt(0).toUpperCase() + tail.slice(1);
  }
  return nm || bid || 'App';
}

function isUnsupportedBundleId(bid) {
  var b = (bid || '').toLowerCase();
  if (!b) return true;
  if (b.indexOf('com.apple.') === 0) return true;
  if (/changeinfoios|trollstorepersistence|shadowhelper|swiftterm|down[_-]?down|persistencehelper/.test(b)) return true;
  if (/\.appex|\.framework|\.bundle|\.plugin|\.xpc/.test(b)) return true;
  return false;
}

function filterVisibleApps(apps) {
  var list = Array.isArray(apps) ? apps : [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var a = list[i] || {};
    var bid = (a.bundleId || a.bundle_id || '').trim();
    if (!bid || isUnsupportedBundleId(bid)) continue;
    out.push(a);
  }
  return out;
}

DEVICE_APPS_PRELOADED = filterVisibleApps(DEVICE_APPS_PRELOADED);
__ciAppsCache = filterVisibleApps(__ciAppsCache);

function loadPickListFromStorage(key) {
  try { var raw = JSON.parse(localStorage.getItem(key) || '[]'); return Array.isArray(raw) ? raw : []; } catch (e) { return []; }
}
function savePickListToStorage(key, list) {
  try { localStorage.setItem(key, JSON.stringify(list || [])); } catch (e) {}
}
function loadArrayFromStorage(key) {
  try { var raw = JSON.parse(localStorage.getItem(key) || '[]'); return Array.isArray(raw) ? raw : []; } catch (e) { return []; }
}
function saveArrayToStorage(key, list) {
  try { localStorage.setItem(key, JSON.stringify(Array.isArray(list) ? list : [])); } catch (e) {}
}
function toSet(arr) {
  var s = {};
  for (var i = 0; i < (arr || []).length; i++) { var v = (arr[i] || '').toString().trim(); if (v) s[v] = 1; }
  return s;
}
function setToArray(s) {
  var out = []; for (var k in s) if (Object.prototype.hasOwnProperty.call(s, k) && s[k]) out.push(k); return out;
}

function initSelectionState() {
  var wipe = loadArrayFromStorage(CI_WIPE_SELECTED_KEY);
  if (!wipe.length) wipe = loadArrayFromStorage('ci_pending_wipes');
  __wipeSelectedSet = toSet(wipe);
  var backup = loadArrayFromStorage(CI_BACKUP_SELECTED_KEY);
  if (!backup.length) backup = loadArrayFromStorage('ci_backup_targets');
  __backupSelectedSet = toSet(backup);
}

function persistWipeSelection() {
  var arr = setToArray(__wipeSelectedSet);
  saveArrayToStorage(CI_WIPE_SELECTED_KEY, arr);
  try { localStorage.setItem('ci_pending_wipes', JSON.stringify(arr)); } catch (e) {}
}

function persistBackupSelection() {
  var arr = setToArray(__backupSelectedSet);
  saveArrayToStorage(CI_BACKUP_SELECTED_KEY, arr);
  try { localStorage.setItem('ci_backup_targets', JSON.stringify(arr)); } catch (e) {}
}

function selAllDevs() {
  var devs = loadPickListFromStorage(CI_PICK_DEVICES_KEY);
  var allDevs = getDeviceList().map(function(d) { return d.productType; });
  var allSelected = allDevs.length > 0 && allDevs.every(function(d) { return devs.indexOf(d) >= 0; });
  var newList = allSelected ? [] : allDevs.slice();
  savePickListToStorage(CI_PICK_DEVICES_KEY, newList);
  renderSelDevices();
  updateSelCounts();
}

function selAllIOS() {
  var vers = loadPickListFromStorage(CI_PICK_IOS_KEY);
  var allVers = Object.keys(IOS_VERSIONS);
  var allSelected = allVers.length > 0 && allVers.every(function(v) { return vers.indexOf(v) >= 0; });
  var newList = allSelected ? [] : allVers.slice();
  savePickListToStorage(CI_PICK_IOS_KEY, newList);
  renderSelIOS();
  updateSelCounts();
}

function updateSelCounts() {
  var devs = loadPickListFromStorage(CI_PICK_DEVICES_KEY);
  var vers = loadPickListFromStorage(CI_PICK_IOS_KEY);
  var devBadge = document.getElementById('selDevCount');
  var iosBadge = document.getElementById('selIOSCount');
  if (devBadge) devBadge.textContent = devs.length;
  if (iosBadge) iosBadge.textContent = vers.length;
}

function toggleSelItem(item, type, value) {
  var list = type === 'dev' ? loadPickListFromStorage(CI_PICK_DEVICES_KEY) : loadPickListFromStorage(CI_PICK_IOS_KEY);
  var idx = list.indexOf(value);
  if (idx >= 0) { list.splice(idx, 1); item.classList.remove('selected'); }
  else { list.push(value); item.classList.add('selected'); }
  if (type === 'dev') savePickListToStorage(CI_PICK_DEVICES_KEY, list);
  else savePickListToStorage(CI_PICK_IOS_KEY, list);
  updateSelCounts();
}

function renderSelDevices() {
  var grid = document.getElementById('selDevGrid');
  if (!grid) return;
  var selected = loadPickListFromStorage(CI_PICK_DEVICES_KEY);
  var models = getDeviceList();
  var h = '';
  for (var i = 0; i < models.length; i++) {
    var m = models[i];
    var isSel = selected.indexOf(m.productType) >= 0;
    h += '<div class="sel-item' + (isSel ? ' selected' : '') + '"' +
      ' onclick="toggleSelItem(this,\'dev\',\'' + escapeHtml(m.productType) + '\')">' +
      '<div class="sel-item-check"></div>' +
      '<div class="sel-item-info">' +
      '<div class="sel-item-name">' + escapeHtml(m.marketing) + '</div>' +
      '<div class="sel-item-code">' + escapeHtml(m.productType) + '</div>' +
      '</div></div>';
  }
  grid.innerHTML = h;
  updateSelCounts();
}

function renderSelIOS() {
  var grid = document.getElementById('selIOSGrid');
  if (!grid) return;
  var selected = loadPickListFromStorage(CI_PICK_IOS_KEY);
  var versions = getIOSVersionList();
  var h = '';
  for (var i = 0; i < versions.length; i++) {
    var v = versions[i];
    var isSel = selected.indexOf(v.version) >= 0;
    h += '<div class="sel-item' + (isSel ? ' selected' : '') + '"' +
      ' onclick="toggleSelItem(this,\'ios\',\'' + escapeHtml(v.version) + '\')">' +
      '<div class="sel-item-check"></div>' +
      '<div class="sel-item-info">' +
      '<div class="sel-item-name">iOS ' + escapeHtml(v.version) + '</div>' +
      '<div class="sel-item-code">' + escapeHtml(v.buildVersion || '') + '</div>' +
      '</div></div>';
  }
  grid.innerHTML = h;
  updateSelCounts();
}

// App Icon Loader
var __iconCache = {};
try { __iconCache = JSON.parse(localStorage.getItem('ci_icon_cache') || '{}'); } catch (e) { __iconCache = {}; }
var __iconQueue = [];
var __iconLoading = false;

function _saveIconCache() { try { localStorage.setItem('ci_icon_cache', JSON.stringify(__iconCache)); } catch (e) {} }

function _processIconQueue() {
  if (__iconLoading || __iconQueue.length === 0) return;
  __iconLoading = true;
  var item = __iconQueue.shift();
  var bid = item.bid;
  var els = item.els;
  fetch('https://itunes.apple.com/lookup?bundleId=' + encodeURIComponent(bid) + '&country=vn')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var url = (data.results && data.results[0]) ? (data.results[0].artworkUrl100 || data.results[0].artworkUrl60 || '') : '';
      __iconCache[bid] = url || '_none_';
      _saveIconCache();
      if (url) {
        for (var i = 0; i < els.length; i++) {
          els[i].innerHTML = '<img src="' + url + '" style="width:100%;height:100%;border-radius:inherit;object-fit:cover;" onerror="this.parentNode.innerHTML=\'' + escapeHtml(appInitial(els[i].getAttribute('data-nm') || '?')) + '\'">';
        }
      }
    })
    .catch(function() { __iconCache[bid] = '_none_'; _saveIconCache(); })
    .finally(function() { __iconLoading = false; setTimeout(_processIconQueue, 80); });
}

function loadAllAppIcons() {
  var icos = document.querySelectorAll('.app-ico[data-bid]');
  var byBid = {};
  for (var i = 0; i < icos.length; i++) {
    var bid = icos[i].getAttribute('data-bid');
    if (!bid) continue;
    if (__iconCache[bid] && __iconCache[bid] !== '_none_') {
      icos[i].innerHTML = '<img src="' + __iconCache[bid] + '" style="width:100%;height:100%;border-radius:inherit;object-fit:cover;" onerror="this.parentNode.innerHTML=\'' + escapeHtml(appInitial(icos[i].getAttribute('data-nm') || '?')) + '\'">';
      continue;
    }
    if (__iconCache[bid] === '_none_') continue;
    if (!byBid[bid]) byBid[bid] = [];
    byBid[bid].push(icos[i]);
  }
  __iconQueue = [];
  for (var b in byBid) { __iconQueue.push({ bid: b, els: byBid[b] }); }
  _processIconQueue();
}

function appInitial(name) { var t = (name || '?').trim(); return t.length ? t.charAt(0).toUpperCase() : '?'; }

// App list rendering
function renderAppListFromNative(apps, isFiltered, bannerHtml) {
  var mount = document.getElementById('appListMount');
  if (!mount) return;
  var cnt = document.getElementById('appListCount');
  if (cnt) {
    var n = apps ? apps.length : 0, t = __ciAppsCache.length;
    cnt.textContent = (isFiltered && t && n !== t) ? 'Showing ' + n + ' of ' + t + ' apps' : (t ? n + ' app' + (n !== 1 ? 's' : '') : '');
  }
  var h = '';
  if (apps && apps.length) {
    for (var i = 0; i < apps.length; i++) {
      var a = apps[i], bid = a.bundleId || a.bundle_id || '', nm = normalizeAppDisplayName(a);
      if (!bid) continue;
      var initLetter = escapeHtml(appInitial(nm));
      var icoAttr = ' data-bid="' + escapeHtml(bid) + '" data-nm="' + escapeHtml(nm) + '"';
      var icoInner = a.icon ? '<img src="data:image/png;base64,' + a.icon + '" style="width:100%;height:100%;border-radius:inherit;object-fit:cover;" onerror="this.parentNode.innerHTML=\'' + initLetter + '\'">' : initLetter;
      h += '<div class="app-row" onclick="toggleWipeRow(this)"><input class="app-check" type="checkbox" data-b="' + escapeHtml(bid) + '"><div class="app-ico"' + icoAttr + '>' + icoInner + '</div><div class="app-txt"><div class="app-name">' + escapeHtml(nm) + '</div></div><span class="app-mark">✓</span></div>';
    }
  }
  var emptyMsg = __ciSettingsMode ? 'No apps found on device.' : 'No apps available. Tap <strong>Load</strong> to refresh.';
  if (__ciAppsCache.length === 0 && isCiNativeBridge()) emptyMsg = 'No apps returned — tap <strong>Load</strong> again.';
  var body = h;
  if (!body) body = '<div class="empty-box">' + emptyMsg + '</div>';
  mount.innerHTML = (bannerHtml || '') + body;
  syncWipeRowStates();
  loadAllAppIcons();
}

function renderBackupListFromApps(apps, isFiltered) {
  var mount = document.getElementById('backupListMount');
  if (!mount) return;
  var cnt = document.getElementById('backupAppListCount');
  if (cnt) {
    var n = apps ? apps.length : 0, t = __ciAppsCache.length;
    cnt.textContent = (isFiltered && t && n !== t) ? 'Showing ' + n + ' of ' + t + ' apps' : (t ? n + ' app' + (n !== 1 ? 's' : '') : '');
  }
  var h = '';
  if (apps && apps.length) {
    for (var i = 0; i < apps.length; i++) {
      var a = apps[i], bid = a.bundleId || a.bundle_id || '', nm = normalizeAppDisplayName(a);
      if (!bid) continue;
      var initLetter = escapeHtml(appInitial(nm));
      var icoAttr = ' data-bid="' + escapeHtml(bid) + '" data-nm="' + escapeHtml(nm) + '"';
      var icoInner = a.icon ? '<img src="data:image/png;base64,' + a.icon + '" style="width:100%;height:100%;border-radius:inherit;object-fit:cover;" onerror="this.parentNode.innerHTML=\'' + initLetter + '\'">' : initLetter;
      h += '<div class="app-row" onclick="toggleBackupRow(this)"><input class="backup-check" type="checkbox" data-bk="' + escapeHtml(bid) + '"><div class="app-ico"' + icoAttr + '>' + icoInner + '</div><div class="app-txt"><div class="app-name">' + escapeHtml(nm) + '</div></div><span class="backup-mark">✓</span></div>';
    }
  }
  if (!h) h = '<div class="empty-box">No apps available</div>';
  mount.innerHTML = h;
  syncBackupRowStates();
  loadAllAppIcons();
}

function syncWipeRowStates() {
  var mount = document.getElementById('appListMount');
  if (!mount) return;
  var rows = mount.querySelectorAll('.app-row');
  for (var i = 0; i < rows.length; i++) {
    var cb = rows[i].querySelector('.app-check');
    if (cb) {
      var bid = cb.getAttribute('data-b');
      rows[i].classList.toggle('active', !!(__wipeSelectedSet[bid]));
    }
  }
}

function syncBackupRowStates() {
  var mount = document.getElementById('backupListMount');
  if (!mount) return;
  var rows = mount.querySelectorAll('.app-row');
  for (var i = 0; i < rows.length; i++) {
    var cb = rows[i].querySelector('.backup-check');
    if (cb) {
      var bid = cb.getAttribute('data-bk');
      rows[i].classList.toggle('active', !!(__backupSelectedSet[bid]));
    }
  }
}

function toggleWipeRow(row) {
  var cb = row.querySelector('.app-check');
  if (!cb) return;
  var bid = cb.getAttribute('data-b');
  if (__wipeSelectedSet[bid]) { delete __wipeSelectedSet[bid]; row.classList.remove('active'); }
  else { __wipeSelectedSet[bid] = true; row.classList.add('active'); }
  persistWipeSelection();
}

function toggleBackupRow(row) {
  var cb = row.querySelector('.backup-check');
  if (!cb) return;
  var bid = cb.getAttribute('data-bk');
  if (__backupSelectedSet[bid]) { delete __backupSelectedSet[bid]; row.classList.remove('active'); }
  else { __backupSelectedSet[bid] = true; row.classList.add('active'); }
  persistBackupSelection();
}

function selAllWipe(select) {
  var mount = document.getElementById('appListMount');
  if (!mount) return;
  var rows = mount.querySelectorAll('.app-row');
  for (var i = 0; i < rows.length; i++) {
    var cb = rows[i].querySelector('.app-check');
    if (!cb) continue;
    var bid = cb.getAttribute('data-b');
    if (select) { __wipeSelectedSet[bid] = true; rows[i].classList.add('active'); }
    else { delete __wipeSelectedSet[bid]; rows[i].classList.remove('active'); }
  }
  persistWipeSelection();
}

function selectAllBackup(select) {
  var mount = document.getElementById('backupListMount');
  if (!mount) return;
  var rows = mount.querySelectorAll('.app-row');
  for (var i = 0; i < rows.length; i++) {
    var cb = rows[i].querySelector('.backup-check');
    if (!cb) continue;
    var bid = cb.getAttribute('data-bk');
    if (select) { __backupSelectedSet[bid] = true; rows[i].classList.add('active'); }
    else { delete __backupSelectedSet[bid]; rows[i].classList.remove('active'); }
  }
  persistBackupSelection();
}

function filterInstalledAppList() {
  var q = document.getElementById('appListSearch');
  var query = q ? q.value.trim().toLowerCase() : '';
  if (!query) {
    renderAppListFromNative(__ciAppsCache, false);
    return;
  }
  var filtered = __ciAppsCache.filter(function(a) {
    var bid = (a.bundleId || '').toLowerCase();
    var nm = (a.name || '').toLowerCase();
    return bid.indexOf(query) >= 0 || nm.indexOf(query) >= 0;
  });
  renderAppListFromNative(filtered, true);
}

function filterBackupAppList() {
  var q = document.getElementById('backupAppListSearch');
  var query = q ? q.value.trim().toLowerCase() : '';
  if (!query) {
    renderBackupListFromApps(__ciAppsCache, false);
    return;
  }
  var filtered = __ciAppsCache.filter(function(a) {
    var bid = (a.bundleId || '').toLowerCase();
    var nm = (a.name || '').toLowerCase();
    return bid.indexOf(query) >= 0 || nm.indexOf(query) >= 0;
  });
  renderBackupListFromApps(filtered, true);
}

function wipeSelected() {
  var wipes = getSelectedWipes();
  if (wipes.length === 0) { showToast('No apps selected', 'err'); return; }
  __ciCallNative({ action: 'wipe', wipes: wipes, options: getCiOptions() });
  showToast('Wipe running…', 'ok');
}

function backupSelectedApps() {
  var picks = getSelectedBackups();
  if (picks.length === 0) { showToast('No apps selected for backup', 'err'); return; }
  __backupSelectedSet = toSet(picks);
  persistBackupSelection();
  __ciCallNative({ action: 'backup', bundles: picks });
  showToast('Backup running: ' + picks.length + ' app(s)', 'ok');
}

// Install app callbacks
window.__ciSetInstalledApps = function(list) {
  if (installedAppsTimer) { clearTimeout(installedAppsTimer); installedAppsTimer = null; }
  installedAppsPending = false;
  __ciAppsCache = filterVisibleApps(Array.isArray(list) ? list.slice() : []);
  var qel = document.getElementById('appListSearch');
  if (qel && qel.value.trim()) filterInstalledAppList();
  else renderAppListFromNative(__ciAppsCache, false);
  renderBackupListFromApps(__ciAppsCache, false);
};

window.__ciSetInstallError = function(msg) {
  if (installedAppsTimer) { clearTimeout(installedAppsTimer); installedAppsTimer = null; }
  installedAppsPending = false;
  loadFallbackApps();
  showToast((msg && String(msg)) ? ('Lỗi đọc app: ' + String(msg)) : 'Không lấy được danh sách app trên máy', 'err');
};

function loadFallbackApps() {
  if (FALLBACK_POPULAR_APPS.length > 0) {
    __ciAppsCache = FALLBACK_POPULAR_APPS.slice();
    renderAppListFromNative(__ciAppsCache, false);
    renderBackupListFromApps(__ciAppsCache, false);
  }
}

function requestInstalledApps() {
  var mount = document.getElementById('appListMount');
  if (!mount) return;

  if (__ciAppsCache.length > 0) {
    renderAppListFromNative(__ciAppsCache, false);
    renderBackupListFromApps(__ciAppsCache, false);
    tryRefreshAppsInBackground();
    return;
  }

  if (isCiNativeBridge()) {
    mount.innerHTML = '<div class="empty-box">Đang quét app…</div>';
    if (installedAppsTimer) clearTimeout(installedAppsTimer);
    installedAppsPending = true;
    try {
      __ciCallNative({ action: 'listApps' });
    } catch (e1) {
      installedAppsPending = false;
      loadFallbackApps();
      return;
    }
    installedAppsTimer = setTimeout(function() {
      if (!installedAppsPending) return;
      installedAppsPending = false; installedAppsTimer = null;
      if (__ciAppsCache.length === 0) loadFallbackApps();
      else { renderAppListFromNative(__ciAppsCache, false); renderBackupListFromApps(__ciAppsCache, false); }
    }, 8000);
    return;
  }

  var serverUrl = getCiServerUrl(), token = getCiServerToken();
  if (serverUrl && token) {
    mount.innerHTML = '<div class="empty-box">Đang tải từ server…</div>';
    fetch(serverUrl + '/api/installed-apps', { headers: { 'X-Auth-Token': token } })
      .then(function(r) { if (r.status === 401) throw new Error('Token expired'); return r.json(); })
      .then(function(data) {
        var apps = [];
        if (Array.isArray(data)) {
          apps = data.map(function(item) {
            if (typeof item === 'string') return { bundleId: item, name: item };
            return { bundleId: item.bundleId || item.bundle_id || item, name: item.name || item.bundleId || item };
          });
        }
        if (apps.length === 0) showToast('Server returned 0 apps', 'info');
        __ciSetInstalledApps(apps);
      })
      .catch(function(e) {
        showToast(e.message || 'Server error', 'err');
        loadFallbackApps();
      });
    return;
  }

  // WebClip mode with no server configured
  loadFallbackApps();
}

function tryRefreshAppsInBackground() {
  if (isCiNativeBridge()) {
    try { __ciCallNative({ action: 'listApps' }); } catch (e) {}
    return;
  }
  var serverUrl = getCiServerUrl(), token = getCiServerToken();
  if (serverUrl && token) {
    fetch(serverUrl + '/api/installed-apps', { headers: { 'X-Auth-Token': token } })
      .then(function(r) { return r.status === 200 ? r.json() : null; })
      .then(function(data) {
        if (data && Array.isArray(data)) {
          var apps = data.map(function(item) {
            if (typeof item === 'string') return { bundleId: item, name: item };
            return { bundleId: item.bundleId || item.bundle_id || item, name: item.name || item.bundleId || item };
          });
          __ciSetInstalledApps(apps);
        }
      })
      .catch(function() {});
  }
}
