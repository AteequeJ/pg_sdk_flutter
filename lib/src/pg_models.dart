import 'dart:ui' show Color;

/// Which gateway environment the SDK talks to.
enum PGEnvironment { sandbox, production }

/// Payment methods the checkout UI can offer.
enum PGPaymentMethod {
  upi('upi'),
  card('card'),
  netBanking('net_banking');

  const PGPaymentMethod(this.wireValue);

  /// Value used on the platform channel and by the gateway's REST API.
  final String wireValue;

  static PGPaymentMethod? fromWireValue(Object? value) {
    for (final method in values) {
      if (method.wireValue == value) return method;
    }
    return null;
  }
}

/// How a UPI payment is collected. Honoured on iOS; the Android SDK picks the
/// flow itself (intent when a UPI app is installed, collect otherwise).
enum PGUpiFlow { intent, collect }

/// Optional brand colours for the native checkout UI.
class PGTheme {
  const PGTheme({this.primaryColor, this.onPrimaryColor});

  /// Buttons, highlights and the amount header.
  final Color? primaryColor;

  /// Text/icons drawn on top of [primaryColor]. Android only.
  final Color? onPrimaryColor;

  Map<String, Object?> toMap() => {
        'primaryColor': primaryColor?.toARGB32(),
        'onPrimaryColor': onPrimaryColor?.toARGB32(),
      };
}

/// Android-only configuration.
class PGAndroidOptions {
  const PGAndroidOptions({
    required this.merchantId,
    required this.backendBaseUrl,
    this.connectTimeoutSeconds = 15,
    this.readTimeoutSeconds = 30,
  });

  /// Your merchant/account identifier, used for display and analytics.
  final String merchantId;

  /// Base URL of the payment gateway's API, e.g.
  /// `https://api.gateway.example.com/`. Must be HTTPS (plain http is allowed
  /// only for localhost / 10.0.2.2 in [PGEnvironment.sandbox]).
  final String backendBaseUrl;

  final int connectTimeoutSeconds;
  final int readTimeoutSeconds;

  Map<String, Object?> toMap() => {
        'merchantId': merchantId,
        'backendBaseUrl': backendBaseUrl,
        'connectTimeoutSeconds': connectTimeoutSeconds,
        'readTimeoutSeconds': readTimeoutSeconds,
      };
}

/// iOS-only configuration.
class PGIosOptions {
  const PGIosOptions({
    required this.callbackUrlScheme,
    this.customBaseUrl,
    this.requestTimeoutSeconds = 30,
    this.pinnedSpkiHashes,
  });

  /// URL scheme registered in your app's `Info.plist` (`CFBundleURLTypes`)
  /// that UPI apps and bank pages return to. The plugin forwards matching
  /// URLs to the SDK automatically.
  final String callbackUrlScheme;

  /// Overrides the gateway host implied by [PGConfig.environment].
  final String? customBaseUrl;

  final double requestTimeoutSeconds;

  /// Base64-encoded SHA-256 SPKI hashes to pin the gateway's TLS
  /// certificate against. `null` disables pinning.
  final Set<String>? pinnedSpkiHashes;

  Map<String, Object?> toMap() => {
        'callbackUrlScheme': callbackUrlScheme,
        'customBaseUrl': customBaseUrl,
        'requestTimeoutSeconds': requestTimeoutSeconds,
        'pinnedSpkiHashes': pinnedSpkiHashes?.toList(),
      };
}

/// SDK-wide configuration, passed once to `PGCheckout.instance.configure`.
///
/// [publishableKey] must be a client-safe **publishable** key. Secret keys
/// belong on your backend only; `configure` rejects keys that look secret.
class PGConfig {
  const PGConfig({
    required this.publishableKey,
    required this.merchantDisplayName,
    this.environment = PGEnvironment.production,
    this.enableLogging = false,
    this.allowedPaymentMethods = PGPaymentMethod.values,
    this.theme = const PGTheme(),
    this.android,
    this.ios,
  });

  final String publishableKey;

  /// Shown in the checkout UI's header, e.g. "Acme Store".
  final String merchantDisplayName;

  final PGEnvironment environment;

  /// Verbose native SDK logs. Keep `false` in production builds.
  final bool enableLogging;

  /// Methods the checkout may offer. A request's own
  /// [PGPaymentRequest.allowedMethods] narrows this further.
  final List<PGPaymentMethod> allowedPaymentMethods;

  final PGTheme theme;

  /// Required when running on Android.
  final PGAndroidOptions? android;

  /// Required when running on iOS.
  final PGIosOptions? ios;

  Map<String, Object?> toMap() => {
        'publishableKey': publishableKey,
        'merchantDisplayName': merchantDisplayName,
        'environment': environment.name,
        'enableLogging': enableLogging,
        'allowedPaymentMethods':
            allowedPaymentMethods.map((m) => m.wireValue).toList(),
        'theme': theme.toMap(),
        'android': android?.toMap(),
        'ios': ios?.toMap(),
      };
}

class PGCustomerInfo {
  const PGCustomerInfo({this.name, this.email, this.phone});

  final String? name;
  final String? email;
  final String? phone;

  Map<String, Object?> toMap() => {'name': name, 'email': email, 'phone': phone};
}

/// A single checkout, for an order your **backend** has already created.
class PGPaymentRequest {
  const PGPaymentRequest({
    required this.orderId,
    required this.orderToken,
    required this.amountMinor,
    this.currency = 'INR',
    this.description,
    this.customer,
    this.metadata = const {},
    this.allowedMethods,
    this.upiFlow = PGUpiFlow.intent,
  });

  /// Your order identifier.
  final String orderId;

  /// Opaque token your backend received from the gateway when creating the
  /// order.
  final String orderToken;

  /// Amount in minor units (paise for INR): ₹499.00 → `49900`.
  final int amountMinor;

  /// 3-letter ISO 4217 code.
  final String currency;

  final String? description;
  final PGCustomerInfo? customer;

  /// Free-form key/values passed to the gateway with the attempt.
  final Map<String, String> metadata;

  /// Narrows [PGConfig.allowedPaymentMethods] for this checkout. iOS only.
  final List<PGPaymentMethod>? allowedMethods;

  /// iOS only; see [PGUpiFlow].
  final PGUpiFlow upiFlow;

  Map<String, Object?> toMap() => {
        'orderId': orderId,
        'orderToken': orderToken,
        'amountMinor': amountMinor,
        'currency': currency,
        'description': description,
        'customer': customer?.toMap(),
        'metadata': metadata,
        'allowedMethods': allowedMethods?.map((m) => m.wireValue).toList(),
        'upiFlow': upiFlow.name,
      };
}
