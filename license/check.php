<?php
// ============================================================
// check.php — device-facing license validation API.
// POST: key, udid, nonce, ts
// Returns HMAC-signed JSON (see lib.php hios_respond).
//
// Model: 1 key = 1 device.
//   - Key is created (admin) with durationDays, unactivated.
//   - First successful check binds the udid AND starts the clock
//     (activatedAt = now, expiry = now + durationDays).
//   - Later checks must come from the SAME udid; else wrong_device.
//   - expired / revoked handled explicitly.
// ============================================================
require __DIR__ . '/lib.php';

// Keys are case-insensitive: uppercase-normalize (app does the same).
$key   = isset($_POST['key'])   ? strtoupper(trim($_POST['key'])) : '';
$udid  = isset($_POST['udid'])  ? trim($_POST['udid'])  : '';
$nonce = isset($_POST['nonce']) ? trim($_POST['nonce']) : '';
$ts    = isset($_POST['ts'])    ? intval($_POST['ts'])  : 0;

// udid + nonce are mandatory. key MAY be empty → that's a DEVICE-LOGIN.
if ($udid === '' || $nonce === '') {
    hios_respond(false, 'bad_request', '', 0, $nonce);
}
if ($ts > 0 && abs(time() - $ts) > HIOS_REPLAY_WINDOW) {
    // clock skew too large — still answer but mark bad_request (app may retry)
    hios_respond(false, 'bad_request', '', 0, $nonce);
}

$data = hios_load();

// DEVICE-LOGIN: empty key → resolve the active key already bound to this UDID.
// Lets a device that was bound before (even after app reinstall) log in
// straight away without re-typing the key. Returns need_key if none.
if ($key === '') {
    $found = '';
    foreach ($data['keys'] as $kk => $kv) {
        if (($kv['udid'] ?? '') === $udid && ($kv['status'] ?? 'active') !== 'revoked') {
            $found = $kk; break;
        }
    }
    if ($found === '') {
        hios_respond(false, 'need_key', '', 0, $nonce);
    }
    $key = $found;
}

if (!isset($data['keys'][$key])) {
    hios_respond(false, 'not_found', '', 0, $nonce);
}

$k = &$data['keys'][$key];

// revoked
if (($k['status'] ?? 'active') === 'revoked') {
    hios_respond(false, 'revoked', hios_iso($k['expiry'] ?? 0), 0, $nonce);
}

$now = time();

// Bind udid. Start the clock ONLY on the very first activation (activatedAt
// unset). An admin 'unbind' clears just the udid, so re-binding a key that was
// already activated must NOT reset expiry to a fresh full term — otherwise
// 'unbind' doubles as a free renewal for whoever logs in next.
if (empty($k['udid'])) {
    $k['udid'] = $udid;
    if (empty($k['activatedAt'])) {
        $k['activatedAt'] = $now;
        $k['expiry']      = $now + (intval($k['durationDays'] ?? 30) * 86400);
    }
    hios_save($data);
} else if (!hash_equals($k['udid'], $udid)) {
    // bound to a different device
    hios_respond(false, 'wrong_device', hios_iso($k['expiry'] ?? 0), 0, $nonce);
}

// expiry check
$expiry = intval($k['expiry'] ?? 0);
if ($now >= $expiry) {
    hios_respond(false, 'expired', hios_iso($expiry), 0, $nonce);
}

$daysLeft = (int)ceil(($expiry - $now) / 86400);

// record last seen (best-effort; ignore save failure)
$k['lastSeen'] = $now;
hios_save($data);

hios_respond(true, 'valid', hios_iso($expiry), $daysLeft, $nonce);
