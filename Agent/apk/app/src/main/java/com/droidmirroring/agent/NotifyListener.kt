package com.droidmirroring.agent

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

class NotifyListener : NotificationListenerService() {
    companion object {
        private const val TAG = "NotifyListener"
    }

    private val agentUrl = "http://127.0.0.1:5557/notifications"

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            val ext = sbn.notification.extras
            val json = JSONObject().apply {
                put("type", "posted")
                put("key", sbn.key)
                put("package", sbn.packageName)
                put("title", ext.getString("android.title") ?: "")
                put("text", ext.getString("android.text") ?: "")
                put("time", System.currentTimeMillis())
            }
            sendToAgent(json.toString())
        } catch (e: Exception) {
            Log.e(TAG, "failed to forward notification", e)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        try {
            val json = JSONObject().apply {
                put("type", "removed")
                put("key", sbn.key)
                put("package", sbn.packageName)
            }
            sendToAgent(json.toString())
        } catch (_: Exception) {}
    }

    private fun sendToAgent(json: String) {
        try {
            val url = URL(agentUrl)
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.connectTimeout = 2000
            conn.readTimeout = 2000
            OutputStreamWriter(conn.outputStream).use { it.write(json) }
            conn.responseCode
        } catch (_: Exception) {}
    }
}
