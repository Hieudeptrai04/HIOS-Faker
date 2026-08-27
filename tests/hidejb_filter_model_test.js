#!/usr/bin/env node
'use strict';
// ============================================================================
// HAND-SYNCED MODEL TEST — COMPILED TEST = NOT RUN.
// This is a JS re-implementation (MODEL) of the C/ObjC algorithm in
//   tweak-mg/Tweak.xm : ci_canonPath() [status enum], isJBPath(), isTweakDataPath()
//   app/main.m        : ci_staticFilterVerify()  [ITEM 3, read-only, replaces the
//                       REMOVED ci_filterWriteVerified/ci_writtenFilterHasRequired],
//                       ci_configMirrorMatches()  [ITEM 4, exact mirror read-back],
//                       the Change-Device wipe-count gate [ITEM 5, count-on-success].
// It does NOT compile or run the tweak/app binary and is NOT native parity proof.
// MODELLING LIMITS (cannot be reproduced in pure JS, asserted only structurally):
//   - lstat()/S_ISREG regular-file-not-symlink check is passed in as a boolean;
//   - Foundation disk I/O, real writeToFile, DAC permissions, ci_run() shell rc,
//     LSApplicationProxy fresh-resolve [ITEM 2] are NOT exercised.
// TWO DRIFT GUARDS below read tweak-mg/Tweak.xm AND app/main.m and FAIL if the
// constants (CI_CANON_MAXSEG, kCfgDir, kHide, vcam spellings, media exts; kZaloBID,
// Filter Mode="Any", the identity-key list, kSharedConfigPath) drift from this
// model, so silent divergence is caught. Run: node tests/hidejb_filter_model_test.js
// Benchmark at the end is NON-GATING (JS timing only; says nothing about C).
// ============================================================================
const fs = require('fs');
const path = require('path');

// ---- Model constants (MUST mirror the C; drift guard verifies) ----
const CI_CANON_MAXSEG = 512;
const OUTSZ = 1024;                                  // sizeof(canon) in BYTES
const kCfg = '/var/jb/etc/changeinfoios';            // no trailing slash (boundary-aware)
const kHide = ['/var/jb','/private/var/jb','/var/lib/apt','/private/var/lib/apt','/var/lib/cydia',
  '/var/cache/apt','/Applications/Cydia.app','/Applications/Sileo.app','/Applications/Zebra.app',
  '/Applications/filza.app','/Library/MobileSubstrate','/var/MobileSubstrate','/usr/lib/libsubstrate.dylib',
  '/usr/lib/substrate','/var/checkra1n.dmg','/.bootstraprc','/bootstraprc','/private/etc/apt','/etc/apt',
  '/bin/bash','/bin/sh','/bin/zsh','/usr/sbin/sshd','/usr/bin/ssh','/etc/ssh','/usr/libexec/cydia',
  '/usr/libexec/substrate','/usr/bin/cycript','/usr/lib/libcycript.dylib','/usr/lib/TweakInject',
  '/var/lib/dpkg','/Library/dpkg','/.installed_unc0ver','/.bootstrapped_electra','/.bootstrapped',
  '/taurine','/var/binpack','/private/var/binpack','/jb','/Applications/Filza.app'];
const VCAM_SPELLINGS = ['vcam','Vcam','VCam'];        // C uses 3 exact-case strstr, NOT /vcam/i
const MEDIA_EXTS = ['.mov','.mp4','.m4v'];             // C strcasecmp on last 4 bytes (case-insensitive)

const S = { OK:'OK', INVALID:'INVALID', CWD_FAILED:'CWD_FAILED', SEG_OVERFLOW:'SEG_OVERFLOW', OUT_TRUNCATED:'OUT_TRUNCATED' };

function u8len(s){ return Buffer.byteLength(s,'utf8'); }          // UTF-8 byte length like C

// Port of ci_canonPath status enum. cwd simulates getcwd() (null => getcwd failed).
function canonStatus(inp, cwd, outsz=OUTSZ) {
  if (inp == null || inp === '') return { status:S.INVALID, out:'' };
  let segs = [];
  const push = (seg) => { if (segs.length >= CI_CANON_MAXSEG) return false; segs.push(seg); return true; };
  if (inp[0] !== '/') {
    if (!cwd || cwd[0] !== '/') return { status:S.CWD_FAILED, out:'' };
    for (const seg of cwd.split('/')) {
      if (seg === '' || seg === '.') continue;
      if (seg === '..') { if (segs.length) segs.pop(); continue; }
      if (segs.length >= CI_CANON_MAXSEG) return { status:S.SEG_OVERFLOW, out:'' };
      segs.push(seg);
    }
  }
  for (const seg of inp.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { if (segs.length) segs.pop(); continue; }
    if (segs.length >= CI_CANON_MAXSEG) return { status:S.SEG_OVERFLOW, out:'' };
    segs.push(seg);
  }
  if (segs.length === 0) return outsz >= 2 ? { status:S.OK, out:'/' } : { status:S.OUT_TRUNCATED, out:'' };
  // build with UTF-8 byte budget; truncate at outsz-1 bytes
  let out = ''; let bytes = 0;
  for (const seg of segs) {
    if (bytes + 1 >= outsz) return { status:S.OUT_TRUNCATED, out };
    out += '/'; bytes += 1;
    for (const ch of seg) {
      const b = u8len(ch);
      if (bytes + b >= outsz) return { status:S.OUT_TRUNCATED, out };
      out += ch; bytes += b;
    }
  }
  return { status:S.OK, out };
}
function isTweakDataPath(cp){
  for (const v of VCAM_SPELLINGS) if (cp.includes(v)) return true;   // exact-case substrings (not /i)
  const low = cp.toLowerCase();
  for (const e of MEDIA_EXTS) if (low.endsWith(e)) return true;      // last-4 case-insensitive
  return false;
}
function boundary(cp, pre){ return cp.startsWith(pre) && (cp.length === pre.length || cp[pre.length] === '/'); }
function isJBPath(path_, cwd) {
  if (path_ == null) return false;
  const { status, out } = canonStatus(path_, cwd);
  // ITEM 1 — ERROR PARITY: hide ONLY on a fully-OK canonicalization. Any non-OK
  // status (INVALID / CWD_FAILED / SEG_OVERFLOW / OUT_TRUNCATED) → return false so
  // the hook passes through to the ORIGINAL syscall and its real errno is preserved
  // (no fabricated ENOENT masking ENAMETOOLONG). Mirrors `if (st != CI_CANON_OK)
  // return NO;` in tweak-mg/Tweak.xm (drift guard asserts that line exists).
  if (status !== S.OK) return false;
  const cp = out;
  if (boundary(cp, kCfg)) return false;
  if (isTweakDataPath(cp)) return false;
  for (const h of kHide) if (boundary(cp, h)) return true;
  return false;
}
function setEq(a,b){ a=new Set(a); b=new Set(b); if(a.size!==b.size) return false; for(const x of a) if(!b.has(x)) return false; return true; }

// ITEM 3 — MODEL of ci_staticFilterVerify(). `isRegularFile` stands in for the
// lstat()+S_ISREG check (a symlink/dir/missing path → false; the C rejects it BEFORE
// reading, so a symlink can't redirect the read). NON-empty Bundles+Executables of
// NON-empty strings, Mode=="Any", every required (injectable) bid present. No write.
function staticFilterVerify(isRegularFile, plist, requiredBids, noInject){
  if(!isRegularFile) return false;
  const f = plist && plist.Filter; if(!f || typeof f!=='object') return false;
  if(f.Mode!=='Any') return false;
  if(!Array.isArray(f.Bundles)||f.Bundles.length===0) return false;
  for(const b of f.Bundles) if(typeof b!=='string'||b.length===0) return false;
  if(f.Executables!==undefined){                      // Executables OPTIONAL (MG ships Bundles only)
    if(!Array.isArray(f.Executables)) return false;
    for(const e of f.Executables) if(typeof e!=='string'||e.length===0) return false;
  }
  const bs=new Set(f.Bundles); noInject=noInject||new Set();
  for(const bid of (requiredBids||[])){
    if(!bid||noInject.has(bid)) continue;
    if(!bs.has(bid)) return false;
  }
  return true;
}

// ITEM 4 — MODEL of ci_configMirrorMatches(). Exact read-back: every identity key
// present in the LIVE config must be a string that EXACTLY equals the mirror on
// disk. Any mismatch/missing → false. If ZERO identity keys were comparable → FAIL
// CLOSED (we cannot prove the mirror landed).
function configMirrorMatches(disk, live, identityKeys){
  if(!disk||typeof disk!=='object') return false;
  let checked=0;
  for(const k of identityKeys){
    const lv=live[k];
    if(typeof lv!=='string'||lv.length===0) continue;   // not part of this profile
    const gv=disk[k];
    if(typeof gv!=='string'||gv!==lv) return false;      // stale/missing mirror → abort
    checked++;
  }
  return checked>0;                                      // checked===0 → fail-closed
}

// ITEM 5 — MODEL of the wipe-count gate. `wiped` counts ONLY apps whose sub-dir
// shells all returned 0 (subsOK) AND whose marker read back non-empty (markerOK).
// Any failure lands in `failed` so the UI reports PARTIAL.
function wipeGate(apps){
  let wiped=0; const failed=[];
  for(const a of apps){
    if(a.subsOK && a.markerOK) wiped++; else failed.push(a.name);
  }
  return {wiped, failed};
}

// CODEX P0-2 — MODEL of ci_criticalConfigReadback(): the CRITICAL tweak-consumed keys
// read back before wipe. identity + _ci_lic_tok(==live, nonempty) + targetBundles
// set-equal + every wipe_gen_<bid>==nonce + every wipe_counter_<bid>==counter(number)
// + wipe_deadline == exact staged string AND still in the future.
function criticalConfigReadback(disk, live, identityKeys, allBids, wipeGen, counter, wipeDeadline, now){
  if(!configMirrorMatches(disk, live, identityKeys)) return false;
  if(!disk||typeof disk!=='object') return false;
  const lt = live['_ci_lic_tok'];                       // signed spoof token
  if(typeof lt!=='string'||!lt.length) return false;
  if(disk['_ci_lic_tok'] !== lt) return false;          // must be present + equal on disk
  const tb = disk['targetBundles'];
  if(!Array.isArray(tb) || !setEq(tb, allBids||[])) return false;
  if(!wipeGen) return false;
  for(const bid of (allBids||[])){
    if(typeof bid!=='string'||!bid.length) return false;
    if(disk['wipe_gen_'+bid] !== wipeGen) return false;
    const wc = disk['wipe_counter_'+bid];               // NSNumber → JS number
    if(typeof wc!=='number' || wc !== counter) return false;
  }
  const dl = disk['wipe_deadline'];
  if(dl !== String(wipeDeadline)) return false;         // EXACT staged value (not just nonempty)
  if(wipeDeadline <= now) return false;                 // must still be in the future
  return true;
}

// CODEX P0-3 — MODEL of the per-app wipe verification gate. A sub is clean only if
// rm ok AND mkdir ok AND dir exists+enumerated+empty. An app counts as wiped only if
// ALL subs clean AND .ci_last_wipe reads back the EXACT counter AND .ci_gen reads back
// the EXACT wipeGen. Otherwise it lands in failed with the specific reason(s).
function wipeVerify(app){   // app: {name, subs:[{rmRc,mkdirRc,emptyRc}], lastRc, genRc, genChk}
  const subsOK = app.subs.every(s => s.rmRc===0 && s.mkdirRc===0 && s.emptyRc===0);
  const lastWipeMarkerExact = app.lastRc===0;
  const genMarkerExact = app.genRc===0 && app.genChk===0;
  const reasons = [];
  if(!subsOK) reasons.push('subs');
  if(!lastWipeMarkerExact) reasons.push('last_wipe');
  if(!genMarkerExact) reasons.push('gen');
  return { ok: subsOK && lastWipeMarkerExact && genMarkerExact, reasons };
}

// MODEL of the preflight filter gate: every user-selected injectable app must
// be covered. A wipe-only unsupported app is unsafe because it receives no profile.
function filterGate(mgBundles, ctBundles, resetBids){
  const gateBids = resetBids.filter(bid => bid !== 'com.apple.weather');
  const mg = {Filter:{Bundles:mgBundles, Mode:'Any'}};
  const ct = {Filter:{Bundles:ctBundles, Mode:'Any'}};
  return staticFilterVerify(true, mg, gateBids) && staticFilterVerify(true, ct, gateBids);
}

// identity keys mirrored from ci_configMirrorMatches (drift guard verifies vs source).
// WiFiAddress is CAPITAL-F — the canonical config key (ci_randomizeIdentities @1915).
const IDENTITY_KEYS = ['SerialNumber','UniqueDeviceID','InternationalMobileEquipmentIdentity',
  'advertisingIdentifier','WiFiAddress','BluetoothAddress','ModelNumber'];
const kSharedConfigPathModel = '/var/jb/etc/changeinfoios/config.plist';
const kZaloBIDModel = 'vn.com.vng.zingalo';

let fails=0;
const eq=(name,got,want)=>{const ok=JSON.stringify(got)===JSON.stringify(want); if(!ok)fails++; console.log(`${ok?'PASS':'FAIL'}  ${name}  (got ${JSON.stringify(got)}, want ${JSON.stringify(want)})`);};

// ---------------- DRIFT GUARD: source vs model ----------------
console.log('== DRIFT GUARD (read tweak-mg/Tweak.xm) ==');
const src = fs.readFileSync(path.join(__dirname,'..','tweak-mg','Tweak.xm'),'utf8');
const mMax = src.match(/#define\s+CI_CANON_MAXSEG\s+(\d+)/);
eq('CI_CANON_MAXSEG matches', mMax?Number(mMax[1]):null, CI_CANON_MAXSEG);
const mCfg = src.match(/static const char kCfgDir\[\]\s*=\s*"([^"]+)"/);
eq('kCfgDir matches', mCfg?mCfg[1]:null, kCfg);
// extract kHide entries from the array literal
const hideBlock = src.slice(src.indexOf('static const char * const kHide[]'));
const srcHide = [...hideBlock.slice(0, hideBlock.indexOf('NULL')).matchAll(/"([^"]+)"/g)].map(m=>m[1]);
eq('kHide set matches', setEq(srcHide, kHide) && srcHide.length===kHide.length, true);
const srcVcam = [...(src.match(/strstr\(path,\s*"(vcam|Vcam|VCam)"\)/g)||[])].map(s=>s.match(/"([^"]+)"/)[1]);
eq('vcam spellings match', setEq(srcVcam, VCAM_SPELLINGS) && srcVcam.length===VCAM_SPELLINGS.length, true);
const srcExt = [...(src.match(/strcasecmp\(ext,\s*"(\.[a-z0-9]+)"\)/g)||[])].map(s=>s.match(/"([^"]+)"/)[1]);
eq('media exts match', setEq(srcExt, MEDIA_EXTS) && srcExt.length===MEDIA_EXTS.length, true);
// ITEM 1 — isJBPath must pass through (return NO) for ANY non-OK canonical status.
eq('isJBPath pass-through on non-OK status (item 1)',
   /if\s*\(st\s*!=\s*CI_CANON_OK\)\s*return\s+NO;/.test(src), true);

// ---------------- DRIFT GUARD #2: app/main.m (ITEM 3/4 constants) ----------------
console.log('\n== DRIFT GUARD #2 (read app/main.m) ==');
const asrc = fs.readFileSync(path.join(__dirname,'..','app','main.m'),'utf8');
// kZaloBID literal
eq('kZaloBID present in app/main.m', asrc.includes('@"'+kZaloBIDModel+'"'), true);
// kSharedConfigPath value
const mScp = asrc.match(/kSharedConfigPath\s*=\s*@"([^"]+)"/);
eq('kSharedConfigPath matches', mScp?mScp[1]:null, kSharedConfigPathModel);
// ci_staticFilterVerify enforces Mode=="Any"
eq('static filter verify checks Mode=="Any"',
   /ci_staticFilterVerify[\s\S]*?isEqualToString:@"Any"/.test(asrc), true);
// ci_staticFilterVerify uses lstat + S_ISREG (regular-file, symlink-reject)
eq('static filter verify uses lstat+S_ISREG',
   /ci_staticFilterVerify[\s\S]*?lstat\(/.test(asrc) && /ci_staticFilterVerify[\s\S]*?S_ISREG/.test(asrc), true);
// runtime writeToFile of the DynamicLibraries filter is GONE (ITEM 3: no mobile write)
eq('NO runtime writeToFile into DynamicLibraries filter (item 3)',
   /writeToFile:[^\n]*(CITweakFilterPath|CICTTweakFilterPath|DynamicLibraries)/.test(asrc), false);
// identity-key list in ci_configMirrorMatches matches the model
const idBlock = asrc.slice(asrc.indexOf('kIdentityKeys = @['));
const srcIdKeys = [...idBlock.slice(0, idBlock.indexOf('];')).matchAll(/@"([^"]+)"/g)].map(m=>m[1]);
eq('identity keys match model', setEq(srcIdKeys, IDENTITY_KEYS) && srcIdKeys.length===IDENTITY_KEYS.length, true);
// config save returns BOOL (item 4)
eq('CIConfigManager save returns BOOL (item 4)', /-\s*\(BOOL\)save\b/.test(asrc), true);
// wipe count gated by subsOK && BOTH markers exact (P0-3)
eq('wiped++ gated by subs + both markers exact (P0-3)',
   /if\s*\(subsOK\s*&&\s*lastWipeMarkerExact\s*&&\s*genMarkerExact\)\s*\{\s*wiped\+\+;/.test(asrc), true);
// REAL shipped filters must satisfy the item-3 static verify for Zalo (Bundles+Mode).
// This is a FILE check (not just a model): the package these tweaks ship in bakes Zalo
// with Mode=Any, so the read-only preflight will PROCEED for a Zalo change (not abort).
const mgPlist = fs.readFileSync(path.join(__dirname,'..','tweak-mg','ChangeInfoIosMG.plist'),'utf8');
const ctPlist = fs.readFileSync(path.join(__dirname,'..','tweak-ct','ChangeInfoIosCT.plist'),'utf8');
eq('shipped MG filter bakes Zalo', mgPlist.includes('<string>'+kZaloBIDModel+'</string>'), true);
eq('shipped CT filter bakes Zalo', ctPlist.includes('<string>'+kZaloBIDModel+'</string>'), true);
eq('shipped MG filter Mode=Any', /<key>Mode<\/key>\s*<string>Any<\/string>/.test(mgPlist), true);
eq('shipped CT filter Mode=Any', /<key>Mode<\/key>\s*<string>Any<\/string>/.test(ctPlist), true);

// ---------------- DRIFT GUARD #3: Codex-blocker + self-review fixes ----------------
console.log('\n== DRIFT GUARD #3 (Codex blockers, app/main.m) ==');
// W3: WiFi MAC key is CAPITAL-F everywhere; the lowercase-f typo must be gone.
eq('config writes @"WiFiAddress" (capital F)', asrc.includes('@"WiFiAddress"'), true);
eq('lowercase @"WifiAddress" typo removed', asrc.includes('@"WifiAddress"'), false);
// Blocker 1: LSApplicationProxy resolved DYNAMICALLY; no direct class message that would
// emit an undefined _OBJC_CLASS_$_LSApplicationProxy link symbol.
eq('LSApplicationProxy resolved via NSClassFromString',
   asrc.includes('NSClassFromString(@"LSApplicationProxy")'), true);
eq('NO direct [LSApplicationProxy applicationProxyForIdentifier:] class message',
   /\[\s*LSApplicationProxy\s+applicationProxyForIdentifier:/.test(asrc), false);
// Blocker 2: Zalo target paths ALWAYS overwritten with the fresh-resolved values.
eq('Zalo target uses fresh bundlePath', /zTarget\.bundlePath\s*=\s*zBundlePath;/.test(asrc), true);
eq('Zalo target uses fresh containerPath', /zTarget\.containerPath\s*=\s*zContainerPath;/.test(asrc), true);
// P0-3: rm rc + mkdir rc captured separately; strict dir-exists+enumerate+empty probe.
eq('wipe captures rmRc separately', /int\s+rmRc\s*=\s*ci_run/.test(asrc), true);
eq('wipe captures mkdirRc separately', /int\s+mkdirRc\s*=\s*ci_run/.test(asrc), true);
eq('wipe emptiness fails on missing dir (exit 3)', asrc.includes('|| exit 3'), true);
eq('wipe emptiness fails on ls error NOT swallowed (exit 4)', asrc.includes('|| exit 4'), true);
eq('wipe emptiness fails on non-empty (exit 5)', asrc.includes('|| exit 5'), true);
// P0-3: markers read back EXACTLY (cat == counter / == wipeGen), not just test -s.
eq('.ci_last_wipe read back == exact counter', /cat '%@' 2>\/dev\/null\)\\" = '%lld'/.test(asrc), true);
eq('.ci_gen read back == exact wipeGen', /cat '%@' 2>\/dev\/null\)\\" = '%@'/.test(asrc), true);
eq('marker no longer gated by bare test -s', /markChk[\s\S]*?test -s/.test(asrc), false);
// P0-2: CRITICAL readback (renamed) with exact token/counter/deadline.
eq('ci_criticalConfigReadback exists', /static BOOL ci_criticalConfigReadback\(/.test(asrc), true);
eq('critical readback checks _ci_lic_tok', /ci_criticalConfigReadback[\s\S]*?_ci_lic_tok/.test(asrc), true);
eq('critical readback checks targetBundles', /ci_criticalConfigReadback[\s\S]*?disk\[@"targetBundles"\]/.test(asrc), true);
eq('critical readback checks wipe_gen_', /ci_criticalConfigReadback[\s\S]*?wipe_gen_/.test(asrc), true);
eq('critical readback checks wipe_counter_', /ci_criticalConfigReadback[\s\S]*?wipe_counter_/.test(asrc), true);
eq('critical readback checks wipe_deadline future', /ci_criticalConfigReadback[\s\S]*?wipe_deadline[\s\S]*?timeIntervalSince1970/.test(asrc), true);
// P0-1: the pre-wipe abort GATES on filterOK too (filter recheck now blocks the wipe).
eq('pre-wipe abort gates on filterOK (P0-1)',
   /if\s*\(!mirrorSaved\s*\|\|\s*!cfgReadback\s*\|\|\s*!filterOK\)/.test(asrc), true);
// ORDERING: the pre-wipe gate log must appear BEFORE the "Step 2 done" wipe log.
const idxStage = asrc.indexOf('pre-wipe gate OK');
const idxWiped = asrc.indexOf('Step 2 done: VERIFIED-wiped');
eq('config+filter gate BEFORE wipe', idxStage > 0 && idxWiped > 0 && idxStage < idxWiped, true);
eq('filter gate covers every selected injectable bundle',
   /for\s*\(NSString \*bid in resetBids\)[\s\S]*?ci_isNoInjectBundle\(bid\)[\s\S]*?gateBidsM addObject:bid/.test(asrc), true);
// Blocker 5: every persisted targetBundles entry validated as a non-empty NSString.
eq('resetBids entries validated as non-empty NSString',
   /isKindOfClass:\[NSString class\]\]\s*&&\s*\[\(NSString \*\)b length\]/.test(asrc), true);
// P0-4: shared prefs demoted to secondary diagnostic; the false "đọc config cũ" claim gone.
eq('UI dropped the "tweak sẽ đọc config cũ" claim', asrc.includes('tweak sẽ đọc config cũ'), false);
eq('UI marks shared prefs as secondary diagnostic', asrc.includes('chẩn đoán phụ'), true);
eq('UI lists only VERIFIED-wiped apps (wipedNames)', asrc.includes('wipedNames componentsJoinedByString'), true);

// ---------------- canonicalizer STATUS truth table ----------------
console.log('\n== canonStatus truth table (status, not just hidden) ==');
eq('null → INVALID',        canonStatus(null,null).status, S.INVALID);
eq('empty → INVALID',       canonStatus('',null).status, S.INVALID);
eq('abs normal → OK',       canonStatus('/var/jb/apt',null).status, S.OK);
eq('dot/dotdot → OK+resolve', canonStatus('/a/./b/../c',null), {status:S.OK,out:'/a/c'});
eq('dup slash → OK',        canonStatus('//var//jb//apt',null), {status:S.OK,out:'/var/jb/apt'});
eq('relative cwd null → CWD_FAILED', canonStatus('apt',null).status, S.CWD_FAILED);
eq('relative cwd non-abs → CWD_FAILED', canonStatus('apt','relative').status, S.CWD_FAILED);
// Segment boundary (512 OK / 513 overflow) must be tested with an AMPLE buffer so
// it is not masked by output truncation — segment-count and output-bytes are two
// independent limits. 513 aborts in PARSE (out empty) regardless of buffer size.
eq('512 segs → OK (ample buffer isolates seg-count)', canonStatus('/'+Array(512).fill('a').join('/'),null,8192).status, S.OK);
eq('513 segs → SEG_OVERFLOW', canonStatus('/'+Array(513).fill('a').join('/'),null,8192).status, S.SEG_OVERFLOW);
eq('overflow out empty',    canonStatus('/'+Array(513).fill('a').join('/'),null,8192).out, '');
// With the PRODUCTION 1024-byte buffer, 512 single-char segments (1024B) OUT_TRUNCATE —
// documents the buffer/segment interaction; a 512-segment path is not a realistic probe.
eq('512 single-char segs @1024 buffer → OUT_TRUNCATED', canonStatus('/'+Array(512).fill('a').join('/'),null,1024).status, S.OUT_TRUNCATED);
// truncation-only: <=512 segments but UTF-8 canonical > buffer. Use a small outsz to test capacity edge.
eq('capacity-1 fits → OK',  canonStatus('/'+'a'.repeat(10), null, 12).status, S.OK);       // "/aaaaaaaaaa"=11B, outsz12 ok
eq('capacity+1 → OUT_TRUNCATED', canonStatus('/'+'a'.repeat(12), null, 12).status, S.OUT_TRUNCATED);
eq('UTF-8 é byte-length trunc', canonStatus('/'+'é'.repeat(6), null, 12).status, S.OUT_TRUNCATED); // é=2B ×6=12 +'/' > 12

// ---------------- isJBPath by status ----------------
console.log('\n== isJBPath (status-driven) ==');
eq('cfg-dir ../ escape hide', isJBPath('/var/jb/etc/changeinfoios/../../Applications/Sileo.app'), true);
eq('vcam ../ escape hide',    isJBPath('/var/mobile/vcam/../../../Applications/Cydia.app'), true);
eq('exact config dir exempt', isJBPath('/var/jb/etc/changeinfoios'), false);
eq('config child exempt',     isJBPath('/var/jb/etc/changeinfoios/config.plist'), false);
eq('changeinfoiosX boundary hide', isJBPath('/var/jb/etc/changeinfoiosX/foo'), true);  // NOT config dir (boundary) → under /var/jb
eq('legit .mov exempt',       isJBPath('/var/jb/var/mobile/Library/temp.mov'), false);
eq('[KNOWN_BYPASS] /var/jb/apt/x.mov exempt', isJBPath('/var/jb/apt/x.mov'), false);
eq('[KNOWN_BYPASS] /var/jb/vcam_marker exempt', isJBPath('/var/jb/vcam_marker'), false);
eq('mixed-case vCaM NOT exempt (C 3-spelling only) → under /var/jb hide', isJBPath('/var/jb/vCaM_x'), true);
eq('/var/jbx boundary not hidden', isJBPath('/var/jbx'), false);
eq('CydiaX boundary not hidden', isJBPath('/Applications/CydiaX.app'), false);
eq('/var/jb hide', isJBPath('/var/jb'), true);
eq('relative var/jb/apt cwd=/', isJBPath('var/jb/apt','/'), true);
eq('relative apt cwd=/var/jb', isJBPath('apt','/var/jb'), true);
eq('relative x.txt cwd=/var/mobile', isJBPath('x.txt','/var/mobile'), false);
eq('relative ../jb/apt cwd=/var/mobile', isJBPath('../jb/apt','/var/mobile'), true);
eq('CWD_FAILED (relative,no cwd) → pass-through NOT hidden (item 1)', isJBPath('var/jb/apt',null), false);
// ITEM 1 CHANGE: >512-seg SEG_OVERFLOW no longer falls back to a raw prefix hide.
// Even a /var/jb path passes through (NOT hidden) so the original syscall's errno is
// preserved. [LIMITATION] a genuine but >512-segment JB path is not hidden — but such
// a path is not a realistic anti-fraud probe (probes stat short Cydia/apt/bash paths).
eq('[LIMITATION] SEG_OVERFLOW even under /var/jb → pass-through NOT hidden (item 1)',
   isJBPath('/var/jb/'+'a/'.repeat(600)+'x'), false);
eq('overflow non-JB-raw-prefix → pass-through NOT hidden (item 1)',
   isJBPath('/var/mobile/'+'a/'.repeat(600)+'../../../var/jb/apt'), false);
eq('[LIMITATION] symlink evil path NOT_RESOLVED (needs readlink)', isJBPath('/var/mobile/evil'), false);
eq('every kHide exact=hidden', kHide.every(h=>isJBPath(h)===true), true);
eq('every kHide /child=hidden', kHide.every(h=>isJBPath(h+'/child')===true), true);

// ---------------- ITEM 1 counterexamples: error-parity pass-through ----------------
// A non-OK canonical status must NOT fabricate a hide for a NON-JB path: isJBPath
// returns false → the hook falls through to the ORIGINAL syscall, whose native errno
// (ENAMETOOLONG / ENOENT / …) is preserved. The tweak never rewrites ENAMETOOLONG to
// a fake ENOENT. (The contrast case shows a genuine JB path still hides on truncation.)
console.log('\n== ITEM 1: error-parity pass-through (non-OK status) ==');
eq('OUT_TRUNCATED non-JB → not hidden (pass-through, keep ENAMETOOLONG)',
   isJBPath('/System/Library/'+'a'.repeat(2000)), false);
eq('SEG_OVERFLOW non-JB raw prefix → not hidden (pass-through)',
   isJBPath('/var/mobile/'+'a/'.repeat(600)), false);
eq('INVALID empty → not hidden (original syscall runs on real path)',
   isJBPath(''), false);
eq('CWD_FAILED relative non-JB → not hidden (pass-through)',
   isJBPath('Documents/file.txt', null), false);
// ITEM 1: even a genuine JB path that OUT_TRUNCATES passes through (NOT hidden) so the
// original syscall's ENAMETOOLONG survives. [LIMITATION] a >1024-byte JB path is not
// hidden — accepted trade-off (such a path is not a realistic probe; fabricating a
// hide there would itself be a detectable errno tell).
eq('[LIMITATION] OUT_TRUNCATED genuine JB → pass-through NOT hidden (item 1)',
   isJBPath('/var/jb/'+'a'.repeat(2000)), false);

// ---------------- ITEM 3 counterexamples: static read-only filter verify ----------------
console.log('\n== ITEM 3: ci_staticFilterVerify (read-only, no write) ==');
const Z = kZaloBIDModel;
const goodF = {Filter:{Bundles:[Z],Executables:['Zalo','CommCenter'],Mode:'Any'}};
eq('regular file + Zalo present + Mode=Any → true', staticFilterVerify(true, goodF, [Z]), true);
eq('COUNTEREXAMPLE symlink (not regular file) → false even if content good',
   staticFilterVerify(false, goodF, [Z]), false);
eq('COUNTEREXAMPLE missing Zalo → false', staticFilterVerify(true,
   {Filter:{Bundles:['com.other'],Executables:['x'],Mode:'Any'}}, [Z]), false);
eq('COUNTEREXAMPLE Mode!=Any → false', staticFilterVerify(true,
   {Filter:{Bundles:[Z],Executables:['Zalo'],Mode:'All'}}, [Z]), false);
eq('COUNTEREXAMPLE empty Bundles → false', staticFilterVerify(true,
   {Filter:{Bundles:[],Executables:['Zalo'],Mode:'Any'}}, [Z]), false);
eq('Executables ABSENT (shipped MG style, Bundles only) → true', staticFilterVerify(true,
   {Filter:{Bundles:[Z],Mode:'Any'}}, [Z]), true);
eq('COUNTEREXAMPLE Executables present w/ empty-string entry → false', staticFilterVerify(true,
   {Filter:{Bundles:[Z],Executables:[''],Mode:'Any'}}, [Z]), false);
eq('COUNTEREXAMPLE non-string bundle entry → false', staticFilterVerify(true,
   {Filter:{Bundles:[Z,''],Executables:['Zalo'],Mode:'Any'}}, [Z]), false);
eq('COUNTEREXAMPLE no Filter → false', staticFilterVerify(true, {Foo:1}, [Z]), false);
eq('COUNTEREXAMPLE nil plist → false', staticFilterVerify(true, null, [Z]), false);
eq('no-inject required bid skipped (still true)', staticFilterVerify(true, goodF,
   [Z,'com.apple.weather'], new Set(['com.apple.weather'])), true);

// ---------------- ITEM 4 counterexamples: config mirror exact read-back ----------------
console.log('\n== ITEM 4: ci_configMirrorMatches (exact /var/jb mirror read-back) ==');
const live = {SerialNumber:'F2LABC123', UniqueDeviceID:'00008030-DEAD', ModelNumber:'MQ9V3VN/A'};
eq('exact match → true', configMirrorMatches({...live}, live, IDENTITY_KEYS), true);
eq('COUNTEREXAMPLE stale mirror (one key differs) → false',
   configMirrorMatches({...live, SerialNumber:'OLDSERIAL'}, live, IDENTITY_KEYS), false);
eq('COUNTEREXAMPLE mirror missing a live key → false',
   configMirrorMatches({UniqueDeviceID:'00008030-DEAD', ModelNumber:'MQ9V3VN/A'}, live, IDENTITY_KEYS), false);
eq('COUNTEREXAMPLE disk null/unparseable → false',
   configMirrorMatches(null, live, IDENTITY_KEYS), false);
eq('COUNTEREXAMPLE zero identity keys present → fail-closed',
   configMirrorMatches({unrelated:'x'}, {unrelated:'x'}, IDENTITY_KEYS), false);
eq('extra disk keys but identity exact → true',
   configMirrorMatches({...live, proxyHost:'should-not-matter'}, live, IDENTITY_KEYS), true);

// ---------------- ITEM 5 counterexamples: wipe-count gate + PARTIAL ----------------
console.log('\n== ITEM 5: wipe-count gate (count only verified; PARTIAL on failure) ==');
eq('all verified → wiped=3, failed=[]', wipeGate([
   {name:'Zalo',subsOK:true,markerOK:true},
   {name:'FB',subsOK:true,markerOK:true},
   {name:'Safari',subsOK:true,markerOK:true}]), {wiped:3, failed:[]});
eq('COUNTEREXAMPLE marker read-back fail → NOT counted, PARTIAL', wipeGate([
   {name:'Zalo',subsOK:true,markerOK:false},
   {name:'FB',subsOK:true,markerOK:true}]), {wiped:1, failed:['Zalo']});
eq('COUNTEREXAMPLE sub-dir shell fail → NOT counted, PARTIAL', wipeGate([
   {name:'Zalo',subsOK:false,markerOK:true}]), {wiped:0, failed:['Zalo']});
eq('COUNTEREXAMPLE all fail → wiped=0, all PARTIAL', wipeGate([
   {name:'Zalo',subsOK:false,markerOK:false},
   {name:'FB',subsOK:true,markerOK:false}]), {wiped:0, failed:['Zalo','FB']});
console.log('NOTE: ITEM 2 (LSApplicationProxy fresh-resolve) + ITEM 3 lstat + real disk I/O / shell rc are');
console.log('      NOT exercised here (need a device/runtime) — see DEVICE RUNTIME VERIFICATION = BLOCKED_RUNTIME.');

// ---------------- filter gate = every selected injectable app ----------------
console.log('\n== preflight filter gate covers every selected injectable app ==');
const MG_BAKED = ['vn.com.vng.zingalo','com.viber','com.apple.mobilesafari','com.apple.Maps'];
const CT_BAKED = ['vn.com.vng.zingalo','com.viber','com.facebook.Facebook'];
eq('Zalo alone → gate passes', filterGate(MG_BAKED, CT_BAKED, ['vn.com.vng.zingalo']), true);
eq('Zalo + Viber → both filters cover both',
   filterGate(MG_BAKED, CT_BAKED, ['vn.com.vng.zingalo','com.viber']), true);
eq('unsupported WhatsApp → fail before wipe',
   filterGate(MG_BAKED, CT_BAKED, ['com.whatsapp.WhatsApp']), false);
eq('no-inject Weather is skipped', filterGate(MG_BAKED, CT_BAKED, ['com.apple.weather']), true);
eq('COUNTEREXAMPLE Zalo requested but MG filter lacks Zalo → gate fails',
   filterGate(['com.apple.mobilesafari'], CT_BAKED, ['vn.com.vng.zingalo']), false);
eq('COUNTEREXAMPLE Zalo requested but CT filter lacks Zalo → gate fails',
   filterGate(MG_BAKED, ['com.facebook.Facebook'], ['vn.com.vng.zingalo']), false);

// ---------------- CODEX W3: WiFiAddress spelling read-back ----------------
console.log('\n== CODEX: WiFiAddress (capital F) is actually read back ==');
const liveW = {SerialNumber:'F2LABC123', WiFiAddress:'02:AA:BB:CC:DD:EE'};
eq('WiFiAddress matches → true', configMirrorMatches({...liveW}, liveW, IDENTITY_KEYS), true);
eq('COUNTEREXAMPLE stale WiFiAddress on disk → false (the typo would have missed this)',
   configMirrorMatches({...liveW, WiFiAddress:'02:00:00:00:00:00'}, liveW, IDENTITY_KEYS), false);
eq('model IDENTITY_KEYS carries capital-F WiFiAddress', IDENTITY_KEYS.includes('WiFiAddress'), true);
eq('model IDENTITY_KEYS does NOT carry lowercase WifiAddress', IDENTITY_KEYS.includes('WifiAddress'), false);

// ---------------- CODEX P0-2: CRITICAL config read-back (exact token/counter/deadline) ----
console.log('\n== CODEX P0-2: ci_criticalConfigReadback (identity + token + target + gen + counter + deadline) ==');
const idl = {SerialNumber:'F2LABC123', UniqueDeviceID:'00008030-DEAD', ModelNumber:'MQ9V3VN/A'};
const TOK = '1786470000|deadbeefcafe';
const live2 = {...idl, _ci_lic_tok:TOK};
const bids = ['vn.com.vng.zingalo','com.apple.mobilesafari'];
const GEN = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';
const CNT = 1786462800;
const NOW = 1786462800;
const DL  = NOW + 7200;                 // staged deadline, in the future
const okDisk = {...idl, _ci_lic_tok:TOK, targetBundles:bids,
  ['wipe_gen_'+bids[0]]:GEN, ['wipe_gen_'+bids[1]]:GEN,
  ['wipe_counter_'+bids[0]]:CNT, ['wipe_counter_'+bids[1]]:CNT,
  wipe_deadline:String(DL)};
const CRB = (over={}, dl=DL, now=NOW) =>
  criticalConfigReadback({...okDisk, ...over}, live2, IDENTITY_KEYS, bids, GEN, CNT, dl, now);
eq('P0-2 all critical keys correct → PASS', CRB(), true);
eq('P0-2 COUNTEREXAMPLE mirror MISSING token → FAIL',
   (()=>{const d={...okDisk}; delete d._ci_lic_tok; return criticalConfigReadback(d, live2, IDENTITY_KEYS, bids, GEN, CNT, DL, NOW);})(), false);
eq('P0-2 COUNTEREXAMPLE token WRONG → FAIL', CRB({_ci_lic_tok:'WRONG|x'}), false);
eq('P0-2 COUNTEREXAMPLE deadline "1" → FAIL (needs exact + future, not just nonempty)',
   criticalConfigReadback({...okDisk, wipe_deadline:'1'}, live2, IDENTITY_KEYS, bids, GEN, CNT, DL, NOW), false);
eq('P0-2 COUNTEREXAMPLE deadline in the PAST → FAIL',
   criticalConfigReadback({...okDisk, wipe_deadline:String(NOW-1)}, live2, IDENTITY_KEYS, bids, GEN, CNT, NOW-1, NOW), false);
eq('P0-2 COUNTEREXAMPLE OLD counter → FAIL', CRB({['wipe_counter_'+bids[1]]:CNT-100}), false);
eq('P0-2 COUNTEREXAMPLE targetBundles mismatch → FAIL', CRB({targetBundles:['vn.com.vng.zingalo']}), false);
eq('P0-2 COUNTEREXAMPLE a wipe_gen stale → FAIL', CRB({['wipe_gen_'+bids[1]]:'OLDGEN'}), false);
eq('P0-2 COUNTEREXAMPLE identity stale → FAIL (delegates to configMirrorMatches)', CRB({SerialNumber:'OLD'}), false);

// ---------------- CODEX P0-3: per-app wipe verification (no false greens) ----------------
console.log('\n== CODEX P0-3: wipe verify — subs clean + BOTH markers exact ==');
const cleanSub = {rmRc:0, mkdirRc:0, emptyRc:0};
const okApp = {name:'Zalo', subs:[cleanSub,cleanSub,cleanSub,cleanSub,cleanSub], lastRc:0, genRc:0, genChk:0};
eq('P0-3 all clean + both markers exact → wiped', wipeVerify(okApp).ok, true);
eq('P0-3 COUNTEREXAMPLE a sub emptyRc!=0 (dir missing/ls err/non-empty) → NOT wiped',
   wipeVerify({...okApp, subs:[cleanSub,{rmRc:0,mkdirRc:0,emptyRc:3},cleanSub,cleanSub,cleanSub]}).ok, false);
eq('P0-3 COUNTEREXAMPLE mkdirRc!=0 → NOT wiped',
   wipeVerify({...okApp, subs:[{rmRc:0,mkdirRc:1,emptyRc:0},cleanSub,cleanSub,cleanSub,cleanSub]}).ok, false);
eq('P0-3 COUNTEREXAMPLE rmRc!=0 → NOT wiped',
   wipeVerify({...okApp, subs:[{rmRc:1,mkdirRc:0,emptyRc:0},cleanSub,cleanSub,cleanSub,cleanSub]}).ok, false);
eq('P0-3 COUNTEREXAMPLE .ci_last_wipe counter mismatch (lastRc!=0) → NOT wiped, reason last_wipe',
   wipeVerify({...okApp, lastRc:1}).reasons.includes('last_wipe'), true);
eq('P0-3 COUNTEREXAMPLE .ci_gen mismatch (genChk!=0) → NOT wiped, reason gen',
   wipeVerify({...okApp, genChk:1}).reasons.includes('gen'), true);
eq('P0-3 gen write fail (genRc!=0) → NOT wiped (one-shot keychain would not run)',
   wipeVerify({...okApp, genRc:1}).ok, false);

// ---------------- NON-GATING benchmark ----------------
const N=200000, p='/System/Library/PrivateFrameworks/Foo.framework/Bar/qux.dylib';
let t=process.hrtime.bigint(); for(let i=0;i<N;i++) canonStatus(p,null); let ns=Number(process.hrtime.bigint()-t)/N;
console.log(`\n[NON-GATING] JS canonStatus: ${ns.toFixed(0)} ns/call over ${N} (JS ONLY; says nothing about compiled C perf).`);

console.log(`\n${fails===0?'ALL MODEL ASSERTIONS PASS (MODEL-PASS; COMPILED-NOT-RUN)':'FAILURES: '+fails}`);
process.exit(fails===0?0:1);
