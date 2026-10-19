package com.smartwear.core

import android.util.Log

/** Log chung của các SDK. Bật [verbose] để in từng gói byte gửi/nhận. */
object SmartWearLog {
    const val TAG = "SmartWear"

    @Volatile
    var verbose: Boolean = false

    fun v(message: () -> String) {
        if (verbose) Log.v(TAG, message())
    }

    fun d(message: String) = Log.d(TAG, message)
    fun i(message: String) = Log.i(TAG, message)
    fun w(message: String, error: Throwable? = null) = Log.w(TAG, message, error)
    fun e(message: String, error: Throwable? = null) = Log.e(TAG, message, error)
}

fun ByteArray.toHex(): String = joinToString(" ") { "%02X".format(it) }
