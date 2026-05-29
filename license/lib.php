<?php
// ============================================================
// HIOS Faker v3 — License backend (PHP, no MySQL, JSON storage)
// Shared library: config, JSON store (flock), HMAC, admin auth.
// ============================================================

// ---- CONFIG: CHANGE THESE TWO BEFORE DEPLOY ----------------
// 1) HMAC secret — MUST match kLicenseSecret in the iOS app.
//    Generate a random 48-char string and paste the SAME value here and in the app.
const HIOS_SECRET = 'hF9kQ2mZ7vX1pR4nL8wB6cT3yD5sG0aJeU2iO9rK4lM7nP1qV8xZ3bN6';
// 2) Admin login (trang admin.php). User + pass cố định.
//    Hai giá trị này chỉ nằm ở server (PHP), KHÔNG bao giờ gửi xuống trình
//    duyệt → F12 xem source không thấy. Lúc đăng nhập, trình duyệt hash
//    SHA-256 trước khi gửi nên F12 Network chỉ thấy chuỗi hash, không thấy
//    mật khẩu thật.
// ⚠ ĐẶT TRỰC TIẾP TRÊN SERVER, KHÔNG commit giá trị thật lên GitHub (repo public).
const HIOS_ADMIN_USER = 'CHANGE_ME_admin_user';
const HIOS_ADMIN_PASS = 'CHANGE_ME_admin_pass';
// ------------------------------------------------------------

const HIOS_DATA_FILE = __DIR__ . '/keys.json';
const HIOS_REPLAY_WINDOW = 300; // seconds a request ts is accepted (anti-replay)

date_default_timezone_set('UTC');

// ---- JSON store (atomic, flock) ----------------------------
function hios_load() {
    $f = HIOS_DATA_FILE;
    if (!file_exists($f)) return ['keys' => []];
    $fp = fopen($f, 'r');
    if (!$fp) return ['keys' => []];
    flock($fp, LOCK_SH);
    $raw = stream_get_contents($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    $d = json_decode($raw, true);
    if (!is_array($d) || !isset($d['keys'])) return ['keys' => []];
    return $d;
}

function hios_save($data) {
    $f = HIOS_DATA_FILE;
    $fp = fopen($f, 'c+');
    if (!$fp) return false;
    flock($fp, LOCK_EX);
    ftruncate($fp, 0);
    rewind($fp);
    fwrite($fp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    return true;
}

// ---- HMAC signing (responses) ------------------------------
// Canonical string the app re-computes and verifies.
function hios_sign($ok, $status, $expiry, $daysLeft, $ts, $nonce) {
    $canon = ($ok ? '1' : '0') . '|' . $status . '|' . $expiry . '|' .
             $daysLeft . '|' . $ts . '|' . $nonce;
    return hash_hmac('sha256', $canon, HIOS_SECRET);
}

function hios_respond($ok, $status, $expiry, $daysLeft, $nonce) {
    $ts = time();
    $sig = hios_sign($ok, $status, $expiry, $daysLeft, $ts, $nonce);
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    echo json_encode([
        'ok'       => $ok,
        'status'   => $status,   // valid | expired | revoked | wrong_device | not_found | bad_request
        'expiry'   => $expiry,   // ISO8601 or ''
        'daysLeft' => $daysLeft,
        'ts'       => $ts,
        'nonce'    => $nonce,
        'sig'      => $sig,
    ]);
    exit;
}

// ---- Key generation: HIOS-XXXX-XXXX-XXXX -------------------
function hios_gen_key() {
    $alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no confusing 0/O/1/I
    $seg = function() use ($alpha) {
        $s = '';
        for ($i = 0; $i < 4; $i++) $s .= $alpha[random_int(0, strlen($alpha) - 1)];
        return $s;
    };
    return 'HIOS-' . $seg() . '-' . $seg() . '-' . $seg();
}

// ---- ISO8601 helper ----------------------------------------
function hios_iso($ts) { return $ts ? gmdate('Y-m-d\TH:i:s\Z', $ts) : ''; }

// ---- Admin session auth ------------------------------------
// The browser hashes SHA-256(user:pass) client-side and submits ONLY the
// hash (field 'auth'). The user/pass inputs have no name attribute, so the
// plaintext never appears in the POST body / F12 Network tab. The expected
// hash is computed server-side and never sent to the client.
function hios_admin_expected_hash() {
    return hash('sha256', HIOS_ADMIN_USER . ':' . HIOS_ADMIN_PASS);
}

function hios_admin_require() {
    // HttpOnly session cookie (not readable by JS / F12 console)
    session_set_cookie_params(['httponly' => true, 'samesite' => 'Lax']);
    session_start();
    if (!empty($_SESSION['hios_admin'])) return;

    if (isset($_POST['auth'])) {
        if (hash_equals(hios_admin_expected_hash(), (string)$_POST['auth'])) {
            session_regenerate_id(true);
            $_SESSION['hios_admin'] = true;
            header('Location: admin.php'); exit;
        }
    }
    $err = isset($_POST['auth']) ? 'Sai tài khoản hoặc mật khẩu.' : '';
    ?><!DOCTYPE html><html lang="vi"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>HIOS Admin</title>
    <style>body{font-family:-apple-system,sans-serif;background:#1a1a1a;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    form{background:#262626;padding:32px;border-radius:12px;width:300px}h2{color:#FF8C00;margin-top:0}
    input{width:100%;padding:12px;margin:8px 0;border-radius:8px;border:1px solid #444;background:#1a1a1a;color:#fff;box-sizing:border-box}
    button{width:100%;padding:12px;background:#FF8C00;color:#fff;border:0;border-radius:8px;font-weight:600;font-size:16px;margin-top:8px}
    .e{color:#e74c3c;font-size:13px;min-height:16px}</style>
    </head><body>
    <form id="lf" method="post" autocomplete="off">
      <h2>HIOS Admin</h2>
      <div class="e"><?=$err?></div>
      <input id="u" placeholder="Tài khoản" autocomplete="off" autofocus>
      <input id="p" type="password" placeholder="Mật khẩu" autocomplete="off">
      <input type="hidden" name="auth" id="auth">
      <button type="submit">Đăng nhập</button>
    </form>
    <script>
    document.getElementById('lf').addEventListener('submit', async function(ev){
      ev.preventDefault();
      var u=document.getElementById('u').value, p=document.getElementById('p').value;
      var data=new TextEncoder().encode(u+':'+p);
      var buf=await crypto.subtle.digest('SHA-256', data);
      var hex=Array.from(new Uint8Array(buf)).map(function(b){return b.toString(16).padStart(2,'0');}).join('');
      document.getElementById('auth').value=hex;
      // clear plaintext fields before the form submits (defense-in-depth)
      document.getElementById('u').value=''; document.getElementById('p').value='';
      ev.target.submit();
    });
    </script>
    </body></html><?php
    exit;
}
