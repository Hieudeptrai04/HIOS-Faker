// ============================================================
// SERVER - Login, server API, tracking
// ============================================================

// Auth
var AUTH_SALT = '_changeinfoios_salt';
var USERS_DB = [{"u":"admin","h":"c01a144e6f5099a3dd6b171b3c40964e1536c9314b98773ffc8a8d64483f6d0d","a":true},{"u":"hieu123","h":"50ccc1352f8efd48120fc5c8c4569443b3ae6a4a2ca7ddff007fbe5cac743000","a":true}];

function sha256(msg) {
  function rr(v, s) { return (v >>> s) | (v << (32 - s)); }
  var K = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  var H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  var bytes = [];
  for (var i = 0; i < msg.length; i++) {
    var c = msg.charCodeAt(i);
    if (c < 128) bytes.push(c);
    else if (c < 2048) { bytes.push(192 | (c >> 6)); bytes.push(128 | (c & 63)); }
    else { bytes.push(224 | (c >> 12)); bytes.push(128 | ((c >> 6) & 63)); bytes.push(128 | (c & 63)); }
  }
  var bl = bytes.length * 8;
  bytes.push(128);
  while (bytes.length % 64 !== 56) bytes.push(0);
  bytes.push((bl >>> 24) & 0xff, (bl >>> 16) & 0xff, (bl >>> 8) & 0xff, bl & 0xff);
  for (var ch = 0; ch < bytes.length; ch += 64) {
    var w = [];
    for (var j = 0; j < 16; j++) w[j] = (bytes[ch + j * 4] << 24) | (bytes[ch + j * 4 + 1] << 16) | (bytes[ch + j * 4 + 2] << 8) | bytes[ch + j * 4 + 3];
    for (var jj = 16; jj < 64; jj++) {
      var s0 = (rr(w[jj - 15], 7)) ^ (rr(w[jj - 15], 18)) ^ (w[jj - 15] >>> 3);
      var s1 = (rr(w[jj - 2], 17)) ^ (rr(w[jj - 2], 19)) ^ (w[jj - 2] >>> 10);
      w[jj] = (w[jj - 16] + s0 + w[jj - 7] + s1) | 0;
    }
    var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (var kk = 0; kk < 64; kk++) {
      var S1 = (rr(e, 6)) ^ (rr(e, 11)) ^ (rr(e, 25));
      var ch2 = (e & f) ^ ((~e) & g);
      var t1 = (h + S1 + ch2 + K[kk] + w[kk]) | 0;
      var S0 = (rr(a, 2)) ^ (rr(a, 13)) ^ (rr(a, 22));
      var maj = (a & b) ^ (a & c) ^ (b & c);
      var t2 = (S0 + maj) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
    H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
  }
  var hex = '';
  for (var ii = 0; ii < 8; ii++) { var hx = (H[ii] >>> 0).toString(16); while (hx.length < 8) hx = '0' + hx; hex += hx; }
  return hex;
}

function getSavedSession() {
  try { var s = localStorage.getItem('ci_session'); if (s) return JSON.parse(s); } catch (e) {}
  return null;
}

function saveSession(username, token) {
  try { localStorage.setItem('ci_session', JSON.stringify({ u: username, t: token })); } catch (e) {}
}

function doLogin() {
  var uEl = document.getElementById('username');
  var pEl = document.getElementById('password');
  var sEl = document.getElementById('loginStatus');
  if (!uEl || !pEl) return;
  var u = (uEl.value || '').trim();
  var p = (pEl.value || '');
  if (!u || !p) { if (sEl) sEl.textContent = 'Please enter username and password'; return; }
  var hash = sha256(sha256(p + AUTH_SALT) + ':' + u + AUTH_SALT);
  var user = null;
  for (var i = 0; i < USERS_DB.length; i++) {
    if (USERS_DB[i].u === u && USERS_DB[i].h === hash) { user = USERS_DB[i]; break; }
  }
  if (!user) { if (sEl) sEl.textContent = 'Invalid username or password'; return; }
  saveSession(u, hash);
  var ls = document.getElementById('loginScreen');
  var ma = document.getElementById('mainApp');
  var acc = document.getElementById('accUser');
  if (ls) ls.style.display = 'none';
  if (ma) ma.style.display = 'flex';
  if (acc) acc.innerText = u;
  __ciAppInit();
}

function getTrackingUrl() { try { return localStorage.getItem('ci_tracking_url') || 'http://ip-api.com/json'; } catch (e) { return 'http://ip-api.com/json'; } }

function saveTrackingUrl() {
  var el = document.getElementById('trackingUrl');
  if (!el) return;
  try { localStorage.setItem('ci_tracking_url', el.value.trim()); } catch (e) {}
  syncTrackingInputs();
}

function refreshNetworkInfo(doShowToast) {
  var ipEl = document.getElementById('iIP');
  var countryEl = document.getElementById('iCountry');
  var tzEl = document.getElementById('iTZ');
  if (ipEl) ipEl.textContent = '…';
  if (countryEl) countryEl.textContent = '…';
  if (tzEl) tzEl.textContent = '…';
  fetch(getTrackingUrl())
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (data.query && ipEl) ipEl.textContent = data.query;
      if (data.country && countryEl) countryEl.textContent = data.country;
      if (data.timezone && tzEl) tzEl.textContent = data.timezone;
    })
    .catch(function() {
      if (ipEl) ipEl.textContent = '—';
      if (countryEl) countryEl.textContent = '—';
      if (tzEl) tzEl.textContent = '—';
      if (doShowToast) showToast('Network info fetch failed', 'err');
    });
}
