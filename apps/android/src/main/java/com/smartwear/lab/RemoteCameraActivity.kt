package com.smartwear.lab

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.smartwear.core.RemoteCameraEvent
import com.smartwear.core.SmartWearLog
import com.smartwear.lab.ui.ButtonKind
import com.smartwear.lab.ui.Palette
import com.smartwear.lab.ui.PillButton
import com.smartwear.lab.ui.SmartWearTheme
import com.smartwear.lab.ui.Type
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Màn chụp ảnh từ xa (bản CameraX của `com.ute.camera.CameraActivity` trong GloryFitPro): mở màn ⇒ `C4 01` (khi đã có quyền
 * camera, như `onCreate` → `setCameraStatus(1)`), đóng ⇒ `C4 03` (`onDestroy` → `setCameraStatus(2)`). Đồng hồ bấm chụp
 * (`C4 02`/`D1 03`) ⇒ chụp; đồng hồ đóng màn chụp (`D1 0F`) ⇒ đóng (`onWatchCameraControl`). Ảnh lưu MediaStore, thư mục Ảnh/SmartWear.
 */
class RemoteCameraActivity : ComponentActivity() {

    private val bridge get() = (application as SmartWearApp).camera
    private lateinit var previewView: PreviewView
    private var imageCapture: ImageCapture? = null
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private val status = mutableStateOf<String?>(null)
    private val ready = mutableStateOf(false)
    private var shots = 0

    private val needed: Array<String>
        get() = if (Build.VERSION.SDK_INT < 29) arrayOf(Manifest.permission.CAMERA, Manifest.permission.WRITE_EXTERNAL_STORAGE)
        else arrayOf(Manifest.permission.CAMERA)

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (hasPermissions()) startCamera() else status.value = "Cần quyền camera để chụp ảnh từ xa"
    }

    private fun hasPermissions() = needed.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bridge.cameraShowing = true
        previewView = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        val watches = bridge.cameraDevices().joinToString { it.name }
        setContent {
            SmartWearTheme {
                val message by status
                val isReady by ready
                Box(Modifier.fillMaxSize().background(Color.Black)) {
                    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
                    Row(
                        Modifier.fillMaxWidth().statusBarsPadding().padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Chụp ảnh từ xa", style = Type.headline, color = Color.White)
                            Text(
                                if (watches.isEmpty()) "Chưa có đồng hồ kết nối" else "Bấm chụp trên $watches",
                                style = Type.footnote, color = Color.White.copy(alpha = 0.75f),
                            )
                        }
                        PillButton("Đóng", { finish() })
                    }
                    Column(
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 28.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        message?.let { Text(it, style = Type.footnote, color = Color.White) }
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                            PillButton("Đổi camera", { switchCamera() }, enabled = isReady)
                            Box(
                                Modifier.size(76.dp).clip(CircleShape).background(if (isReady) Color.White else Color.White.copy(alpha = 0.3f))
                                    .border(4.dp, Palette.separator, CircleShape)
                                    .clickable(enabled = isReady) { takePhoto() },
                            )
                            if (!hasPermissions()) PillButton("Cấp quyền", { permissions.launch(needed) }, kind = ButtonKind.PRIMARY)
                        }
                    }
                }
            }
        }
        lifecycleScope.launch {
            bridge.cameraEvents.collect { e ->
                when (e) {
                    RemoteCameraEvent.SHUTTER -> takePhoto()
                    RemoteCameraEvent.CLOSED -> finish()
                    RemoteCameraEvent.OPENED -> Unit
                }
            }
        }
        if (hasPermissions()) startCamera() else permissions.launch(needed)
    }

    override fun onDestroy() {
        bridge.setCameraOpen(false)
        super.onDestroy()
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            runCatching {
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                val capture = ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY).build()
                val selector = CameraSelector.Builder().requireLensFacing(lensFacing).build()
                provider.unbindAll()
                provider.bindToLifecycle(this, selector, preview, capture)
                imageCapture = capture
                if (!ready.value) bridge.setCameraOpen(true)
                ready.value = true
            }.onFailure {
                SmartWearLog.w("Mở camera lỗi: ${it.message}")
                status.value = "Không mở được camera: ${it.message}"
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun switchCamera() {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        startCamera()
    }

    private fun takePhoto() {
        val capture = imageCapture ?: return
        val name = "SmartWear_" + SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/SmartWear")
        }
        val options = ImageCapture.OutputFileOptions.Builder(contentResolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values).build()
        capture.takePicture(options, ContextCompat.getMainExecutor(this), object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                shots++
                status.value = "Đã lưu $shots ảnh vào Ảnh/SmartWear"
            }

            override fun onError(exception: ImageCaptureException) {
                SmartWearLog.w("Chụp ảnh lỗi: ${exception.message}")
                status.value = "Chụp lỗi: ${exception.message}"
            }
        })
    }
}
