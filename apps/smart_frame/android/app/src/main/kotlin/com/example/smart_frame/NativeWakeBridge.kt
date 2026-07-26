package com.example.smart_frame

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.EventChannel
import kotlin.concurrent.thread

/**
 * Compatibility adapter for the wake engine already installed on AILABS/Tmall
 * Genie hardware. It forwards only wake/availability metadata to Flutter; audio
 * recognition and speech synthesis remain Home Agent responsibilities.
 */
class NativeWakeBridge(private val context: Context) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var serviceBinder: IBinder? = null
    private var bound = false
    @Volatile private var wakeLogProcess: Process? = null
    @Volatile private var wakeLogThread: Thread? = null
    @Volatile private var lastWakeAtMs = 0L

    private val callback = object : Binder() {
        init {
            attachInterface(null, CALLBACK_DESCRIPTOR)
        }

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            when (code) {
                INTERFACE_TRANSACTION -> {
                    reply?.writeString(CALLBACK_DESCRIPTOR)
                    return true
                }
                CALLBACK_STATUS -> {
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    val status = if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data) else null
                    reply?.writeNoException()
                    handleStatus(status)
                    return true
                }
                CALLBACK_COMMAND -> {
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    val command =
                        if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data) else null
                    logBundle("command", command)
                    reply?.writeNoException()
                    reply?.writeMap(emptyMap<String, Any>())
                    return true
                }
                CALLBACK_CONTEXT -> {
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data)
                    reply?.writeNoException()
                    reply?.writeString(null)
                    return true
                }
                CALLBACK_SCENE -> {
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data)
                    reply?.writeNoException()
                    reply?.writeInt(0)
                    return true
                }
                CALLBACK_CLIENT -> {
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    val eventId = data.readInt()
                    val event =
                        if (data.readInt() != 0) Bundle.CREATOR.createFromParcel(data) else null
                    handleClientEvent(eventId, event)
                    reply?.writeNoException()
                    reply?.writeInt(0)
                    return true
                }
            }
            return super.onTransact(code, data, reply, flags)
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            serviceBinder = binder
            try {
                registerCallback(binder)
                Log.i(TAG, "AliTVASR callback registered: ${context.packageName}")
                startFirmwareWakeLogAdapter()
                emit(mapOf("event" to "availability", "available" to true))
            } catch (error: Exception) {
                Log.w(TAG, "AliTVASR callback registration failed", error)
                emit(
                    mapOf(
                        "event" to "availability",
                        "available" to false,
                        "reason" to (error.message ?: error.javaClass.simpleName),
                    ),
                )
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            serviceBinder = null
            Log.w(TAG, "AliTVASR service disconnected: $name")
            emit(mapOf("event" to "availability", "available" to false))
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        bind()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        unbind()
    }

    private fun bind() {
        if (bound) return
        val intent = Intent(SERVICE_ACTION).setComponent(ComponentName(SERVICE_PACKAGE, SERVICE_CLASS))
        bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        if (!bound) {
            emit(
                mapOf(
                    "event" to "availability",
                    "available" to false,
                    "reason" to "native wake service not found",
                ),
            )
        }
    }

    private fun unbind() {
        stopFirmwareWakeLogAdapter()
        if (!bound) return
        serviceBinder?.let { binder ->
            try {
                transact(binder, UNREGISTER_CALLBACK) { parcel ->
                    parcel.writeString(context.packageName)
                }
            } catch (_: Exception) {
            }
        }
        context.unbindService(connection)
        serviceBinder = null
        bound = false
    }

    private fun registerCallback(binder: IBinder) {
        transact(binder, REGISTER_CALLBACK) { parcel ->
            parcel.writeString(context.packageName)
            parcel.writeStrongBinder(callback)
            parcel.writeInt(0) // Do not request the vendor ASR user interface.
        }
    }

    private fun transact(binder: IBinder, code: Int, writer: (Parcel) -> Unit) {
        val request = Parcel.obtain()
        val response = Parcel.obtain()
        try {
            request.writeInterfaceToken(SERVICE_DESCRIPTOR)
            writer(request)
            check(binder.transact(code, request, response, 0)) { "native wake transaction failed" }
            response.readException()
        } finally {
            response.recycle()
            request.recycle()
        }
    }

    private fun handleStatus(bundle: Bundle?) {
        logBundle("status", bundle)
        if (bundle?.getString("status") != "start_recording") return
        val source = bundle.getInt("volume", -1)
        // This is the same filter used by the vendor SDK's own wake listener.
        if (source == 4) return
        emitWake(source = source, adapter = "alitvasr")
    }

    private fun emitWake(source: Int, adapter: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastWakeAtMs < WAKE_DEDUPLICATION_MS) return
        lastWakeAtMs = now
        Log.i(TAG, "native wake adapter=$adapter source=$source")
        emit(
            mapOf(
                "event" to "wake",
                "wakeWord" to "天猫精灵",
                "source" to source,
                "adapter" to adapter,
            ),
        )
    }

    private fun startFirmwareWakeLogAdapter() {
        if (wakeLogProcess != null) return
        try {
            val process =
                ProcessBuilder(
                    "su",
                    "-c",
                    "exec logcat -v brief -T 1 -s WakeupManager:D",
                ).redirectErrorStream(true).start()
            wakeLogProcess = process
            val startedAt = SystemClock.elapsedRealtime()
            wakeLogThread =
                thread(name = "smart-frame-native-wake", isDaemon = true) {
                    try {
                        process.inputStream.bufferedReader().useLines { lines ->
                            lines.forEach { line ->
                                Log.v(TAG, "firmware: $line")
                                // `-T 1` may replay one buffered line. Ignore it during startup
                                // so reopening the App cannot create a false wake.
                                if (
                                    SystemClock.elapsedRealtime() - startedAt > LOG_REPLAY_GUARD_MS &&
                                        isTmallGenieWakeLine(line)
                                ) {
                                    emitWake(source = FIRMWARE_LOG_SOURCE, adapter = "firmware_log")
                                }
                            }
                        }
                    } catch (error: Exception) {
                        if (wakeLogProcess === process) {
                            Log.w(TAG, "firmware wake log adapter stopped", error)
                        }
                    } finally {
                        if (wakeLogProcess === process) wakeLogProcess = null
                    }
                }
            Log.i(TAG, "firmware wake log adapter started")
        } catch (error: Exception) {
            Log.w(TAG, "firmware wake log adapter unavailable", error)
        }
    }

    private fun stopFirmwareWakeLogAdapter() {
        val process = wakeLogProcess
        wakeLogProcess = null
        process?.destroy()
        wakeLogThread?.interrupt()
        wakeLogThread = null
    }

    private fun handleClientEvent(eventId: Int, bundle: Bundle?) {
        // AliTVASR id=10007 is NativeClientCallback.onNotifyEvent. Keep this
        // diagnostic metadata local to logcat until a firmware-independent wake
        // event is confirmed; never forward vendor ASR text to Flutter.
        val type = bundle?.getInt("type", Int.MIN_VALUE) ?: Int.MIN_VALUE
        val arg1 = bundle?.getInt("arg1", Int.MIN_VALUE) ?: Int.MIN_VALUE
        Log.i(
            TAG,
            "client event id=$eventId type=$type arg1=$arg1 keys=${bundleKeys(bundle)}",
        )
    }

    private fun logBundle(source: String, bundle: Bundle?) {
        val status = bundle?.getString("status")
        val volume = bundle?.getInt("volume", Int.MIN_VALUE) ?: Int.MIN_VALUE
        Log.i(TAG, "$source status=$status volume=$volume keys=${bundleKeys(bundle)}")
    }

    private fun bundleKeys(bundle: Bundle?): String =
        bundle?.keySet()?.sorted()?.joinToString(",", prefix = "[", postfix = "]") ?: "[]"

    private fun emit(event: Map<String, Any>) {
        mainHandler.post { eventSink?.success(event) }
    }

    companion object {
        const val EVENT_CHANNEL = "smart_frame/native_wake"
        private const val TAG = "SmartFrameNativeWake"
        private const val WAKE_DEDUPLICATION_MS = 1_500L
        private const val LOG_REPLAY_GUARD_MS = 500L
        private const val FIRMWARE_LOG_SOURCE = 100
        private const val SERVICE_ACTION = "com.yunos.tv.alitvasr.service"
        private const val SERVICE_PACKAGE = "com.alibaba.ailabs.genie.smartapp"
        private const val SERVICE_CLASS = "com.alibaba.ailabs.geniesdk.NativeService"
        private const val SERVICE_DESCRIPTOR = "com.yunos.tv.alitvasr.IAliTVASR"
        private const val CALLBACK_DESCRIPTOR = "com.yunos.tv.alitvasr.IAliTVASRCallback"
        private const val REGISTER_CALLBACK = 1
        private const val UNREGISTER_CALLBACK = 2
        private const val CALLBACK_STATUS = 1
        private const val CALLBACK_COMMAND = 2
        private const val CALLBACK_CONTEXT = 3
        private const val CALLBACK_SCENE = 4
        private const val CALLBACK_CLIENT = 5

        internal fun isTmallGenieWakeLine(line: String): Boolean =
            line.contains("wakeup word is 天猫精灵")
    }
}
