// ============================================================
// PROFILE - Save/load profiles, fake layer toggles
// ============================================================

var CI_PROFILES_KEY = 'ci_profiles';

function loadProfiles() {
  try { var p = JSON.parse(localStorage.getItem(CI_PROFILES_KEY) || '[]'); return Array.isArray(p) ? p : []; } catch (e) { return []; }
}

function saveProfiles(profiles) {
  try { localStorage.setItem(CI_PROFILES_KEY, JSON.stringify(profiles)); } catch (e) {}
}

function saveProfile() {
  var nameEl = document.getElementById('profileName');
  var name = nameEl ? nameEl.value.trim() : '';
  if (!name) { showToast('Enter profile name', 'err'); return; }
  if (!currentProfile) { showToast('Generate a device first', 'err'); return; }
  var p = loadProfiles();
  var date = new Date().toLocaleDateString('vi-VN');
  var entry = { name: name, date: date, model: currentProfile.MarketingName || '', data: JSON.parse(JSON.stringify(currentProfile)) };
  p.unshift(entry);
  if (p.length > 50) p = p.slice(0, 50);
  saveProfiles(p);
  if (nameEl) nameEl.value = '';
  showToast('Profile "' + name + '" saved', 'ok');
  renderProfiles();
}

function loadProfile(idx) {
  var p = loadProfiles();
  if (!p[idx]) { showToast('Profile not found', 'err'); return; }
  currentProfile = JSON.parse(JSON.stringify(p[idx].data));
  mergeDefaultFakeLayers(currentProfile);
  try { localStorage.setItem('ci_last_profile', JSON.stringify(currentProfile)); } catch (e0) {}
  updateInfoCard(currentProfile);
  syncSelectorsFromProfile(currentProfile);
  setCardStatus(true);
  syncFakeLayerUI();
  showToast('Profile "' + p[idx].name + '" loaded', 'ok');
}

function deleteProfile(idx) {
  var p = loadProfiles();
  if (!p[idx]) return;
  var name = p[idx].name;
  p.splice(idx, 1);
  saveProfiles(p);
  renderProfiles();
  showToast('Profile "' + name + '" deleted', 'info');
}

function renderProfiles() {
  var listEl = document.getElementById('profileList');
  if (!listEl) return;
  var p = loadProfiles();
  var h = '';
  for (var i = 0; i < p.length; i++) {
    h += '<div class="profile-card"><div><div class="p-name">' + escapeHtml(p[i].name) + '</div><div class="p-meta">' + escapeHtml(p[i].model || '') + ' · ' + escapeHtml(p[i].date || '') + '</div></div><div class="p-actions"><button class="p-btn-load" data-idx="' + i + '">Load</button><button class="p-btn-del" data-idx="' + i + '">Delete</button></div></div>';
  }
  listEl.innerHTML = h || '<div class="empty-box" style="padding:20px;">No profiles saved yet.</div>';
}

function loadLastProfile() {
  var last = null;
  try { var s = localStorage.getItem('ci_last_profile'); if (s) last = JSON.parse(s); } catch (e) {}
  if (last) {
    currentProfile = last;
    mergeDefaultFakeLayers(currentProfile);
    try { localStorage.setItem('ci_last_profile', JSON.stringify(currentProfile)); } catch (e0) {}
    updateInfoCard(currentProfile);
    syncSelectorsFromProfile(currentProfile);
    setCardStatus(true);
  } else { setCardStatus(false); }
  syncFakeLayerUI();
}

// Fake layer toggles
function getCiOptions() {
  var o = {};
  try { var s = localStorage.getItem('ci_options'); if (s) o = JSON.parse(s); } catch (e) {}
  document.querySelectorAll('[data-opt]').forEach(function(el) {
    var key = el.dataset.opt;
    if (el.type === 'checkbox') o[key] = el.checked;
    else o[key] = el.value;
  });
  return o;
}

function saveCiOptions(o) {
  try { localStorage.setItem('ci_options', JSON.stringify(o)); } catch (e) {}
}

function bindOptionToggles() {
  document.querySelectorAll('[data-opt]').forEach(function(el) {
    var key = el.dataset.opt;
    var saved = null;
    try { var s = localStorage.getItem('ci_options'); if (s) { var p = JSON.parse(s); saved = p[key]; } } catch (e) {}
    if (saved !== null) {
      if (el.type === 'checkbox') el.checked = !!saved;
      else el.value = saved;
    }
    el.addEventListener('change', function() {
      var opts = getCiOptions();
      if (el.type === 'checkbox') opts[el.dataset.opt] = el.checked;
      else opts[el.dataset.opt] = el.value;
      saveCiOptions(opts);
      applyOptionSideEffects();
    });
  });
}

function applyOptionSideEffects() {
  var opts = getCiOptions();
  if (opts.main_webSvc) refreshNetworkInfo(false);
}

function renderFakeLayerToggles() {
  var el = document.getElementById('fakeLayersList');
  if (!el) return;
  var h = '';
  for (var i = 0; i < FAKE_LAYER_DEFS.length; i++) {
    var layer = FAKE_LAYER_DEFS[i];
    var opts = getCiOptions();
    var key = layer.key;
    var enabled = opts && opts['set_' + key] !== undefined ? opts['set_' + key] : DEFAULT_FAKE_LAYERS[key];
    h += '<div class="fl-item' + (layer.risk ? ' fl-risk' : '') + '">' +
      '<div class="fl-info"><div class="fl-name">' + escapeHtml(layer.label) + '</div><div class="fl-desc">' + escapeHtml(layer.desc) + '</div></div>' +
      '<div class="fl-right"><label class="fl-sw"><input type="checkbox"' + (enabled ? ' checked' : '') + ' data-layer="' + escapeHtml(key) + '"><span class="fl-sl"></span></label></div>' +
      '</div>';
  }
  el.innerHTML = h;
  el.querySelectorAll('input[data-layer]').forEach(function(cb) {
    cb.addEventListener('change', function() {
      var opts = getCiOptions();
      opts['set_' + cb.dataset.layer] = cb.checked;
      saveCiOptions(opts);
      syncFakeLayerUI();
    });
  });
}

function syncFakeLayerUI() {
  var opts = getCiOptions();
  document.querySelectorAll('input[data-layer]').forEach(function(cb) {
    var key = cb.dataset.layer;
    var enabled = opts && opts['set_' + key] !== undefined ? opts['set_' + key] : DEFAULT_FAKE_LAYERS[key];
    cb.checked = !!enabled;
  });
}
