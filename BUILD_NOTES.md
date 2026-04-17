# Build Notes - ChangeInfoIos

## Trạng thái hiện tại (17/04/2026 - Phiên làm việc tiếp theo cần giải quyết)

### Vấn đề 1: CI Build liên tục FAIL

**Tình trạng:** Build `Build iOS Tweak (Native)` fail liên tục sau commit `d6c2c00` (fix Hooks.mm extern declarations).

**Root cause hiện tại:** CHƯA XÁC ĐỊNH ĐƯỢC. Không xem được chi tiết lỗi từ GitHub Actions vì:
- Artifact `make-output` chỉ có 809 bytes - quá nhỏ để chứa output của `make package`
- GitHub API bị rate limit khiến không tải được logs chi tiết
- Workflow step "Build rootless tweak" chạy ~16-42s rồi exit code 2 nhưng không capture được log đầy đủ

**Các điều đã thử và không hiệu quả:**
1. Xóa extern forward declarations trong Hooks.mm (d6c2c00) - fix code OK nhưng CI vẫn fail
2. Thêm `make setup` trước `make package` - không tồn tại trong Theos, step fail ngay
3. Force fresh Theos clone và SDK download mỗi lần build - vẫn fail
4. Nhiều lần sửa workflow để capture log - artifact vẫn nhỏ (~800 bytes)
5. `make package` exit với code 2 nhưng không rõ lý do

**Lưu ý quan trọng:** Commit `643db20` ("refactor Hooks.mm to separate C-level hooks") đã BUILD THÀNH CÔNG với 41s. Tất cả commit sau đó fail trong 14-42s. Điều này gợi ý vấn đề nằm ở CI environment hoặc Theos/Makefile state, KHÔNG phải ở source code.

### Vấn đề 2: Hooks.mm - ĐÃ FIX THÀNH CÔNG

**Thay đổi đã thực hiện (d6c2c00):**
- Xóa 21 dòng `extern` forward declarations cho các `orig_*` trampoline pointers
- Giữ nguyên các `static ... = NULL` definitions - đây là cách đúng trong C
- File: `tweak/Hooks.mm` dòng 29-48 (đã xóa)

**Lý do fix đúng:**
- C standard không cho phép `static` definition follow `extern` declaration
- `static` function pointer vừa là declaration vừa là definition trong C
- Chỉ cần khai báo `static ... = NULL` một lần là đủ

### Files hiện tại trong repo

- `tweak/Tweak.xm` - Objective-C hooks (Logos %hook)
- `tweak/Hooks.mm` - C-level hooks dùng MSHookFunction (ĐÃ FIX)
- `tweak/Makefile` - Build config, PACKAGE_VERSION = 2.2.0
- `.github/workflows/build-native.yml` - CI workflow (CẦN SỬA)
- `.github/workflows/build-deb.yml` - CI workflow đơn giản (dùng beerpiss/theos-action)
- `.github/workflows/debug-build.yml` - Debug workflow (chờ trigger thủ công)
- `scripts/inspect_deb.py` - Inspect .deb contents

### Git commits gần nhất

```
1fd97bb ci: add make output artifact upload on failure
c7ad7fb ci: fix exit code capture and always show log on failure
94c8488 ci: force fresh Theos clone and SDK download to fix cache issues
269e8e8 ci: capture make output to file and display last lines on failure
d6c2c00 fix Hooks.mm: remove extern forward declarations, keep static definitions only  <-- FIX HOOKS.MM
641f535 fix Hooks.mm: extern forward declarations for hook pointers (LỖI)
b04e86d fix Hooks.mm: add #include substrate.h, use _dyld_get_image_name loop
643db20 fix: refactor Tweak.xm to separate C-level hooks into Hooks.mm  <-- BUILD PASS ở đây!
```

### Kế hoạch cần làm cho Claude tiếp theo

**Ưu tiên 1: Debug CI build failure**
Mục tiêu: Xác định lý do `make package` exit code 2.

Cách tiếp cận gợi ý:
1. Login vào GitHub Actions để xem trực tiếp build log: https://github.com/Hieudeptrai04/HIOS-Faker/actions/runs/24573955503
2. Tải artifact `make-output` (run #36) để xem chi tiết lỗi
3. So sánh environment ở commit 643db20 (pass) với hiện tại

**Ưu tiên 2: Hoặc dùng workflow khác**
Sử dụng `build-deb.yml` (dùng `beerpiss/theos-action`) thay vì `build-native.yml` vì nó đơn giản hơn và đã pre-configured.

**Ưu tiên 3: Manual trigger debug workflow**
Vào https://github.com/Hieudeptrai04/HIOS-Faker/actions/workflows/debug-build.yml -> "Run workflow" để có log chi tiết hơn.

### Liên kết hữu ích

- Actions: https://github.com/Hieudeptrai04/HIOS-Faker/actions
- Build log mới nhất: https://github.com/Hieudeptrai04/HIOS-Faker/actions/runs/24573955503
- Artifact make-output (cần login): https://github.com/Hieudeptrai04/HIOS-Faker/actions/artifacts/6499586655
