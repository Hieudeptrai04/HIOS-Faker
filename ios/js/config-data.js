// ============================================================
// CONFIG DATA - Device database, constants, static data
// ============================================================

var DEVICE_DATABASE = {
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
  'iPhone14,4': { marketing: 'iPhone 13 mini', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8110', screenW: 375, screenH: 812, scale: 3, nativeW: 1080, nativeH: 2340, ram: 4294967296, cpuCores: 6, gpu: 'Apple A15 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone14,5': { marketing: 'iPhone 13', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8110', screenW: 390, screenH: 844, scale: 3, nativeW: 1170, nativeH: 2532, ram: 4294967296, cpuCores: 6, gpu: 'Apple A15 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone14,2': { marketing: 'iPhone 13 Pro', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8110', screenW: 390, screenH: 844, scale: 3, nativeW: 1170, nativeH: 2556, ram: 6442450944, cpuCores: 6, gpu: 'Apple A15 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone14,3': { marketing: 'iPhone 13 Pro Max', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8110', screenW: 428, screenH: 926, scale: 3, nativeW: 1284, nativeH: 2778, ram: 6442450944, cpuCores: 6, gpu: 'Apple A15 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone14,7': { marketing: 'iPhone 14', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8110', screenW: 390, screenH: 844, scale: 3, nativeW: 1170, nativeH: 2532, ram: 6442450944, cpuCores: 6, gpu: 'Apple A15 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone14,8': { marketing: 'iPhone 14 Plus', color: '#1F2020', enclosureColor: '#1F2020', boardId: '0x20', chipId: '0x8110', screenW: 428, screenH: 926, scale: 3, nativeW: 1284, nativeH: 2778, ram: 6442450944, cpuCores: 6, gpu: 'Apple A15 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone15,2': { marketing: 'iPhone 14 Pro', color: '#1F2020', enclosureColor: '#403E3D', boardId: '0x40', chipId: '0x8120', screenW: 393, screenH: 852, scale: 3, nativeW: 1179, nativeH: 2556, ram: 6442450944, cpuCores: 6, gpu: 'Apple A16 GPU', cpuType: 16777228, cpuSubtype: 2 },
  'iPhone15,3': { marketing: 'iPhone 14 Pro Max', color: '#1F2020', enclosureColor: '#403E3D', boardId: '0x40', chipId: '0x8120', screenW: 430, screenH: 932, scale: 3, nativeW: 1290, nativeH: 2796, ram: 6442450944, cpuCores: 6, gpu: 'Apple A16 GPU', cpuType: 16777228, cpuSubtype: 2 },
};

var HW_MODEL_MAP = {
  'iPhone10,3': 'D22AP', 'iPhone10,6': 'D221AP',
  'iPhone11,2': 'D321AP', 'iPhone11,8': 'N841AP',
  'iPhone12,1': 'N104AP', 'iPhone12,3': 'D421AP', 'iPhone12,5': 'D431AP',
  'iPhone13,1': 'D52gAP', 'iPhone13,2': 'D53gAP', 'iPhone13,3': 'D53pAP', 'iPhone13,4': 'D54pAP',
  'iPhone14,4': 'D16AP', 'iPhone14,5': 'D17AP', 'iPhone14,2': 'D63AP', 'iPhone14,3': 'D64AP',
  'iPhone14,7': 'D27AP', 'iPhone14,8': 'D28AP',
  'iPhone15,2': 'D73AP', 'iPhone15,3': 'D74AP',
};

var IOS_VERSIONS = {
  '15.0': '19A346', '15.1': '19B74', '15.2': '19C56', '15.3': '19D50',
  '15.4': '19E241', '15.5': '19F77', '15.6': '19G71', '15.7': '19H12',
  '16.0': '20A362', '16.1': '20B82', '16.2': '20C65', '16.3': '20D47',
  '16.4': '20E247', '16.5': '20F66', '16.6': '20G75', '16.6.1': '20G81',
  '16.7': '20H19', '16.7.1': '20H30', '16.7.2': '20H115', '16.7.3': '20H232',
  '16.7.4': '20H240', '16.7.5': '20H307', '16.7.6': '20H320', '16.7.7': '20H330',
  '16.7.8': '20H343', '16.7.9': '20H350', '16.7.10': '20H360',
};

var CARRIERS_VN = [
  { name: 'Viettel', mcc: '452', mnc: '04', iso: 'vn' },
  { name: 'Mobifone', mcc: '452', mnc: '01', iso: 'vn' },
  { name: 'Vinaphone', mcc: '452', mnc: '02', iso: 'vn' },
  { name: 'Vietnamobile', mcc: '452', mnc: '05', iso: 'vn' },
  { name: 'Gmobile', mcc: '452', mnc: '07', iso: 'vn' },
];

var CARRIERS_INTL = [
  { name: 'AT&T', mcc: '310', mnc: '410', iso: 'us' },
  { name: 'T-Mobile', mcc: '310', mnc: '260', iso: 'us' },
  { name: 'Verizon', mcc: '311', mnc: '480', iso: 'us' },
  { name: 'DTAC', mcc: '520', mnc: '01', iso: 'th' },
  { name: 'AIS', mcc: '520', mnc: '03', iso: 'th' },
  { name: 'TrueMove H', mcc: '520', mnc: '04', iso: 'th' },
];

var WIFI_NAMES = [
  'FPT-Home', 'VNPT-WiFi', 'Viettel-WiFi', 'TP-Link', 'Tenda_WiFi',
  'HOME-WIFI', 'Family_Net', 'MyWiFi', 'ASUS_5G', 'Xiaomi_Router',
  'Coffee-WiFi', 'Office_Net', 'Guest-WiFi', 'NetGear', 'D-Link',
];

var FALLBACK_POPULAR_APPS = [
  {bundleId:'com.vng.zalo', name:'Zalo'},
  {bundleId:'com.zing.zalo', name:'Zalo (Zing)'},
  {bundleId:'com.zhiliaoapp.musically', name:'TikTok'},
  {bundleId:'com.ss.iphone.ugc.Aweme', name:'TikTok (CN)'},
  {bundleId:'com.facebook.Facebook', name:'Facebook'},
  {bundleId:'com.burbn.instagram', name:'Instagram'},
  {bundleId:'com.segf4ult.joker', name:'Joker'},
  {bundleId:'com.mojang.minecraftpe', name:'Minecraft PE'},
  {bundleId:'com.netease.mm', name:'WeChat'},
  {bundleId:'com.nhn.android.band', name:'Band'},
  {bundleId:'jp.naver.line', name:'LINE'},
  {bundleId:'com.kakao.talk', name:'KakaoTalk'},
  {bundleId:'com.tencent.mm', name:'WeChat (HK)'},
  {bundleId:'com.lazadaVN', name:'Lazada'},
  {bundleId:'com.shopee.vn', name:'Shopee'},
  {bundleId:'com.tiki.app', name:'Tiki'},
  {bundleId:'com.facebook.Messenger', name:'Messenger'},
  {bundleId:'com.zaloapp.zalovn', name:'Zalo Lite'},
  {bundleId:'com.tpbank.ebank', name:'TPBank'},
  {bundleId:'com.acb.acbmobileapp', name:'ACB'},
  {bundleId:'com.VPBank.VPBankNeo', name:'VPBank Neo'},
];

var FAKE_LAYER_DEFS = [
  { key: 'uiddevice', label: 'UIDevice', desc: 'name, model, systemVersion, IDFV, battery' },
  { key: 'homebutton', label: 'Home Button', desc: 'isMultitaskingSupported, userInterfaceIdiom' },
  { key: 'hardware', label: 'MobileGestalt', desc: 'Serial, UDID, ECID, IMEI, HardwareModel' },
  { key: 'ads', label: 'Advertising', desc: 'IDFA, trackingAuthorizationStatus' },
  { key: 'screen', label: 'Screen', desc: 'bounds, scale, nativeBounds, nativeScale' },
  { key: 'realscreen', label: 'Real Screen', desc: 'nativeScreenWidth/Height, nativeScale' },
  { key: 'browser', label: 'Browser', desc: 'User-Agent, WKWebView, Metal GPU' },
  { key: 'datetime', label: 'Date/Timezone', desc: 'timezoneName, systemUptime, boot time' },
  { key: 'locale', label: 'Locale', desc: 'localeIdentifier, countryCode, languageCode' },
  { key: 'network', label: 'Network', desc: 'carrierName, MCC, MNC, SIM, RadioAccess' },
  { key: 'wifi', label: 'WiFi Info', desc: 'SSID, BSSID, WiFi/Bluetooth MAC' },
];

var CI_BUNDLE_ALIASES = {
  zalo:'com.vng.zalo', facebook:'com.facebook.Facebook', fb:'com.facebook.Facebook',
  messenger:'com.facebook.Messenger', tiktok:'com.zhiliaoapp.musically', shopee:'com.shopee.vn',
  lazada:'com.lazadaVN', tiki:'com.tiki.app', zing:'com.vng.zalo',
  instagram:'com.burbn.instagram', twitter:'com.atebits.Tweetie2',
  telegram:'ph.telegra.Telegraph', whatsapp:'net.whatsapp.WhatsApp',
  viber:'com.viber', skype:'com.skype.skype', snapchat:'com.toyopagroup.picaboo',
  chrome:'com.google.chrome.ios', safari:'com.apple.mobilesafari',
};

var CI_WIPE_SELECTED_KEY = 'ci_wipe_selected';
var CI_BACKUP_SELECTED_KEY = 'ci_backup_selected';
var __wipeSelectedSet = {};
var __backupSelectedSet = {};
var __ciAppsCache = [];
var __ciSettingsMode = false;
var __ciCurrentTab = 0;
var currentProfile = null;
var installedAppsPending = false;
var installedAppsTimer = null;
var __ciManualBundles = [];
var DEVICE_APPS_RAW = '';
var DEVICE_APPS_PRELOADED = [];
if (DEVICE_APPS_RAW) {
  try {
    DEVICE_APPS_PRELOADED = DEVICE_APPS_RAW.split(',,').map(function(s) {
      var parts = s.split('|');
      if (parts.length >= 2) return { bundleId: parts[0], name: parts[1] };
      if (parts.length === 1 && parts[0]) return { bundleId: parts[0], name: parts[0] };
      return null;
    }).filter(Boolean);
    __ciAppsCache = DEVICE_APPS_PRELOADED.slice();
  } catch(e) { DEVICE_APPS_PRELOADED = []; }
}
if (typeof DEVICE_APPS_PRELOADED === 'undefined') DEVICE_APPS_PRELOADED = [];
if (!__ciAppsCache.length && DEVICE_APPS_PRELOADED.length) {
  __ciAppsCache = DEVICE_APPS_PRELOADED.slice();
}
