package com.droidmirroring.agent

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

class AgentService : Service() {

    companion object {
        private const val TAG = "AgentService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "agent_channel"
        private const val SSE_PORT = 5557

        @Volatile
        var isRunning = false

        private const val ADB_TCP_PORT = "5555"
        const val PREFS_NAME = "agent_prefs"
        const val KEY_PORT = "agent_port"

        val sseClients = CopyOnWriteArrayList<OutputStream>()
    }

    private var sseThread: Thread? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand")
        isRunning = true
        startForeground(NOTIFICATION_ID, buildNotification())
        registerMdns()
        startSseServer()
        if (hasRoot()) {
            enableAdbTcp()
        } else {
            Log.w(TAG, "no root, ADB TCP skipped — use manual wireless debugging")
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        unregisterMdns()
        stopSseServer()
        if (hasRoot()) disableAdbTcp()
        isRunning = false
    }

    private fun hasRoot(): Boolean {
        return try {
            val proc = Runtime.getRuntime().exec(arrayOf("/system/bin/su", "-c", "id"))
            val result = proc.inputStream.bufferedReader().readLine()
            proc.waitFor()
            result?.contains("uid=0") == true
        } catch (_: Exception) { false }
    }

    private fun enableAdbTcp() {
        try {
            val port = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .getString(KEY_PORT, ADB_TCP_PORT) ?: ADB_TCP_PORT
            Log.i(TAG, "enabling ADB TCP on port $port")

            // Only restart adbd if the port changed — avoids killing
            // an active mirroring session when Android restarts the service
            val cmd = "if [ \"$(getprop service.adb.tcp.port)\" != \"$port\" ]; then " +
                      "  setprop service.adb.tcp.port $port && " +
                      "  (setprop ctl.restart adbd 2>/dev/null || stop adbd && start adbd 2>/dev/null || true); " +
                      "else " +
                      "  echo 'port already set, skipping restart'; " +
                      "fi"
            val proc = Runtime.getRuntime().exec(arrayOf("/system/bin/su", "-c", cmd))
            proc.waitFor()
            Log.i(TAG, "ADB TCP enabled, exit=${proc.exitValue()}")
        } catch (e: Exception) {
            Log.e(TAG, "failed to enable ADB TCP", e)
        }
    }

    private fun disableAdbTcp() {
        try {
            Log.i(TAG, "disabling ADB TCP (property only, no restart)")
            Runtime.getRuntime().exec(arrayOf(
                "/system/bin/su", "-c",
                "setprop service.adb.tcp.port -1"
            ))
            Log.i(TAG, "ADB TCP disabled")
        } catch (e: Exception) {
            Log.e(TAG, "failed to disable ADB TCP", e)
        }
    }

    private fun startSseServer() {
        sseThread = Thread({
            try {
                val server = ServerSocket(SSE_PORT)
                Log.i(TAG, "SSE server listening on $SSE_PORT")
                while (!Thread.interrupted()) {
                    val client = server.accept()
                    Thread({
                        try {
                            val out = client.getOutputStream()
                            val input = client.getInputStream()
                            val request = StringBuilder()
                            var c: Int
                            while (input.read().also { c = it } != -1) {
                                request.append(c.toChar())
                                if (request.endsWith("\r\n\r\n")) break
                            }
                            val isPost = request.startsWith("POST")
                            if (isPost) {
                                val contentLength = request.lines()
                                    .find { it.startsWith("Content-Length:", ignoreCase = true) }
                                    ?.substringAfter(":")?.trim()?.toIntOrNull() ?: 0
                                val body = ByteArray(contentLength)
                                var read = 0
                                while (read < contentLength) {
                                    val n = input.read(body, read, contentLength - read)
                                    if (n == -1) break else read += n
                                }
                                val data = String(body, 0, read)
                                broadcast("data: $data\n\n")
                                out.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".toByteArray())
                                out.flush()
                            } else {
                                val headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n"
                                out.write(headers.toByteArray())
                                out.flush()
                                sseClients.add(out)
                                while (input.read() != -1) { /* drain */ }
                            }
                            if (!isPost) sseClients.remove(out)
                        } catch (_: Exception) {}
                        try { client.close() } catch (_: Exception) {}
                    }, "sse-client").apply { isDaemon = true; start() }
                }
            } catch (e: Exception) {
                if (Thread.interrupted()) return@Thread
                Log.e(TAG, "SSE server error", e)
            }
        }, "sse-server").apply { isDaemon = true; start() }
    }

    private fun broadcast(message: String) {
        for (client in sseClients) {
            try { client.write(message.toByteArray()); client.flush() } catch (_: Exception) {}
        }
    }

    private fun stopSseServer() {
        sseThread?.interrupt()
        sseThread = null
        sseClients.clear()
    }

    private var nsdListener: NsdManager.RegistrationListener? = null
    private var nsdManager: NsdManager? = null

    private fun registerMdns() {
        try {
            // Unregister any previous registration first (START_STICKY re-entry)
            unregisterMdns()
            nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
            val model = getDeviceModel()
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {
                    Log.i(TAG, "mDNS registered: ${info.serviceName}")
                }
                override fun onRegistrationFailed(s: NsdServiceInfo, e: Int) {
                    Log.e(TAG, "mDNS failed: $e")
                }
                override fun onServiceUnregistered(s: NsdServiceInfo) {}
                override fun onUnregistrationFailed(s: NsdServiceInfo, e: Int) {}
            }
            nsdListener = listener
            nsdManager?.registerService(
                NsdServiceInfo().apply {
                    serviceName = model
                    serviceType = "_droidmirror._tcp"
                    port = SSE_PORT
                },
                NsdManager.PROTOCOL_DNS_SD,
                listener)
            Log.i(TAG, "mDNS registration requested")
        } catch (e: Exception) {
            Log.e(TAG, "mDNS error", e)
        }
    }

    private fun unregisterMdns() {
        val mgr = nsdManager
        val listener = nsdListener
        nsdManager = null
        nsdListener = null
        if (mgr != null && listener != null) {
            try {
                mgr.unregisterService(listener)
                Log.i(TAG, "mDNS unregistered")
            } catch (e: Exception) {
                Log.e(TAG, "mDNS unregister failed", e)
            }
        }
    }

    private fun getDeviceModel(): String {
        return try {
            val proc = Runtime.getRuntime().exec(arrayOf("getprop", "ro.product.model"))
            proc.inputStream.bufferedReader().readLine().trim().ifEmpty { "Android Device" }
        } catch (_: Exception) { "Android Device" }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("DroidMirror Agent")
            .setContentText("服务运行中")
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Agent Service", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "DroidMirror Agent"
                    setShowBadge(false)
                })
        }
    }
}
