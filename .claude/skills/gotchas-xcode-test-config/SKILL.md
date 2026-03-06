---
name: gotchas-xcode-test-config
description: Use when Xcode unit tests won't run, Product > Test is greyed out, Cmd+U does nothing, or "no test bundles available" error appears.
user-invocable: false
---

# Gotcha: Xcode Test Target Not Running

**Trigger**: unit tests, xcode, test bundle, cmd+u, no test bundles, product test greyed out, test host, code signing tests
**Confidence**: high
**Created**: 2026-03-06
**Updated**: 2026-03-06
**Version**: 1

## Symptom

- Product > Test is greyed out in Xcode menu
- Cmd+U does nothing or shows no targets
- Test Plans UI shows "0 test targets"
- Message: *"There are no test bundles available to test"*
- Or: *"Could not find test host for KindleSyncTests"*
- Or: *"code signature not valid — mapping process and mapped file have different Team IDs"*

## Root Causes & Fixes (apply in order — each fix may reveal the next issue)

### 1. Test target missing from scheme's BuildAction

The scheme must list the test target with `buildForTesting = "YES"`. Without it, Xcode never builds the `.xctest` bundle.

Fix in `KindleSync.xcodeproj/xcshareddata/xcschemes/KindleSync.xcscheme` — add inside `<BuildActionEntries>`:

```xml
<BuildActionEntry
   buildForTesting = "YES"
   buildForRunning = "NO"
   buildForProfiling = "NO"
   buildForArchiving = "NO"
   buildForAnalyzing = "NO">
   <BuildableReference
      BuildableIdentifier = "primary"
      BlueprintIdentifier = "AA000019"
      BuildableName = "KindleSyncTests.xctest"
      BlueprintName = "KindleSyncTests"
      ReferencedContainer = "container:KindleSync.xcodeproj">
   </BuildableReference>
</BuildActionEntry>
```

### 2. TEST_HOST path has wrong app bundle name

`TEST_HOST` in `project.pbxproj` must match the *actual* built app bundle name. The product name comes from `TARGET_NAME` — which may or may not match a display name with spaces.

In KindleSync: `PRODUCT_NAME = "$(TARGET_NAME)"` builds as `KindleSync.app`, but TEST_HOST was set to `Kindle Sync.app` (with space) — causing "Could not find test host."

Fix in both Debug and Release configs for the test target in `project.pbxproj`:
```
TEST_HOST = "$(BUILT_PRODUCTS_DIR)/KindleSync.app/Contents/MacOS/KindleSync";
```

Verify actual name: `ls ~/Library/Developer/Xcode/DerivedData/KindleSync-*/Build/Products/Debug/`

### 3. DEVELOPMENT_TEAM mismatch → code signing failure at runtime

If the app target has `DEVELOPMENT_TEAM = XYZ` and the test target has `DEVELOPMENT_TEAM = ""`, macOS `dlopen` rejects the test bundle at load time: *"different Team IDs"*.

Fix: match the test target's `DEVELOPMENT_TEAM` to the app target's value in both Debug and Release configs:
```bash
grep DEVELOPMENT_TEAM KindleSync.xcodeproj/project.pbxproj
# Find the team ID on the app target, copy to test target
```

### 4. Missing GENERATE_INFOPLIST_FILE

Without this, code signing fails at build time: *"Cannot code sign because the target does not have an Info.plist file."*

Fix: add to both Debug and Release build settings for the test target:
```
GENERATE_INFOPLIST_FILE = YES;
```

## Diagnosis Commands

```bash
# See what targets/schemes xcodebuild sees
xcodebuild -list

# Run tests from CLI — shows real errors before Xcode UI masks them
xcodebuild test -scheme KindleSync -destination 'platform=macOS' 2>&1 | grep -E "error:|Test Suite|passed|failed"

# Check actual built app name
ls ~/Library/Developer/Xcode/DerivedData/KindleSync-*/Build/Products/Debug/

# Check TEST_HOST and DEVELOPMENT_TEAM settings
grep -n "TEST_HOST\|DEVELOPMENT_TEAM\|GENERATE_INFOPLIST" KindleSync.xcodeproj/project.pbxproj
```

## Prevention

When creating a test target by hand (via `project.pbxproj` edits rather than Xcode UI), always set all four:
1. `BuildAction` entry in scheme with `buildForTesting = "YES"`
2. `TEST_HOST` pointing to correct app bundle name
3. `DEVELOPMENT_TEAM` matching app target
4. `GENERATE_INFOPLIST_FILE = YES`
