package com.smartwear.lab.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.smartwear.core.Capability
import com.smartwear.core.Reading
import com.smartwear.core.ReadingStatus
import com.smartwear.lab.R
import java.util.Locale

/** Inter (OFL) thay cho SF Pro, vốn không được phép dùng trên Android. */
@OptIn(ExperimentalTextApi::class)
private fun inter(weight: Int) = Font(
    R.font.inter,
    weight = FontWeight(weight),
    variationSettings = FontVariation.Settings(FontVariation.weight(weight)),
)

val Inter = FontFamily(inter(400), inter(500), inter(600), inter(700))

object Palette {
    val background = Color(0xFF050608)
    val label = Color(0xFFF5F5F7)
    val secondary = Color(0xFFA1A1A6)
    val tertiary = Color(0xFF6E6E73)
    val separator = Color(0x1FFFFFFF)
    val green = Color(0xFF30D158)
    val orange = Color(0xFFFF9F0A)
    val red = Color(0xFFFF453A)
    val accent = Color(0xFF0A84FF)

    /** Màu nhận diện thiết bị, gán theo thứ tự thêm vào. */
    val devices = listOf(
        Color(0xFF5DE0C8), Color(0xFFF2C46B), Color(0xFF7FB4FF), Color(0xFFFF8A65),
        Color(0xFFB9A3FF), Color(0xFF9BE15D), Color(0xFFFF7AA8),
    )
}

object Type {
    val largeTitle = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Bold, fontSize = 32.sp, letterSpacing = (-0.02).em)
    val title = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, letterSpacing = (-0.01).em)
    val headline = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    val body = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 16.sp)
    val callout = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 15.sp)
    val footnote = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Normal, fontSize = 13.sp)
    val caption = TextStyle(fontFamily = Inter, fontWeight = FontWeight.Medium, fontSize = 12.sp)
    val hero = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 76.sp, letterSpacing = (-0.04).em)
    val metric = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 28.sp, letterSpacing = (-0.02).em)
    val mono = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp)
}

@Composable
fun SmartWearTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            background = Palette.background,
            surface = Palette.background,
            primary = Palette.label,
            onPrimary = Color.Black,
        ),
        content = content,
    )
}

/** Thông tin hiển thị cho từng capability. */
data class CapabilityStyle(val label: String, val unit: String, val color: Color, val historyOnly: Boolean = false)

val Capability.style: CapabilityStyle
    get() = when (this) {
        Capability.HEART_RATE -> CapabilityStyle("Nhịp tim", "bpm", Color(0xFFFF453A))
        Capability.SPO2 -> CapabilityStyle("SpO2", "%", Color(0xFF64D2FF))
        Capability.TEMPERATURE -> CapabilityStyle("Nhiệt độ", "°C", Color(0xFFFF9F0A))
        Capability.BLOOD_PRESSURE -> CapabilityStyle("Huyết áp", "mmHg", Color(0xFFFF375F))
        Capability.STRESS -> CapabilityStyle("Stress", "", Color(0xFF66D4CF))
        Capability.HRV -> CapabilityStyle("HRV", "ms", Color(0xFF30D158))
        Capability.BLOOD_SUGAR -> CapabilityStyle("Đường huyết", "mmol/L", Color(0xFFFFD60A))
        Capability.ECG -> CapabilityStyle("ECG", "", Color(0xFFFF6482))
        Capability.STEPS -> CapabilityStyle("Bước chân", "", Color(0xFF32D74B), historyOnly = true)
        Capability.SLEEP -> CapabilityStyle("Giấc ngủ", "", Color(0xFF7D7AFF), historyOnly = true)
        Capability.MENSTRUATION -> CapabilityStyle("Chu kỳ", "", Color(0xFFFF6FAE), historyOnly = true)
        Capability.GESTURE -> CapabilityStyle("Cử chỉ chạm", "", Color(0xFFAEAEB2), historyOnly = true)
        Capability.MET -> CapabilityStyle("MET", "", Color(0xFFFFB340), historyOnly = true)
        Capability.URIC_ACID -> CapabilityStyle("Acid uric", "μmol/L", Color(0xFFBF5AF2))
        Capability.BLOOD_LIPIDS -> CapabilityStyle("Mỡ máu", "mmol/L", Color(0xFFFF8A65))
        Capability.BODY_COMPOSITION -> CapabilityStyle("Thành phần cơ thể", "% mỡ", Color(0xFF5AC8FA))
    }

/** Số chữ số thập phân khi hiển thị giá trị của capability. */
fun Capability.decimals(): Int = when (this) {
    Capability.TEMPERATURE, Capability.BLOOD_SUGAR, Capability.MET, Capability.BODY_COMPOSITION -> 1
    Capability.BLOOD_LIPIDS -> 2
    else -> 0
}

fun Capability.format(v: Double): String = if (decimals() == 0) Math.round(v).toString() else String.format(Locale("vi"), "%.${decimals()}f", v)

/** Chỉ số phụ của phép đo nhiều giá trị (mỡ máu, thành phần cơ thể), một dòng ngắn. */
fun Reading.extraText(): String? {
    if (status != ReadingStatus.OK || extra.isEmpty()) return null
    val names = mapOf(
        "uricAcid" to "uric", "totalCholesterol" to "TC", "triglycerides" to "TG", "hdl" to "HDL", "ldl" to "LDL",
        "bmi" to "BMI", "muscleRate" to "cơ %", "bodyWaterRate" to "nước %", "boneMass" to "xương kg", "basalMetabolicRate" to "BMR",
    )
    return extra.filterKeys { it in names }.entries.joinToString(" · ") { (k, v) -> "${names[k]} ${String.format(Locale("vi"), "%.1f", v)}" }
}

/** Giá trị hiển thị của một lần đo, ví dụ "79", "36,6", "120/80". Null nếu chưa có giá trị. */
fun Reading.display(): String? {
    if (status != ReadingStatus.OK) return null
    if (capability == Capability.BLOOD_PRESSURE) return if (systolic != null && diastolic != null) "$systolic/$diastolic" else null
    val v = value ?: return null
    return capability.format(v)
}

fun Reading?.statusText(): String = when (this?.status) {
    null -> "chưa đo"
    ReadingStatus.MEASURING -> "đang đo…"
    ReadingStatus.NOT_WORN -> if (this?.needsTouch == true) "Chưa chạm cảm biến" else "Chưa đeo"
    ReadingStatus.ERROR -> if (this?.needsTouch == true) "Lỗi: chưa chạm cảm biến" else "Lỗi khi đo"
    ReadingStatus.OK -> display() ?: "chưa đo"
}
