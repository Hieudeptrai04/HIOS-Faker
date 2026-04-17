// ============================================================
// UTILS - Utility functions, UI helpers
// ============================================================

function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str).replace(/[&<>"']/g, function(m) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":"&#39;"}[m];
  });
}

function randInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randHex(len) {
  var s = '';
  for (var i = 0; i < len; i++) s += '0123456789abcdef'[randInt(0, 15)];
  return s;
}

function randUpperHex(len) {
  var s = '';
  for (var i = 0; i < len; i++) s += '0123456789ABCDEF'[randInt(0, 15)];
  return s;
}

function generateUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

function showToast(msg, kind) {
  var el = document.getElementById('toast');
  if (!el) return;
  el.className = 'toast';
  el.textContent = msg;
  el.style.color = '';
  if (kind === 'ok' || kind === 't-ok') el.classList.add('t-ok');
  else if (kind === 'err') el.classList.add('t-err');
  else el.classList.add('t-info');
  setTimeout(function() { el.classList.add('show'); }, 10);
  setTimeout(function() { el.classList.remove('show'); }, 2800);
}

function ciBusyShow(title) {
  var el = document.getElementById('ciBusy');
  if (!el) return;
  var t = document.getElementById('ciBusyTitle');
  var s = document.getElementById('ciBusyStep');
  if (t) t.textContent = title || '';
  if (s) s.textContent = '';
  el.classList.add('on');
}

function ciBusyStepText(msg) {
  var s = document.getElementById('ciBusyStep');
  if (s) s.textContent = msg || '';
}

function ciBusyHide() {
  var el = document.getElementById('ciBusy');
  if (el) el.classList.remove('on');
}

function ciDelay(ms) {
  return new Promise(function(r) { setTimeout(r, ms); });
}

function getCiServerUrl() {
  try {
    var s = localStorage.getItem('ci_server_url');
    if (s) return s;
  } catch(e) {}
  var inp = document.getElementById('ciServerUrl');
  if (inp && inp.value) return inp.value;
  var urlEl = document.getElementById('ciServerUrlDisplay');
  if (urlEl) return urlEl.textContent.replace(/\/$/, '');
  return '';
}

function getCiServerToken() {
  try {
    var s = localStorage.getItem('ci_server_token');
    if (s) return s;
  } catch(e) {}
  var inp = document.getElementById('ciServerToken');
  if (inp && inp.value) return inp.value;
  return '';
}

function setCiServerUrl(url) {
  try { localStorage.setItem('ci_server_url', url); } catch(e) {}
}

function setCiServerToken(token) {
  try { localStorage.setItem('ci_server_token', token); } catch(e) {}
}

function getCiOptions() {
  var o = {};
  try {
    var s = localStorage.getItem('ci_options');
    if (s) o = JSON.parse(s);
  } catch(e) {}
  document.querySelectorAll('[data-opt]').forEach(function(el) {
    var key = el.dataset.opt;
    if (el.type === 'checkbox') o[key] = el.checked;
    else o[key] = el.value;
  });
  return o;
}

function saveCiOptions(o) {
  try { localStorage.setItem('ci_options', JSON.stringify(o)); } catch(e) {}
}

function isCiNativeBridge() {
  return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.changeinfo);
}

function isCiWebClip() {
  try {
    if (window.location.protocol === 'file:') return true;
  } catch (e) {}
  return !!(window.__CI_WEB_CLIP);
}

window.__CI_WEB_CLIP = (function() {
  try {
    if (window.location.protocol === 'file:') return true;
  } catch (e) {}
  return false;
})();

// Wrapper for all native bridge calls
// Falls back to error toast in WebClip mode
function __ciCallNative(msg) {
  if (isCiNativeBridge()) {
    try {
      window.webkit.messageHandlers.changeinfo.postMessage(msg);
    } catch (e) {
      ciToast('Native bridge error: ' + e.message);
    }
  } else {
    // WebClip mode - show appropriate message
    var action = msg.action || 'unknown';
    if (action === 'listApps') {
      ciToast('App list not available in WebClip mode. Install via SSH server.');
    } else if (action === 'deploy') {
      ciToast('Device spoofing not available in WebClip mode. Use SSH server.');
    } else if (action === 'wipe' || action === 'backup') {
      ciToast('Wipe/Backup not available in WebClip mode. Use SSH server.');
    } else {
      ciToast('Native bridge not available in WebClip mode.');
    }
  }
}

function syncTrackingInputs() {
  var url = getCiServerUrl();
  var token = getCiServerToken();
  var uEl = document.getElementById('ciServerUrl');
  var tEl = document.getElementById('ciServerToken');
  if (uEl && !uEl.value) uEl.value = url;
  if (tEl && !tEl.value) tEl.value = token;
}

function initCiServerInputs() {
  syncTrackingInputs();
}

function setCardStatus(ok) {
  var dot = document.getElementById('iStatDot');
  var st = document.getElementById('iStat');
  if (!dot || !st) return;
  if (ok) { dot.className = 'status-dot on'; st.className = 'status-ok'; st.innerText = 'Ready'; }
  else { dot.className = 'status-dot off'; st.className = 'status-wait'; st.innerText = 'Idle'; }
}

function toSet(arr) {
  var s = {};
  if (arr.forEach) arr.forEach(function(v) { s[v] = true; });
  else for (var i = 0; i < arr.length; i++) s[arr[i]] = true;
  return s;
}

function getSelectedWipes() {
  return Object.keys(__wipeSelectedSet);
}

function getSelectedBackups() {
  return Object.keys(__backupSelectedSet);
}

function persistWipeSelection() {
  try { localStorage.setItem(CI_WIPE_SELECTED_KEY, JSON.stringify(__wipeSelectedSet)); } catch(e) {}
}

function persistBackupSelection() {
  try { localStorage.setItem(CI_BACKUP_SELECTED_KEY, JSON.stringify(__backupSelectedSet)); } catch(e) {}
}

function loadWipeSelection() {
  try {
    var s = localStorage.getItem(CI_WIPE_SELECTED_KEY);
    if (s) __wipeSelectedSet = JSON.parse(s);
  } catch(e) { __wipeSelectedSet = {}; }
}

function loadBackupSelection() {
  try {
    var s = localStorage.getItem(CI_BACKUP_SELECTED_KEY);
    if (s) __backupSelectedSet = JSON.parse(s);
  } catch(e) { __backupSelectedSet = {}; }
}

function switchTab(k) {
  var pages = document.querySelectorAll('.page');
  var tabs = document.querySelectorAll('.tab-bar .tab');
  var map = [0,1,2,3,4];
  var target = map[k] !== undefined ? map[k] : 0;
  for (var i = 0; i < pages.length; i++) {
    pages[i].classList.toggle('active', i === target);
  }
  for (var j = 0; j < tabs.length; j++) {
    tabs[j].classList.toggle('on', j === target);
  }
  __ciCurrentTab = target;
  if (target === 1) {
    var models = getDeviceList(), vers = getIOSVersionList();
    if (typeof renderSelectPools === 'function') renderSelectPools(models, vers);
  }
}

function onTabPress(k) {
  if (__ciSettingsMode) switchFormTab(k);
  else switchTab(k);
}

function switchFormTab(k) {
  var map = [4, 0, 1, 2, 3];
  if (k === 1) {
    try { renderSelectPools(getDeviceList(), getIOSVersionList()); } catch(e) {}
  }
  switchTab(map[k] !== undefined ? map[k] : 0);
}

function enterSettingsMode() {
  setSettingsMode(true);
  switchFormTab(0);
}

function exitSettingsMode() {
  setSettingsMode(false);
  switchTab(0);
}

function setSettingsMode(enabled) {
  __ciSettingsMode = !!enabled;
  var appRoot = document.getElementById('mainApp');
  if (appRoot) appRoot.classList.toggle('main-settings-mode', __ciSettingsMode);
  var labels = enabled
    ? ['General', 'Select Devices', 'Wipe App', 'Backup App', 'Proxy']
    : ['Main', 'RRS', 'Apple ID', 'Accounts', 'Settings'];
  var els = document.querySelectorAll('.tab-lbl');
  for (var i = 0; i < els.length && i < labels.length; i++) els[i].textContent = labels[i];
  var backBtn = document.getElementById('hdrBackBtn');
  if (backBtn) backBtn.style.display = enabled ? 'flex' : 'none';
  var extras = document.querySelectorAll('#p1 .rrs-extra');
  for (var j = 0; j < extras.length; j++) extras[j].style.display = enabled ? 'none' : '';
  var bLoad = document.getElementById('rrsBtnLoad');
  var bDelete = document.getElementById('rrsBtnDelete');
  var bSel = document.getElementById('rrsBtnSelectAll');
  var bFilter = document.getElementById('rrsBtnFilter');
  var mount = document.getElementById('appListMount');
  if (enabled) {
    if (bLoad) { bLoad.textContent = 'Load'; }
    if (bDelete) { bDelete.textContent = 'Wipe'; }
    if (bSel) { bSel.textContent = 'Select All'; }
    if (bFilter) { bFilter.textContent = 'Clear'; }
    if (mount) { mount.classList.remove('rrs-list'); mount.classList.add('wipe-list'); }
  } else {
    if (bLoad) { bLoad.textContent = 'Load RRS'; }
    if (bDelete) { bDelete.textContent = 'Delete'; }
    if (bSel) { bSel.textContent = 'Select All'; }
    if (bFilter) { bFilter.textContent = 'Filter'; }
    if (mount) { mount.classList.remove('wipe-list'); mount.classList.add('rrs-list'); }
  }
}

function refreshCiModeBanner() {
  var el = document.getElementById('ciModeBanner');
  if (!el) return;
  var shell = !!(window.__CI_NATIVE_SHELL || isCiNativeBridge());
  if (shell) {
    el.className = 'ci-mode-banner';
    el.innerHTML = '';
    return;
  }
  el.className = 'ci-mode-banner show ci-mode-webclip';
  el.innerHTML = 'Preview mode: open native <strong>HIOS Faker</strong> app for real apply/reset.';
}

function resetAll() {
  try {
    localStorage.clear();
    sessionStorage.clear();
  } catch(e) {}
  __ciAppsCache = [];
  __wipeSelectedSet = {};
  __backupSelectedSet = {};
  currentProfile = null;
  showToast('All data reset', 'ok');
  location.reload();
}

// Desktop/browser fallback: mouse wheel scrolls content area.
(function bindDesktopWheelScroll() {
  var scroller = document.querySelector('.safe-bottom');
  if (!scroller) return;
  scroller.addEventListener('wheel', function(e) {
    if (!e || !e.deltaY) return;
    scroller.scrollTop += e.deltaY;
    e.preventDefault();
  }, { passive: false });
})();
