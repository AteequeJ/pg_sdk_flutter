package com.pgsdk.flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import com.pgsdk.core.PGCheckoutTheme
import com.pgsdk.core.PGConfig
import com.pgsdk.core.PGDebugInterceptor
import com.pgsdk.core.PGEnvironment
import com.pgsdk.core.PGPaymentContract
import com.pgsdk.core.PGPaymentSDK
import com.pgsdk.model.PGCustomerInfo
import com.pgsdk.model.PGErrorCode
import com.pgsdk.model.PGPaymentMethod
import com.pgsdk.model.PGPaymentRequest
import com.pgsdk.model.PGPaymentResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Bridges the `com.pgsdk/flutter` method channel to [PGPaymentSDK].
 *
 * Checkout is launched with [Activity.startActivityForResult] and
 * [PGPaymentContract], rather than [com.pgsdk.core.PGPaymentLauncher], so it
 * works from a plain `FlutterActivity` (which isn't an `ActivityResultCaller`).
 */
class PgFlutterSdkPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val REQUEST_CODE = 0x5047 // "PG"

        /**
         * Development hook: intercepts gateway requests in-process, e.g. a mock
         * gateway so a demo app runs without a backend. Set it from native code
         * (e.g. `MainActivity.onCreate`) before Dart calls `configure`. The
         * native SDK rejects it in PRODUCTION.
         */
        @JvmStatic
        var debugInterceptors: List<PGDebugInterceptor> = emptyList()
    }

    private lateinit var channel: MethodChannel
    private lateinit var applicationContext: Context
    private var activityBinding: ActivityPluginBinding? = null
    private val contract = PGPaymentContract()
    private var pendingResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.pgsdk/flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> configure(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(), result)
            "startPayment" -> startPayment(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(), result)
            else -> result.notImplemented()
        }
    }

    // region configure

    private fun configure(args: Map<*, *>, result: MethodChannel.Result) {
        val android = args["android"] as? Map<*, *>
        if (android == null) {
            result.error(PGErrorCode.INVALID_CONFIG, "PGConfig.android is required on Android.", null)
            return
        }
        val theme = args["theme"] as? Map<*, *>
        val config = try {
            val merchantId = android["merchantId"] as? String ?: ""
            PGConfig(
                merchantId = merchantId,
                publishableKey = args["publishableKey"] as? String ?: "",
                backendBaseUrl = android["backendBaseUrl"] as? String ?: "",
                environment = if (args["environment"] == "sandbox") PGEnvironment.SANDBOX else PGEnvironment.PRODUCTION,
                merchantDisplayName = args["merchantDisplayName"] as? String ?: merchantId,
                enableLogging = args["enableLogging"] as? Boolean ?: false,
                connectTimeoutSeconds = (android["connectTimeoutSeconds"] as? Number)?.toLong() ?: 15L,
                readTimeoutSeconds = (android["readTimeoutSeconds"] as? Number)?.toLong() ?: 30L,
                theme = PGCheckoutTheme(
                    primaryColor = (theme?.get("primaryColor") as? Number)?.toInt(),
                    onPrimaryColor = (theme?.get("onPrimaryColor") as? Number)?.toInt()
                ),
                allowedPaymentMethods = methods(args["allowedPaymentMethods"]) ?: PGPaymentMethod.entries.toSet(),
                debugInterceptors = debugInterceptors
            )
        } catch (e: IllegalArgumentException) {
            result.error(PGErrorCode.INVALID_CONFIG, e.message, null)
            return
        }
        PGPaymentSDK.initialize(applicationContext, config)
        result.success(null)
    }

    // endregion

    // region startPayment

    private fun startPayment(args: Map<*, *>, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.success(failure(PGErrorCode.INVALID_REQUEST, "A payment is already in progress."))
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(failure(PGErrorCode.UNKNOWN, "No activity available to launch checkout from."))
            return
        }
        val request = try {
            val customer = args["customer"] as? Map<*, *>
            PGPaymentRequest(
                orderId = args["orderId"] as? String ?: "",
                orderToken = args["orderToken"] as? String ?: "",
                amountMinor = (args["amountMinor"] as? Number)?.toLong() ?: 0L,
                currency = args["currency"] as? String ?: "INR",
                description = args["description"] as? String,
                customer = customer?.let {
                    PGCustomerInfo(
                        name = it["name"] as? String,
                        email = it["email"] as? String,
                        phone = it["phone"] as? String
                    )
                },
                notes = (args["metadata"] as? Map<*, *>)
                    ?.entries?.associate { (k, v) -> k.toString() to v.toString() }
                    ?: emptyMap()
            )
        } catch (e: IllegalArgumentException) {
            result.success(failure(PGErrorCode.INVALID_REQUEST, e.message ?: "Invalid payment request."))
            return
        }

        val intent = try {
            contract.createIntent(activity, request)
        } catch (e: IllegalStateException) {
            result.success(failure(PGErrorCode.NOT_INITIALIZED, e.message ?: "SDK not initialized."))
            return
        }
        pendingResult = result
        activity.startActivityForResult(intent, REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        result.success(encode(contract.parseResult(resultCode, data)))
        return true
    }

    // endregion

    // region ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        pendingResult?.success(
            failure(PGErrorCode.UNKNOWN, "The host activity was destroyed before checkout finished.")
        )
        pendingResult = null
    }

    // endregion

    // region Encoding

    private fun encode(result: PGPaymentResult): Map<String, Any?> = when (result) {
        is PGPaymentResult.Success -> mapOf(
            "status" to "success",
            "paymentId" to result.paymentId,
            "method" to result.method?.let(::wireValue),
            "verificationReference" to result.rawReference
        )
        is PGPaymentResult.Pending -> mapOf(
            "status" to "pending",
            "paymentId" to result.paymentId,
            "message" to result.message
        )
        is PGPaymentResult.Cancelled -> mapOf("status" to "cancelled")
        is PGPaymentResult.Failure ->
            if (result.error.code == PGErrorCode.USER_CANCELLED) {
                mapOf("status" to "cancelled")
            } else {
                failure(result.error.code, result.error.message, result.error.isRetryable)
            }
    }

    private fun failure(code: String, message: String, isRetryable: Boolean = false): Map<String, Any?> =
        mapOf(
            "status" to "failure",
            "error" to mapOf("code" to code, "message" to message, "isRetryable" to isRetryable)
        )

    private fun wireValue(method: PGPaymentMethod): String = when (method) {
        PGPaymentMethod.UPI -> "upi"
        PGPaymentMethod.CARD -> "card"
        PGPaymentMethod.NET_BANKING -> "net_banking"
    }

    private fun methods(value: Any?): Set<PGPaymentMethod>? =
        (value as? List<*>)?.mapNotNull { wire ->
            PGPaymentMethod.entries.find { wireValue(it) == wire }
        }?.toSet()

    // endregion
}
