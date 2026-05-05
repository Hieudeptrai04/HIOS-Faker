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

// --- Dual-thumb range slider state (replaces the legacy multi-select grid) ---
// Both ranges store {minIdx,maxIdx} into the ordered arrays declared in
// config-data.js. Range bounds are inclusive; randomization picks any element
// in [minIdx, maxIdx]. If the user has not interacted yet, defaults span the
// full list (oldest → newest).

function loadRangeFromStorage(key, max) {
  try {
    var raw = JSON.parse(localStorage.getItem(key) || 'null');
    if (raw && typeof raw.minIdx === 'number' && typeof raw.maxIdx === 'number') {
      var lo = Math.max(0, Math.min(max, raw.minIdx));
      var hi = Math.max(0, Math.min(max, raw.maxIdx));
      if (lo > hi) { var t = lo; lo = hi; hi = t; }
      return { minIdx: lo, maxIdx: hi };
    }
  } catch (e) {}
  return { minIdx: 0, maxIdx: max };
}

function saveRangeToStorage(key, range) {
  try { localStorage.setItem(key, JSON.stringify(range)); } catch (e) {}
}

function getDeviceRange() {
  return loadRangeFromStorage(CI_DEVICE_RANGE_KEY, DEVICE_RELEASE_ORDER.length - 1);
}

function getIOSRange() {
  return loadRangeFromStorage(CI_IOS_RANGE_KEY, IOS_VERSION_ORDER.length - 1);
}

function _rangeFillStyle(slider, minIdx, maxIdx, max) {
  if (max <= 0) return { left: '0%', width: '100%' };
  var lo = (minIdx / max) * 100;
  var hi = (maxIdx / max) * 100;
  return { left: lo + '%', width: (hi - lo) + '%' };
}

function _wireRangeSlider(opts) {
  // opts = { minEl, maxEl, fillEl, minLbl, maxLbl, items, fmt, storageKey }
  var max = opts.items.length - 1;
  if (max < 0) return;
  opts.minEl.min = 0; opts.minEl.max = max;
  opts.maxEl.min = 0; opts.maxEl.max = max;
  var saved = loadRangeFromStorage(opts.storageKey, max);
  opts.minEl.value = saved.minIdx;
  opts.maxEl.value = saved.maxIdx;

  function refresh(commit) {
    var lo = parseInt(opts.minEl.value, 10) || 0;
    var hi = parseInt(opts.maxEl.value, 10) || 0;
    if (lo > hi) {
      // Active thumb stays where it is; the other thumb snaps to it.
      if (document.activeElement === opts.minEl) opts.maxEl.value = lo;
      else opts.minEl.value = hi;
      lo = parseInt(opts.minEl.value, 10) || 0;
      hi = parseInt(opts.maxEl.value, 10) || 0;
    }
    var st = _rangeFillStyle(null, lo, hi, max);
    opts.fillEl.style.left = st.left;
    opts.fillEl.style.width = st.width;
    if (opts.minLbl) opts.minLbl.textContent = opts.fmt(opts.items[lo]);
    if (opts.maxLbl) opts.maxLbl.textContent = opts.fmt(opts.items[hi]);
    if (commit) saveRangeToStorage(opts.storageKey, { minIdx: lo, maxIdx: hi });
  }

  opts.minEl.addEventListener('input', function() { refresh(false); });
  opts.maxEl.addEventListener('input', function() { refresh(false); });
  opts.minEl.addEventListener('change', function() { refresh(true); });
  opts.maxEl.addEventListener('change', function() { refresh(true); });
  opts.minEl.addEventListener('touchend', function() { refresh(true); });
  opts.maxEl.addEventListener('touchend', function() { refresh(true); });
  refresh(false);
}

function initRangeSliders() {
  var devMin = document.getElementById('rangeDevMin');
  var devMax = document.getElementById('rangeDevMax');
  var devFill = document.getElementById('rangeDevFill');
  if (devMin && devMax && devFill) {
    _wireRangeSlider({
      minEl: devMin, maxEl: devMax, fillEl: devFill,
      minLbl: document.getElementById('rangeDevMinLbl'),
      maxLbl: document.getElementById('rangeDevMaxLbl'),
      items: DEVICE_RELEASE_ORDER,
      fmt: function(productType) {
        var info = DEVICE_DATABASE[productType];
        return info ? info.marketing : productType;
      },
      storageKey: CI_DEVICE_RANGE_KEY,
    });
  }
  var iosMin = document.getElementById('rangeIOSMin');
  var iosMax = document.getElementById('rangeIOSMax');
  var iosFill = document.getElementById('rangeIOSFill');
  if (iosMin && iosMax && iosFill) {
    _wireRangeSlider({
      minEl: iosMin, maxEl: iosMax, fillEl: iosFill,
      minLbl: document.getElementById('rangeIOSMinLbl'),
      maxLbl: document.getElementById('rangeIOSMaxLbl'),
      items: IOS_VERSION_ORDER,
      fmt: function(v) { return 'iOS ' + v; },
      storageKey: CI_IOS_RANGE_KEY,
    });
  }
}

// Legacy stubs — old code paths still call these; they are now no-ops because
// the multi-select grid was replaced by the range slider above.
function selAllDevs() {}
function selAllIOS() {}
function updateSelCounts() {}
function toggleSelItem() {}
function renderSelDevices() {}
function renderSelIOS() {}

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
  var mount = document.getElementById('appListMount');
  if (mount) mount.innerHTML = '<div class="empty-box">Không lấy được danh sách app trên máy.</div>';
  renderBackupListFromApps([], false);
  showToast((msg && String(msg)) ? ('Lỗi đọc app: ' + String(msg)) : 'Không lấy được danh sách app trên máy', 'err');
};

function requestInstalledApps() {
  var mount = document.getElementById('appListMount');
  if (!mount) return;

  if (__ciAppsCache.length > 0) {
    renderAppListFromNative(__ciAppsCache, false);
    renderBackupListFromApps(__ciAppsCache, false);
    tryRefreshAppsInBackground();
    return;
  }

  if (!isCiNativeBridge()) {
    mount.innerHTML = '<div class="empty-box">Native bridge không sẵn sàng.</div>';
    return;
  }

  mount.innerHTML = '<div class="empty-box">Đang quét app…</div>';
  if (installedAppsTimer) clearTimeout(installedAppsTimer);
  installedAppsPending = true;
  try {
    __ciCallNative({ action: 'listApps' });
  } catch (e1) {
    installedAppsPending = false;
    mount.innerHTML = '<div class="empty-box">Không lấy được danh sách app trên máy.</div>';
    showToast(e1.message || 'Native bridge error', 'err');
    return;
  }
  installedAppsTimer = setTimeout(function() {
    if (!installedAppsPending) return;
    installedAppsPending = false;
    installedAppsTimer = null;
    if (__ciAppsCache.length === 0) {
      mount.innerHTML = '<div class="empty-box">Không lấy được danh sách app trên máy.</div>';
    } else {
      renderAppListFromNative(__ciAppsCache, false);
      renderBackupListFromApps(__ciAppsCache, false);
    }
  }, 8000);
}

function tryRefreshAppsInBackground() {
  if (!isCiNativeBridge()) return;
  try { __ciCallNative({ action: 'listApps' }); } catch (e) {}
}
