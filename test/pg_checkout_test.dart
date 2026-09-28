import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pg_flutter_sdk/pg_flutter_sdk.dart';

const _channel = MethodChannel('com.pgsdk/flutter');

const _config = PGConfig(
  publishableKey: 'pk_test_123',
  merchantDisplayName: 'Acme Store',
  environment: PGEnvironment.sandbox,
  theme: PGTheme(primaryColor: Color(0xFF3355FF)),
  android: PGAndroidOptions(
    merchantId: 'acme',
    backendBaseUrl: 'https://sandbox-api.example-pg.com/',
  ),
  ios: PGIosOptions(callbackUrlScheme: 'acmestore'),
);

const _request = PGPaymentRequest(
  orderId: 'order_1',
  orderToken: 'tok_1',
  amountMinor: 49900,
  metadata: {'cart': '42'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PGCheckout checkout;
  late List<MethodCall> calls;
  Object? Function(MethodCall call) handler = (_) => null;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    checkout = PGCheckout.withChannel(_channel);
    calls = [];
    handler = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('configure', () {
    test('sends the config to the platform', () async {
      await checkout.configure(_config);

      expect(checkout.isConfigured, isTrue);
      expect(calls.single.method, 'configure');
      final args = calls.single.arguments as Map;
      expect(args['publishableKey'], 'pk_test_123');
      expect(args['environment'], 'sandbox');
      expect(args['allowedPaymentMethods'], ['upi', 'card', 'net_banking']);
      expect((args['theme'] as Map)['primaryColor'], 0xFF3355FF);
      expect((args['android'] as Map)['merchantId'], 'acme');
      expect((args['ios'] as Map)['callbackUrlScheme'], 'acmestore');
    });

    for (final key in ['sk_live_abc', 'secret_abc', 'pk_secret_abc', '']) {
      test('rejects publishable key "$key" without calling the platform', () async {
        final config = PGConfig(
          publishableKey: key,
          merchantDisplayName: 'Acme',
          android: _config.android,
        );
        await expectLater(
          checkout.configure(config),
          throwsA(isA<PGError>().having((e) => e.code, 'code', PGErrorCode.invalidConfig)),
        );
        expect(calls, isEmpty);
      });
    }

    test('requires android options on Android', () async {
      const config = PGConfig(publishableKey: 'pk_1', merchantDisplayName: 'Acme');
      await expectLater(checkout.configure(config), throwsA(isA<PGError>()));
    });

    test('requires ios options on iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const config = PGConfig(
        publishableKey: 'pk_1',
        merchantDisplayName: 'Acme',
        android: PGAndroidOptions(merchantId: 'm', backendBaseUrl: 'https://x/'),
      );
      await expectLater(checkout.configure(config), throwsA(isA<PGError>()));
    });

    test('surfaces native rejection as PGError', () async {
      handler = (_) => throw PlatformException(code: 'invalid_config', message: 'bad url');
      await expectLater(
        checkout.configure(_config),
        throwsA(isA<PGError>()
            .having((e) => e.code, 'code', 'invalid_config')
            .having((e) => e.message, 'message', 'bad url')),
      );
      expect(checkout.isConfigured, isFalse);
    });
  });

  group('startPayment', () {
    test('fails without calling the platform when not configured', () async {
      final result = await checkout.startPayment(_request);
      expect(result, isA<PGPaymentFailure>());
      expect((result as PGPaymentFailure).error.code, PGErrorCode.notInitialized);
      expect(calls, isEmpty);
    });

    test('rejects an invalid request', () async {
      await checkout.configure(_config);
      calls.clear();
      final result = await checkout.startPayment(const PGPaymentRequest(
        orderId: 'o', orderToken: 't', amountMinor: 0,
      ));
      expect((result as PGPaymentFailure).error.code, PGErrorCode.invalidRequest);
      expect(calls, isEmpty);
    });

    test('sends the request and decodes success', () async {
      await checkout.configure(_config);
      handler = (call) => {
            'status': 'success',
            'paymentId': 'pay_1',
            'method': 'net_banking',
            'verificationReference': 'sig_1',
            'rawFields': {'bank': 'HDFC'},
          };

      final result = await checkout.startPayment(_request);

      final args = calls.last.arguments as Map;
      expect(args['orderId'], 'order_1');
      expect(args['amountMinor'], 49900);
      expect(args['currency'], 'INR');
      expect(args['metadata'], {'cart': '42'});
      expect(args['upiFlow'], 'intent');

      expect(result, isA<PGPaymentSuccess>());
      final success = result as PGPaymentSuccess;
      expect(success.orderId, 'order_1');
      expect(success.orderToken, 'tok_1');
      expect(success.paymentId, 'pay_1');
      expect(success.method, PGPaymentMethod.netBanking);
      expect(success.verificationReference, 'sig_1');
      expect(success.rawFields, {'bank': 'HDFC'});
    });

    test('decodes pending', () async {
      await checkout.configure(_config);
      handler = (_) => {'status': 'pending', 'paymentId': 'pay_2', 'method': 'upi', 'message': 'waiting'};
      final result = await checkout.startPayment(_request) as PGPaymentPending;
      expect(result.paymentId, 'pay_2');
      expect(result.method, PGPaymentMethod.upi);
      expect(result.message, 'waiting');
    });

    test('decodes cancelled', () async {
      await checkout.configure(_config);
      handler = (_) => {'status': 'cancelled', 'paymentId': null};
      final result = await checkout.startPayment(_request);
      expect(result, isA<PGPaymentCancelled>());
      expect(result.orderId, 'order_1');
    });

    test('decodes failure', () async {
      await checkout.configure(_config);
      handler = (_) => {
            'status': 'failure',
            'error': {'code': 'payment_declined', 'message': 'Card declined', 'isRetryable': true},
          };
      final result = await checkout.startPayment(_request) as PGPaymentFailure;
      expect(result.error.code, PGErrorCode.paymentDeclined);
      expect(result.error.message, 'Card declined');
      expect(result.error.isRetryable, isTrue);
    });

    test('maps a PlatformException and unknown status to failure', () async {
      await checkout.configure(_config);
      handler = (_) => throw PlatformException(code: 'network_error', message: 'offline');
      final thrown = await checkout.startPayment(_request) as PGPaymentFailure;
      expect(thrown.error.code, 'network_error');

      handler = (_) => {'status': 'weird'};
      final unknown = await checkout.startPayment(_request) as PGPaymentFailure;
      expect(unknown.error.code, PGErrorCode.unknown);
    });

    test('rejects a second payment while one is in progress', () async {
      await checkout.configure(_config);
      handler = (_) => Future.delayed(
            const Duration(milliseconds: 10),
            () => {'status': 'cancelled'},
          );

      final first = checkout.startPayment(_request);
      final second = await checkout.startPayment(_request);

      expect((second as PGPaymentFailure).error.message, contains('already in progress'));
      expect(await first, isA<PGPaymentCancelled>());
      // The guard is released once the first payment completes.
      expect(await checkout.startPayment(_request), isA<PGPaymentCancelled>());
    });
  });
}
