import Flutter
import PGPaymentSDK
import UIKit

/// Bridges the `com.pgsdk/flutter` method channel to `PGCheckout`.
///
/// Also forwards incoming callback URLs (return from a UPI app or bank page)
/// to `PGCheckout.shared.handleOpenURL(_:)`, for both scene-based and
/// app-delegate-based apps, so merchants don't have to.
public class PgFlutterSdkPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {

  /// Development hook: `URLProtocol` classes installed on the SDK's
  /// `URLSession`, e.g. a mock gateway so a demo app runs without a backend.
  /// Set it from native code (e.g. `AppDelegate`) before Dart calls
  /// `configure`. The native SDK rejects it in `.production`.
  nonisolated(unsafe) public static var debugURLProtocolClasses: [AnyClass]?

  private var theme: PGTheme = .default
  private var configuredMethods: [PGPaymentMethodType] = PGPaymentMethodType.allCases
  private var paymentInProgress = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.pgsdk/flutter", binaryMessenger: registrar.messenger())
    let instance = PgFlutterSdkPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "configure":
      MainActor.assumeIsolated { configure(args, result: result) }
    case "startPayment":
      MainActor.assumeIsolated { startPayment(args, result: result) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - configure

  @MainActor
  private func configure(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let ios = args["ios"] as? [String: Any],
          let callbackURLScheme = ios["callbackUrlScheme"] as? String else {
      result(FlutterError(code: "invalid_config", message: "PGConfig.ios is required on iOS.", details: nil))
      return
    }

    let environment: PGEnvironment
    if let custom = ios["customBaseUrl"] as? String {
      guard let url = URL(string: custom) else {
        result(FlutterError(code: "invalid_config", message: "ios.customBaseUrl is not a valid URL.", details: nil))
        return
      }
      environment = .custom(baseURL: url)
    } else {
      environment = (args["environment"] as? String) == "sandbox" ? .sandbox : .production
    }

    let pinning = (ios["pinnedSpkiHashes"] as? [String]).map {
      PGCertificatePinning(base64EncodedSPKIHashes: Set($0))
    }

    let configuration = PGConfiguration(
      publishableKey: args["publishableKey"] as? String ?? "",
      environment: environment,
      merchantDisplayName: args["merchantDisplayName"] as? String ?? "",
      callbackURLScheme: callbackURLScheme,
      logLevel: (args["enableLogging"] as? Bool ?? false) ? .debug : .none,
      requestTimeout: (ios["requestTimeoutSeconds"] as? NSNumber)?.doubleValue ?? 30,
      pinning: pinning,
      debugURLProtocolClasses: Self.debugURLProtocolClasses
    )

    do {
      try PGCheckout.shared.configure(configuration)
    } catch {
      result(FlutterError(code: "invalid_config", message: error.localizedDescription, details: nil))
      return
    }

    configuredMethods = Self.methods(args["allowedPaymentMethods"]) ?? PGPaymentMethodType.allCases
    if let themeArgs = args["theme"] as? [String: Any],
       let primary = (themeArgs["primaryColor"] as? NSNumber).map({ Self.color(argb: $0.uint32Value) }) {
      theme = PGTheme(primaryColor: primary)
    } else {
      theme = .default
    }
    result(nil)
  }

  // MARK: - startPayment

  @MainActor
  private func startPayment(_ args: [String: Any], result: @escaping FlutterResult) {
    guard !paymentInProgress else {
      result(Self.failure(code: "invalid_request", message: "A payment is already in progress."))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(Self.failure(code: "unknown_error", message: "No view controller available to present checkout from."))
      return
    }

    // A per-request list narrows the configured one.
    var methods = configuredMethods
    if let requested = Self.methods(args["allowedMethods"]) {
      methods = methods.filter(requested.contains)
    }

    let customer = (args["customer"] as? [String: Any]).map {
      PGCustomerInfo(
        name: $0["name"] as? String,
        email: $0["email"] as? String,
        phoneNumber: $0["phone"] as? String
      )
    }

    let request = PGPaymentRequest(
      orderToken: args["orderToken"] as? String ?? "",
      amountMinorUnits: (args["amountMinor"] as? NSNumber)?.int64Value ?? 0,
      currency: args["currency"] as? String ?? "INR",
      allowedMethods: methods,
      upiFlow: (args["upiFlow"] as? String) == "collect" ? .collect : .intent,
      customer: customer,
      metadata: args["metadata"] as? [String: String] ?? [:]
    )

    paymentInProgress = true
    Task { @MainActor [weak self] in
      let outcome = await PGCheckout.shared.startPayment(request: request, from: presenter, theme: self?.theme ?? .default)
      self?.paymentInProgress = false
      result(Self.encode(outcome))
    }
  }

  // MARK: - URL forwarding

  public func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    MainActor.assumeIsolated { PGCheckout.shared.handleOpenURL(url) }
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    MainActor.assumeIsolated {
      URLContexts.reduce(false) { handled, context in
        PGCheckout.shared.handleOpenURL(context.url) || handled
      }
    }
  }

  // MARK: - Encoding

  private static func encode(_ outcome: PGPaymentResult) -> [String: Any?] {
    switch outcome {
    case .success(let success):
      return [
        "status": "success",
        "paymentId": success.paymentId,
        "method": success.method.rawValue,
        "verificationReference": success.verificationReference,
        "rawFields": success.rawFields,
      ]
    case .pending(let pending):
      return [
        "status": "pending",
        "paymentId": pending.paymentId,
        "method": pending.method.rawValue,
      ]
    case .cancelled(let cancellation):
      return ["status": "cancelled", "paymentId": cancellation.paymentId]
    case .failure(.userCancelled):
      return ["status": "cancelled"]
    case .failure(let error):
      return failure(code: code(for: error), message: error.localizedDescription, isRetryable: isRetryable(error))
    }
  }

  private static func failure(code: String, message: String, isRetryable: Bool = false) -> [String: Any?] {
    ["status": "failure", "error": ["code": code, "message": message, "isRetryable": isRetryable]]
  }

  /// Maps onto the Android SDK's `PGErrorCode` values, which the Dart API
  /// shares across platforms.
  private static func code(for error: PGError) -> String {
    switch error {
    case .invalidConfiguration: return "invalid_config"
    case .notConfigured: return "sdk_not_initialized"
    case .invalidRequest: return "invalid_request"
    case .network(.timedOut), .timeout: return "timeout"
    case .network: return "network_error"
    case .server, .decoding: return "server_error"
    case .userCancelled: return "user_cancelled"
    case .paymentFailed: return "payment_declined"
    case .noUPIAppAvailable: return "no_upi_app_found"
    case .unknown: return "unknown_error"
    }
  }

  private static func isRetryable(_ error: PGError) -> Bool {
    switch error {
    case .network(.tlsPinningFailed): return false
    case .network, .timeout, .server, .paymentFailed: return true
    default: return false
    }
  }

  // MARK: - Helpers

  private static func methods(_ value: Any?) -> [PGPaymentMethodType]? {
    (value as? [String]).map { $0.compactMap(PGPaymentMethodType.init(rawValue:)) }
  }

  private static func color(argb: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }

  @MainActor
  private static func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
