package com.pgsdk.pg_flutter_sdk_example

import android.os.Bundle
import com.pgsdk.flutter.PgFlutterSdkPlugin
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Demo only: answer gateway requests in-process, so the example runs
        // without a backend. Delete this for a real integration.
        PgFlutterSdkPlugin.debugInterceptors = listOf(MockGatewayInterceptor())
        super.onCreate(savedInstanceState)
    }
}
