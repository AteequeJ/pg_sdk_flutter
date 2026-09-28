import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pg_models.dart';
import 'pg_result.dart';

/// Entry point for the Payment Gateway SDK.
///
/// ```dart
/// // App start:
/// await PGCheckout.instance.configure(PGConfig(
///   publishableKey: 'pk_live_...',
///   merchantDisplayName: 'Acme Store',
///   android: PGAndroidOptions(
///     merchantId: 'acme',
///     backendBaseUrl: 'https://api.gateway.example.com/',
///   ),
///   ios: PGIosOptions(callbackUrlScheme: 'acmestore'),
/// ));
///
/// // Checkout, for an order created by your backend:
/// final result = await PGCheckout.instance.startPayment(PGPaymentRequest(
///   orderId: order.id,
///   orderToken: order.token,
///   amountMinor: 49900,
/// ));
/// switch (result) {
///   case PGPaymentSuccess(): // verify on your backend before fulfilling
///   case PGPaymentPending(): // wait for webhook / poll
///   case PGPaymentFailure(:final error): // show error.message
///   case PGPaymentCancelled():
/// }
/// ```
///
/// Opens the native iOS / Android checkout UI; the payment itself is handled
/// by the native SDKs.
class PGCheckout {
  @visibleForTesting
  PGCheckout.withChannel(this._channel);

  static final PGCheckout instance =
      PGCheckout.withChannel(const MethodChannel('com.pgsdk/flutter'));

  final MethodChannel _channel;
  bool _isConfigured = false;
  bool _paymentInProgress = false;

  bool get isConfigured => _isConfigured;

  static const _secretKeyPrefixes = ['sk_', 'sk-', 'secret_', 'server_'];

  /// Configures the native SDK. Call once at app start, before
  /// [startPayment]. Calling again reconfigures it.
  ///
  /// Throws [PGError] with [PGErrorCode.invalidConfig] if [config] is
  /// invalid.
  Future<void> configure(PGConfig config) async {
    _validate(config);
    try {
      await _channel.invokeMethod<void>('configure', config.toMap());
      _isConfigured = true;
    } on PlatformException catch (e) {
      throw PGError(
        code: e.code,
        message: e.message ?? 'Configuration was rejected by the native SDK.',
      );
    }
  }

  /// Presents the native checkout UI and completes with its final outcome.
  ///
  /// Never throws: problems (not configured, invalid request, a payment
  /// already in progress) come back as a [PGPaymentFailure].
  Future<PGPaymentResult> startPayment(PGPaymentRequest request) async {
    PGPaymentFailure fail(String code, String message) => PGPaymentFailure(
          orderId: request.orderId,
          orderToken: request.orderToken,
          error: PGError(code: code, message: message),
        );

    if (!_isConfigured) {
      return fail(PGErrorCode.notInitialized,
          'PGCheckout.instance.configure() must be called before startPayment().');
    }
    final requestError = _requestError(request);
    if (requestError != null) {
      return fail(PGErrorCode.invalidRequest, requestError);
    }
    if (_paymentInProgress) {
      return fail(PGErrorCode.invalidRequest, 'A payment is already in progress.');
    }

    _paymentInProgress = true;
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>(
          'startPayment', request.toMap());
      if (map == null) {
        return fail(PGErrorCode.unknown, 'Checkout finished without a result.');
      }
      return PGPaymentResult.fromMap(map, request);
    } on PlatformException catch (e) {
      return fail(e.code, e.message ?? 'Checkout failed.');
    } finally {
      _paymentInProgress = false;
    }
  }

  void _validate(PGConfig config) {
    Never invalid(String message) =>
        throw PGError(code: PGErrorCode.invalidConfig, message: message);

    final key = config.publishableKey.trim().toLowerCase();
    if (key.isEmpty) invalid('publishableKey must not be empty.');
    if (_secretKeyPrefixes.any(key.startsWith) || key.contains('secret')) {
      invalid('publishableKey looks like a secret key. Only publishable keys '
          'may be embedded in the app; secret keys belong on your backend.');
    }
    if (config.merchantDisplayName.trim().isEmpty) {
      invalid('merchantDisplayName must not be empty.');
    }
    if (config.allowedPaymentMethods.isEmpty) {
      invalid('allowedPaymentMethods must not be empty.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final android = config.android;
        if (android == null) invalid('PGConfig.android is required on Android.');
        if (android.merchantId.trim().isEmpty) {
          invalid('android.merchantId must not be empty.');
        }
        if (android.backendBaseUrl.trim().isEmpty) {
          invalid('android.backendBaseUrl must not be empty.');
        }
      case TargetPlatform.iOS:
        final ios = config.ios;
        if (ios == null) invalid('PGConfig.ios is required on iOS.');
        if (ios.callbackUrlScheme.trim().isEmpty) {
          invalid('ios.callbackUrlScheme must not be empty.');
        }
      default:
        invalid('pg_flutter_sdk supports only Android and iOS.');
    }
  }

  static String? _requestError(PGPaymentRequest request) {
    if (request.orderId.trim().isEmpty) return 'orderId must not be empty.';
    if (request.orderToken.trim().isEmpty) return 'orderToken must not be empty.';
    if (request.amountMinor <= 0) return 'amountMinor must be greater than zero.';
    if (!RegExp(r'^[A-Za-z]{3}$').hasMatch(request.currency)) {
      return 'currency must be a 3-letter ISO 4217 code.';
    }
    if (request.allowedMethods?.isEmpty ?? false) {
      return 'allowedMethods must not be empty when set.';
    }
    return null;
  }
}
