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

## 4. Bump version — ĐỔI ĐỒNG THỜI 5 FILE

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

## 6. Bug đã fix (2026-04-19)

### Symptom
Khi bấm "Change", thông báo "Change thành công" hiện lên nhưng app đọc `[UIDevice currentDevice].model` vẫn trả `"iPhone"` thay vì model được chọn (VD `"iPhone 15 Pro Max"`). Tất cả ứng dụng test đều không thấy thay đổi thông số.

### Root cause
Trong `app/main.m`, function `ci_randomizeizeIdentities()` (dòng ~502) — được gọi mỗi khi bấm Change — đặt key `deviceModel = @"iPhone"` quá chung chung. Hook `UIDevice.model` trong `Tweak.xm` đọc key này:

```objc
- (NSString *)model {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"deviceModel");
    return val ?: %orig;   // "iPhone" != nil → trả "iPhone"
}
```

Vì `"iPhone"` không phải `nil`, hook trả `"iPhone"` thay vì gọi `%orig` (model thật hoặc model fake đầy đủ).

Ngoài ra, 2 key khác cũng thiếu:
- `systemName` — UIDevice.systemName hook đọc nhưng không set → trả giá trị thật `"iOS"`
- `deviceName` — UIDevice.name hook đọc key `"deviceName"` nhưng code chỉ set `"DeviceName"`, `"DeviceNameMG"`, `"UserAssignedDeviceName"` → nil → trả tên thiết bị thật

### Fix (commit `ee7d565`)
```objc:app/main.m
// TRƯỚC:
[cm setObject:@"iPhone" forKey:@"deviceModel"];  // quá chung → hook trả "iPhone"

// SAU:
[cm setObject:preset[0] forKey:@"deviceModel"];   // "iPhone 15 Pro Max"
[cm setObject:@"iPhone" forKey:@"systemName"];    // thêm: UIDevice.systemName hook
[cm setObject:[NSString stringWithFormat:@"iPhone %@", preset[0]] forKey:@"deviceName"];  // thêm: UIDevice.name hook
```

`preset[0]` là tên đầy đủ từ database (VD `"iPhone 15 Pro Max"`, `"iPhone 16 Pro"`, ...).

### Đã commit
- Commit: `ee7d565` — "fix: set proper deviceModel in ci_randomizeIdentities instead of generic iPhone"
- Branch: `master`
- GitHub Actions: tự trigger build, artifact `ChangeInfoIos-combined`

---

## 7. Tính năng đã cài (v2.3.0)

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

## 8. Config keys quan trọng

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

## 9. Checklist trước khi push

- [ ] Đã bump version ở **4 file** (§4)?
- [ ] `app/main.m` compile-check: còn `#import <math.h>`?
- [ ] `Info.plist` còn `NSAllowsArbitraryLoads`?
- [ ] Chỉ stage file mình sửa, không `git add -A`?
- [ ] Không tạo workflow mới, chỉ sửa `build.yml`?
- [ ] Hooks.mm không có `extern <type> orig_*`?

Push lên master → vào Actions tab chờ ~2-3 phút → tải artifact `ChangeInfoIos-combined`.

---

## 10. 🔴 BUG ĐANG CÓ: "Change thành công nhưng AIDA64 vẫn máy gốc"

### 10.1 Triệu chứng
Bấm **Reset Data** → HUD 12s → alert "Change thành công". Mở **AIDA64** (hoặc bất kỳ target app nào), các field `Model`, `Serial`, `UDID`, `IMEI`, `MAC`, `IDFA`, `IDFV`… vẫn là giá trị **máy thật**. Hook KHÔNG hoạt động dù tweak đã inject.

### 10.2 Nguyên nhân gốc (đọc kỹ trước khi fix)
Config duy nhất mà tweak đọc được là file:
```
/var/mobile/Library/Preferences/com.changeinfoios.plist
```
Hardcode ở [tweak/Tweak.xm:78](tweak/Tweak.xm#L78) (`kConfigPath`) và [app/main.m:36](app/main.m#L36) (`kSharedPrefPath`).

Flow khi bấm Reset Data:
1. `ci_randomizeIdentities()` sinh ID mới → ghi vào `_cfg` in-memory.
2. `[cm save]` ([app/main.m:137](app/main.m#L137)) ghi ra **2 nơi**:
   - `CILocalConfigPath()` = `<sandbox>/Documents/config.plist` → **OK** (app's own sandbox).
   - `kSharedPrefPath` = `/var/mobile/Library/Preferences/com.changeinfoios.plist` → **FAIL SILENT** vì Sandbox profile của app chặn `writeToFile:` Cocoa API (trả NO không throw). App chạy user `mobile` nhưng vẫn bị sandboxed.
3. Post Darwin notification `com.changeinfoios/ReloadPrefs`.
4. Tweak trong AIDA64 nhận notify → `reloadConfigFromDisk()` đọc lại `/var/mobile/Library/Preferences/com.changeinfoios.plist` — **FILE VẪN CŨ / RỖNG** → `spoofConfig = nil`.
5. Mọi hook: `getConfig(...) == nil → return %orig` → **AIDA64 đọc giá trị thật**.

### 10.3 Bằng chứng xác minh qua SSH
Sau khi bấm Reset:
```bash
ls -la /var/mobile/Library/Preferences/com.changeinfoios.plist
plutil -p  /var/mobile/Library/Preferences/com.changeinfoios.plist | head -30
```
File không tồn tại / thiếu keys như `advertisingIdentifier`, `deviceModel`, `fake_uiddevice` → **bug xác nhận**.

Console.app xem log tweak:
```
[ChangeInfoIos] No config file at /var/mobile/Library/Preferences/com.changeinfoios.plist
```
Có sẵn ở [tweak/Tweak.xm:115](tweak/Tweak.xm#L115).

### 10.4 Fix KHÔNG giải quyết (ĐỪNG lặp)
- ❌ Đổi `_cfg[@"fake_*"] = @(YES)` — key đã có sẵn, không liên quan.
- ❌ Gọi `[cm save]` nhiều lần — fail cùng chỗ.
- ❌ `chmod 0644` sau `writeToFile:` — chmod file chưa có = no-op.
- ❌ Tạo workflow mới để debug — lỗi runtime, không phải build.
- ❌ Respring / reboot — không giải quyết write fail.
- ❌ Bump version — không liên quan.
- ❌ Đổi tweak filter — AIDA64 đã có trong list.
- ❌ Prefix `/var/jb/` — `/var/mobile/` KHÔNG bị prefix trong rootless.

### 10.5 Hướng fix đúng

**Hướng A — shell copy fallback (rẻ, thử trước)**
Trong `[CIConfigManager save]`, sau khi `writeToFile:CILocalConfigPath()` xong, thêm `ci_run()` shell copy:
```objc
NSString *cmd = [NSString stringWithFormat:
    @"cp '%@' '%@' 2>/tmp/ci_save.err && chmod 0644 '%@' 2>>/tmp/ci_save.err",
    CILocalConfigPath(), kSharedPrefPath, kSharedPrefPath];
int rc = ci_run([cmd UTF8String]);
NSLog(@"[ChangeInfoIos] shell mirror rc=%d", rc);
```
Shell `/bin/sh` spawn qua `posix_spawn` kế thừa entitlements app. Nếu rootless jailbreak có sandbox hook (ellekit/substitute) cho app, shell có thể bypass được Cocoa filter. Verify bằng `cat /tmp/ci_save.err` + §10.6.

**Hướng B — entitlements.plist (nếu A fail)**
Tạo `app/entitlements.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>platform-application</key><true/>
    <key>com.apple.private.security.no-sandbox</key><true/>
    <key>com.apple.private.security.container-required</key><false/>
</dict></plist>
```
Trong `app/Makefile`:
```make
ChangeInfoIosApp_CODESIGN_FLAGS = -Sentitlements.plist
```
ldid sẽ sign với entitlements đó → app được FS access đầy đủ. Rebuild, verify §10.6.

**Hướng C — LaunchDaemon helper (overkill)**
Daemon root nghe Darwin notif, mirror từ sandbox sang `/var/mobile/Library/Preferences/`.

**Hướng D — đổi arch, tweak tự ghi (lớn)**
App gửi dict qua CFMessagePort / mach_msg → tweak inject trong SpringBoard (root) nhận, ghi file.

### 10.6 Verify fix có work
```bash
# 1. Bấm Reset Data trong app
# 2. Check file đã có:
ls -la /var/mobile/Library/Preferences/com.changeinfoios.plist
# Phải có: size > 2KB, mtime mới nhất

# 3. Check keys fake:
plutil -p /var/mobile/Library/Preferences/com.changeinfoios.plist | \
    grep -E 'fake_uiddevice|advertisingIdentifier|deviceModel'

# 4. killall AIDA64 && mở lại, Serial/UDID phải đổi
killall -9 com.finalwire.aida64 2>/dev/null
```

### 10.7 KHÔNG PHẢI nguyên nhân (Cursor hay đoán sai)
- **Filter plist** — [tweak/ChangeInfoIos.plist:16](tweak/ChangeInfoIos.plist#L16) có `com.finalwire.aida64`. Tweak CHẮC CHẮN inject.
- **Rootless path prefix** — `/var/mobile/` KHÔNG bị prefix `/var/jb/`. Chỉ `/usr`, `/etc`, `/Applications`, `/Library/MobileSubstrate` mới bị prefix trong rootless.
- **ellekit vs substrate** — `Depends: ellekit | mobilesubstrate` handle cả 2 case.
- **Hook không load** — nếu vậy `fake_jbhide` cũng chết (AIDA64 sẽ detect JB). User báo hide JB work → hook load bình thường.
- **MGCopyAnswer chưa hook** — đã hook ở [tweak/Tweak.xm:315](tweak/Tweak.xm#L315). AIDA64 dùng MGCopyAnswer.

### 10.8 Gợi ý cho AI fix tiếp (IMPORTANT)
1. Đọc kỹ §10.2–§10.5 **trước khi** đụng code. Đừng skip.
2. Trước khi fix, SSH vào iPhone chạy §10.3 để confirm bug thật là ở write.
3. Apply **Hướng A** trước (shell copy). Test §10.6.
4. Fail → **Hướng B** (entitlements). Test lại.
5. KHÔNG đụng tweak-side cho đến khi file config đã ghi xuống disk. Bug 100% ở app-side write.
6. Log `stat`/`ls -la` của shared plist trong alert "Change thành công" để user thấy ngay file có ghi được không → khỏi phải SSH.

---

## 11. Fix đã áp dụng

*Điền sau khi Hướng A/B được test thực tế trên iPhone. Ghi rõ hướng nào + output SSH verify.*
