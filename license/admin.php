<?php
// ============================================================
// admin.php — web admin to create / list / revoke / extend keys.
// Password-protected (HIOS_ADMIN_PASS in lib.php).
// ============================================================
require __DIR__ . '/lib.php';
hios_admin_require();

$msg = '';

// ---- actions ----
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';
    $data = hios_load();

    if ($action === 'create') {
        $days   = max(1, intval($_POST['days'] ?? 30));
        $count  = max(1, min(100, intval($_POST['count'] ?? 1)));
        $note   = trim($_POST['note'] ?? '');
        $custom = strtoupper(trim($_POST['customkey'] ?? '')); // keys are case-insensitive (stored uppercase)
        $mk = function($d) use ($days, $note) {
            return [
                'created'      => time(),
                'durationDays' => $days,
                'activatedAt'  => null,
                'expiry'       => null,
                'udid'         => null,
                'status'       => 'active',
                'note'         => $note,
                'lastSeen'     => null,
            ];
        };
        if ($custom !== '') {
            // Tự đặt tên key. Cho phép chữ/số/-/_ , 3-40 ký tự.
            if (!preg_match('/^[A-Za-z0-9\-_]{3,40}$/', $custom)) {
                $msg = '⚠ Tên key chỉ gồm chữ, số, - hoặc _ (3–40 ký tự).';
            } else if (isset($data['keys'][$custom])) {
                $msg = '⚠ Key "' . $custom . '" đã tồn tại.';
            } else {
                $data['keys'][$custom] = $mk($custom);
                hios_save($data);
                $msg = 'Đã tạo key: ' . $custom . ' (' . $days . ' ngày)';
            }
        } else {
            $made = [];
            for ($i = 0; $i < $count; $i++) {
                do { $nk = hios_gen_key(); } while (isset($data['keys'][$nk]));
                $data['keys'][$nk] = $mk($nk);
                $made[] = $nk;
            }
            hios_save($data);
            $msg = 'Đã tạo ' . $count . ' key (' . $days . ' ngày): ' . implode(', ', $made);
        }
    }
    else if ($action === 'revoke' && !empty($_POST['key'])) {
        $kk = $_POST['key'];
        if (isset($data['keys'][$kk])) { $data['keys'][$kk]['status'] = 'revoked'; hios_save($data); $msg = 'Đã thu hồi ' . $kk; }
    }
    else if ($action === 'activate' && !empty($_POST['key'])) { // un-revoke
        $kk = $_POST['key'];
        if (isset($data['keys'][$kk])) { $data['keys'][$kk]['status'] = 'active'; hios_save($data); $msg = 'Đã bật lại ' . $kk; }
    }
    else if ($action === 'extend' && !empty($_POST['key'])) {
        $kk = $_POST['key']; $add = max(1, intval($_POST['days'] ?? 30));
        if (isset($data['keys'][$kk])) {
            $base = max(time(), intval($data['keys'][$kk]['expiry'] ?? 0));
            // if not activated yet, just grow durationDays
            if (empty($data['keys'][$kk]['udid'])) {
                $data['keys'][$kk]['durationDays'] = intval($data['keys'][$kk]['durationDays']) + $add;
            } else {
                $data['keys'][$kk]['expiry'] = $base + $add * 86400;
            }
            hios_save($data); $msg = 'Đã gia hạn ' . $kk . ' +' . $add . ' ngày';
        }
    }
    else if ($action === 'unbind' && !empty($_POST['key'])) { // reset device binding
        $kk = $_POST['key'];
        if (isset($data['keys'][$kk])) { $data['keys'][$kk]['udid'] = null; hios_save($data); $msg = 'Đã gỡ bind máy cho ' . $kk; }
    }
    else if ($action === 'delete' && !empty($_POST['key'])) {
        $kk = $_POST['key'];
        if (isset($data['keys'][$kk])) { unset($data['keys'][$kk]); hios_save($data); $msg = 'Đã xoá ' . $kk; }
    }
    else if ($action === 'logout') { session_destroy(); header('Location: admin.php'); exit; }
}

$data = hios_load();
$keys = $data['keys'];
// sort: active+bound first, then by created desc
uasort($keys, function($a, $b){ return ($b['created'] ?? 0) <=> ($a['created'] ?? 0); });

$now = time();
function statusBadge($k, $now) {
    if (($k['status'] ?? '') === 'revoked') return ['Thu hồi', '#e74c3c'];
    if (empty($k['udid']))                  return ['Chưa kích hoạt', '#888'];
    $exp = intval($k['expiry'] ?? 0);
    if ($now >= $exp)                        return ['Hết hạn', '#e67e22'];
    return ['Đang chạy', '#27ae60'];
}
?><!DOCTYPE html><html lang="vi"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HIOS Faker — Quản lý Key</title>
<style>
:root{--org:#FF8C00}
body{font-family:-apple-system,Segoe UI,sans-serif;background:#161616;color:#eee;margin:0;padding:20px}
h1{color:var(--org);font-size:22px}
.bar{display:flex;gap:12px;flex-wrap:wrap;align-items:flex-end;background:#222;padding:16px;border-radius:12px;margin-bottom:16px}
.bar label{font-size:12px;color:#aaa;display:block;margin-bottom:4px}
input,select{padding:9px;border-radius:7px;border:1px solid #444;background:#1a1a1a;color:#fff}
button{padding:9px 16px;border:0;border-radius:7px;background:var(--org);color:#fff;font-weight:600;cursor:pointer}
button.sm{padding:5px 10px;font-size:12px;background:#333}
button.danger{background:#c0392b}
.msg{background:#1e3a1e;border:1px solid #2e6e2e;padding:10px 14px;border-radius:8px;margin-bottom:14px;font-size:14px;word-break:break-all}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid #2a2a2a}
th{color:#888;font-weight:600}
code{background:#000;padding:3px 7px;border-radius:5px;color:#fff;font-size:13px}
.badge{padding:3px 9px;border-radius:20px;color:#fff;font-size:11px;font-weight:600}
.udid{font-size:11px;color:#888;max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
form.inline{display:inline}
.top{display:flex;justify-content:space-between;align-items:center}
</style></head><body>
<div class="top"><h1>🔑 HIOS Faker — Quản lý Key</h1>
<form method="post"><button name="action" value="logout" class="sm">Đăng xuất</button></form></div>

<?php if ($msg): ?><div class="msg"><?=htmlspecialchars($msg)?></div><?php endif; ?>

<form method="post" class="bar">
  <input type="hidden" name="action" value="create">
  <div><label>Số ngày thuê</label><input type="number" name="days" value="30" min="1" style="width:90px"></div>
  <div style="min-width:220px"><label>Tên key tự đặt (để trống = tự sinh)</label>
    <input type="text" name="customkey" placeholder="vd: KHACHA-ZALO-T12" style="width:100%"></div>
  <div><label>SL (chỉ khi tự sinh)</label><input type="number" name="count" value="1" min="1" max="100" style="width:80px"></div>
  <div style="flex:1;min-width:140px"><label>Ghi chú (tên khách...)</label><input type="text" name="note" placeholder="vd: khách A - zalo" style="width:100%"></div>
  <button type="submit">+ Tạo key</button>
</form>

<table>
<tr><th>Key</th><th>Trạng thái</th><th>Còn lại</th><th>Hết hạn</th><th>Máy (UDID)</th><th>Ghi chú</th><th>Thao tác</th></tr>
<?php foreach ($keys as $kk => $k):
  list($lbl, $col) = statusBadge($k, $now);
  $exp = intval($k['expiry'] ?? 0);
  $left = empty($k['udid']) ? intval($k['durationDays']).'ng (chưa KH)'
          : ($now >= $exp ? '—' : (int)ceil(($exp-$now)/86400).' ngày');
?>
<tr>
  <td><code><?=htmlspecialchars($kk)?></code></td>
  <td><span class="badge" style="background:<?=$col?>"><?=$lbl?></span></td>
  <td><?=$left?></td>
  <td><?= $exp ? gmdate('d/m/Y H:i', $exp) : '—' ?></td>
  <td class="udid" title="<?=htmlspecialchars($k['udid']??'')?>"><?=htmlspecialchars($k['udid']?:'—')?></td>
  <td><?=htmlspecialchars($k['note']??'')?></td>
  <td>
    <form class="inline" method="post"><input type="hidden" name="key" value="<?=htmlspecialchars($kk)?>">
      <input type="hidden" name="days" value="30">
      <button class="sm" name="action" value="extend">+30d</button></form>
    <?php if(($k['status']??'')==='revoked'): ?>
      <form class="inline" method="post"><input type="hidden" name="key" value="<?=htmlspecialchars($kk)?>"><button class="sm" name="action" value="activate">Bật lại</button></form>
    <?php else: ?>
      <form class="inline" method="post"><input type="hidden" name="key" value="<?=htmlspecialchars($kk)?>"><button class="sm danger" name="action" value="revoke">Thu hồi</button></form>
    <?php endif; ?>
    <form class="inline" method="post"><input type="hidden" name="key" value="<?=htmlspecialchars($kk)?>"><button class="sm" name="action" value="unbind" onclick="return confirm('Gỡ bind máy? Khách có thể đăng nhập máy mới.')">Gỡ máy</button></form>
    <form class="inline" method="post"><input type="hidden" name="key" value="<?=htmlspecialchars($kk)?>"><button class="sm danger" name="action" value="delete" onclick="return confirm('Xoá hẳn key này?')">Xoá</button></form>
  </td>
</tr>
<?php endforeach; ?>
</table>
<p style="color:#666;font-size:12px;margin-top:20px">Tổng: <?=count($keys)?> key • Server time (UTC): <?=gmdate('Y-m-d H:i:s')?></p>
</body></html>
