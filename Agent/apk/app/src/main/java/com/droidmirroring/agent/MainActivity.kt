package com.droidmirroring.agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
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
        val rootOk = hasRoot()
        binding.switchAgent.isChecked = running
        binding.textStatus.text = when {
            running && hasRoot() -> "ADB TCP 已开启"
            running -> "发现 + 通知已开启"
            !hasRoot() -> "需要 Root（可降级使用）"
            else -> "已关闭"
        }
        binding.textAddress.text = "IP: ${getWifiIp()}"
    }

    private fun hasRoot(): Boolean {
        return try {
            val proc = Runtime.getRuntime().exec(arrayOf("/system/bin/su", "-c", "id"))
            val result = proc.inputStream.bufferedReader().readLine()
            proc.waitFor()
            result?.contains("uid=0") == true
        } catch (_: Exception) {
            false
        }
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
}
