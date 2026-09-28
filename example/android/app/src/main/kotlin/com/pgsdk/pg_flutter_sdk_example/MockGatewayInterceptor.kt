package com.pgsdk.pg_flutter_sdk_example

import com.pgsdk.core.PGDebugInterceptor
import com.pgsdk.core.PGDebugRequest
import com.pgsdk.core.PGDebugResponse
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * In-process stand-in for a real payment gateway backend, so this sample app can
 * exercise the SDK's full checkout flow in the emulator without a real backend or any
 * separate process. Installed via `PgFlutterSdkPlugin.debugInterceptors` (see
 * [MainActivity]) -- the SDK's OkHttp client routes every gateway request through here
 * instead of the network. Mirrors the REST contract in docs/API.md; a real gateway
 * integration would delete this file entirely and just point `PGConfig.backendBaseUrl`
 * at the real API.
 *
 * Card/net-banking redirect URLs point at a real `https://example.com` page (matching
 * the iOS sample's approach) since there's no server here to host an interactive mock
 * page -- the attempt resolves on its own after a couple of poll ticks regardless of
 * what's shown in the WebView.
 *
 * Test values:
 * - Card ending `4242` -> succeeds. Ending `0002` -> tokenize call itself fails (402).
 *   Ending `0001` -> tokenizes OK, then resolves to failed. Ending `1117` -> returns a
 *   3DS redirect. Any other Luhn-valid number succeeds.
 * - VPA `success@upi` (or anything not below) -> succeeds. `failure@upi` -> fails.
 *   `pending@upi` -> never resolves (tests the poller-timeout -> Pending path).
 * - Net banking: any bank -> succeeds after a couple of poll ticks.
 */
internal class MockGatewayInterceptor : PGDebugInterceptor {

    private data class Attempt(
        val method: String,
        val orderToken: String,
        var status: String = "created",
        var pollCount: Int = 0,
        var outcome: String = "succeed",
        var failureReason: String? = null,
        var verificationReference: String? = null
    )

    private val attempts = ConcurrentHashMap<String, Attempt>()

    override fun intercept(request: PGDebugRequest): PGDebugResponse? {
        val body = request.bodyJson?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject()

        return when {
            request.method == "POST" && request.path == "/v1/payment_attempts" -> createAttempt(body)

            request.method == "GET" && request.path.matchesAttemptStatusPath() ->
                status(attemptId = request.path.removePrefix("/v1/payment_attempts/"))

            request.method == "POST" && request.path.endsWith("/upi/intent") ->
                upiIntent(attemptId = idFromSuffixedPath(request.path, "/upi/intent"))

            request.method == "POST" && request.path.endsWith("/upi/collect") ->
                upiCollect(attemptId = idFromSuffixedPath(request.path, "/upi/collect"), body = body)

            request.method == "POST" && request.path.endsWith("/card/tokenize") ->
                cardTokenize(attemptId = idFromSuffixedPath(request.path, "/card/tokenize"), body = body)

            request.method == "GET" && request.path == "/v1/net_banking/banks" -> banks()

            request.method == "POST" && request.path.endsWith("/net_banking/initiate") ->
                netBankingInitiate(attemptId = idFromSuffixedPath(request.path, "/net_banking/initiate"))

            else -> jsonResponse(404, JSONObject().put("code", "not_found").put("message", "No mock route."))
        }
    }

    private fun String.matchesAttemptStatusPath(): Boolean =
        startsWith("/v1/payment_attempts/") &&
            !endsWith("/upi/intent") && !endsWith("/upi/collect") &&
            !endsWith("/card/tokenize") && !endsWith("/net_banking/initiate")

    private fun idFromSuffixedPath(path: String, suffix: String): String =
        path.removePrefix("/v1/payment_attempts/").removeSuffix(suffix)

    private fun createAttempt(body: JSONObject): PGDebugResponse {
        val id = "att_" + UUID.randomUUID().toString().take(10)
        val method = body.optString("method", "upi")
        val orderToken = body.optString("order_token", "")
        attempts[id] = Attempt(method = method, orderToken = orderToken)
        return jsonResponse(
            200,
            JSONObject().put("attempt_id", id).put("order_token", orderToken).put("status", "created")
        )
    }

    private fun status(attemptId: String): PGDebugResponse {
        val attempt = attempts[attemptId] ?: return notFound(attemptId)
        advance(attempt)
        val json = JSONObject()
            .put("attempt_id", attemptId)
            .put("order_token", attempt.orderToken)
            .put("status", attempt.status)
            .put("method", attempt.method)
            .put("verification_reference", attempt.verificationReference)
            .put("failure_reason", attempt.failureReason)
        return jsonResponse(200, json)
    }

    /** Resolves a created/pending attempt toward its scripted outcome. */
    private fun advance(attempt: Attempt) {
        if (attempt.status != "created" && attempt.status != "pending") return
        if (attempt.outcome == "stay_pending") {
            attempt.status = "pending"
            return
        }
        attempt.pollCount++
        if (attempt.pollCount < 2) {
            attempt.status = "pending"
            return
        }
        if (attempt.outcome == "fail") {
            attempt.status = "failed"
            attempt.failureReason = attempt.failureReason ?: "The mock gateway declined this attempt."
        } else {
            attempt.status = "succeeded"
            attempt.verificationReference = "mock_ref_" + UUID.randomUUID().toString().take(8)
        }
    }

    private fun upiIntent(attemptId: String): PGDebugResponse {
        if (!attempts.containsKey(attemptId)) return notFound(attemptId)
        val intentUrl = "upi://pay?pa=merchant@mockbank&pn=Mock%20Merchant&am=1.00&cu=INR&tr=$attemptId"
        return jsonResponse(200, JSONObject().put("intent_url", intentUrl))
    }

    private fun upiCollect(attemptId: String, body: JSONObject): PGDebugResponse {
        val attempt = attempts[attemptId] ?: return notFound(attemptId)
        val vpa = body.optString("vpa", "").lowercase()
        attempt.outcome = when {
            vpa.startsWith("failure@") || vpa.startsWith("fail@") -> "fail"
            vpa.startsWith("pending@") -> "stay_pending"
            else -> "succeed"
        }
        attempt.status = "pending"
        return jsonResponse(200, JSONObject().put("status", "pending"))
    }

    private fun cardTokenize(attemptId: String, body: JSONObject): PGDebugResponse {
        val attempt = attempts[attemptId] ?: return notFound(attemptId)
        val number = body.optString("card_number", "").filter { it.isDigit() }

        if (number.endsWith("0002")) {
            return jsonResponse(
                402,
                JSONObject().put("code", "card_declined").put("message", "The card was declined by the issuer.")
            )
        }

        val cardToken = "tok_" + UUID.randomUUID().toString().take(10)
        return when {
            number.endsWith("0001") -> {
                attempt.outcome = "fail"
                attempt.status = "pending"
                jsonResponse(
                    200,
                    JSONObject().put("card_token", cardToken).put("three_ds_redirect_url", JSONObject.NULL)
                        .put("status", "pending")
                )
            }

            number.endsWith("1117") -> {
                attempt.outcome = "succeed"
                attempt.status = "pending"
                jsonResponse(
                    200,
                    JSONObject().put("card_token", cardToken)
                        .put("three_ds_redirect_url", "https://example.com/mock-3ds-verify")
                        .put("status", "pending")
                )
            }

            else -> {
                attempt.outcome = "succeed"
                attempt.status = "pending"
                jsonResponse(
                    200,
                    JSONObject().put("card_token", cardToken).put("three_ds_redirect_url", JSONObject.NULL)
                        .put("status", "pending")
                )
            }
        }
    }

    private fun banks(): PGDebugResponse {
        val banks = listOf("HDFC" to "HDFC Bank", "ICIC" to "ICICI Bank", "SBIN" to "State Bank of India")
            .map { (id, name) -> JSONObject().put("id", id).put("name", name).put("icon_url", JSONObject.NULL) }
        val array = org.json.JSONArray(banks)
        return jsonResponse(200, JSONObject().put("banks", array))
    }

    private fun netBankingInitiate(attemptId: String): PGDebugResponse {
        val attempt = attempts[attemptId] ?: return notFound(attemptId)
        attempt.outcome = "succeed"
        return jsonResponse(200, JSONObject().put("redirect_url", "https://example.com/mock-bank-login"))
    }

    private fun notFound(attemptId: String) = jsonResponse(
        404,
        JSONObject().put("code", "not_found").put("message", "Unknown attempt $attemptId.")
    )

    private fun jsonResponse(statusCode: Int, json: JSONObject) =
        PGDebugResponse(statusCode = statusCode, bodyJson = json.toString())
}
