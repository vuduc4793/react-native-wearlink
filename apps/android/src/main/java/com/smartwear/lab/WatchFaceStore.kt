package com.smartwear.lab

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.smartwear.core.Complication
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.SmartWearLog
import com.smartwear.core.TimePosition
import com.smartwear.core.WatchFaceCustomizable
import com.smartwear.core.WatchFaceStyle
import com.smartwear.core.WatchWidget
import com.smartwear.core.WearableDevice
import com.smartwear.core.WidgetPlacement
import com.smartwear.core.WatchFaceManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * Lưu mặt đồng hồ mặc định của từng thiết bị: thiết kế tự chỉnh (ảnh + bố cục) hoặc một bộ trong [WatchFaceLibrary].
 * Khi thiết bị kết nối, tự cài lại nếu đồng hồ không còn hiển thị mặt tuỳ chỉnh (vừa reset, đổi mặt) hoặc mặc định đã đổi.
 * Thiết bị chưa có gì thì dùng [WatchFaceLibrary.DEFAULT_ID].
 */
class WatchFaceStore(private val context: Context, private val manager: DeviceManager) {

    /** [preset] khác null = bộ trong thư viện (khi đó [image], [style] null). */
    data class Saved(
        val image: Bitmap?,
        val style: WatchFaceStyle?,
        val preset: String?,
        val autoApply: Boolean,
        val hash: String,
        val pushedHash: String?,
    )

    /** Mặc định khi thiết bị chưa lưu gì: bộ [WatchFaceLibrary.DEFAULT_ID], chưa từng gửi. */
    private val fallback = Saved(null, null, WatchFaceLibrary.DEFAULT_ID, true, presetHash(WatchFaceLibrary.DEFAULT_ID), null)

    /** Trạng thái tự cài theo thiết bị, để UI hiển thị (null = không làm gì). */
    private val _status = MutableStateFlow<Map<String, String>>(emptyMap())
    val status: StateFlow<Map<String, String>> = _status.asStateFlow()

    /** Tạm tắt tự cài khi kết nối (chỉ trong phiên chạy, dùng khi gỡ lỗi). */
    @Volatile var paused = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val watched = mutableSetOf<String>()
    private val jobs = mutableMapOf<String, Job>()

    private fun dir(id: String) = File(context.filesDir, "watchfaces/" + id.replace(":", "")).apply { mkdirs() }

    /** Thiết kế đã lưu; null nếu chưa lưu gì (xem [effective]). */
    fun load(id: String): Saved? = runCatching {
        val d = dir(id)
        val meta = JSONObject(File(d, "design.json").readText())
        val pushedHash = meta.optString("pushedHash").ifEmpty { null }
        val preset = meta.optString("preset").ifEmpty { null }
        if (preset != null && WatchFaceLibrary.find(preset) == null) return null // bộ đã bỏ khỏi thư viện
        if (preset != null) return Saved(null, null, preset, meta.optBoolean("autoApply", true), presetHash(preset), pushedHash)
        val image = BitmapFactory.decodeFile(File(d, "image.png").path) ?: return null
        Saved(image, styleFromJson(meta.getJSONObject("style")), null, meta.optBoolean("autoApply", true), meta.getString("hash"), pushedHash)
    }.getOrNull()

    /** Mặc định thực tế của thiết bị: thiết kế đã lưu, hoặc bộ mặc định của thư viện. */
    fun effective(id: String): Saved = load(id) ?: fallback

    /** Lưu thiết kế tự chỉnh làm mặc định; [pushed] = vừa gửi thành công bản này lên đồng hồ. */
    fun save(id: String, image: Bitmap, style: WatchFaceStyle, autoApply: Boolean, pushed: Boolean) {
        val d = dir(id)
        File(d, "image.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val hash = hash(image, style)
        writeMeta(id, JSONObject().put("style", styleToJson(style)), autoApply, hash, pushed)
        _version.value++
    }

    /** Đặt một bộ trong thư viện làm mặc định. */
    fun savePreset(id: String, preset: String, autoApply: Boolean, pushed: Boolean) {
        File(dir(id), "image.png").delete()
        writeMeta(id, JSONObject().put("preset", preset), autoApply, presetHash(preset), pushed)
        _version.value++
    }

    private fun writeMeta(id: String, meta: JSONObject, autoApply: Boolean, hash: String, pushed: Boolean) {
        val previous = load(id)
        meta.put("autoApply", autoApply).put("hash", hash).put("pushedHash", if (pushed) hash else previous?.pushedHash ?: "")
        File(dir(id), "design.json").writeText(meta.toString())
    }

    fun setAutoApply(id: String, enabled: Boolean) {
        val s = effective(id)
        if (s.preset != null) savePreset(id, s.preset, enabled, pushed = false)
        else save(id, s.image!!, s.style!!, enabled, pushed = false)
    }

    /** Tăng mỗi lần lưu, để UI đọc lại [effective]. */
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()

    /** Cài một bộ trong thư viện lên thiết bị và đặt làm mặc định. */
    suspend fun installPreset(device: WearableDevice, preset: String, progress: (Float) -> Unit = {}) {
        val faces = device as? WatchFaceManager ?: throw IllegalStateException("${device.name} không cài được mặt đồng hồ")
        val bin = withContext(Dispatchers.IO) { WatchFaceLibrary.bin(context, preset) }
        faces.installWatchFace(bin, progress)
        withContext(Dispatchers.IO) { savePreset(device.id, preset, autoApply = effective(device.id).autoApply, pushed = true) }
    }

    /** Theo dõi mọi thiết bị: mỗi lần kết nối thì kiểm tra và tự cài lại nếu cần. */
    fun start() {
        scope.launch {
            manager.devices.collect { list ->
                for (d in list) {
                    if (d !is WatchFaceCustomizable || !watched.add(d.id)) continue
                    scope.launch {
                        d.state.collect { state ->
                            if (state == ConnectionState.CONNECTED && jobs[d.id]?.isActive != true) {
                                jobs[d.id] = scope.launch { ensure(d) }
                            }
                        }
                    }
                }
            }
        }
    }

    private suspend fun ensure(device: WearableDevice) {
        val face = device as WatchFaceCustomizable
        val saved = effective(device.id)
        if (!saved.autoApply || paused) return
        if (saved.preset != null && !face.supportsWatchFace) return
        delay(4_000) // để bắt tay và các lệnh khi kết nối chạy xong trước
        if (device.state.value != ConnectionState.CONNECTED) return
        val active = runCatching { face.isCustomWatchFaceActive() }.getOrElse { return }
        val changed = saved.pushedHash != saved.hash
        if (active && !changed) {
            SmartWearLog.i("[${device.name}] mặt đồng hồ đã đúng, không cần cài lại")
            return
        }
        if (saved.preset != null) {
            val spec = runCatching { face.watchFaceSpec() }.getOrElse { return }
            if (spec.width != WatchFaceLibrary.WIDTH || spec.height != WatchFaceLibrary.HEIGHT) return // thư viện chỉ có bộ 466 × 466
        }
        val reason = if (!active) "đồng hồ không hiển thị mặt của app" else "mặt mặc định đã thay đổi"
        SmartWearLog.i("[${device.name}] tự cài lại mặt đồng hồ: $reason")
        setStatus(device.id, "Đang tự cài mặt đồng hồ ($reason)…")
        val onProgress = { p: Float -> setStatus(device.id, "Đang tự cài mặt đồng hồ · ${(p * 100).toInt()} %") }
        runCatching {
            if (saved.preset != null) {
                installPreset(device, saved.preset, onProgress)
            } else {
                face.setWatchFace(saved.image!!, saved.style!!, onProgress)
                save(device.id, saved.image, saved.style, true, pushed = true)
            }
        }.onSuccess {
            setStatus(device.id, "Đã tự cài lại mặt đồng hồ")
        }.onFailure {
            setStatus(device.id, "Tự cài mặt đồng hồ lỗi: ${it.message}")
        }
    }

    private fun setStatus(id: String, text: String?) {
        _status.value = if (text == null) _status.value - id else _status.value + (id to text)
    }

    // ---------- JSON ----------

    private fun styleToJson(s: WatchFaceStyle) = JSONObject()
        .put("textColor", s.textColor).put("accentColor", s.accentColor).put("backgroundColor", s.backgroundColor)
        .put("timePosition", s.timePosition.name).put("imageScale", s.imageScale.toDouble()).put("timeSize", s.timeSize.toDouble())
        .put("scrim", s.scrim).put("hour12", s.hour12)
        .put("complications", JSONArray(s.complications.map { it.name }))
        .put("placements", JSONObject().apply {
            s.placements.forEach { (w, p) -> put(w.name, JSONObject().put("cx", p.cx.toDouble()).put("cy", p.cy.toDouble()).put("scale", p.scale.toDouble())) }
        })

    private fun styleFromJson(o: JSONObject): WatchFaceStyle {
        val comps = o.getJSONArray("complications").let { a -> (0 until a.length()).mapNotNull { runCatching { Complication.valueOf(a.getString(it)) }.getOrNull() }.toSet() }
        val pl = o.optJSONObject("placements")
        val placements = pl?.keys()?.asSequence()?.mapNotNull { k ->
            val w = runCatching { WatchWidget.valueOf(k) }.getOrNull() ?: return@mapNotNull null
            val p = pl.getJSONObject(k)
            w to WidgetPlacement(p.getDouble("cx").toFloat(), p.getDouble("cy").toFloat(), p.getDouble("scale").toFloat())
        }?.toMap().orEmpty()
        return WatchFaceStyle(
            textColor = o.getInt("textColor"), accentColor = o.getInt("accentColor"), backgroundColor = o.getInt("backgroundColor"),
            timePosition = TimePosition.valueOf(o.getString("timePosition")), imageScale = o.getDouble("imageScale").toFloat(),
            timeSize = o.getDouble("timeSize").toFloat(), scrim = o.getBoolean("scrim"), hour12 = o.getBoolean("hour12"),
            complications = comps, placements = placements,
        )
    }

    private fun presetHash(preset: String) = "preset:$preset"

    private fun hash(image: Bitmap, style: WatchFaceStyle): String {
        val md = MessageDigest.getInstance("SHA-256")
        val px = IntArray(image.width * image.height).also { image.getPixels(it, 0, image.width, 0, 0, image.width, image.height) }
        val buf = java.nio.ByteBuffer.allocate(px.size * 4).also { b -> px.forEach { b.putInt(it) } }
        md.update(buf.array())
        md.update(styleToJson(style).toString().toByteArray())
        return md.digest().joinToString("") { "%02x".format(it) }.take(16)
    }
}
