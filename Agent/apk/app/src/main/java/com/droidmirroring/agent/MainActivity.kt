package com.droidmirroring.agent

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.droidmirroring.agent.databinding.ActivityMainBinding
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private val TAG = "MainActivity"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val prefs = getSharedPreferences(AgentService.PREFS_NAME, MODE_PRIVATE)
        val savedPort = prefs.getString(AgentService.KEY_PORT, "5555") ?: "5555"
        binding.editPort.setText(savedPort)
        binding.textPort.text = "ADB 端口: $savedPort"
        updateUi()

        binding.btnApplyPort.setOnClickListener {
            val port = binding.editPort.text.toString()
            if (port.isNotEmpty() && port.toIntOrNull() in 1024..65535) {
                prefs.edit().putString(AgentService.KEY_PORT, port).apply()
                binding.textPort.text = "ADB 端口: $port"
                if (AgentService.isRunning) {
                    stopService(Intent(this, AgentService::class.java))
                    binding.switchAgent.isChecked = false
                }
            }
        }

        binding.switchAgent.setOnCheckedChangeListener { _, isChecked ->
            Log.i(TAG, "switch toggled: isChecked=$isChecked")
            if (isChecked) {
                // Check notification listener permission
                if (!isNotificationListenerEnabled()) {
                    showNotificationGuide()
                    binding.switchAgent.isChecked = false
                    return@setOnCheckedChangeListener
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                        binding.switchAgent.isChecked = false
                        return@setOnCheckedChangeListener
                    }
                }
                AgentService.isRunning = true
                startService(Intent(this, AgentService::class.java))
                showBatteryGuide()
            } else {
                AgentService.isRunning = false
                stopService(Intent(this, AgentService::class.java))
            }
            updateUi()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            AgentService.isRunning = true
            startService(Intent(this, AgentService::class.java))
            updateUi()
        }
    }

    override fun onResume() {
        super.onResume()
        updateUi()
    }

    private fun updateUi() {
        val running = AgentService.isRunning
        val notifyOk = isNotificationListenerEnabled()
        binding.switchAgent.isChecked = running
        binding.textStatus.text = when {
            running && notifyOk -> "发现 + 通知已开启"
            running -> "发现已开启（通知未授权）"
            !notifyOk -> "需通知权限"
            else -> "已关闭"
        }
        binding.textAddress.text = "IP: ${getWifiIp()}"
    }

    private fun showBatteryGuide() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        AlertDialog.Builder(this)
            .setTitle("保持后台运行")
            .setMessage("为防止通知推送被系统关闭，建议关闭电池优化。\n\n是否前往设置？")
            .setPositiveButton("去设置") { _, _ ->
                try {
                    startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    })
                } catch (_: Exception) {}
            }
            .setNegativeButton("稍后", null)
            .show()
    }

    private fun getWifiIp(): String {
        try {
            NetworkInterface.getNetworkInterfaces()?.asIterator()?.forEach { intf ->
                if (!intf.isUp || intf.isLoopback) return@forEach
                intf.inetAddresses.asIterator().forEach { addr ->
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        return addr.hostAddress ?: "--"
                    }
                }
            }
        } catch (_: Exception) {}
        return "--"
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val cn = ComponentName(this, NotifyListener::class.java)
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
        return flat.contains(cn.flattenToString())
    }

    private fun showNotificationGuide() {
        AlertDialog.Builder(this)
            .setTitle("需要通知权限")
            .setMessage("Mac 端接收手机通知需要开启「通知使用权」。\n\n是否前往设置？")
            .setPositiveButton("去设置") { _, _ ->
                try {
                    startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS"))
                } catch (_: Exception) {
                    startActivity(Intent(Settings.ACTION_SETTINGS))
                }
            }
            .setNegativeButton("稍后", null)
            .show()
    }
}
