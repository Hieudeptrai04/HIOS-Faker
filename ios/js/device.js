// ============================================================
// DEVICE - Profile generation, device data, info card
// ============================================================

// rand helpers
function randInt(min, max) { return Math.floor(Math.random() * (max - min + 1)) + min; }
function randHex(len) { var s = ''; for (var i = 0; i < len; i++) s += '0123456789abcdef'[randInt(0, 15)]; return s; }
function randAlphaNum(len) { var c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'; var s = ''; for (var i = 0; i < len; i++) s += c[randInt(0, c.length - 1)]; return s; }
function randFrom(arr) { return arr[randInt(0, arr.length - 1)]; }

function generateUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}
function generateSerial() { return randAlphaNum(12); }
function generateUDID() { return randHex(40).toUpperCase(); }
function generateECID() { return randHex(16); }
function generateIMEI() { var d = [8,6,8,8,8,8,8]; var s = d.join(''); var sum = 0; for (var i = 0; i < s.length; i++) { var n = parseInt(s[i], 10); if (i % 2 === 0) { n *= 2; if (n > 9) n -= 9; } sum += n; } var check = (10 - (sum % 10)) % 10; return s + check; }
function generateICCID() { var s = '89' + randInt(10, 99) + randInt(100, 999) + randHex(16); var sum = 0; for (var i = 0; i < s.length; i++) { var n = parseInt(s[i], 10); if (i % 2 === 0) { n *= 2; if (n > 9) n -= 9; } sum += n; } var check = (10 - (sum % 10)) % 10; return s + check; }
function generateBSSID() { return randFrom(['00','08','0c','14','1c','20','24','28','2c','30','34','38','3c','40','44','48','4c']) + ':' + randHex(2) + ':' + randHex(2) + ':' + randHex(2) + ':' + randHex(2) + ':' + randHex(2); }
function randAppleMAC() { return '3c:07:54:' + randHex(2) + ':' + randHex(2) + ':' + randHex(2); }
function generateLocalIP() { return '192.168.' + randInt(1, 254) + '.' + randInt(1, 254); }

var DEVICE_NAMES_VN = ['iPhone của tôi','iPhone Minh','iPhone Hoàng','iPhone Lan','iPhone Tuấn','iPhone Pro Max','iPhone 14 Pro','iPhone 13','iPhone 15','iPhone 12 mini'];

var DEFAULT_FAKE_LAYERS = {
  fake_uiddevice: true, fake_homebutton: true, fake_hardware: true, fake_ads: true,
  fake_screen: true, fake_realscreen: false, fake_browser: true, fake_datetime: true,
  fake_locale: true, fake_network: true, fake_wifi: true,
};

function getDeviceList() {
  var entries = Object.entries(DEVICE_DATABASE), result = [];
  for (var i = 0; i < entries.length; i++) result.push({ productType: entries[i][0], marketing: entries[i][1].marketing, hwModel: HW_MODEL_MAP[entries[i][0]] });
  return result;
}
function getIOSVersionList() {
  var entries = Object.entries(IOS_VERSIONS), result = [];
  for (var i = 0; i < entries.length; i++) result.push({ version: entries[i][0], buildVersion: entries[i][1] });
  return result;
}
function getCarrierList() { return { vietnam: CARRIERS_VN, international: CARRIERS_INTL }; }

function generateFullProfile(options) {
  options = options || {};
  // Device pick: prefer explicit productType, else pick from ordered range
  // [deviceMinIdx, deviceMaxIdx] into DEVICE_RELEASE_ORDER. Falls back to the
  // entire DB when range is unset (first run / no slider interaction yet).
  var pool;
  if (options.productType && DEVICE_DATABASE[options.productType]) {
    pool = [options.productType];
  } else if (typeof options.deviceMinIdx === 'number' && typeof options.deviceMaxIdx === 'number'
      && Array.isArray(DEVICE_RELEASE_ORDER) && DEVICE_RELEASE_ORDER.length > 0) {
    var lo = Math.max(0, options.deviceMinIdx | 0);
    var hi = Math.min(DEVICE_RELEASE_ORDER.length - 1, options.deviceMaxIdx | 0);
    if (lo > hi) { var t = lo; lo = hi; hi = t; }
    pool = DEVICE_RELEASE_ORDER.slice(lo, hi + 1);
  } else {
    pool = Object.keys(DEVICE_DATABASE);
  }
  var productType = randFrom(pool);
  if (!DEVICE_DATABASE[productType]) productType = Object.keys(DEVICE_DATABASE)[0];
  var device = DEVICE_DATABASE[productType];
  var hwModel = HW_MODEL_MAP[productType] || 'D17AP';

  // iOS pick: same range logic against IOS_VERSION_ORDER.
  var iosPool;
  if (options.iosVersion && IOS_VERSIONS[options.iosVersion]) {
    iosPool = [options.iosVersion];
  } else if (typeof options.iosMinIdx === 'number' && typeof options.iosMaxIdx === 'number'
      && Array.isArray(IOS_VERSION_ORDER) && IOS_VERSION_ORDER.length > 0) {
    var ilo = Math.max(0, options.iosMinIdx | 0);
    var ihi = Math.min(IOS_VERSION_ORDER.length - 1, options.iosMaxIdx | 0);
    if (ilo > ihi) { var tt = ilo; ilo = ihi; ihi = tt; }
    iosPool = IOS_VERSION_ORDER.slice(ilo, ihi + 1);
  } else {
    iosPool = Object.keys(IOS_VERSIONS);
  }
  var iosVersion = randFrom(iosPool);
  if (!IOS_VERSIONS[iosVersion]) iosVersion = Object.keys(IOS_VERSIONS)[0];
  var buildVersion = IOS_VERSIONS[iosVersion] || '20G75';
  var carrier = options.carrierRegion === 'international' ? randFrom(CARRIERS_INTL) : randFrom(CARRIERS_VN);
  var wifiMAC = randAppleMAC();
  var btMAC = randAppleMAC();
  var serial = generateSerial();
  var udid = generateUDID();
  var ecid = generateECID();
  var imei = generateIMEI();
  var idfv = generateUUID();
  var idfa = generateUUID();
  var diskTotal = randFrom([64, 128, 256, 512]) * 1073741824;
  var diskFree = Math.floor(diskTotal * (randInt(15, 75) / 100));
  var diskUsed = diskTotal - diskFree;

  var profile = {
    _version: '1.0', _generated: new Date().toISOString(), _productType: productType,
    deviceName: options.deviceName || randFrom(DEVICE_NAMES_VN),
    deviceModel: 'iPhone', localizedModel: 'iPhone', systemName: 'iPhone OS',
    systemVersion: iosVersion, identifierForVendor: idfv,
    batteryLevel: (randInt(20, 95) / 100).toFixed(2), batteryState: randFrom([1, 2, 3]),
    UniqueDeviceID: udid, SerialNumber: serial, UniqueChipID: ecid,
    InternationalMobileEquipmentIdentity: imei, InternationalMobileEquipmentIdentity2: generateIMEI(),
    MobileEquipmentIdentifier: imei.substring(0, 14),
    IntegratedCircuitCardIdentity: generateICCID(), IntegratedCircuitCardIdentity2: generateICCID(),
    PhoneNumber: options.phoneNumber || ('0' + randInt(90, 99) + randInt(1000000, 9999999)),
    ProductType: productType, HardwareModel: hwModel, HWModelStr: hwModel,
    ModelNumber: 'M' + randAlphaNum(4) + carrier.iso.toUpperCase() + '/A',
    RegionCode: carrier.iso.toUpperCase(), RegionInfo: carrier.iso.toUpperCase() + '/A',
    WiFiAddress: wifiMAC, BluetoothAddress: btMAC, EthernetAddress: randAppleMAC(),
    BoardId: device.boardId, ChipID: device.chipId,
    FirmwareVersion: 'iBoot-' + randInt(7000, 8999) + '.' + randInt(1, 99) + '.' + randInt(1, 9),
    BasebandVersion: randInt(1, 9) + '.' + randInt(10, 99) + '.' + randInt(0, 9),
    BasebandSerialNumber: randHex(24),
    BasebandChipId: '0x' + randInt(10, 99) + '0' + randInt(1, 9) + '000',
    BasebandCertId: '0x' + randHex(16),
    BuildVersion: buildVersion, ProductVersion: iosVersion,
    DeviceColor: device.color, DeviceEnclosureColor: device.enclosureColor, DeviceColorMap: 'default',
    DiskUsage: diskUsed, TotalDiskCapacity: diskTotal, TotalSystemAvailable: diskFree,
    BatteryCurrentCapacity: randInt(20, 95), BatteryIsCharging: randFrom([true, false]),
    BatterySerialNumber: randAlphaNum(12), BootNonce: randHex(32),
    DeviceNameMG: options.deviceName || randFrom(DEVICE_NAMES_VN),
    UserAssignedDeviceName: options.deviceName || randFrom(DEVICE_NAMES_VN),
    MarketingName: device.marketing, AirplaneMode: false,
    MobileSubscriberCountryCode: carrier.mcc, MobileSubscriberNetworkCode: carrier.mnc,
    SIMTrayStatus: 'kCTSIMSupportSIMStatusReady',
    IOPlatformSerialNumber: serial, IOPlatformUUID: generateUUID().toUpperCase(),
    IOBoardId: device.boardId, IOProductName: productType, IOModel: hwModel,
    IODeviceTreeSerial: serial, IODeviceTreeMLBSerial: randAlphaNum(17),
    carrierName: carrier.name, carrierMCC: carrier.mcc, carrierMNC: carrier.mnc,
    carrierISO: carrier.iso, carrierAllowsVOIP: true,
    carrierRadioAccess: randFrom(['CTRadioAccessTechnologyLTE', 'CTRadioAccessTechnologyNR']),
    wifiSSID: options.wifiSSID || randFrom(WIFI_NAMES), wifiBSSID: generateBSSID(),
    wifiMAC: wifiMAC, localIP: generateLocalIP(),
    advertisingIdentifier: idfa, isAdvertisingTrackingEnabled: false,
    trackingAuthorizationStatus: 2,
    hw_machine: productType, hw_model: hwModel, hw_memsize: device.ram,
    hw_physicalcpu: device.cpuCores, hw_logicalcpu_max: device.cpuCores,
    hw_cpufrequency: randInt(2300000000, 3400000000),
    hw_cputype: device.cpuType, hw_cpusubtype: device.cpuSubtype,
    kern_hostname: (options.deviceName || 'iPhone').replace(/[^a-zA-Z0-9-]/g, '-'),
    kern_osversion: buildVersion, kern_osrelease: '22.' + randInt(1, 6) + '.' + randInt(0, 9),
    kern_boottime: Math.floor(Date.now() / 1000) - randInt(3600, 604800),
    uname_sysname: 'Darwin',
    uname_nodename: (options.deviceName || 'iPhone').replace(/[^a-zA-Z0-9-]/g, '-'),
    uname_release: '22.' + randInt(1, 6) + '.' + randInt(0, 9),
    uname_version: 'Darwin Kernel Version 22.' + randInt(1, 6) + '.' + randInt(0, 9) + ': ' + randFrom(['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) + ' ' + randFrom(['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun']) + ' ' + randInt(1, 28) + ' ' + randInt(10, 23) + ':' + randInt(10, 59) + ':' + randInt(10, 59) + ' PDT 2023; root:xnu-8796.' + randInt(100, 200) + '.' + randInt(1, 9) + '~' + randInt(1, 9) + '/RELEASE_ARM64_T' + randInt(8000, 9000),
    uname_machine: productType,
    keychainReset: true, keychainFakeDeviceToken: generateUUID(),
    screenWidth: device.screenW, screenHeight: device.screenH, screenScale: device.scale,
    nativeScreenWidth: device.nativeW, nativeScreenHeight: device.nativeH, nativeScale: device.scale,
    screenBrightness: (randInt(30, 80) / 100).toFixed(2),
    processHostName: (options.deviceName || 'iPhone').replace(/[^a-zA-Z0-9-]/g, '-'),
    processorCount: device.cpuCores, physicalMemory: device.ram,
    systemUptime: randInt(3600, 604800), thermalState: 0,
    locationEnabled: options.locationEnabled || false,
    latitude: options.latitude || (10.7769 + (Math.random() - 0.5) * 0.1),
    longitude: options.longitude || (106.7009 + (Math.random() - 0.5) * 0.1),
    altitude: randInt(1, 50), locationAccuracy: randInt(5, 100),
    localeIdentifier: options.locale || 'vi_VN', localeCountryCode: options.localeCountry || 'VN',
    localeLanguageCode: options.localeLang || 'vi', localeCurrencyCode: options.localeCurrency || 'VND',
    timezoneName: options.timezone || 'Asia/Ho_Chi_Minh',
    timezoneAbbreviation: options.timezoneAbbr || 'ICT', timezoneSecondsFromGMT: options.timezoneOffset || 25200,
    hideJailbreak: true,
    hiddenPaths: ['/var/jb', '/var/jb/usr/lib', '/var/jb/usr/bin', '/Applications/Cydia.app', '/Applications/Sileo.app', '/usr/sbin/sshd', '/usr/bin/ssh', '/usr/lib/TweakInject', '/Library/MobileSubstrate', '/var/mobile/Library/Caches/com.saurik.Cydia', '/.installed_dopamine', '/.installed_palera1n', '/var/binpack', '/var/LIB', '/var/ulb', '/private/preboot/*/procursus'],
    hiddenURLSchemes: ['cydia://', 'sileo://', 'zbra://', 'filza://'],
    hiddenDylibs: ['SubstrateLoader', 'SubstrateInserter', 'SubstrateBootstrap', 'TweakInject', 'CydiaSubstrate', 'substitute', 'ElleKit', 'libhooker', 'pspawn_payload'],
    blockEnvVars: ['DYLD_INSERT_LIBRARIES', 'MobileSubstratePath', '_MSSafeMode'],
    zalo_clearKeychain: true,
    zalo_fakeWebViewUA: 'Mozilla/5.0 (iPhone; CPU iPhone OS ' + iosVersion.replace(/\./g, '_') + ' like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
    zalo_canvasNoiseSeed: randInt(1, 999999), zalo_metalGPU: device.gpu,
    zalo_openGLRenderer: 'Apple ' + device.gpu, zalo_timingOffset: randInt(-500000, 500000),
    web_fakeEnabled: true, web_glVendor: 'Apple Inc.', web_glRenderer: 'Apple ' + device.gpu,
    web_canvasNoise: 'zls_' + randInt(1000, 99999),
  };
  var df = DEFAULT_FAKE_LAYERS;
  var ol = options.layers || {};
  for (var fk in df) { if (Object.prototype.hasOwnProperty.call(df, fk)) profile[fk] = df[fk]; }
  for (var fk2 in ol) { if (Object.prototype.hasOwnProperty.call(ol, fk2)) profile[fk2] = ol[fk2]; }
  return profile;
}

function mergeDefaultFakeLayers(p) {
  if (!p) return;
  for (var k in DEFAULT_FAKE_LAYERS) {
    if (p[k] === undefined) p[k] = DEFAULT_FAKE_LAYERS[k];
  }
}

function applyFullDeviceReroll() {
  var rg = document.getElementById('carrierRegion');
  rg = rg ? rg.value : 'vietnam';
  // Range slider drives both device + iOS pick. typeof getDeviceRange guards
  // against ordering issues if this fires before apps.js initializes.
  var devR = (typeof getDeviceRange === 'function') ? getDeviceRange() : null;
  var iosR = (typeof getIOSRange === 'function') ? getIOSRange() : null;
  currentProfile = generateFullProfile({
    carrierRegion: rg,
    deviceMinIdx: devR ? devR.minIdx : undefined,
    deviceMaxIdx: devR ? devR.maxIdx : undefined,
    iosMinIdx: iosR ? iosR.minIdx : undefined,
    iosMaxIdx: iosR ? iosR.maxIdx : undefined,
  });
  syncSelectorsFromProfile(currentProfile);
  updateInfoCard(currentProfile);
  setCardStatus(true);
  try { localStorage.setItem('ci_last_profile', JSON.stringify(currentProfile)); } catch (e0) {}
  syncFakeLayerUI();
  if (getCiOptions().main_webSvc) refreshNetworkInfo(false);
}

function updateInfoCard(p) {
  if (!p) return;
  var el = function(id) { return document.getElementById(id); };
  var m = el('iModel'); if (m) m.textContent = p.MarketingName || p.ProductType || 'iPhone';
  var v = el('iVer'); if (v) v.textContent = p.systemVersion || '—';
  var idfa = el('iIDFA'); if (idfa) idfa.textContent = (p.advertisingIdentifier || '—').substring(0, 8) + '…';
  var pr = el('iProxy'); if (pr) pr.textContent = 'null';
  var ip = el('iIP'); if (ip) ip.textContent = '—';
  var co = el('iCountry'); if (co) co.textContent = p.localeCountryCode || '—';
  var tz = el('iTZ'); if (tz) tz.textContent = p.timezoneName || '—';
}

function syncSelectorsFromProfile(p) {
  if (!p) return;
  // The dropdowns are gone — only the carrier select remains.
  var rg = document.getElementById('carrierRegion');
  if (rg && p.carrierISO) {
    rg.value = p.carrierISO === 'vn' ? 'vietnam' : 'international';
  }
}

function profileToPlist(profile) {
  var xml = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n';
  var entries = Object.entries(profile);
  for (var i = 0; i < entries.length; i++) {
    var key = entries[i][0], value = entries[i][1];
    xml += '\t<key>' + escapeXml(key) + '</key>\n';
    if (typeof value === 'string') xml += '\t<string>' + escapeXml(value) + '</string>\n';
    else if (typeof value === 'number') xml += Number.isInteger(value) ? '\t<integer>' + value + '</integer>\n' : '\t<real>' + value + '</real>\n';
    else if (typeof value === 'boolean') xml += '\t<' + value + '/>\n';
    else if (Array.isArray(value)) { xml += '\t<array>\n'; value.forEach(function(item) { xml += '\t\t<string>' + escapeXml(String(item)) + '</string>\n'; }); xml += '\t</array>\n'; }
  }
  xml += '</dict>\n</plist>\n';
  return xml;
}

function escapeXml(str) {
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function renderSelectPools() {
  // Range sliders are wired in apps.js → initRangeSliders(). Kept as no-op
  // for back-compat with any caller path that still invokes it.
  if (typeof initRangeSliders === 'function') initRangeSliders();
}

// Deploy & Reset actions
var __ciDeployPhase = null;
var __ciDeployResolve = null;
window.__ciOnDeployProgress = function(phase) {
  __ciDeployPhase = phase;
  if (__ciDeployResolve) { var r = __ciDeployResolve; __ciDeployResolve = null; r(phase); }
};

function ciAwaitNativeProgress(timeoutMs) {
  return new Promise(function(resolve) {
    if (__ciDeployPhase) { resolve(__ciDeployPhase); __ciDeployPhase = null; return; }
    __ciDeployResolve = resolve;
    setTimeout(function() { if (__ciDeployResolve === resolve) { __ciDeployResolve = null; resolve('timeout'); } }, timeoutMs);
  });
}

async function randomizeAll() {
  ciBusyShow('Reset data');
  var toastMsg = '', toastKind = 'ok';
  try {
    ciBusyStepText('Generating new device identity…');
    await ciDelay(350);
    applyFullDeviceReroll();
    mergeDefaultFakeLayers(currentProfile);
    try { localStorage.setItem('ci_last_profile', JSON.stringify(currentProfile)); } catch (e0) {}
    var o = getCiOptions();
    var wipes = getSelectedWipes();
    ciBusyStepText('Writing profile to device…');
    await ciDelay(300);
    if (!isCiNativeBridge()) throw new Error('Native bridge not available');
    __ciCallNative({ action: 'deploy', profile: currentProfile, wipes: wipes, options: o });
    var phase = await ciAwaitNativeProgress(5000);
    if (phase === 'configWritten') {
      ciBusyStepText('App data cleared. Reloading SpringBoard…');
      await ciAwaitNativeProgress(8000);
      ciBusyStepText('Reload triggered. Please wait…');
      await ciDelay(1500);
    } else {
      await ciAwaitNativeProgress(6000);
    }
    toastMsg = 'Reset + apply started on device'; toastKind = 'ok';
  } catch (e) { toastMsg = 'Reset failed: ' + String(e); toastKind = 'err'; }
  finally { ciBusyHide(); }
  if (toastMsg) showToast(toastMsg, toastKind);
}

async function deployConfig() {
  ciBusyShow('Backup & reset');
  var toastMsg = '', toastKind = 'ok';
  try {
    ciBusyStepText('Preparing…');
    await ciDelay(220);
    if (!currentProfile) { ciBusyStepText('Building device identity…'); await ciDelay(400); applyFullDeviceReroll(); }
    mergeDefaultFakeLayers(currentProfile);
    ciBusyStepText('Merging layers & wipe list…');
    await ciDelay(350);
    var wipes = getSelectedWipes();
    ciBusyStepText('Writing plist…');
    await ciDelay(300);
    try { localStorage.setItem('ci_last_profile', JSON.stringify(currentProfile)); } catch (e0) {}
    if (!isCiNativeBridge()) throw new Error('Native bridge not available');
    __ciCallNative({ action: 'deploy', profile: currentProfile, wipes: wipes, options: getCiOptions() });
    ciBusyStepText('Config written. Reloading SpringBoard…');
    var phase = await ciAwaitNativeProgress(5000);
    if (phase === 'configWritten') {
      ciBusyStepText('Reload triggered. Please wait…');
      await ciDelay(1500);
    }
    toastMsg = 'Backup & reset applied'; toastKind = 'ok';
  } catch (e) { toastMsg = 'Deploy failed: ' + String(e); toastKind = 'err'; }
  finally { ciBusyHide(); }
  if (toastMsg) showToast(toastMsg, toastKind);
}
