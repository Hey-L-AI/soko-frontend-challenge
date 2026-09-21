## 2.3.1+heyl.2 (vendored)

Restore the FileProvider registration that the initial vendoring dropped:

4. `android/src/main/AndroidManifest.xml` — re-added the `<provider>`
   registering `SocialSharePluginFileProvider` with authority
   `${applicationId}.com.shekarmudaliyar.social_share`.
5. `android/src/main/res/xml/filepaths.xml` — re-added the FileProvider
   path whitelist (cache-path/files-path/external-path).

Without these two resources, `FileProvider.getUriForFile(...)` in
`SocialSharePlugin.kt` throws `IllegalArgumentException` at share time and
the Instagram Story handoff fails on Android (iOS is unaffected — it uses
`UIPasteboard` + `instagram-stories://`, not FileProvider). This is why
PROD-2785 shipped working on iOS but broken on Android.

## 2.3.1+heyl.1 (vendored)

Local fork of upstream 2.3.1 for the HeyL app. The published package is
unmaintained and doesn't build against Flutter 3.38 + AGP 8. Three patches:

1. `android/build.gradle` — added `namespace`, bumped `compileSdk` 28 → 35,
   raised `minSdkVersion` 16 → 21 (matches app), dropped the legacy buildscript
   classpath / jcenter block (host project supplies AGP + Kotlin).
2. `android/src/main/AndroidManifest.xml` — removed the `package=` attribute
   (redundant now that `namespace` is set in the build.gradle).
3. `SocialSharePlugin.kt` — removed the unused
   `io.flutter.plugin.common.PluginRegistry.Registrar` import (v1 embedding
   was removed in Flutter 3.29+).

Nothing else changed. If we later drop this dep or move to a maintained fork,
delete `heyl_app/third_party/social_share/` and revert the `pubspec.yaml`
entry back to `social_share: ^2.3.1` (or the replacement).

## 2.3.1

### Changes for the new version is done by [dpacchi](https://github.com/dpacchi) 🙌🙌

- Support for image background in both Facebook and Instagram stories
- Support for video background in both Facebook and Instagram stories
- Facebook App Id support in instagram stories (required starting december 2022)
- Clipboard sharing fixes
- Example updated and fixed using the latest flutter release

## 2.2.1

- migrated to android v2 embedding
- imporved null safety

## 2.1.1

- Val reassign error fix

## 2.1.0

- Migrated to null saftey

## 2.0.6

- shareInstagramStory refactor
- URI parsing fixes
- build error fixes

## 2.0.5

- shareOptions without image fixed

## 2.0.3

- shareTelegram added to direct share on telegram

## 2.0.2

- sharetwitter url fixes

## 2.0.1

- changed file provider directory

## 2.0.0

- added support for android

## 1.0.7

- added trailing text parameter in twitter and sms

## 1.0.4

- added url parameter in sharetwitter

## 1.0.2

- added check installed apps

## 1.0.0

- modified share facebook story method
- added copy to clipboard
- Added share on Instagram story with background.
- Added share on Twitter
- Added share with Sms
- Added share on Whatsapp
- Added default share options

## 0.0.1

- Added share on Instagram story.
- Added share on Facebook story.
