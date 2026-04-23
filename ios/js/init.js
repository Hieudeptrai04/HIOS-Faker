// ============================================================
// INIT - Bind button events, app initialization
// This is the CRITICAL init that ensures ALL buttons work
// ============================================================

// Called after DOM + all scripts are loaded
function __ciAppInit() {
  // Populate selectors
  renderSelectPools(getDeviceList(), getIOSVersionList());

  // Fake layer toggles
  renderFakeLayerToggles();
  bindOptionToggles();
  applyOptionSideEffects();

  // Profiles
  renderProfiles();
  loadLastProfile();
  if (!currentProfile) {
    try { applyFullDeviceReroll(); } catch (e) {}
  }

  // App data
  try { initSelectionState(); } catch (e) {}
  try { requestInstalledApps(); } catch (e) {}

  // Network
  try { initCiServerInputs(); } catch (e) {}
  try { syncTrackingInputs(); } catch (e) {}
  try { refreshNetworkInfo(false); } catch (e) {}

  // Backup list
  if (__ciAppsCache.length > 0) {
    try { renderBackupListFromApps(__ciAppsCache, false); } catch (e) {}
  }

}

function bindAllButtonEvents() {
  // Main action buttons
  var btnLogin = document.getElementById('loginBtn');
  if (btnLogin) btnLogin.onclick = doLogin;

  var btnReset = document.getElementById('btnResetData');
  if (btnReset) btnReset.onclick = randomizeAll;

  var btnBackup = document.getElementById('btnBackupReset');
  if (btnBackup) btnBackup.onclick = deployConfig;

  var btnSettings = document.getElementById('btnSettings');
  if (btnSettings) btnSettings.onclick = enterSettingsMode;

  var hdrBack = document.getElementById('hdrBackBtn');
  if (hdrBack) hdrBack.onclick = exitSettingsMode;

  var hdrAcc = document.querySelector('.hdr-acc');
  if (hdrAcc) hdrAcc.onclick = function() { switchTab(3); };

  // RRS buttons
  var rrsLoad = document.getElementById('rrsBtnLoad');
  if (rrsLoad) rrsLoad.onclick = requestInstalledApps;

  var rrsDelete = document.getElementById('rrsBtnDelete');
  if (rrsDelete) rrsDelete.onclick = wipeSelected;

  var rrsSelAll = document.getElementById('rrsBtnSelectAll');
  if (rrsSelAll) rrsSelAll.onclick = function() { selAllWipe(true); };

  var rrsFilter = document.getElementById('rrsBtnFilter');
  if (rrsFilter) rrsFilter.onclick = function() { selAllWipe(false); };

  var rrsEdit = document.getElementById('rrsBtnEdit');
  if (rrsEdit) rrsEdit.onclick = function() { showToast('Edit mode', 'info'); };

  // Backup buttons
  var btnBackupApps = document.getElementById('btnBackupApps');
  if (btnBackupApps) btnBackupApps.onclick = backupSelectedApps;

  var btnSelAllBackup = document.getElementById('btnSelectAllBackup');
  if (btnSelAllBackup) btnSelAllBackup.onclick = function() { selectAllBackup(true); };

  var btnClearBackup = document.getElementById('btnClearBackup');
  if (btnClearBackup) btnClearBackup.onclick = function() { selectAllBackup(false); };

  // Select device/iOS buttons
  var btnSelDevs = document.getElementById('btnSelAllDevs');
  if (btnSelDevs) btnSelDevs.onclick = selAllDevs;

  var btnSelIOS = document.getElementById('btnSelAllIOS');
  if (btnSelIOS) btnSelIOS.onclick = selAllIOS;

  // Settings buttons
  var btnSaveProfile = document.getElementById('btnSaveProfile');
  if (btnSaveProfile) btnSaveProfile.onclick = saveProfile;

  var btnSaveTrackingUrl = document.getElementById('btnSaveTrackingUrl');
  if (btnSaveTrackingUrl) btnSaveTrackingUrl.onclick = saveTrackingUrl;

  var btnResetAll = document.getElementById('btnResetAll');
  if (btnResetAll) btnResetAll.onclick = resetAll;

  // Tab bar
  var tabs = document.querySelectorAll('.tab-bar .tab');
  tabs.forEach(function(tab) {
    tab.onclick = function() {
      var k = parseInt(tab.dataset.tab || '0', 10);
      onTabPress(k);
    };
  });

  // Search inputs
  var appSearch = document.getElementById('appListSearch');
  if (appSearch) appSearch.oninput = filterInstalledAppList;

  var backupSearch = document.getElementById('backupAppListSearch');
  if (backupSearch) backupSearch.oninput = filterBackupAppList;

  // Profile list buttons (delegated)
  document.addEventListener('click', function(e) {
    var target = e.target;
    if (!target) return;

    // Profile Load/Delete buttons
    var idx = target.dataset.idx;
    if (target.classList.contains('p-btn-load') && idx !== undefined) {
      loadProfile(parseInt(idx, 10));
      return;
    }
    if (target.classList.contains('p-btn-del') && idx !== undefined) {
      deleteProfile(parseInt(idx, 10));
      return;
    }

    // Device/iOS grid items
    var parent = target.closest('.sel-item');
    if (parent) {
      var parent2 = parent.closest('.sel-grid');
      if (parent2) {
        var type = parent2.id === 'selDevGrid' ? 'dev' : 'ios';
        var value = parent.dataset.value || parent.querySelector('.sel-item-name, .sel-item-code');
        if (parent.hasAttribute('data-value')) {
          var v2 = parent.getAttribute('data-value');
          if (v2) {
            var divs = parent.querySelectorAll('[class*="sel-item-"]');
            var txt = divs.length > 0 ? (divs[0].textContent || '') : parent.textContent;
            toggleSelItem(parent, type, v2);
            return;
          }
        }
      }
    }

    // App row clicks
    var appRow = target.closest('.app-row');
    if (appRow) {
      var mount = appRow.closest('#appListMount, #backupListMount');
      if (mount) {
        if (mount.id === 'appListMount') toggleWipeRow(appRow);
        else if (mount.id === 'backupListMount') toggleBackupRow(appRow);
      }
    }
  });
}

// INIT SEQUENCE - This is the ONLY place where DOM-dependent init happens
(function ciInit() {
  // Step 1: Bind all button events immediately
  bindAllButtonEvents();

  // Step 2: Check for saved session
  var saved = null;
  try { saved = localStorage.getItem('ci_session'); } catch (e) {}

  var ls = document.getElementById('loginScreen');
  var ma = document.getElementById('mainApp');

  if (saved) {
    try {
      var sess = JSON.parse(saved);
      if (sess && sess.u) {
        // Auto-login: hide login, show main
        if (ls) ls.style.display = 'none';
        if (ma) ma.style.display = 'flex';
        var acc = document.getElementById('accUser');
        if (acc) acc.innerText = sess.u;

        // Run full init
        __ciAppInit();
        return;
      }
    } catch (e) {}
  }

  // No session: show main app (login screen hidden anyway by CSS)
  if (ma) ma.style.display = 'flex';
  if (ls) ls.style.display = 'none';
})();
