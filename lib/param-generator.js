/**
 * ChangeInfoIos - Parameter Generator
 * Generates valid, realistic device parameters for all 142 spoofed values
 * Optimized for Zalo anti-detection bypass
 */

const crypto = require('crypto');

// ============================================================
// DATABASE: Real device specs for consistency
// ============================================================
const DEVICE_DATABASE = {
  'iPhone7,2':  { marketing: 'iPhone 6',        color: '#7D7E80', enclosureColor: '#A6AAAE', boardId: '0x10', chipId: '0x7000', screenW: 375, screenH: 667, scale: 2, nativeW: 750,  nativeH: 1334, ram: 1073741824, cpuCores: 2, gpu: 'Apple A8 GPU',  cpuType: 16777228, cpuSubtype: 1 },
  'iPhone7,1':  { marketing: 'iPhone 6 Plus',   color: '#7D7E80', enclosureColor: '#A6AAAE', boardId: '0x10', chipId: '0x7000', screenW: 414, screenH: 736, scale: 3, nativeW: 1080, nativeH: 1920, ram: 1073741824, cpuCores: 2, gpu: 'Apple A8 GPU',  cpuType: 16777228, cpuSubtype: 1 },
  'iPhone8,1':  { marketing: 'iPhone 6s',       color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8000', screenW: 375, screenH: 667, scale: 2, nativeW: 750,  nativeH: 1334, ram: 2147483648, cpuCores: 2, gpu: 'Apple A9 GPU',  cpuType: 16777228, cpuSubtype: 2 },
  'iPhone8,2':  { marketing: 'iPhone 6s Plus',  color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8000', screenW: 414, screenH: 736, scale: 3, nativeW: 1080, nativeH: 1920, ram: 2147483648, cpuCores: 2, gpu: 'Apple A9 GPU',  cpuType: 16777228, cpuSubtype: 2 },
  'iPhone8,4':  { marketing: 'iPhone SE (1st)', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8000', screenW: 320, screenH: 568, scale: 2, nativeW: 640,  nativeH: 1136, ram: 2147483648, cpuCores: 2, gpu: 'Apple A9 GPU',  cpuType: 16777228, cpuSubtype: 2 },
  'iPhone9,1':  { marketing: 'iPhone 7',        color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8010', screenW: 375, screenH: 667, scale: 2, nativeW: 750,  nativeH: 1334, ram: 2147483648, cpuCores: 4, gpu: 'Apple A10 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone9,2':  { marketing: 'iPhone 7 Plus',   color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8010', screenW: 414, screenH: 736, scale: 3, nativeW: 1080, nativeH: 1920, ram: 3221225472, cpuCores: 4, gpu: 'Apple A10 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone10,1': { marketing: 'iPhone 8',        color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8015', screenW: 375, screenH: 667, scale: 2, nativeW: 750,  nativeH: 1334, ram: 2147483648, cpuCores: 6, gpu: 'Apple A11 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone10,2': { marketing: 'iPhone 8 Plus',   color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8015', screenW: 414, screenH: 736, scale: 3, nativeW: 1080, nativeH: 1920, ram: 3221225472, cpuCores: 6, gpu: 'Apple A11 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone10,3': { marketing: 'iPhone X', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x10', chipId: '0x8015', screenW: 375, screenH: 812, scale: 3, nativeW: 1125, nativeH: 2436, ram: 3221225472, cpuCores: 6, gpu: 'Apple A11 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone10,6': { marketing: 'iPhone X', color: '#F5F5F0', enclosureColor: '#E1CCAD', boardId: '0x10', chipId: '0x8015', screenW: 375, screenH: 812, scale: 3, nativeW: 1125, nativeH: 2436, ram: 3221225472, cpuCores: 6, gpu: 'Apple A11 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone11,2': { marketing: 'iPhone XS', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8020', screenW: 375, screenH: 812, scale: 3, nativeW: 1125, nativeH: 2436, ram: 4294967296, cpuCores: 6, gpu: 'Apple A12 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone11,8': { marketing: 'iPhone XR', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8020', screenW: 414, screenH: 896, scale: 2, nativeW: 828, nativeH: 1792, ram: 3221225472, cpuCores: 6, gpu: 'Apple A12 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone12,1': { marketing: 'iPhone 11', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8030', screenW: 414, screenH: 896, scale: 2, nativeW: 828, nativeH: 1792, ram: 4294967296, cpuCores: 6, gpu: 'Apple A13 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone12,3': { marketing: 'iPhone 11 Pro', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8030', screenW: 375, screenH: 812, scale: 3, nativeW: 1125, nativeH: 2436, ram: 4294967296, cpuCores: 6, gpu: 'Apple A13 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone12,5': { marketing: 'iPhone 11 Pro Max', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8030', screenW: 414, screenH: 896, scale: 3, nativeW: 1242, nativeH: 2688, ram: 4294967296, cpuCores: 6, gpu: 'Apple A13 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone13,1': { marketing: 'iPhone 12 mini', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8101', screenW: 375, screenH: 812, scale: 3, nativeW: 1080, nativeH: 2340, ram: 4294967296, cpuCores: 6, gpu: 'Apple A14 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone13,2': { marketing: 'iPhone 12', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8101', screenW: 390, screenH: 844, scale: 3, nativeW: 1170, nativeH: 2532, ram: 4294967296, cpuCores: 6, gpu: 'Apple A14 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone13,3': { marketing: 'iPhone 12 Pro', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8101', screenW: 390, screenH: 844, scale: 3, nativeW: 1170, nativeH: 2532, ram: 6442450944, cpuCores: 6, gpu: 'Apple A14 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone13,4': { marketing: 'iPhone 12 Pro Max', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8101', screenW: 428, screenH: 926, scale: 3, nativeW: 1284, nativeH: 2778, ram: 6442450944, cpuCores: 6, gpu: 'Apple A14 GPU', cpuType: 16777228, cpuSubtype: 2 },
  // NOTE: Devices > iPhone 12 Pro Max removed — Zalo's anti-detection only recognizes
  // identifiers from iPhone 5s → iPhone 12 Pro Max. Faking newer models triggers detection.
};

const HW_MODEL_MAP = {
  'iPhone7,2':  'N61AP',  'iPhone7,1':  'N56AP',
  'iPhone8,1':  'N71AP',  'iPhone8,2':  'N66AP',  'iPhone8,4':  'N69AP',
  'iPhone9,1':  'D10AP',  'iPhone9,2':  'D11AP',
  'iPhone10,1': 'D20AP',  'iPhone10,2': 'D21AP',
  'iPhone10,3': 'D22AP', 'iPhone10,6': 'D221AP',
  'iPhone11,2': 'D321AP', 'iPhone11,8': 'N841AP',
  'iPhone12,1': 'N104AP', 'iPhone12,3': 'D421AP', 'iPhone12,5': 'D431AP',
  'iPhone13,1': 'D52gAP', 'iPhone13,2': 'D53gAP', 'iPhone13,3': 'D53pAP', 'iPhone13,4': 'D54pAP',
};

const IOS_VERSIONS = {
  '15.0':  '19A346', '15.1':  '19B74',  '15.2':  '19C56',  '15.3':  '19D50',
  '15.4':  '19E241', '15.5':  '19F77',  '15.6':  '19G71',  '15.7':  '19H12',
  '16.0':  '20A362', '16.1':  '20B82',  '16.2':  '20C65',  '16.3':  '20D47',
  '16.4':  '20E247', '16.5':  '20F66',  '16.6':  '20G75',  '16.6.1':'20G81',
  '16.7':  '20H19',  '16.7.1':'20H30',  '16.7.2':'20H115', '16.7.3':'20H232',
  '16.7.4':'20H240', '16.7.5':'20H307', '16.7.6':'20H320', '16.7.7':'20H330',
  '16.7.8':'20H343', '16.7.9':'20H350', '16.7.10':'20H360',
};

const CARRIERS_VN = [
  { name: 'Viettel', mcc: '452', mnc: '04', iso: 'vn' },
  { name: 'Mobifone', mcc: '452', mnc: '01', iso: 'vn' },
  { name: 'Vinaphone', mcc: '452', mnc: '02', iso: 'vn' },
  { name: 'Vietnamobile', mcc: '452', mnc: '05', iso: 'vn' },
  { name: 'Gmobile', mcc: '452', mnc: '07', iso: 'vn' },
];

const CARRIERS_INTL = [
  { name: 'AT&T', mcc: '310', mnc: '410', iso: 'us' },
  { name: 'T-Mobile', mcc: '310', mnc: '260', iso: 'us' },
  { name: 'Verizon', mcc: '311', mnc: '480', iso: 'us' },
  { name: 'DTAC', mcc: '520', mnc: '01', iso: 'th' },
  { name: 'AIS', mcc: '520', mnc: '03', iso: 'th' },
  { name: 'TrueMove H', mcc: '520', mnc: '04', iso: 'th' },
];

const WIFI_NAMES = [
  'FPT-Home', 'VNPT-WiFi', 'Viettel-WiFi', 'TP-Link', 'Tenda_WiFi',
  'HOME-WIFI', 'Family_Net', 'MyWiFi', 'ASUS_5G', 'Xiaomi_Router',
  'Coffee-WiFi', 'Office_Net', 'Guest-WiFi', 'NetGear', 'D-Link',
];

const DEVICE_NAMES_VN = [
  'iPhone', 'iPhone của Minh', 'iPhone của An', 'iPhone của Hùng',
  'iPhone của Lan', 'iPhone của Tú', 'iPhone của Nam', 'iPhone của Hoa',
  'My iPhone', 'Phone', 'Điện thoại', 'iPhone của em',
];

// GPS Location database — realistic locations across Vietnam for random assignment
const GPS_LOCATIONS_VN = [
  { name: 'HCM - Quận 1', lat: 10.7769, lng: 106.7009, alt: 5 },
  { name: 'HCM - Quận 7', lat: 10.7340, lng: 106.7218, alt: 3 },
  { name: 'HCM - Thủ Đức', lat: 10.8512, lng: 106.7720, alt: 8 },
  { name: 'HCM - Bình Thạnh', lat: 10.8105, lng: 106.7091, alt: 6 },
  { name: 'HCM - Gò Vấp', lat: 10.8381, lng: 106.6546, alt: 12 },
  { name: 'HCM - Tân Bình', lat: 10.8016, lng: 106.6478, alt: 10 },
  { name: 'Hà Nội - Hoàn Kiếm', lat: 21.0285, lng: 105.8542, alt: 8 },
  { name: 'Hà Nội - Cầu Giấy', lat: 21.0378, lng: 105.7885, alt: 10 },
  { name: 'Hà Nội - Thanh Xuân', lat: 20.9935, lng: 105.8148, alt: 7 },
  { name: 'Hà Nội - Long Biên', lat: 21.0500, lng: 105.8884, alt: 6 },
  { name: 'Đà Nẵng - Hải Châu', lat: 16.0544, lng: 108.2022, alt: 3 },
  { name: 'Đà Nẵng - Sơn Trà', lat: 16.0870, lng: 108.2349, alt: 5 },
  { name: 'Cần Thơ - Ninh Kiều', lat: 10.0452, lng: 105.7469, alt: 2 },
  { name: 'Hải Phòng - Hồng Bàng', lat: 20.8449, lng: 106.6881, alt: 4 },
  { name: 'Nha Trang - Trung tâm', lat: 12.2388, lng: 109.1967, alt: 5 },
  { name: 'Đà Lạt - Trung tâm', lat: 11.9404, lng: 108.4583, alt: 1500 },
  { name: 'Huế - Thành phố', lat: 16.4637, lng: 107.5909, alt: 8 },
  { name: 'Vũng Tàu - Bãi Sau', lat: 10.3460, lng: 107.0843, alt: 3 },
  { name: 'Biên Hòa - Đồng Nai', lat: 10.9574, lng: 106.8426, alt: 10 },
  { name: 'Bình Dương - Thủ Dầu Một', lat: 11.0036, lng: 106.6520, alt: 15 },
];

const GPS_LOCATIONS_INTL = [
  { name: 'Bangkok', lat: 13.7563, lng: 100.5018, alt: 3 },
  { name: 'Singapore', lat: 1.3521, lng: 103.8198, alt: 15 },
  { name: 'Seoul', lat: 37.5665, lng: 126.9780, alt: 38 },
  { name: 'Tokyo', lat: 35.6762, lng: 139.6503, alt: 40 },
  { name: 'New York', lat: 40.7128, lng: -74.0060, alt: 10 },
  { name: 'Los Angeles', lat: 34.0522, lng: -118.2437, alt: 71 },
  { name: 'London', lat: 51.5074, lng: -0.1278, alt: 11 },
  { name: 'Taipei', lat: 25.0330, lng: 121.5654, alt: 9 },
];

const SERIAL_PREFIXES = ['C', 'D', 'F', 'G', 'H'];
const SERIAL_FACTORY = ['39', '8Q', 'QJ', 'QH', 'TY', 'VQ', 'W8', 'DX', 'F1', 'GR', 'JC'];

/**
 * Các khóa fake_* trong plist — bật/tắt từng lớp hook (thiếu key = coi như bật).
 * Nhãn tiếng Việt cho người dùng nằm trong tweak/mobile-app-standalone.html (FAKE_LAYER_DEFS).
 */
const DEFAULT_FAKE_LAYERS = {
  fake_uiddevice: true,
  fake_homebutton: true,
  fake_hardware: true,
  fake_ads: true,
  fake_screen: true,
  fake_realscreen: false,
  fake_browser: true,
  fake_webrtc: false,
  fake_datetime: true,
  fake_locale: true,
  fake_network: true,
  fake_wifi: true,
  fake_sysctl: true,
  fake_sysosversion: true,
  fake_location: true,
  fake_sensor: true,
  fake_processinfo: true,
  fake_keychain: true,
  fake_trackingdefaults: true,
  fake_jbhide: true,
  // New deep layers
  fake_metal: true,           // Metal GPU fingerprint spoof
  fake_timing: true,          // Timing anti-fingerprint (mach_absolute_time, CFAbsoluteTime)
  fake_tracking_pasteboard: true, // Pasteboard anti cross-app tracking
};

// ============================================================
// UTILITY FUNCTIONS
// All randomness goes through crypto.* — Math.random (xorshift128+ in V8)
// is fast but not cryptographically strong. For users registering 10K+
// accounts in one server session, Math.random can show subtle patterns
// (modulo bias on small ranges, predictable seed if process-fork timing
// is observable). crypto.randomInt() is CSPRNG-backed (BoringSSL on
// Node 18+) so each call is independent of prior calls.
// ============================================================
function randInt(min, max) {
  // crypto.randomInt is [min, max) — bump max by 1 to match the
  // previous inclusive-max contract used everywhere in this file.
  return crypto.randomInt(min, max + 1);
}

function randHex(length) {
  return crypto.randomBytes(Math.ceil(length / 2)).toString('hex').substring(0, length);
}

function randAlphaNum(length) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
  let result = '';
  for (let i = 0; i < length; i++) result += chars[crypto.randomInt(0, chars.length)];
  return result;
}

function randFrom(arr) {
  return arr[crypto.randomInt(0, arr.length)];
}

// Crypto-strong single-digit picker, used by IMEI/ICCID/phone generators.
function randDigit() {
  return crypto.randomInt(0, 10).toString();
}

function randMAC() {
  const octets = [];
  for (let i = 0; i < 6; i++) octets.push(randHex(2));
  // Set locally administered + unicast bits on first octet
  let first = parseInt(octets[0], 16);
  first = (first & 0xFC) | 0x02; // locally administered, unicast
  octets[0] = first.toString(16).padStart(2, '0');
  return octets.join(':');
}

function randAppleMAC() {
  // Apple OUI prefixes
  const appleOUI = ['00:CD:FE', 'A4:83:E7', '3C:06:30', '14:7D:DA', '48:A9:1C',
    'F0:D1:A9', '8C:85:90', 'AC:BC:32', '70:DE:E2', '88:66:A5',
    '78:7E:61', 'D0:D2:B0', 'F4:5C:89', 'A8:51:AB', '64:B0:A6'];
  const oui = randFrom(appleOUI);
  return `${oui}:${randHex(2)}:${randHex(2)}:${randHex(2)}`;
}

// Generate valid IMEI with Luhn checksum
function generateIMEI() {
  const tac = ['35', '86', '01']; // Common TAC starts
  let imei = randFrom(tac);
  for (let i = 0; i < 12; i++) imei += randDigit();
  // Calculate Luhn check digit
  let sum = 0;
  for (let i = 0; i < 14; i++) {
    let digit = parseInt(imei[i]);
    if (i % 2 === 1) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
  }
  const check = (10 - (sum % 10)) % 10;
  return imei + check.toString();
}

// Generate valid Apple Serial Number (12 chars)
function generateSerial() {
  const prefix = randFrom(SERIAL_PREFIXES);
  const factory = randFrom(SERIAL_FACTORY);
  const year = String.fromCharCode(65 + randInt(0, 25)); // A-Z
  const week = randAlphaNum(1);
  const unique = randAlphaNum(3);
  const model = randAlphaNum(4);
  return `${prefix}${factory}${year}${week}${unique}${model}`;
}

// Generate UDID (40 hex chars for most devices)
function generateUDID() {
  return randHex(40);
}

// Generate ECID (16 hex chars)
function generateECID() {
  return '0x' + randHex(16).toUpperCase();
}

// Generate ICCID (19-20 digits)
function generateICCID() {
  let iccid = '89' + randFrom(['84', '01', '44', '66']); // MII + country
  for (let i = 0; i < 14; i++) iccid += randDigit();
  // Luhn check
  let sum = 0;
  for (let i = 0; i < 18; i++) {
    let d = parseInt(iccid[i]);
    if (i % 2 === 0) { d *= 2; if (d > 9) d -= 9; }
    sum += d;
  }
  iccid += ((10 - (sum % 10)) % 10).toString();
  return iccid;
}

// Generate Vietnamese phone number  
function generatePhoneVN() {
  const prefixes = ['032', '033', '034', '035', '036', '037', '038', '039', // Viettel
    '070', '076', '077', '078', '079', // Mobifone
    '081', '082', '083', '084', '085', // Vinaphone
    '056', '058', // Vietnamobile
  ];
  let phone = randFrom(prefixes);
  for (let i = 0; i < 7; i++) phone += randDigit();
  return '+84' + phone.substring(1);
}

// Generate WiFi BSSID
function generateBSSID() {
  return randMAC().toUpperCase();
}

// Generate local IP
function generateLocalIP() {
  return `192.168.${randInt(0, 10)}.${randInt(2, 254)}`;
}

// Generate UUID
function generateUUID() {
  return crypto.randomUUID();
}

// ============================================================
// MAIN GENERATOR
// ============================================================
// Mirror of DEVICE_RELEASE_ORDER / IOS_VERSION_ORDER from ios/js/config-data.js
// — used when the caller passes a range index pair (deviceMinIdx/deviceMaxIdx,
// iosMinIdx/iosMaxIdx) instead of a single value.
const DEVICE_RELEASE_ORDER = Object.keys(DEVICE_DATABASE);
const IOS_VERSION_ORDER = Object.keys(IOS_VERSIONS);

function generateFullProfile(options = {}) {
  const keys = Object.keys(DEVICE_DATABASE);

  // Device pick: explicit productType wins; otherwise honor the range slider
  // bounds; otherwise random over the entire DB.
  let productType;
  if (options.productType && DEVICE_DATABASE[options.productType]) {
    productType = options.productType;
  } else if (typeof options.deviceMinIdx === 'number' && typeof options.deviceMaxIdx === 'number'
      && DEVICE_RELEASE_ORDER.length > 0) {
    let lo = Math.max(0, options.deviceMinIdx | 0);
    let hi = Math.min(DEVICE_RELEASE_ORDER.length - 1, options.deviceMaxIdx | 0);
    if (lo > hi) [lo, hi] = [hi, lo];
    productType = randFrom(DEVICE_RELEASE_ORDER.slice(lo, hi + 1));
  } else {
    productType = randFrom(keys);
  }
  if (!DEVICE_DATABASE[productType]) productType = keys[0];
  const device = DEVICE_DATABASE[productType];
  const hwModel = HW_MODEL_MAP[productType] || 'D17AP';

  // iOS pick: same logic against IOS_VERSION_ORDER.
  const iosVersions = Object.keys(IOS_VERSIONS);
  let iosVersion;
  if (options.iosVersion && IOS_VERSIONS[options.iosVersion]) {
    iosVersion = options.iosVersion;
  } else if (typeof options.iosMinIdx === 'number' && typeof options.iosMaxIdx === 'number'
      && IOS_VERSION_ORDER.length > 0) {
    let ilo = Math.max(0, options.iosMinIdx | 0);
    let ihi = Math.min(IOS_VERSION_ORDER.length - 1, options.iosMaxIdx | 0);
    if (ilo > ihi) [ilo, ihi] = [ihi, ilo];
    iosVersion = randFrom(IOS_VERSION_ORDER.slice(ilo, ihi + 1));
  } else {
    iosVersion = randFrom(iosVersions);
  }
  if (!IOS_VERSIONS[iosVersion]) iosVersion = iosVersions[0];
  const buildVersion = IOS_VERSIONS[iosVersion] || '20G75';

  const carrier = options.carrierRegion === 'international'
    ? randFrom(CARRIERS_INTL)
    : randFrom(CARRIERS_VN);

  const wifiMAC = randAppleMAC();
  const btMAC = randAppleMAC();
  const serial = generateSerial();
  const udid = generateUDID();
  const ecid = generateECID();
  const imei = generateIMEI();
  const imei2 = generateIMEI();
  const iccid = generateICCID();
  const iccid2 = generateICCID();
  const idfv = generateUUID();
  const idfa = generateUUID();

  const diskTotal = randFrom([64, 128, 256, 512]) * 1073741824; // GB to bytes
  const diskUsed = Math.floor(diskTotal * (randInt(15, 75) / 100));
  const diskFree = diskTotal - diskUsed;

  const profile = {
    // === Meta ===
    _version: '1.0',
    _generated: new Date().toISOString(),
    _productType: productType,

    // === Layer 1: UIDevice ===
    deviceName: options.deviceName || randFrom(DEVICE_NAMES_VN),
    deviceModel: 'iPhone',
    localizedModel: 'iPhone',
    systemName: 'iPhone OS',
    systemVersion: iosVersion,
    identifierForVendor: idfv,
    batteryLevel: (randInt(20, 95) / 100).toFixed(2),
    batteryState: randFrom([1, 2, 3]), // 1=unplugged, 2=charging, 3=full

    // === Layer 2: MGCopyAnswer ===
    UniqueDeviceID: udid,
    SerialNumber: serial,
    UniqueChipID: ecid,
    InternationalMobileEquipmentIdentity: imei,
    InternationalMobileEquipmentIdentity2: imei2,
    MobileEquipmentIdentifier: imei.substring(0, 14),
    IntegratedCircuitCardIdentity: iccid,
    IntegratedCircuitCardIdentity2: iccid2,
    PhoneNumber: options.phoneNumber || generatePhoneVN(),
    ProductType: productType,
    HardwareModel: hwModel,
    HWModelStr: hwModel,
    ModelNumber: `M${randAlphaNum(4)}${carrier.iso.toUpperCase()}/A`,
    RegionCode: carrier.iso.toUpperCase(),
    RegionInfo: `${carrier.iso.toUpperCase()}/A`,
    WiFiAddress: wifiMAC,
    BluetoothAddress: btMAC,
    EthernetAddress: randAppleMAC(),
    BoardId: device.boardId,
    ChipID: device.chipId,
    FirmwareVersion: `iBoot-${randInt(7000, 8999)}.${randInt(1, 99)}.${randInt(1, 9)}`,
    BasebandVersion: `${randInt(1, 9)}.${randInt(10, 99)}.${randInt(0, 9)}`,
    BasebandSerialNumber: randHex(24),
    BasebandChipId: `0x${randInt(10, 99)}0${randInt(1, 9)}000`,
    BasebandCertId: `0x${randHex(16)}`,
    BuildVersion: buildVersion,
    ProductVersion: iosVersion,
    DeviceColor: device.color,
    DeviceEnclosureColor: device.enclosureColor,
    DeviceColorMap: 'default',
    DiskUsage: diskUsed,
    TotalDiskCapacity: diskTotal,
    TotalSystemAvailable: diskFree,
    BatteryCurrentCapacity: randInt(20, 95),
    BatteryIsCharging: randFrom([true, false]),
    BatterySerialNumber: randAlphaNum(12),
    BootNonce: randHex(32),
    DeviceNameMG: options.deviceName || randFrom(DEVICE_NAMES_VN),
    UserAssignedDeviceName: options.deviceName || randFrom(DEVICE_NAMES_VN),
    MarketingName: device.marketing,
    AirplaneMode: false,
    MobileSubscriberCountryCode: carrier.mcc,
    MobileSubscriberNetworkCode: carrier.mnc,
    SIMTrayStatus: 'kCTSIMSupportSIMStatusReady',

    // === Layer 3: IOKit ===
    IOPlatformSerialNumber: serial,
    IOPlatformUUID: generateUUID().toUpperCase(),
    IOBoardId: device.boardId,
    IOProductName: productType,
    IOModel: hwModel,
    IODeviceTreeSerial: serial,
    IODeviceTreeMLBSerial: randAlphaNum(17),

    // === Layer 4: CoreTelephony ===
    carrierName: carrier.name,
    carrierMCC: carrier.mcc,
    carrierMNC: carrier.mnc,
    carrierISO: carrier.iso,
    carrierAllowsVOIP: true,
    carrierRadioAccess: randFrom(['CTRadioAccessTechnologyLTE', 'CTRadioAccessTechnologyNR']),

    // === Layer 5: Network ===
    wifiSSID: options.wifiSSID || randFrom(WIFI_NAMES),
    wifiBSSID: generateBSSID(),
    wifiMAC: wifiMAC,
    localIP: generateLocalIP(),

    // === Layer 6: Advertising ===
    advertisingIdentifier: idfa,
    isAdvertisingTrackingEnabled: false,
    trackingAuthorizationStatus: 2, // ATTrackingManager.denied

    // === Layer 7: Low-level C ===
    hw_machine: productType,
    hw_model: hwModel,
    hw_memsize: device.ram,
    hw_physicalcpu: device.cpuCores,
    hw_logicalcpu_max: device.cpuCores,
    hw_cpufrequency: randInt(2300000000, 3400000000),
    hw_cputype: device.cpuType,
    hw_cpusubtype: device.cpuSubtype,
    kern_hostname: (options.deviceName || 'iPhone').replace(/[^a-zA-Z0-9-]/g, '-'),
    kern_osversion: buildVersion,
    kern_osrelease: `22.${randInt(1, 6)}.${randInt(0, 9)}`,
    kern_boottime: Math.floor(Date.now() / 1000) - randInt(3600, 604800),
    uname_sysname: 'Darwin',
    uname_nodename: (options.deviceName || 'iPhone').replace(/[^a-zA-Z0-9-]/g, '-'),
    uname_release: `22.${randInt(1, 6)}.${randInt(0, 9)}`,
    uname_version: `Darwin Kernel Version 22.${randInt(1, 6)}.${randInt(0, 9)}: ${randFrom(['Mon', 'Tue', 'Wed', 'Thu', 'Fri'])} ${randFrom(['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'])} ${randInt(1, 28)} ${randInt(10, 23)}:${randInt(10, 59)}:${randInt(10, 59)} PDT 2023; root:xnu-8796.${randInt(100, 200)}.${randInt(1, 9)}~${randInt(1, 9)}/RELEASE_ARM64_T${randInt(8000, 9000)}`,
    uname_machine: productType,

    // === Layer 8: Keychain ===
    keychainReset: true,
    keychainFakeDeviceToken: generateUUID(),

    // === Layer 9: Screen ===
    screenWidth: device.screenW,
    screenHeight: device.screenH,
    screenScale: device.scale,
    nativeScreenWidth: device.nativeW,
    nativeScreenHeight: device.nativeH,
    nativeScale: device.scale,
    screenBrightness: (randInt(30, 80) / 100).toFixed(2),

    // === Layer 10: NSProcessInfo ===
    processHostName: (options.deviceName || 'iPhone').replace(/[^a-zA-Z0-9-]/g, '-'),
    processorCount: device.cpuCores,
    physicalMemory: device.ram,
    systemUptime: randInt(3600, 604800),
    thermalState: 0, // nominal

    // === Layer 11: Location (GPS Fake - deep) ===
    locationEnabled: true, // Always enabled by default now
    ...(() => {
      if (options.latitude && options.longitude) {
        return { latitude: options.latitude, longitude: options.longitude, altitude: options.altitude || randInt(1, 50) };
      }
      const loc = options.carrierRegion === 'international'
        ? randFrom(GPS_LOCATIONS_INTL)
        : randFrom(GPS_LOCATIONS_VN);
      // GPS jitter ~±0.005° (~550m at equator) — use crypto for unpredictability.
      const jitter = () => (crypto.randomInt(0, 1_000_001) / 1_000_000 - 0.5) * 0.01;
      return {
        latitude: loc.lat + jitter(),
        longitude: loc.lng + jitter(),
        altitude: loc.alt + randInt(-2, 5),
        _locationName: loc.name,
      };
    })(),
    locationAccuracy: randInt(5, 65),

    // === Layer 12: Locale/Timezone ===
    localeIdentifier: options.locale || 'vi_VN',
    localeCountryCode: options.localeCountry || 'VN',
    localeLanguageCode: options.localeLang || 'vi',
    localeCurrencyCode: options.localeCurrency || 'VND',
    timezoneName: options.timezone || 'Asia/Ho_Chi_Minh',
    timezoneAbbreviation: options.timezoneAbbr || 'ICT',
    timezoneSecondsFromGMT: options.timezoneOffset || 25200,

    // === Layer 13: Jailbreak Hide ===
    hideJailbreak: true,
    hiddenPaths: [
      '/var/jb', '/var/jb/usr/lib', '/var/jb/usr/bin',
      '/Applications/Cydia.app', '/Applications/Sileo.app',
      '/usr/sbin/sshd', '/usr/bin/ssh',
      '/usr/lib/TweakInject', '/Library/MobileSubstrate',
      '/var/mobile/Library/Caches/com.saurik.Cydia',
      '/.installed_dopamine', '/.installed_palera1n',
      '/var/binpack', '/var/LIB', '/var/ulb',
      '/private/preboot/*/procursus',
    ],
    hiddenURLSchemes: ['cydia://', 'sileo://', 'zbra://', 'filza://'],
    hiddenDylibs: [
      'SubstrateLoader', 'SubstrateInserter', 'SubstrateBootstrap',
      'TweakInject', 'CydiaSubstrate', 'substitute',
      'ElleKit', 'libhooker', 'pspawn_payload',
    ],
    blockEnvVars: ['DYLD_INSERT_LIBRARIES', 'MobileSubstratePath', '_MSSafeMode'],

    // === BONUS: Zalo Specific ===
    zalo_clearKeychain: true,
    zalo_fakeWebViewUA: `Mozilla/5.0 (iPhone; CPU iPhone OS ${iosVersion.replace(/\./g, '_')} like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148`,
    zalo_canvasNoiseSeed: randInt(1, 999999),
    zalo_metalGPU: device.gpu,
    zalo_openGLRenderer: `Apple ${device.gpu}`,
    zalo_timingOffset: randInt(-500000, 500000),

    // 32-byte APNS device-token hex. Tweak's UIApplicationDelegate swizzle
    // passes this to the host app's didRegisterForRemoteNotifications: in
    // place of the real APNS token. Without this, two accounts registered on
    // the same physical device share the real Apple-assigned token (which
    // doesn't rotate across Reset Data) → server-side correlation. Must be
    // regenerated every full profile re-roll, same as the other IDs above.
    apnsTokenSpoof: randHex(64),

    // AVCaptureDevice.uniqueID — per-camera hardware string read by anti-
    // fraud SDKs during eKYC selfie/ID capture. Real values look like
    // "0001:0001" for back camera. Derive deterministically from UDID so
    // it stays internally consistent within a profile.
    AVCaptureDeviceUniqueID: udid.substring(0, 8) + ':' + udid.substring(8, 16),

    // === WebGL / Fake Web ===
    web_fakeEnabled: true,
    web_glVendor: 'Apple Inc.',
    web_glRenderer: `Apple ${device.gpu}`,
    web_canvasNoise: `zls_${randInt(1000, 99999)}`,

    // === Deep Reset Flags (used by server-side wipe) ===
    clearPasteboard: true,          // Block pasteboard reads for cross-app tracking
    resetAPNS: true,                // Flag to reset push notification token
    resetAdvertisingID: true,       // Flag to reset system IDFA folder
    resetDeviceCheck: true,         // Flag to reset App Attest / DeviceCheck data
    resetLaunchServices: true,      // Flag to clear launch services cache
  };

  Object.assign(profile, DEFAULT_FAKE_LAYERS, options.layers || {});

  return profile;
}

function updateSingleParam(profile, key, value) {
  profile[key] = value;
  profile._generated = new Date().toISOString();
  return profile;
}

function getDeviceList() {
  return Object.entries(DEVICE_DATABASE).map(([type, info]) => ({
    productType: type,
    marketing: info.marketing,
    hwModel: HW_MODEL_MAP[type],
  }));
}

function getIOSVersionList() {
  return Object.entries(IOS_VERSIONS).map(([ver, build]) => ({
    version: ver,
    buildVersion: build,
  }));
}

function getCarrierList() {
  return { vietnam: CARRIERS_VN, international: CARRIERS_INTL };
}

// Convert profile to iOS plist format (XML)
function profileToPlist(profile) {
  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
  xml += '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n';
  xml += '<plist version="1.0">\n<dict>\n';

  for (const [key, value] of Object.entries(profile)) {
    xml += `\t<key>${escapeXml(key)}</key>\n`;
    if (typeof value === 'string') {
      xml += `\t<string>${escapeXml(value)}</string>\n`;
    } else if (typeof value === 'number') {
      if (Number.isInteger(value)) {
        xml += `\t<integer>${value}</integer>\n`;
      } else {
        xml += `\t<real>${value}</real>\n`;
      }
    } else if (typeof value === 'boolean') {
      xml += `\t<${value}/>\n`;
    } else if (Array.isArray(value)) {
      xml += '\t<array>\n';
      value.forEach(item => {
        xml += `\t\t<string>${escapeXml(String(item))}</string>\n`;
      });
      xml += '\t</array>\n';
    }
  }

  xml += '</dict>\n</plist>\n';
  return xml;
}

function escapeXml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

module.exports = {
  DEFAULT_FAKE_LAYERS,
  generateFullProfile,
  updateSingleParam,
  getDeviceList,
  getIOSVersionList,
  getCarrierList,
  profileToPlist,
  generateIMEI,
  generateSerial,
  generateUDID,
  generateECID,
  generateICCID,
  generatePhoneVN,
  generateUUID,
  randAppleMAC,
  DEVICE_DATABASE,
  HW_MODEL_MAP,
  IOS_VERSIONS,
  GPS_LOCATIONS_VN,
  GPS_LOCATIONS_INTL,
};
