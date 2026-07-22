═══════════════════════════════════════════════════════════════
  HIOS FAKER v3 — HỆ THỐNG KEY (PHP, không cần MySQL)
═══════════════════════════════════════════════════════════════

FILE:
  lib.php      — thư viện chung (config, JSON store, HMAC, admin auth)
  check.php    — API máy gọi để kiểm tra key (app gọi file này)
  admin.php    — trang web quản lý key (bạn dùng để tạo/thu hồi)
  keys.json    — database (tự tạo, để rỗng {"keys":{}} ban đầu)

───────────────────────────────────────────────────────────────
BƯỚC 1 — CẤU HÌNH (lib.php) — ĐÃ ĐẶT SẴN, không cần sửa
───────────────────────────────────────────────────────────────
  HIOS_SECRET     = đã đặt sẵn, KHỚP với app. KHÔNG sửa.
  HIOS_ADMIN_USER = hieunguyen1819   (tài khoản admin)
  HIOS_ADMIN_PASS = hieunguyen1819   (mật khẩu admin)

  Bảo mật: user/pass chỉ nằm ở server (PHP), không gửi xuống trình duyệt
  → F12 xem source KHÔNG thấy. Lúc đăng nhập, trình duyệt hash SHA-256
  trước khi gửi → F12 Network chỉ thấy hash, không thấy "hieunguyen1819".

  ⚠ Phải mở admin qua HTTPS (https://flightmy.info/hios/admin.php) —
    cơ chế hash cần HTTPS mới chạy.

───────────────────────────────────────────────────────────────
BƯỚC 2 — UPLOAD (để thẳng ở GỐC miền flightmy.info, không cần folder)
───────────────────────────────────────────────────────────────
  Upload 5 file vào thư mục gốc của flightmy.info (/domains/flightmy.info):
    lib.php
    check.php
    admin.php
    keys.json      → CHMOD 666 (PHP cần ghi)
    .htaccess      → CHẶN tải trực tiếp keys.json (BẮT BUỘC up file này!)
  Các file .php để 644.
  → URL API:   https://flightmy.info/check.php
  → URL admin: https://flightmy.info/admin.php

  ⚠ BẢO MẬT: keys.json chứa toàn bộ key + UDID khách. File .htaccess chặn
    không cho tải trực tiếp qua https://flightmy.info/keys.json. Nhớ up
    .htaccess! Sau khi up, thử mở https://flightmy.info/keys.json — phải báo
    403 Forbidden (KHÔNG tải được) thì mới an toàn. Nếu vẫn tải được (host
    dùng nginx, không đọc .htaccess) → báo tôi để chuyển cách lưu khác.

───────────────────────────────────────────────────────────────
BƯỚC 3 — DÙNG
───────────────────────────────────────────────────────────────
  1. Mở admin.php → nhập mật khẩu admin.
  2. "Tạo key": đặt số ngày thuê + số lượng → bấm Tạo.
     Key dạng HIOS-XXXX-XXXX-XXXX. Gửi key cho khách.
  3. Khách mở app HIOS Faker → màn Login → nhập key.
     - Lần đầu: key gắn cứng vào máy đó (1 key = 1 máy) + bắt đầu đếm ngày.
     - Hết hạn / thu hồi / sai máy → app văng ra Login, KHÓA Change Device.
  4. Quản lý: gia hạn (+30d), thu hồi, gỡ bind máy (cho khách đổi máy),
     xoá key — ngay trên admin.php.

───────────────────────────────────────────────────────────────
LOGIC KEY
───────────────────────────────────────────────────────────────
  • Tạo key = chưa kích hoạt, đồng hồ CHƯA chạy (bán trước thoải mái).
  • Khách nhập key lần đầu = kích hoạt → hết hạn = giờ đó + số ngày.
  • Mỗi lần mở app + trước khi Change Device → app gọi check.php online.
  • Mất mạng: app dùng hạn đã cache, cho chạy tối đa 48 giờ offline.
  • Response server ký HMAC-SHA256 → app không bị lừa bằng server giả.

LƯU Ý BẢO MẬT: máy jailbreak do khách kiểm soát nên về lý thuyết cao thủ
có thể patch. Cơ chế online + HMAC + bind UDID đủ chặn khách thường và
chống share key. Không lưu secret ra log.
═══════════════════════════════════════════════════════════════
