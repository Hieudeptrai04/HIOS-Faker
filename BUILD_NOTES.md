# Build Notes — HIOS Faker (ChangeInfoIos)

Mục tiêu của file: giúp AI trợ lý (Claude, Cursor, Codex…) build đúng ngay lần đầu, không phá CI.

---

## 1. Kiến trúc repo

```
ChangeInfoIos/
├── tweak/           → .dylib inject vào target apps (Logos %hook + MSHookFunction)
│   ├── Tweak.xm     → ObjC hooks (UIDevice, CLLocation, MGCopyAnswer, …)
│   ├── Hooks.mm     → C-level hooks (KHÔNG extern forward decl — xem §5)
│   ├── Makefile     → PACKAGE_VERSION, TWEAK_NAME=ChangeInfoIos
│   └── control      → Debian metadata, phải KHỚP Makefile
├── app/             → App UI native chạy trên iPhone
│   ├── main.m       → Toàn bộ UI + logic trong 1 file (~1900 dòng)
│   ├── Makefile     → APPLICATION_NAME=ChangeInfoIosApp
│   ├── control      → Debian metadata
│   └── Resources/
│       └── Info.plist
└── .github/workflows/
    └── build.yml    → CI build duy nhất. CÁC WORKFLOW `.disabled` KHÔNG ĐƯỢC KÍCH HOẠT.
```

CI đóng gói **1 .deb gộp** chứa cả tweak + app (xem step "Combine into single deb" trong `build.yml`).

---

## 2. Cách build (CI — khuyến nghị)

Push lên `master` với đường dẫn thay đổi nằm trong `tweak/**`, `app/**`, hoặc `.github/workflows/build.yml` → workflow chạy tự động. Hoặc vào tab **Actions** trên GitHub → `Build ChangeInfoIos` → **Run workflow**.

Artifacts sinh ra:
- `ChangeInfoIos-combined` — **file .deb chính** để cài lên iPhone (Sileo/Zebra)
- `tweak-only`, `app-only` — file .deb rời (debug)
- `app-build-log` — full `make` log nếu app build fail

---

## 3. Cách build local (macOS + Theos)

```bash
export THEOS=~/theos
export THEOS_PACKAGE_SCHEME=rootless
cd tweak && make package FINALPACKAGE=1 ARCHS=arm64
cd ../app && make package FINALPACKAGE=1 ARCHS=arm64
```

Output: `tweak/packages/*.deb` và `app/packages/*.deb`.

---

## 4. Bump version — ĐỔI ĐỒNG THỜI 4 FILE

Mỗi lần release mới, phải sửa **cả 4** chỗ này cho đồng bộ, nếu không CI sẽ gộp version lệch:

| File | Key |
|------|-----|
| `tweak/Makefile` | `PACKAGE_VERSION = X.Y.Z` |
| `tweak/control`  | `Version: X.Y.Z` |
| `app/Makefile`   | `PACKAGE_VERSION = X.Y.Z` |
| `app/control`    | `Version: X.Y.Z` |
| `app/Resources/Info.plist` | `CFBundleShortVersionString` |

Version hiện tại: **2.3.0**.

---

## 5. Những lỗi đã gặp và ĐỪNG lặp lại

### 5.1 `extern` forward declarations trong Hooks.mm — **KHÔNG ĐƯỢC LÀM**
C standard không cho `static <type> ptr = NULL;` đứng sau `extern <type> ptr;`. Cứ khai báo 1 lần `static MSHookFunction_t orig_foo = NULL;` là đủ. Từng bị lỗi ở commit `641f535`, fix ở `d6c2c00`.

### 5.2 HTTP trong app iOS
App gọi `http://ip-api.com/json` để lấy geo theo proxy. iOS mặc định block HTTP (ATS). **Phải giữ** trong `app/Resources/Info.plist`:
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

### 5.3 Include `<math.h>` ở đầu `app/main.m`
`main.m` dùng `cos/sin/sqrt/M_PI` cho `ci_jitterCoordKm`. Nếu bỏ `#import <math.h>` sẽ fail link trên clang strict mode.

### 5.4 Không tự động stage file trong repo dirty
`git status` đang có `deploy-deb.sh`, `icon.png`, `logo HIOS Faker.jpg`, `tweak/DEBIAN/postinst` ở trạng thái deleted nhưng **không liên quan** đến thay đổi code. Khi commit, chỉ stage các file bạn thực sự sửa — tránh `git add -A`.

### 5.5 Đừng kích hoạt các workflow `.disabled`
Trước đây repo có 8 workflow khác nhau chạy song song gây rối. Chỉ dùng `build.yml`. Nếu muốn debug, sửa `build.yml`, không tạo workflow mới.

### 5.6 Theos SDK version bị pin
`build.yml` pin `SDK_VERSION=16.5`, `SDK_RELEASE=master-146e41f`. Không bump SDK mà không cập nhật `TARGET := iphone:clang:16.5:15.0` trong cả 2 Makefile.

### 5.7 Không đụng `deploy-deb.sh`
File đó đã bị xoá từ commit trước. Không hồi sinh nó.

---

## 6. Tính năng đã cài (v2.3.0)

### App (`app/main.m`)
- **Tên hiển thị:** "HIOS Faker" (title + bundle display name)
- **Footer:** "telegram:Houselis"
- **Home:** nút `Reset Data` giờ chủ động `killall` target apps + `rm -rf` container subdirs (Documents, Library/Caches, Preferences, Cookies, WebKit, Application Support, tmp), HUD tối thiểu 12s, báo "Change thành công". Vẫn bump `wipe_counter_<bid>` làm safety net cho tweak.
- **Fake Settings:**
  - Picker "Chọn Model iPhone" (40 models từ iPhone 5 → 16 Pro Max, kèm native screen)
  - Picker "Chọn iOS Version" (13 mốc từ 12.5.7 → 18.3.2)
  - Nav bar dọn gọn: chỉ còn `Xong` + menu `⋯`
  - Layout cell dùng `safeAreaInsets` → switch không bị notch che
  - **Mặc định bật toàn bộ `fake_*`** (26 layer) ở lần load đầu via `seedDefaultsIfNeeded`
- **Randomize mỗi Reset** (`ci_randomizeIdentities`):
  - Hardware IDs: serial, IDFA, IDFV, UDID, UniqueChipID, IMEI (Luhn-valid), MEID, ICCID, MAC (Wi-Fi/BT/Ethernet), wifiSSID/BSSID
  - GPS strategy:
    - **Có proxy** → fetch `ip-api.com` → pin GPS vào proxy IP với jitter 2km, áp timezone/locale/carrier theo country
    - **Không proxy** → random trong bán kính `vn_radiusKm` (default 999km) từ trung tâm VN (16°N, 107°E), rotate 6 telco VN (Viettel/MobiFone/Vinaphone/Vietnamobile)
  - Location fuzz: `locationAccuracy` 5–25m, `locationSpeed` 0–2 m/s, `locationCourse` 0–360°

### Tweak (`tweak/Tweak.xm`)
- `buildFakeLocation` giờ đọc `locationSpeed/Course/Accuracy` từ config (thay vì hardcode `speed=0`)
- Giữ nguyên micro-jitter 5cm/read để mô phỏng nhiễu GPS thật

---

## 7. Config keys quan trọng

Tất cả lưu trong `/var/mobile/Library/Preferences/com.changeinfoios.plist` (tweak đọc) + `<app-sandbox>/…/config.plist` (app ghi) + Darwin notification `com.changeinfoios/ReloadPrefs` để live reload.

| Key | Dùng cho |
|-----|----------|
| `fake_*` (26 key) | Gate từng layer, mặc định YES |
| `latitude/longitude/altitude` | Tọa độ GPS |
| `locationAccuracy/Speed/Course` | GPS sensor fuzz |
| `locationEnabled` | Phải YES để tweak mới trả fake location |
| `timezoneName`, `locale*`, `carrier*` | Theo country của proxy IP |
| `ip_api_url` | Custom URL (default `http://ip-api.com/json`) |
| `vn_radiusKm` | Bán kính random khi không có proxy (default 999) |
| `__presetModelName`, `__presetIOSName` | Hiển thị giá trị đang chọn trên picker |
| `wipe_counter_<bid>` | Trigger tweak-side wipe ở lần launch kế |

---

## 8. Checklist trước khi push

- [ ] Đã bump version ở **4 file** (§4)?
- [ ] `app/main.m` compile-check: còn `#import <math.h>`?
- [ ] `Info.plist` còn `NSAllowsArbitraryLoads`?
- [ ] Chỉ stage file mình sửa, không `git add -A`?
- [ ] Không tạo workflow mới, chỉ sửa `build.yml`?
- [ ] Hooks.mm không có `extern <type> orig_*`?

Push lên master → vào Actions tab chờ ~2-3 phút → tải artifact `ChangeInfoIos-combined`.
