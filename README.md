# pg_flutter_sdk

Flutter plugin for the PG Payment SDK: UPI, card and net-banking checkout
with a typed success / pending / failure / cancelled result.

It's a thin bridge. The Dart API calls the native SDKs, which present
their own checkout UI and do all networking, storage and pinning:

| Platform | Native SDK | Where it comes from |
|---|---|---|
| Android | `io.github.ateequej:paymentsdk` | Maven Central |
| iOS | `PGPaymentSDK` (XCFramework) | GitHub release, downloaded on `pod install` |

```
lib/                 Dart API (PGCheckout, PGConfig, PGPaymentRequest, PGPaymentResult)
android/             Kotlin bridge → PGPaymentSDK / PGPaymentContract
ios/                 Swift bridge → PGCheckout; forwards callback URLs automatically
scripts/sync_native.sh   local dev only: builds both native SDKs from sibling repos
example/             demo app running against an in-process mock gateway
```

## Requirements

- Flutter 3.38+ (Dart 3.10+)
- Android minSdk 24
- iOS 15.0+

## Adding it to an app

```sh
flutter pub add pg_flutter_sdk
```

**Android.** Nothing extra; the native SDK resolves from Maven Central.

**iOS.** Set `platform :ios, '15.0'` in `ios/Podfile`, then add to `Info.plist`:

```xml
<!-- Scheme UPI apps / bank pages return to; must equal PGIosOptions.callbackUrlScheme -->
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLSchemes</key>
  <array><string>acmestore</string></array>
</dict></array>
<!-- UPI apps the SDK may open -->
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>tez</string><string>phonepe</string><string>paytmmp</string>
  <string>bhim</string><string>credpay</string>
</array>
```

You don't need any AppDelegate/SceneDelegate code. The plugin forwards
callback URLs to the SDK itself.

## Usage

```dart
import 'package:pg_flutter_sdk/pg_flutter_sdk.dart';

// Once, at startup. Throws PGError(invalid_config) on bad config.
await PGCheckout.instance.configure(const PGConfig(
  publishableKey: 'pk_live_...',          // never a secret key
  merchantDisplayName: 'Acme Store',
  environment: PGEnvironment.production,
  android: PGAndroidOptions(
    merchantId: 'acme',
    backendBaseUrl: 'https://api.gateway.example.com/',
  ),
  ios: PGIosOptions(callbackUrlScheme: 'acmestore'),
));

// Per checkout, for an order YOUR backend created. Never throws.
final result = await PGCheckout.instance.startPayment(PGPaymentRequest(
  orderId: order.id,
  orderToken: order.token,
  amountMinor: 49900,                     // ₹499.00
));

switch (result) {
  case PGPaymentSuccess(:final paymentId, :final verificationReference):
    // Verify on your backend before fulfilling. This is NOT proof of payment.
  case PGPaymentPending():
    // Don't fulfill yet; wait for the webhook / poll your backend.
  case PGPaymentFailure(:final error):
    // error.code is one of PGErrorCode; error.isRetryable
  case PGPaymentCancelled():
}
```

### Platform differences

The Dart API is the same on both platforms. A few options apply to only one:

| Option | Android | iOS |
|---|---|---|
| `PGConfig.android` (`merchantId`, `backendBaseUrl`, timeouts) | required | ignored |
| `PGConfig.ios` (`callbackUrlScheme`, `customBaseUrl`, pinning) | ignored | required |
| `PGTheme.primaryColor` | ✓ | ✓ |
| `PGTheme.onPrimaryColor` | ✓ | – |
| `PGPaymentRequest.description` | ✓ | – |
| `PGPaymentRequest.allowedMethods`, `upiFlow` | – (use `PGConfig.allowedPaymentMethods`) | ✓ |
| `PGPaymentSuccess.verificationReference` | gateway `rawReference` | ✓ |

Error codes are the Android SDK's `PGErrorCode` values on both platforms.
iOS `PGError` cases are mapped onto them.

## Security

The native SDKs' security model applies unchanged. In short:

- Only ever pass a **publishable** key. `configure` rejects keys that look secret.
- Your backend creates orders with the secret key; the app only sees `orderToken`.
- A success result is not proof of payment. Always verify server-side.

See the [iOS SDK README](https://github.com/AteequeJ/pg_sdk_ios/blob/main/README.md)
and the [Android SDK docs](https://github.com/AteequeJ/pg_sdk_android/tree/main/docs)
for the full details.

## Example app

```sh
cd example && flutter run
```

Its native code (`MainActivity.kt`, `AppDelegate.swift`) installs a mock
gateway through `PgFlutterSdkPlugin.debugInterceptors` /
`debugURLProtocolClasses`. The native SDKs reject these hooks in
production. Test values: card `4242 4242 4242 4242` succeeds; UPI ID
`success@upi` succeeds and `failure@upi` fails.

## Tests

```sh
flutter test      # Dart API, validation and result decoding (mocked channel)
```

## Developing against local native SDKs

Clone `pg_sdk_android` and `pg_ios_sdk` next to this repo, then run:

```sh
scripts/sync_native.sh          # both; or `android` / `ios`
```

This publishes the Android AAR to `~/.m2` (the example app checks `mavenLocal`
first) and copies `PGPaymentSDK.xcframework` into `ios/Frameworks/`, which the
podspec uses instead of downloading. Delete `ios/Frameworks/` to go back to the
released framework.

## Releasing

1. Android: publish `io.github.ateequej:paymentsdk:<version>` to Maven Central
   and bump the version in `android/build.gradle.kts`.
2. iOS: zip the XCFramework (`ditto -c -k --keepParent PGPaymentSDK.xcframework PGPaymentSDK.xcframework.zip`),
   attach it to a `pg_sdk_ios` GitHub release, and update `PG_SDK_VERSION` /
   `PG_SDK_SHA256` in `ios/pg_flutter_sdk.podspec` (`shasum -a 256 <zip>`).
3. Bump `version` in `pubspec.yaml` and the podspec, update `CHANGELOG.md`.
4. `flutter pub publish --dry-run`, then `flutter pub publish`.
