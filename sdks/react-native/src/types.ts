/** Kiểu dữ liệu trao đổi với native (cùng hình dạng trên Android và iOS). */

export type ConnectionState = 'DISCONNECTED' | 'CONNECTING' | 'CONNECTED' | 'DISCONNECTING';

export type Capability =
  | 'HEART_RATE' | 'SPO2' | 'TEMPERATURE' | 'BLOOD_PRESSURE' | 'STRESS' | 'HRV' | 'BLOOD_SUGAR' | 'ECG'
  | 'STEPS' | 'SLEEP' | 'MENSTRUATION' | 'GESTURE'
  | 'MET' | 'URIC_ACID' | 'BLOOD_LIPIDS' | 'BODY_COMPOSITION';

export type PairingPrompt =
  | { type: 'code'; digits: number; message: string }
  | { type: 'confirm'; message: string };

export interface Device {
  /** Android: địa chỉ MAC. iOS: UUID CoreBluetooth. */
  id: string;
  name: string;
  /** `qring` | `gloryfit` | `standard` */
  driver: string;
  model: string | null;
  state: ConnectionState;
  /** Đang bật giữ kết nối (tự nối lại). */
  kept: boolean;
  battery: number | null;
  rssi: number | null;
  firmware: string | null;
  capabilities: Capability[];
  /** Đo trực tiếp được. */
  measurable: Capability[];
  supportsHistory: boolean;
  supportsWeather: boolean;
  supportsContacts: boolean;
  supportsCallBluetooth: boolean;
  /** Phần cứng (nếu thiết bị báo). */
  hardware: string | null;
  /** Đang sạc (null nếu thiết bị không báo). */
  charging: boolean | null;
  /** Capability đang đo. */
  measuring: Capability[];
  /** Tính năng điện thoại ↔ thiết bị. Nền tảng không làm được thì false (xem `PhoneLinkSupport`). */
  features: DeviceFeatures;
  /** Số mục cài đặt (0 = không có). */
  controlCount: number;
  lastError: string | null;
  pairingPrompt: PairingPrompt | null;
}

export interface DiscoveredDevice {
  id: string;
  name: string | null;
  driver: string;
  model: string | null;
  rssi: number;
  /** Quảng bá dịch vụ nhịp tim chuẩn 0x180D (dây đo nhịp tim, đồng hồ đang phát nhịp tim). Y25 / GE54 không quảng bá:
   *  nhận theo `driver` ('gloryfit', 'veepoo'). */
  heartRateService: boolean;
}

export type ReadingStatus = 'MEASURING' | 'OK' | 'NOT_WORN' | 'ERROR';

export interface Reading {
  deviceId: string;
  capability: Capability;
  status: ReadingStatus;
  value: number | null;
  systolic: number | null;
  diastolic: number | null;
  /**
   * Ghi chú của driver. Thường là chữ cho người đọc; giá trị máy đọc được:
   * - `'TOUCH_SENSOR'`: phép đo cần ngón tay đặt lên cảm biến / điện cực của vòng tay (Veepoo: `URIC_ACID`, `BLOOD_LIPIDS`,
   *   `BODY_COMPOSITION`). Với `MEASURING`: nhắc "Đặt ngón tay lên cảm biến của vòng tay" (tiến độ ở `extra.progress`);
   *   với `NOT_WORN` / `ERROR`: đo hỏng vì không chạm, nhắc rồi đo lại.
   */
  note: string | null;
  /** ms từ 1970. */
  timestamp: number;
  /**
   * Phép đo nhiều chỉ số. `URIC_ACID` / `BLOOD_LIPIDS` (cùng một lần đo): `uricAcid` μmol/L, `totalCholesterol`, `triglycerides`, `hdl`,
   * `ldl` mmol/L. `BODY_COMPOSITION` (`value` = % mỡ): `bmi`, `bodyFatRate` %, `fatMass` kg, `fatFreeMass` kg, `muscleRate` %,
   * `muscleMass` kg, `subcutaneousFat` %, `bodyWaterRate` %, `waterMass` kg, `skeletalMuscleRate` %, `boneMass` kg, `proteinRate` %,
   * `proteinMass` kg, `basalMetabolicRate` kcal. Khi `MEASURING`: `progress` 0–100 (%) nếu thiết bị báo tiến độ.
   */
  extra?: Record<string, number>;
}

export interface HistoryPoint {
  t: number;
  v: number;
  /** Giá trị phụ: huyết áp `diastolic`, SpO2 `min`, bước `calories`/`distance`, mỡ máu `totalCholesterol`/`triglycerides`/`hdl`/`ldl`,
   *  HRV `rr0`…`rr9` (khoảng RR ms của phút đó, vẽ Lorenz). */
  extra?: Record<string, number>;
}
export type SleepStage = 'LIGHT' | 'DEEP' | 'REM' | 'AWAKE' | 'UNKNOWN';
export interface SleepSession {
  start: number;
  end: number;
  nap: boolean;
  segments: { start: number; minutes: number; stage: SleepStage }[];
}
export interface Workout {
  type: number;
  name: string;
  start: number;
  end: number;
  activeSeconds: number;
  steps: number | null;
  calories: number | null;
  distanceMeters: number | null;
  avgHeartRate: number | null;
  maxHeartRate: number | null;
  minHeartRate: number | null;
  /** Pace trung bình, giây/km. */
  paceSecondsPerKm: number | null;
  /** Khoảng giữa hai mẫu (giây). Từ 0.1.4. */
  sampleIntervalSeconds?: number | null;
  /** Thời gian ở 5 vùng nhịp tim (giây): khởi động, đốt mỡ, ưa khí, kỵ khí, tối đa. Từ 0.1.4. */
  heartRateZoneSeconds?: number[] | null;
  /** Sải bước TB / lớn nhất / nhỏ nhất (cm, theo app hãng). Từ 0.1.4. */
  avgStrideCm?: number | null;
  maxStrideCm?: number | null;
  minStrideCm?: number | null;
  /** Chuỗi mẫu theo thời gian do thiết bị ghi. Rỗng nếu thiết bị không gửi. Từ 0.1.4. */
  samples?: WorkoutSample[];
  /** Đường đi GPS do **đồng hồ** ghi (đồng hồ có GPS riêng, vd. HT43). Rỗng = không có GPS. Từ 0.1.4. */
  track?: TrackPoint[];
}
export interface WorkoutSample {
  /** epoch ms */
  t: number;
  heartRate: number | null;
  /** Môn đi/chạy. */
  paceSecondsPerKm: number | null;
  /** Môn đạp xe. */
  speedKmh: number | null;
  /** Nhịp bước (bước/phút) hoặc nhịp đạp. */
  cadence: number | null;
  latitude: number | null;
  longitude: number | null;
}
export interface TrackPoint {
  /** epoch ms */
  t: number;
  latitude: number;
  longitude: number;
}
export interface DeviceHistory {
  days: number;
  syncedAt: number;
  /** Tổng hôm nay (nếu thiết bị có). `calories` theo kcal. */
  today: { steps: number; calories: number; distanceMeters: number; activeMinutes: number | null } | null;
  series: Partial<Record<Capability, HistoryPoint[]>>;
  sleep: SleepSession[];
  workouts: Workout[];
  /** Bước đồng bộ lỗi (các bước khác vẫn chạy). */
  errors: string[];
}

export type ControlKind = 'action' | 'toggle' | 'number' | 'timeRange' | 'choice';
export type ControlValue = boolean | number | { from: number; to: number };
export interface DeviceControl {
  id: string;
  group: string;
  title: string;
  kind: ControlKind;
  value: ControlValue | null;
  detail: string | null;
  min: number;
  max: number;
  step: number;
  unit: string;
  options: string[];
  enabled: boolean;
  /** Hành động nguy hiểm (vd xoá dữ liệu): câu hỏi xác nhận app phải hiện trước khi gọi `runAction`. */
  confirm: string | null;
}

export type WeatherCondition =
  | 'SUNNY' | 'CLOUDY' | 'OVERCAST' | 'SHOWER' | 'THUNDERSTORM' | 'SLEET'
  | 'LIGHT_RAIN' | 'HEAVY_RAIN' | 'SNOW' | 'DUST' | 'FOG' | 'WIND';
export interface WeatherForecast {
  city: string;
  currentC: number;
  humidity: number;
  uvIndex: number;
  /** Phần tử đầu là hôm nay, tối đa 7 ngày. */
  days: { condition: WeatherCondition; highC: number; lowC: number }[];
}

export interface Contact { name: string; phone: string }
export interface CallBluetoothState {
  name: string;
  address: string;
  enabled: boolean;
  paired: boolean;
  connected: boolean;
}
export interface SyncProgress { deviceId: string; step: string; done: number; total: number }

// ---------- Tính năng điện thoại ↔ thiết bị (docs/plans/2026-10-19-full-feature-api.md) ----------

export interface DeviceFeatures {
  /** Android: app gửi thông báo app/SMS lên thiết bị (`sendNotification`, chuyển tiếp tự động). */
  notifications: boolean;
  /** iOS: thiết bị đã được cấp quyền đọc thông báo iPhone (ANCS). null = chưa biết / Android. */
  ancsAuthorized: boolean | null;
  /** Android: báo cuộc gọi đến lên thiết bị. */
  incomingCall: boolean;
  /** Thiết bị có nút từ chối cuộc gọi (`onRejectCall`). */
  rejectCall: boolean;
  /** Thiết bị điều khiển nhạc điện thoại (`onMusicCommand`). */
  musicControl: boolean;
  /** Thiết bị hiện tên bài hát (`setMusicState`). */
  trackInfo: boolean;
  /** Android: trả lời SMS nhanh từ thiết bị. */
  smsReply: boolean;
  /** Số liên hệ tối đa (0 = không có danh bạ). */
  maxContacts: number;
  clearContacts: boolean;
  /** Gọi điện qua Bluetooth cổ điển (HFP). */
  callAudio: boolean;
  watchFace: boolean;
  watchFaceSlots: boolean;
  /** Android: dựng mặt đồng hồ từ ảnh (`setWatchFaceImage`). */
  customWatchFace: boolean;
  workoutControl: boolean;
  sportList: boolean;
  /** Thiết bị xin vị trí điện thoại khi tập ngoài trời (`onLocationRequest` → `sendLocation`). */
  phoneLocation: boolean;
  remoteCamera: boolean;
  /** Android: nạp firmware chính hãng (OTA). */
  firmwareUpdate: boolean;
  /** Đọc/ghi báo thức (`getAlarms`, `setAlarm`, `deleteAlarm`). */
  alarms: boolean;
  /** Số báo thức tối đa (0 = không có). */
  maxAlarms: number;
  /** Nhịp tim liên tục (`startHeartRateStream`). Chỉ đúng khi đã kết nối. */
  heartRateStream: boolean;
  /** Thiết bị có GPS riêng nhận AGPS (`getAgpsStatus`, `sendAgpsPosition`, `uploadAgpsFiles`). Chỉ đúng khi đã kết nối. */
  agps: boolean;
}

/** Thông tin AGPS thiết bị báo (`getAgpsStatus`). */
export interface AgpsStatus {
  /** Tên file dữ liệu vệ tinh thiết bị cần; gửi đúng tên này trong `uploadAgpsFiles`. */
  files: string[];
  /** Mã nền tảng GNSS của thiết bị (dùng khi xin file từ nguồn dữ liệu). */
  version: number | null;
  /** Chu kỳ thiết bị báo (đơn vị chưa rõ). */
  interval: number | null;
  /** Thiết bị còn dữ liệu vệ tinh hợp lệ; null = không hỏi được. */
  ephemerisValid: boolean | null;
}

/**
 * Thiết bị hỏi AGPS (`onAgpsRequest`). `STATUS`: đã có file chưa (HT43 hỏi mỗi 60 s khi hết dữ liệu); `DOWNLOAD`: sẵn sàng
 * nhận file; `POSITION`: xin vị trí điện thoại. `handled` = thư viện đã tự trả lời bằng vị trí / file app đặt sẵn.
 */
export interface AgpsRequestEvent {
  deviceId: string;
  request: 'STATUS' | 'DOWNLOAD' | 'POSITION';
  handled: boolean;
}

/** Một file dữ liệu vệ tinh (app tự lấy từ nguồn được phép). `name` lấy từ `AgpsStatus.files`. */
export interface AgpsFileData { name: string; base64: string }

/**
 * Một mẫu của luồng nhịp tim liên tục (`onHeartRate`). `t` ms epoch lúc điện thoại nhận.
 * - `bpm` null + `connected: false`: vừa mất kết nối ⇒ bắt đầu khoảng trống nhịp tim (thư viện tự nối lại và mở lại luồng).
 * - `bpm` null + `contact: false`: thiết bị chưa đeo / cảm biến không chạm da.
 * - `error` khác null: luồng lỗi, thư viện thử lại sau 3 s; `'unsupported'` = thiết bị không có nhịp tim liên tục, luồng dừng.
 * Quá 5 s không có mẫu thì coi giá trị đang hiện là cũ (khoảng trống).
 */
export interface HeartRateEvent {
  deviceId: string;
  bpm: number | null;
  /** Khoảng RR (ms) từ dây đo chuẩn, gộp từ các gói kể từ mẫu trước. Rỗng nếu thiết bị không gửi. */
  rrMs: number[];
  contact: boolean | null;
  t: number;
  connected: boolean;
  error: string | null;
}

/** Báo thức trên thiết bị. `repeatDays`: bit0 = thứ Hai … bit6 = Chủ nhật, 0 = một lần. `id` < 0 khi thêm mới. */
export interface Alarm {
  id: number;
  hour: number;
  minute: number;
  repeatDays: number;
  enabled: boolean;
  label: string | null;
}

export type MusicCommand = 'PLAY_PAUSE' | 'NEXT' | 'PREVIOUS' | 'VOLUME_UP' | 'VOLUME_DOWN';
export interface MusicState {
  playing: boolean;
  title?: string | null;
  artist?: string | null;
  /** 0–100. */
  volumePercent?: number | null;
  durationSec?: number | null;
  positionSec?: number | null;
}

export interface NotificationApp {
  /** Khoá dùng cho `sendNotification` và cấu hình chuyển tiếp. */
  key: string;
  name: string;
  /** Gói Android thuộc app này. */
  packages: string[];
  /** Thiết bị có biểu tượng riêng cho app này. */
  hasIcon: boolean;
}

export interface SmsReplyConfig {
  enabled: boolean;
  /** Mẫu trả lời người dùng đặt. */
  templates: string[];
  /** Mẫu cố định của thiết bị (không sửa được). */
  fixedTemplates: string[];
  /** Số mẫu tự đặt tối đa. */
  maxCustom: number;
}
export interface SmsReplyRequest { deviceId: string; number: string; text: string }

export interface WatchFaceInfo {
  width: number;
  height: number;
  round: boolean;
  maxBytes: number;
  currentId: number;
  slotCount: number;
  customActive: boolean;
}
export interface WatchFaceSlot { index: number; faceId: number }

export interface SportType { type: number; name: string; shown: boolean; position: number }
export type WorkoutState = 'STARTED' | 'PAUSED' | 'RESUMED' | 'STOPPED';
export interface WorkoutRealtime {
  sportType: number;
  heartRate: number | null;
  calories: number;
  paceSecondsPerKm: number;
  steps: number;
  count: number;
  distanceMeters: number;
}
export type WorkoutEvent =
  | { deviceId: string; kind: 'state'; state: WorkoutState; sportType: number; byDevice: boolean }
  | ({ deviceId: string; kind: 'realtime' } & WorkoutRealtime);
export interface LocationRequest { deviceId: string; start: boolean; sportType: number | null }
export interface PhoneLocation {
  latitude: number;
  longitude: number;
  altitude?: number;
  /** m/s. */
  speed?: number;
  accuracy?: number;
}

export type DeviceEventName = 'SWITCH_SCREEN_BUTTON' | 'LONG_PRESS_BUTTON_2' | 'LONG_PRESS_BUTTON_3' | 'SOS_BUTTON';
export type RemoteCameraEvent = 'SHUTTER' | 'OPENED' | 'CLOSED';

export interface TransferProgress {
  deviceId: string;
  /** `watchFace` | `contacts` | `firmware` | `agps` */
  what: string;
  /** 0–1. */
  fraction: number;
}

export interface FirmwareCheck {
  /** Image hợp lệ và đúng thiết bị. */
  valid: boolean;
  model: string | null;
  version: string | null;
  /** Lý do không hợp lệ. */
  reason: string | null;
  /** Mô tả chi tiết image. */
  details: string | null;
}

export interface ScanState {
  scanning: boolean;
  error: string | null;
  bluetooth: 'on' | 'off' | 'unauthorized' | 'unknown';
}

/**
 * Android: SDK tự chuyển thông báo / cuộc gọi / nhạc / SMS lên thiết bị đang kết nối, chạy native (không cần JS sống).
 * iOS: hệ thống lo qua ANCS + HFP, cấu hình này không có tác dụng.
 */
export interface PhoneLinkConfig {
  /** Khoá app (`NotificationApp.key`) được chuyển thông báo; rỗng = không chuyển app nào (mặc định). */
  apps: string[];
  /** Chuyển tin SMS (cần quyền đọc thông báo). */
  sms: boolean;
  /** Báo cuộc gọi đến (cần `READ_PHONE_STATE`, `READ_CALL_LOG`; tên từ danh bạ cần `READ_CONTACTS`). Từ chối cuộc gọi
   *  từ thiết bị: bật control `dnd.endCall` của thiết bị, cần `ANSWER_PHONE_CALLS` (Android 9+). */
  calls: boolean;
  /** Điều khiển nhạc + đẩy bài đang phát (cần quyền đọc thông báo). */
  music: boolean;
  /** Gửi SMS khi thiết bị yêu cầu trả lời nhanh (cần `SEND_SMS`). */
  smsReply: boolean;
}

/** Kiểu mặt đồng hồ dựng từ ảnh (Android). Màu dạng 0xAARRGGBB. */
export interface WatchFaceImageStyle {
  timePosition?: 'TOP' | 'CENTER' | 'BOTTOM';
  textColor?: number;
  accentColor?: number;
  backgroundColor?: number;
  hour12?: boolean;
  /** Thành phần hiện thêm: WEEKDAY, DATE, BATTERY, BLUETOOTH, STEPS, STEP_PROGRESS, SECONDS, HEART_RATE, CALORIES, DISTANCE. */
  complications?: string[];
}
