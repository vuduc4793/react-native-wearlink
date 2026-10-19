package com.smartwear.core

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/** Danh sách quyền runtime cần xin trước khi quét/kết nối, theo phiên bản Android. */
object BlePermissions {

    fun required(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    fun granted(context: Context): Boolean = required().all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
}
