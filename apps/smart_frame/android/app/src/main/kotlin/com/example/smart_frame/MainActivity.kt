package com.example.smart_frame

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nativeWakeBridge: NativeWakeBridge? = null
    private var streamingPcmBridge: StreamingPcmBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeWakeBridge = NativeWakeBridge(applicationContext)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NativeWakeBridge.EVENT_CHANNEL,
        ).setStreamHandler(nativeWakeBridge)
        streamingPcmBridge = StreamingPcmBridge()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            StreamingPcmBridge.CHANNEL,
        ).setMethodCallHandler(streamingPcmBridge)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
        )
    }

    override fun onDestroy() {
        streamingPcmBridge?.dispose()
        streamingPcmBridge = null
        super.onDestroy()
    }
}
