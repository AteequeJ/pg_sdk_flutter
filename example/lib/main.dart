import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pg_flutter_sdk/pg_flutter_sdk.dart';

/// Gateway requests are answered in-process by a mock (installed natively in
/// MainActivity.kt / AppDelegate.swift), so this runs without a backend.
///
/// Test values: card 4242 4242 4242 4242 succeeds; UPI ID success@upi
/// succeeds, failure@upi fails. See the mock files for the full list.
const _config = PGConfig(
  // Publishable key only; a secret key must never ship in an app.
  publishableKey: 'pk_test_flutter_example',
  merchantDisplayName: 'PG Flutter Store',
  environment: PGEnvironment.sandbox,
  enableLogging: true,
  theme: PGTheme(primaryColor: Color(0xFF3949AB)),
  android: PGAndroidOptions(
    merchantId: 'flutter_example',
    backendBaseUrl: 'https://sandbox-api.example-pg.com/',
  ),
  // Must match CFBundleURLSchemes in ios/Runner/Info.plist.
  ios: PGIosOptions(callbackUrlScheme: 'pgflutterexample'),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? configError;
  try {
    await PGCheckout.instance.configure(_config);
  } on PGError catch (e) {
    configError = e.message;
  }
  runApp(ExampleApp(configError: configError));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, this.configError});

  final String? configError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PG Flutter SDK',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3949AB)),
      home: CheckoutDemoPage(configError: configError),
    );
  }
}

class CheckoutDemoPage extends StatefulWidget {
  const CheckoutDemoPage({super.key, this.configError});

  final String? configError;

  @override
  State<CheckoutDemoPage> createState() => _CheckoutDemoPageState();
}

class _CheckoutDemoPageState extends State<CheckoutDemoPage> {
  static const _amountMinor = 49900; // ₹499.00

  bool _busy = false;
  PGPaymentResult? _result;

  /// Stands in for `POST /api/orders` on **your** backend, which creates the
  /// order with the gateway's secret key and returns an order token.
  Future<({String id, String token})> _createOrderOnBackend() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final suffix = Random().nextInt(1 << 32).toRadixString(16);
    return (id: 'order_$suffix', token: 'token_$suffix');
  }

  Future<void> _pay() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final order = await _createOrderOnBackend();
    final result = await PGCheckout.instance.startPayment(
      PGPaymentRequest(
        orderId: order.id,
        orderToken: order.token,
        amountMinor: _amountMinor,
        description: 'Wireless headphones',
        customer: const PGCustomerInfo(
          name: 'Test User',
          email: 'test@example.com',
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('PG Flutter SDK')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.configError case final error?)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                title: const Text('SDK configuration failed'),
                subtitle: Text(error),
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.headphones),
              title: const Text('Wireless headphones'),
              trailing: Text('₹499.00', style: theme.textTheme.titleMedium),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.brown),
            onPressed: _busy || widget.configError != null ? null : _pay,
            child: Text(_busy ? 'Processing…' : 'Pay ₹499.00'),
          ),
          if (_result case final result?) ...[
            const SizedBox(height: 24),
            _ResultCard(result: result),
          ],
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final PGPaymentResult result;

  @override
  Widget build(BuildContext context) {
    final (
      IconData icon,
      Color color,
      String title,
      String detail,
    ) = switch (result) {
      PGPaymentSuccess(:final paymentId, :final method) => (
        Icons.check_circle,
        Colors.green,
        'Payment reported successful',
        'Payment $paymentId via ${method?.name ?? 'unknown method'}.\n'
            'Verify it on your backend before fulfilling the order.',
      ),
      PGPaymentPending(:final paymentId, :final message) => (
        Icons.hourglass_top,
        Colors.orange,
        'Payment pending',
        '${message ?? 'Awaiting confirmation.'} Payment: ${paymentId ?? '-'}.\n'
            'Wait for your backend webhook before fulfilling.',
      ),
      PGPaymentFailure(:final error) => (
        Icons.error,
        Colors.red,
        'Payment failed',
        '${error.message}\n(${error.code}${error.isRetryable ? ', retryable' : ''})',
      ),
      PGPaymentCancelled() => (
        Icons.cancel,
        Colors.grey,
        'Payment cancelled',
        'The checkout was closed before paying.',
      ),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(title),
        subtitle: Text('$detail\nOrder: ${result.orderId}'),
        isThreeLine: true,
      ),
    );
  }
}
