# Contact Seeding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Change Device step that replaces the previous HIOS-generated Contacts batch with 30-100 random contacts from the bundled user-provided phone pool.

**Architecture:** Keep the feature in the host app because it owns the Change Device flow and already performs privileged local data operations. Bundle the phone pool as an app resource, parse it in a focused helper block in `app/main.m`, create Contacts through `Contacts.framework`, and track only generated contact identifiers in `/var/jb/etc/changeinfoios/generated_contacts.plist`.

**Tech Stack:** Objective-C, UIKit app, Theos application packaging, `Contacts.framework`, plist persistence.

---

### Task 1: Bundle Contacts Pool And Permissions

**Files:**
- Modify: `app/Makefile`
- Modify: `app/Resources/Info.plist`
- Modify: `app/entitlements.plist`
- Copy: `hA0E199i20bhyt.txt` to `app/Resources/contacts_pool.txt`

- [ ] **Step 1: Copy the pool into app resources**

Run:

```powershell
Copy-Item -LiteralPath .\hA0E199i20bhyt.txt -Destination .\app\Resources\contacts_pool.txt -Force
```

Expected: `app/Resources/contacts_pool.txt` exists and has the same byte size as `hA0E199i20bhyt.txt`.

- [ ] **Step 2: Link Contacts.framework**

Change `app/Makefile` from:

```make
HIOSFakerV3_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia Photos Security
```

to:

```make
HIOSFakerV3_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia Photos Security Contacts
```

- [ ] **Step 3: Add Contacts usage string**

Insert in `app/Resources/Info.plist` near the other usage descriptions:

```xml
<key>NSContactsUsageDescription</key>
<string>HIOS Faker tao danh ba goi y tu danh sach lien he cua ban sau moi lan Change Device.</string>
```

- [ ] **Step 4: Pre-grant Contacts TCC service**

Add this string inside `com.apple.private.tcc.allow` in `app/entitlements.plist`:

```xml
<string>kTCCServiceAddressBook</string>
```

- [ ] **Step 5: Verify resource and metadata edits**

Run:

```powershell
Test-Path .\app\Resources\contacts_pool.txt
Select-String -Path .\app\Makefile -Pattern "Contacts"
Select-String -Path .\app\Resources\Info.plist -Pattern "NSContactsUsageDescription"
Select-String -Path .\app\entitlements.plist -Pattern "kTCCServiceAddressBook"
```

Expected: all commands print matching results.

### Task 2: Add Contact Seeding Helpers

**Files:**
- Modify: `app/main.m`

- [ ] **Step 1: Import Contacts**

Add beside the existing framework imports:

```objc
#import <Contacts/Contacts.h>
```

- [ ] **Step 2: Add helper functions before reset/RRS helpers**

Add a focused helper block before `ci_wipeSafariDeep`:

```objc
static NSString *CIContactsPoolPath(void);
static NSString *CIContactsGeneratedPath(void);
static NSString *ci_normalizeVNPhone(NSString *raw);
static NSArray<NSString *> *ci_loadContactPool(void);
static NSString *ci_randomVietnameseFullName(void);
static NSUInteger ci_seedRandomContacts(void);
```

Then implement the helpers in the same block:

```objc
static NSString *CIContactsPoolPath(void) {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"contacts_pool" ofType:@"txt"];
    return p ?: @"";
}

static NSString *CIContactsGeneratedPath(void) {
    return @"/var/jb/etc/changeinfoios/generated_contacts.plist";
}
```

The helper block parses whitespace-separated numbers with `NSRegularExpression`, normalizes local/VN numbers to `+84...`, deletes only identifiers listed in `generated_contacts.plist`, creates 30-100 `CNMutableContact` entries, and saves the new identifiers back to the plist.

- [ ] **Step 3: Keep generated contact deletion scoped**

Deletion must follow this pattern:

```objc
NSArray *ids = [NSArray arrayWithContentsOfFile:CIContactsGeneratedPath()] ?: @[];
for (NSString *ident in ids) {
    CNContact *c = [store unifiedContactWithIdentifier:ident keysToFetch:@[] error:nil];
    if (c) [request deleteContact:[c mutableCopy]];
}
```

Do not delete contacts by name, phone number, or broad enumeration.

- [ ] **Step 4: Verify parser assumptions locally**

Run:

```powershell
$raw = Get-Content -Raw .\app\Resources\contacts_pool.txt
$nums = [regex]::Matches($raw, '\b\d{8,15}\b') | ForEach-Object { $_.Value }
@{ Count = $nums.Count; Unique = (@($nums | Sort-Object -Unique).Count) }
```

Expected: Count and Unique are both `5052`.

### Task 3: Wire Into Change Device Flow

**Files:**
- Modify: `app/main.m`

- [ ] **Step 1: Call the seeder after identity generation**

In `performRRSBackupLicensed`, immediately after:

```objc
ci_randomizeIdentities();
NSLog(@"[ChangeInfoIos] Step 1 done: fake identities generated");
```

add:

```objc
NSUInteger seededContacts = ci_seedRandomContacts();
NSLog(@"[ChangeInfoIos] Step 1 contacts seeded: %lu", (unsigned long)seededContacts);
```

- [ ] **Step 2: Surface the result in the success alert**

In the final success body, add a short line:

```objc
[body appendFormat:@"Danh ba goi y: %lu contact moi\n", (unsigned long)seededContacts];
```

This value is informational. The Change Device flow continues if contact seeding returns `0`.

- [ ] **Step 3: Verify Objective-C scope**

`seededContacts` is declared inside the dispatch block and used only inside that same block, including the nested final alert block. Objective-C blocks capture it by value, which is correct because it is not mutated later.

### Task 4: Build Verification

**Files:**
- Verify: `app/main.m`
- Verify: `app/Makefile`
- Verify: `app/Resources/Info.plist`
- Verify: `app/entitlements.plist`

- [ ] **Step 1: Static scan**

Run:

```powershell
Select-String -Path .\app\main.m -Pattern "Contacts/Contacts.h|ci_seedRandomContacts|generated_contacts.plist"
Select-String -Path .\app\Makefile -Pattern "Contacts"
Select-String -Path .\app\Resources\Info.plist -Pattern "NSContactsUsageDescription"
```

Expected: each command prints at least one match.

- [ ] **Step 2: Build if Theos is available**

Run from `app/`:

```powershell
make package FINALPACKAGE=1 ARCHS=arm64
```

Expected: Theos compiles `main.m` and produces a package under `app/packages/`. If Theos is unavailable on Windows, record that local build could not be run and rely on GitHub Actions/macOS build.

- [ ] **Step 3: Manual device verification**

Install the package, run Change Device twice, and verify:

1. The first run creates 30-100 Contacts.
2. The second run removes the first HIOS batch and creates a new 30-100 batch.
3. Contacts that were not generated by HIOS remain untouched.
4. Zalo sees a non-empty address book after its next cold launch.
