package com.example.virtual_gamepad

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.bluetooth.*
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

@TargetApi(28)
@SuppressLint("MissingPermission")
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.gamepad.hid/bluetooth"
    private var hidDevice: BluetoothHidDevice? = null
    private var hostDevice: BluetoothDevice? = null

    private val HID_REPORT_DESC = byteArrayOf(
        0x05.toByte(), 0x01.toByte(),
        0x09.toByte(), 0x05.toByte(),
        0xA1.toByte(), 0x01.toByte(),
        0x85.toByte(), 0x01.toByte(),
        0x05.toByte(), 0x09.toByte(),
        0x19.toByte(), 0x01.toByte(),
        0x29.toByte(), 0x10.toByte(),
        0x15.toByte(), 0x00.toByte(),
        0x25.toByte(), 0x01.toByte(),
        0x75.toByte(), 0x01.toByte(),
        0x95.toByte(), 0x10.toByte(),
        0x81.toByte(), 0x02.toByte(),
        0x05.toByte(), 0x01.toByte(),
        0x09.toByte(), 0x30.toByte(),
        0x09.toByte(), 0x31.toByte(),
        0x09.toByte(), 0x32.toByte(),
        0x09.toByte(), 0x35.toByte(),
        0x15.toByte(), 0x81.toByte(),
        0x25.toByte(), 0x7F.toByte(),
        0x75.toByte(), 0x08.toByte(),
        0x95.toByte(), 0x04.toByte(),
        0x81.toByte(), 0x02.toByte(),
        0xC0.toByte()
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startHidProfile" -> initBluetoothHid(result)
                    "sendHidReport" -> {
                        val bytes = call.arguments as ByteArray
                        val dev = hidDevice
                        val host = hostDevice
                        if (dev != null && host != null) {
                            val reportId = bytes[0].toInt()
                            val payload = bytes.copyOfRange(1, 7)
                            dev.sendReport(host, reportId, payload)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun initBluetoothHid(result: MethodChannel.Result) {
        val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = btManager.adapter
        adapter.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                if (profile == BluetoothProfile.HID_DEVICE) {
                    hidDevice = proxy as BluetoothHidDevice
                    val sdp = BluetoothHidDeviceAppSdpSettings(
                        "Pro Virtual Gamepad",
                        "3D Swipe & Gyro Controller",
                        "FlutterHID",
                        BluetoothHidDevice.SUBCLASS1_COMBO,
                        HID_REPORT_DESC
                    )
                    hidDevice?.registerApp(sdp, null, null, Executors.newSingleThreadExecutor(),
                        object : BluetoothHidDevice.Callback() {
                            override fun onConnectionStateChanged(device: BluetoothDevice, state: Int) {
                                if (state == BluetoothProfile.STATE_CONNECTED) {
                                    hostDevice = device
                                }
                            }
                        })
                    result.success("蓝牙 HID 已就绪，请在目标设备蓝牙列表中搜索连接")
                }
            }
            override fun onServiceDisconnected(profile: Int) {
                hidDevice = null
            }
        }, BluetoothProfile.HID_DEVICE)
    }
}
