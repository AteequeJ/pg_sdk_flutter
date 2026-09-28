import 'pg_models.dart';

/// Error codes shared by both platforms (they match the Android SDK's
/// `PGErrorCode`; the iOS bridge maps its `PGError` cases onto them).
abstract final class PGErrorCode {
  static const notInitialized = 'sdk_not_initialized';
  static const invalidConfig = 'invalid_config';
  static const invalidRequest = 'invalid_request';
  static const networkError = 'network_error';
  static const timeout = 'timeout';
  static const serverError = 'server_error';
  static const paymentDeclined = 'payment_declined';
  static const noUpiAppFound = 'no_upi_app_found';
  static const userCancelled = 'user_cancelled';
  static const unknown = 'unknown_error';
}

/// A failure reported by the SDK. Thrown by `PGCheckout.configure`, and
/// carried by [PGPaymentFailure].
class PGError implements Exception {
  const PGError({
    required this.code,
    required this.message,
    this.isRetryable = false,
  });

  /// One of the [PGErrorCode] values.
  final String code;
  final String message;
  final bool isRetryable;

  factory PGError.fromMap(Map<Object?, Object?> map) => PGError(
        code: map['code'] as String? ?? PGErrorCode.unknown,
        message: map['message'] as String? ?? 'Unknown error.',
        isRetryable: map['isRetryable'] as bool? ?? false,
      );

  @override
  String toString() => 'PGError($code): $message';
}

/// Final outcome of `PGCheckout.startPayment`, delivered exactly once.
///
/// **A [PGPaymentSuccess] is not proof of payment.** Always verify the
/// payment on your backend (webhook and/or the gateway's server-side API with
/// your secret key) before fulfilling the order.
sealed class PGPaymentResult {
  const PGPaymentResult({required this.orderId, required this.orderToken});

  /// From the [PGPaymentRequest] this checkout was started with.
  final String orderId;

  /// From the [PGPaymentRequest] this checkout was started with.
  final String orderToken;

  /// Decodes the platform channel's result map for [request].
  factory PGPaymentResult.fromMap(
    Map<Object?, Object?> map,
    PGPaymentRequest request,
  ) {
    final orderId = request.orderId;
    final orderToken = request.orderToken;
    final method = PGPaymentMethod.fromWireValue(map['method']);
    switch (map['status']) {
      case 'success':
        return PGPaymentSuccess(
          orderId: orderId,
          orderToken: orderToken,
          paymentId: map['paymentId'] as String? ?? '',
          method: method,
          verificationReference: map['verificationReference'] as String?,
          rawFields: (map['rawFields'] as Map<Object?, Object?>?)
                  ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
              const {},
        );
      case 'pending':
        return PGPaymentPending(
          orderId: orderId,
          orderToken: orderToken,
          paymentId: map['paymentId'] as String?,
          method: method,
          message: map['message'] as String?,
        );
      case 'cancelled':
        return PGPaymentCancelled(
          orderId: orderId,
          orderToken: orderToken,
          paymentId: map['paymentId'] as String?,
        );
      case 'failure':
        final error = map['error'];
        return PGPaymentFailure(
          orderId: orderId,
          orderToken: orderToken,
          error: error is Map<Object?, Object?>
              ? PGError.fromMap(error)
              : const PGError(code: PGErrorCode.unknown, message: 'Unknown error.'),
        );
      default:
        return PGPaymentFailure(
          orderId: orderId,
          orderToken: orderToken,
          error: PGError(
            code: PGErrorCode.unknown,
            message: 'Unrecognised result status: ${map['status']}',
          ),
        );
    }
  }
}

/// The gateway reported success to the client. Verify server-side before
/// fulfilling.
final class PGPaymentSuccess extends PGPaymentResult {
  const PGPaymentSuccess({
    required super.orderId,
    required super.orderToken,
    required this.paymentId,
    this.method,
    this.verificationReference,
    this.rawFields = const {},
  });

  /// Gateway-assigned payment identifier.
  final String paymentId;
  final PGPaymentMethod? method;

  /// Opaque signature/reference for your backend's verification call.
  final String? verificationReference;

  /// Raw provider fields, for diagnostics only.
  final Map<String, String> rawFields;

  @override
  String toString() => 'PGPaymentSuccess(orderId: $orderId, paymentId: $paymentId, method: $method)';
}

/// Accepted but not final yet (common for UPI collect and some net banking).
/// Don't fulfill until your backend learns the outcome via webhook or poll.
final class PGPaymentPending extends PGPaymentResult {
  const PGPaymentPending({
    required super.orderId,
    required super.orderToken,
    this.paymentId,
    this.method,
    this.message,
  });

  final String? paymentId;
  final PGPaymentMethod? method;
  final String? message;

  @override
  String toString() => 'PGPaymentPending(orderId: $orderId, paymentId: $paymentId)';
}

final class PGPaymentFailure extends PGPaymentResult {
  const PGPaymentFailure({
    required super.orderId,
    required super.orderToken,
    required this.error,
  });

  final PGError error;

  @override
  String toString() => 'PGPaymentFailure(orderId: $orderId, error: $error)';
}

/// The user backed out of checkout.
final class PGPaymentCancelled extends PGPaymentResult {
  const PGPaymentCancelled({
    required super.orderId,
    required super.orderToken,
    this.paymentId,
  });

  /// Set if an attempt had already been created before the user cancelled.
  final String? paymentId;

  @override
  String toString() => 'PGPaymentCancelled(orderId: $orderId)';
}
