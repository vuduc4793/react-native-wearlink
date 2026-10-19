package com.smartwear.core.phone

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import com.smartwear.core.ConnectionState
import com.smartwear.core.MusicCommand
import com.smartwear.core.MusicRemote
import com.smartwear.core.MusicState
import com.smartwear.core.SmartWearLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Trình phát nhạc của điện thoại ↔ thiết bị ([MusicRemote]), như `ServicePresenter` (`registerMediaController`,
 * `setResponseMusicControlRk`) của GloryFitPro: theo dõi mọi phiên MediaSession (cần quyền đọc thông báo), đẩy trạng thái +
 * tên bài, đẩy âm lượng khi đổi, và làm theo nút nhạc trên thiết bị (phím media, âm lượng `STREAM_MUSIC`).
 */
class PhoneMusic internal constructor(
    private val context: Context,
    private val link: PhoneLink,
    private val scope: CoroutineScope,
) {
    private val main = Handler(Looper.getMainLooper())
    private val prefs = context.getSharedPreferences(PhoneLinkConfig.PREFS, Context.MODE_PRIVATE)
    private val audio = context.getSystemService(AudioManager::class.java)
    private var sessions: MediaSessionManager? = null
    private var controllers: List<MediaController> = emptyList()
    private var sessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private var musicActive = false
    private var playState = 0
    private var songName = ""
    private var singerName = ""
    private var lastSent: List<Any>? = null
    private var pushJob: Job? = null

    private val controllerCallback = object : MediaController.Callback() {
        override fun onSessionDestroyed() {
            musicActive = false
            playState = PlaybackState.STATE_STOPPED
            songName = ""
            singerName = ""
            schedulePush(500)
        }

        override fun onPlaybackStateChanged(state: PlaybackState?) {
            val s = state?.state ?: return
            if (s != PlaybackState.STATE_PAUSED && s != PlaybackState.STATE_PLAYING && s != PlaybackState.STATE_STOPPED) return
            playState = s
            musicActive = s == PlaybackState.STATE_PLAYING
            schedulePush(if (musicActive) 500 else 1000)
        }

        override fun onMetadataChanged(metadata: MediaMetadata?) {
            metadata ?: return
            val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty()
            if (title.isEmpty()) return
            singerName = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty()
            songName = title
            prefs.edit().putString("lastSong", songName).putString("lastSinger", singerName).apply()
            schedulePush(if (playState == PlaybackState.STATE_PLAYING) 500 else 1000)
        }
    }

    /**
     * Theo dõi mọi phiên phát nhạc như `ServicePresenter.registerMediaController`. [PhoneNotificationListener] gọi khi đã kết nối
     * (vì `getActiveSessions` cần quyền đọc thông báo).
     */
    fun start() {
        if (sessions != null) return
        val msm = context.getSystemService(MediaSessionManager::class.java) ?: return
        val component = ComponentName(context, PhoneNotificationListener::class.java)
        runCatching {
            val l = MediaSessionManager.OnActiveSessionsChangedListener { list -> registerControllers(list.orEmpty()) }
            msm.addOnActiveSessionsChangedListener(l, component, main)
            sessionsListener = l
            sessions = msm
            registerControllers(msm.getActiveSessions(component))
        }.onFailure { SmartWearLog.w("Không đọc được phiên phát nhạc: ${it.message}") }
    }

    fun stop() {
        controllers.forEach { it.unregisterCallback(controllerCallback) }
        controllers = emptyList()
        sessionsListener?.let { sessions?.removeOnActiveSessionsChangedListener(it) }
        sessionsListener = null
        sessions = null
    }

    private fun registerControllers(list: List<MediaController>) {
        if (list.isEmpty()) return
        controllers.forEach { it.unregisterCallback(controllerCallback) }
        controllers = list
        list.forEach { it.registerCallback(controllerCallback, main) }
    }

    private fun schedulePush(delayMs: Long) {
        pushJob?.cancel()
        pushJob = scope.launch {
            delay(delayMs)
            push(volumeOnly = false)
        }
    }

    /** Âm lượng `STREAM_MUSIC` đổi (broadcast `VOLUME_CHANGED_ACTION`, [PhoneLink] nhận). */
    internal fun pushVolume() = push(volumeOnly = true)

    /**
     * `ServicePresenter` message 3: dựng thông tin (âm lượng thang 15, bài; trống thì lấy bài lưu lần trước), chỉ gửi khi khác lần
     * gửi trước. [volumeOnly] ⇒ [MusicRemote.setMusicVolume]; còn lại ⇒ [MusicRemote.setMusicState] (đang phát + tên bài như Pro).
     */
    private fun push(volumeOnly: Boolean) {
        if (!link.config.value.music) return
        val ws = link.manager.devices.value
            .filter { it.state.value == ConnectionState.CONNECTED }
            .filterIsInstance<MusicRemote>()
            .filter { it.supportsMusicControl || it.supportsTrackInfo }
        if (ws.isEmpty()) return
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val percent = PhoneText.volumePercent(audio.getStreamVolume(AudioManager.STREAM_MUSIC), max)
        var song = songName
        var singer = singerName
        if (song.isEmpty()) {
            song = prefs.getString("lastSong", "").orEmpty()
            if (singer.isEmpty()) singer = prefs.getString("lastSinger", "").orEmpty()
        }
        val info = listOf(percent, playState, song, singer)
        if (info == lastSent) return
        lastSent = info
        if (volumeOnly) {
            ws.forEach { scope.launch { it.setMusicVolume(percent) } }
        } else {
            val state = MusicState(playing = playState == PlaybackState.STATE_PLAYING, title = song)
            ws.forEach { scope.launch { it.setMusicState(state) } }
        }
    }

    /**
     * Nút nhạc trên thiết bị (`ServicePresenter.setResponseMusicControlRk`): phát/tạm dừng theo trạng thái đang biết, bài sau /
     * trước bằng phím media (`dispatchMediaKeyEvent` + broadcast `com.android.music.musicservicecommand`), âm lượng ±1 bậc
     * `STREAM_MUSIC` có hiện thanh âm lượng.
     */
    fun onCommand(c: MusicCommand) {
        when (c) {
            MusicCommand.PLAY_PAUSE -> if (musicActive) mediaKey(KeyEvent.KEYCODE_MEDIA_PAUSE, "pause", active = false)
            else mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY, "play", active = true)
            MusicCommand.NEXT -> mediaKey(KeyEvent.KEYCODE_MEDIA_NEXT, "next", active = true)
            MusicCommand.PREVIOUS -> mediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS, "previous", active = true)
            MusicCommand.VOLUME_UP, MusicCommand.VOLUME_DOWN -> {
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val scaled = PhoneText.volumePercent(audio.getStreamVolume(AudioManager.STREAM_MUSIC), max) * 15 / 100
                if (c == MusicCommand.VOLUME_UP && scaled < 15) {
                    audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
                } else if (c == MusicCommand.VOLUME_DOWN && scaled > 0) {
                    audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
                }
            }
        }
    }

    private fun mediaKey(code: Int, command: String, active: Boolean) {
        musicActive = active
        val now = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(now - 1, now - 1, KeyEvent.ACTION_DOWN, code, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
        context.sendBroadcast(Intent("com.android.music.musicservicecommand").putExtra("command", command))
    }
}
