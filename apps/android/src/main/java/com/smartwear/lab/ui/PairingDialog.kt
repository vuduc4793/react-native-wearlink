package com.smartwear.lab.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartwear.core.PairingPrompt
import com.smartwear.core.WearableDevice

/** Lớp phủ khi một thiết bị cần người dùng thao tác để ghép nối (bind). */
@Composable
fun PairingOverlay(devices: List<WearableDevice>, colorOf: (WearableDevice) -> Color) {
    val pending = devices.firstNotNullOfOrNull { d -> d.pairingPrompt.collectAsState().value?.let { d to it } } ?: return
    val (device, prompt) = pending
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .padding(28.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(30.dp))
                .background(Color(0xF2202328))
                .glass(RoundedCornerShape(30.dp))
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Orb(colorOf(device), 64.dp, pulseKey = System.currentTimeMillis() / 1500)
            Spacer(Modifier.height(12.dp))
            Text("Ghép nối ${device.name}", style = Type.title, color = Palette.label, textAlign = TextAlign.Center)
            Spacer(Modifier.height(6.dp))
            when (prompt) {
                is PairingPrompt.ConfirmOnDevice -> {
                    Text(prompt.message, style = Type.body, color = Palette.secondary, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(18.dp))
                    PillButton("Huỷ", { device.disconnect() }, Modifier.fillMaxWidth())
                }
                is PairingPrompt.EnterCode -> {
                    var code by remember(prompt) { mutableStateOf("") }
                    Text(prompt.message, style = Type.body, color = Palette.secondary, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(18.dp))
                    BasicTextField(
                        value = code,
                        onValueChange = { v -> code = v.filter { it.isDigit() }.take(prompt.digits) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                        textStyle = Type.hero.copy(fontSize = 44.sp, color = Palette.label, textAlign = TextAlign.Center, letterSpacing = 12.sp),
                        cursorBrush = SolidColor(Palette.label),
                        modifier = Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(vertical = 10.dp),
                    )
                    Spacer(Modifier.height(18.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        PillButton("Huỷ", { device.disconnect() }, Modifier.weight(1f))
                        PillButton(
                            "Ghép nối",
                            { device.submitPairingCode(code) },
                            Modifier.weight(1f),
                            kind = ButtonKind.PRIMARY,
                            enabled = code.length == prompt.digits,
                        )
                    }
                }
            }
        }
    }
}
