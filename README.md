# ChangeInfoIos

## Tool thay đổi toàn bộ thông số iPhone cho Jailbreak Rootless
**Hỗ trợ:** Dopamine / palera1n | iOS 15.0 - 16.7.x

---

## 📁 Cấu Trúc Dự Án

```
ChangeInfoIos/
├── server.js                 # Web server (Express)
├── package.json              # Dependencies
├── public/                   # Web Dashboard
│   ├── index.html            # Giao diện chính
│   ├── styles.css            # Dark mode CSS
│   └── app.js                # Frontend logic
├── lib/                      # Backend modules
│   ├── ssh-manager.js        # SSH connection manager
│   ├── param-generator.js    # Random parameter generator
│   └── profile-manager.js    # Profile CRUD
├── profiles/                 # Saved profiles (JSON)
└── tweak/                    # iOS Tweak source code
    ├── Tweak.xm              # 13 layers hook code
    ├── Makefile               # Theos build file
    ├── control                # Debian package info
    └── ChangeInfoIos.plist    # Bundle filter
```

---

## 🚀 Hướng Dẫn Sử Dụng

### 1. Chạy Web Dashboard trên PC

```bash
cd ChangeInfoIos
npm install
npm run dev
```

Mở browser: **http://localhost:3456**

### 2. Cài Tweak trên iPhone

#### Cách 1: Build từ source (cần Theos trên macOS/Linux)
```bash
cd tweak
export THEOS=~/theos
export THEOS_PACKAGE_SCHEME=rootless
make package
```

Cài file `.deb` output qua Sileo/Filza.

#### Cách 2: Cài qua Sileo repo (nếu có repo)
- Thêm repo vào Sileo
- Tìm "ChangeInfoIos"
- Cài đặt → Respring

### 3. Kết Nối Từ PC

#### Qua USB (khuyến nghị):
```bash
# Trên PC (cài libimobiledevice trước)
iproxy 2222 22
```

Trong web dashboard:
- Host: `localhost`
- Port: `2222`
- Username: `root`
- Password: `alpine`

#### Qua WiFi:
- Host: IP iPhone (Settings → WiFi → ⓘ)
- Port: `22`

### 4. Sử Dụng

1. **Kết nối** thiết bị
2. Chuyển tab **Random** → chọn model, iOS, nhà mạng → **Tạo Random**
3. Chỉnh sửa thông số trong tab **Device Info** nếu cần
4. **Deploy & Respring** để áp dụng
5. **Lưu Profile** để dùng lại sau
6. **Clear Data** Zalo trước khi reg acc mới

---

## 📊 142 Thông Số Fake (13 Layers)

| Layer | Loại | Số lượng |
|-------|------|----------|
| 1 | UIDevice | 8 |
| 2 | MGCopyAnswer | 45 |
| 3 | IOKit Registry | 7 |
| 4 | CoreTelephony | 6 |
| 5 | Network/WiFi | 4 |
| 6 | Advertising | 3 |
| 7 | sysctl/uname/C | 14 |
| 8 | Keychain | 4 |
| 9 | Screen/Display | 6 |
| 10 | NSProcessInfo | 7 |
| 11 | GPS Location | 3 |
| 12 | Locale/Timezone | 7 |
| 13 | Jailbreak Hide | 19 |
| Bonus | Zalo Specific | 9 |
| **Total** | | **142** |

---

## ⚠️ Lưu Ý

- Tweak cần iPhone đã jailbreak (Dopamine/palera1n rootless)
- Build tweak cần Theos trên macOS/Linux
- SSH password mặc định của jailbreak là `alpine` - nên đổi
- Sau mỗi lần thay đổi thông số, cần **Respring** để áp dụng
- Xóa data Zalo trước khi reg acc mới với profile mới
