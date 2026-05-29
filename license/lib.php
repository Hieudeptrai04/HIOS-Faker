<?php
// ============================================================
// HIOS Faker v3 — License backend (PHP, no MySQL, JSON storage)
// Shared library: config, JSON store (flock), HMAC, admin auth.
// ============================================================

// ---- CONFIG: CHANGE THESE TWO BEFORE DEPLOY ----------------
// 1) HMAC secret — MUST match kLicenseSecret in the iOS app.
//    Generate a random 48-char string and paste the SAME value here and in the app.
const HIOS_SECRET = 'hF9kQ2mZ7vX1pR4nL8wB6cT3yD5sG0aJeU2iO9rK4lM7nP1qV8xZ3bN6';
// 2) Admin password for admin.php login.
const HIOS_ADMIN_PASS = 'CHANGE_ME_admin_password';
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
function hios_admin_require() {
    session_start();
    if (!empty($_SESSION['hios_admin'])) return;
    // login form post
    if (isset($_POST['admin_pass'])) {
        if (hash_equals(HIOS_ADMIN_PASS, $_POST['admin_pass'])) {
            $_SESSION['hios_admin'] = true;
            header('Location: admin.php'); exit;
        }
    }
    // show login form
    ?><!DOCTYPE html><html lang="vi"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>HIOS Admin</title>
    <style>body{font-family:-apple-system,sans-serif;background:#1a1a1a;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    form{background:#262626;padding:32px;border-radius:12px;width:300px}h2{color:#FF8C00;margin-top:0}
    input{width:100%;padding:12px;margin:8px 0;border-radius:8px;border:1px solid #444;background:#1a1a1a;color:#fff;box-sizing:border-box}
    button{width:100%;padding:12px;background:#FF8C00;color:#fff;border:0;border-radius:8px;font-weight:600;font-size:16px;margin-top:8px}</style>
    </head><body><form method="post"><h2>HIOS Admin</h2>
    <input type="password" name="admin_pass" placeholder="Mật khẩu admin" autofocus>
    <button type="submit">Đăng nhập</button></form></body></html><?php
    exit;
}
