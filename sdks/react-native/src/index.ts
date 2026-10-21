import type { EventSubscription } from 'react-native';
import NativeOrNull, { type Spec } from './NativeSmartWear';
import type {
  Alarm, CallBluetoothState, Capability, Contact, ControlValue, Device, DeviceControl, DeviceEventName, DeviceHistory,
  DiscoveredDevice, FirmwareCheck, LocationRequest, MusicCommand, MusicState,
  NotificationApp, PhoneLinkConfig, PhoneLocation, Reading, RemoteCameraEvent, ScanState, SmsReplyConfig,
  SmsReplyRequest, SportType, SyncProgress, TransferProgress, WatchFaceInfo, WatchFaceSlot, WeatherCondition,
  WatchFaceImageStyle, WeatherForecast, WorkoutEvent,
} from './types';

export * from './types';

/** Binary thiếu module native: import vẫn được, chỉ lúc gọi mới báo lỗi. Kiểm `SmartWear.isAvailable` trước. */
const Native: Spec = NativeOrNull ?? new Proxy({} as Spec, {
  get: () => () => {
    throw new Error('react-native-wearlink: module native SmartWear không có trong bản build này (SmartWear.isAvailable = false)');
  },
});

/** Gọi cổng chung `invoke`; native luôn trả `{ value }`. */
function call<T = void>(method: string, deviceId = '', args: object = {}): Promise<T> {
  return Native.invoke(method, deviceId, args).then(r => (r as { value: T }).value);
}

/** Nghe một loại sự kiện của cổng chung `onEvent`. */
function on<T>(type: string, cb: (e: T) => void): EventSubscription {
  return Native.onEvent(e => {
    const { type: t, ...rest } = e as { type: string };
    if (t === type) cb(rest as T);
  });
}

/**
 * SmartWear: kết nối, đo, đồng bộ, cài đặt cho nhẫn/vòng QRing, đồng hồ GloryFit/UTE và thiết bị Bluetooth chuẩn.
 *
 * ```ts
 * SmartWear.start();
 * SmartWear.onDiscovered(list => setFound(list));
 * SmartWear.startScan(20);
 * await SmartWear.connect(found[0].id);          // giữ kết nối: tự nối lại khi mất, cả lần mở app sau
 * SmartWear.onReading(r => console.log(r.capability, r.value));
 * SmartWear.measure(id, 'HEART_RATE');
 * ```
 */
export const SmartWear = {
  /** Bản build có module native. False khi JS mới chạy trên binary cũ (OTA): đừng gọi hàm nào khác. */
  isAvailable: NativeOrNull != null,
  start: () => Native.start(),
  startScan: (seconds = 30) => Native.startScan(seconds),
  stopScan: () => Native.stopScan(),
  getDiscovered: () => Native.getDiscovered() as Promise<DiscoveredDevice[]>,
  getDevices: () => Native.getDevices() as Promise<Device[]>,
  connect: (id: string, keep = true) => Native.connect(id, keep),
  disconnect: (id: string) => Native.disconnect(id),
  forget: (id: string) => Native.forget(id),
  setKeepConnected: (id: string, keep: boolean) => Native.setKeepConnected(id, keep),
  submitPairingCode: (id: string, code: string) => Native.submitPairingCode(id, code),

  measure: (id: string, capability: Capability) => Native.measure(id, capability),
  stopMeasure: (id: string, capability: Capability) => Native.stopMeasure(id, capability),
  syncHistory: (id: string, days = 7) => Native.syncHistory(id, days) as Promise<DeviceHistory>,

  getControls: (id: string) => Native.getControls(id) as Promise<DeviceControl[]>,
  setControl: (id: string, controlId: string, value: ControlValue) => Native.setControl(id, controlId, { value }),
  runAction: (id: string, actionId: string) => Native.runAction(id, actionId),

  setWeather: (id: string, forecast: WeatherForecast) => Native.setWeather(id, forecast as unknown as object),
  syncContacts: (id: string, contacts: Contact[]) => Native.syncContacts(id, contacts as unknown as object[]),
  getCallBluetoothState: (id: string) => Native.getCallBluetoothState(id) as Promise<CallBluetoothState>,
  pairCallBluetooth: (id: string) => Native.pairCallBluetooth(id),
  setPhoneRinging: (id: string, ringing: boolean) => Native.setPhoneRinging(id, ringing),

  onDevicesChanged: (cb: (devices: Device[]) => void): EventSubscription =>
    Native.onDevicesChanged(e => cb((e as { devices: Device[] }).devices)),
  onDiscovered: (cb: (devices: DiscoveredDevice[]) => void): EventSubscription =>
    Native.onDiscovered(e => cb((e as { devices: DiscoveredDevice[] }).devices)),
  onReading: (cb: (r: Reading) => void): EventSubscription => Native.onReading(e => cb(e as Reading)),
  /** Thiết bị bấm "tìm điện thoại": `ringing` true = đổ chuông, false = dừng. App tự phát âm thanh. */
  onFindPhone: (cb: (e: { deviceId: string; ringing: boolean }) => void): EventSubscription =>
    Native.onFindPhone(e => cb(e as { deviceId: string; ringing: boolean })),
  onSyncProgress: (cb: (p: SyncProgress) => void): EventSubscription => Native.onSyncProgress(e => cb(e as SyncProgress)),

  // ---------- Trạng thái, pin, lịch sử đã lưu ----------

  getScanState: () => call<ScanState>('getScanState'),
  /** Quét bật/tắt, lỗi quét, Bluetooth bật/tắt/chưa cấp quyền. */
  onScanState: (cb: (s: ScanState) => void) => on('scanState', cb),
  /** Đọc lại pin ngay (null nếu thiết bị không báo). */
  refreshBattery: (id: string) => call<number | null>('refreshBattery', id),
  /** Lịch sử của lần đồng bộ gần nhất (không đồng bộ lại); null nếu chưa có. */
  getHistory: (id: string) => call<DeviceHistory | null>('getHistory', id),

  // ---------- Thông báo, cuộc gọi, SMS (Android; iOS do hệ thống lo qua ANCS) ----------

  /**
   * Android: bật / cấu hình việc SDK tự chuyển thông báo, cuộc gọi, nhạc, trả lời SMS lên thiết bị (chạy native kể cả
   * khi JS không chạy). Cần quyền truy cập thông báo (`openNotificationAccessSettings`) và các quyền trong README.
   */
  setPhoneLinkConfig: (config: Partial<PhoneLinkConfig>) => call('setPhoneLinkConfig', '', config),
  getPhoneLinkConfig: () => call<PhoneLinkConfig>('getPhoneLinkConfig'),
  /** Android: app đã được cấp quyền đọc thông báo chưa. iOS: luôn false. */
  hasNotificationAccess: () => call<boolean>('hasNotificationAccess'),
  /** Android: mở màn cấp quyền đọc thông báo. */
  openNotificationAccessSettings: () => call('openNotificationAccessSettings'),
  /**
   * Android: giữ kết nối ở nền bằng foreground service (thông báo thường trực) khi có thiết bị đang giữ kết nối. Mặc định
   * bật. Tắt thì dừng ngay và không bật lại (lưu lại cho lần mở app sau).
   */
  setForegroundService: (enabled: boolean) => call('setForegroundService', '', { enabled }),

  /** Các app thiết bị có biểu tượng riêng (Android). */
  getNotificationApps: (id: string) => call<NotificationApp[]>('getNotificationApps', id),
  /** Gửi một thông báo lên thiết bị (Android). `appKey` từ `getNotificationApps`; trả false nếu đang giờ yên lặng. */
  sendNotification: (id: string, n: { appKey: string; title: string; text: string }) => call<boolean>('sendNotification', id, n),
  sendSms: (id: string, sender: string, text: string) => call('sendSms', id, { sender, text }),
  notifyIncomingCall: (id: string, name: string, number?: string) => call('notifyIncomingCall', id, { name, number: number ?? null }),
  notifyCallEnded: (id: string) => call('notifyCallEnded', id),
  /** Người dùng bấm từ chối cuộc gọi trên thiết bị (Android: SDK tự cúp máy nếu bật `rejectCalls`). */
  onRejectCall: (cb: (e: { deviceId: string }) => void) => on('rejectCall', cb),

  getSmsReply: (id: string) => call<SmsReplyConfig>('getSmsReply', id),
  setSmsReply: (id: string, enabled: boolean, templates: string[]) => call('setSmsReply', id, { enabled, templates }),
  /** Thiết bị muốn gửi SMS trả lời (khi không bật chuyển tiếp native). Gửi xong gọi `sendSmsReplyResult`. */
  onSmsReplyRequest: (cb: (e: SmsReplyRequest) => void) => on('smsReplyRequest', cb),
  sendSmsReplyResult: (id: string, ok: boolean) => call('sendSmsReplyResult', id, { ok }),

  // ---------- Nhạc ----------

  /** Người dùng bấm điều khiển nhạc trên thiết bị. iOS: app chỉ điều khiển được trình phát của chính mình. */
  onMusicCommand: (cb: (e: { deviceId: string; command: MusicCommand }) => void) => on('musicCommand', cb),
  setMusicState: (id: string, state: MusicState) => call('setMusicState', id, state),
  setMusicVolume: (id: string, percent: number) => call('setMusicVolume', id, { percent }),

  // ---------- Danh bạ, gọi điện Bluetooth ----------

  clearContacts: (id: string) => call('clearContacts', id),
  setCallBluetooth: (id: string, on: boolean) => call('setCallBluetooth', id, { on }),

  // ---------- Mặt đồng hồ ----------

  getWatchFaceInfo: (id: string) => call<WatchFaceInfo>('getWatchFaceInfo', id),
  /** Cài file mặt đồng hồ của hãng (`.bin`): `path` (file trên máy) hoặc `base64`. Tiến độ qua `onTransferProgress`. */
  installWatchFace: (id: string, file: { path: string } | { base64: string }) => call('installWatchFace', id, file),
  getWatchFaceSlots: (id: string) => call<WatchFaceSlot[]>('getWatchFaceSlots', id),
  deleteWatchFaceSlot: (id: string, index: number) => call('deleteWatchFaceSlot', id, { index }),
  /** Android: dựng mặt đồng hồ từ ảnh (`path`: file hoặc content URI) rồi cài. Tiến độ qua `onTransferProgress`. */
  setWatchFaceImage: (id: string, path: string, style: WatchFaceImageStyle = {}) =>
    call('setWatchFaceImage', id, { path, ...style }),
  onTransferProgress: (cb: (p: TransferProgress) => void) => on('transferProgress', cb),

  // ---------- Bài tập từ điện thoại ----------

  getSportTypes: (id: string) => call<SportType[]>('getSportTypes', id),
  /** Ghi danh sách môn hiện trên thiết bị (`shown` + `position`). */
  setSportList: (id: string, sports: SportType[]) => call('setSportList', id, { sports }),
  startWorkout: (id: string, sportType: number) => call('startWorkout', id, { sportType }),
  pauseWorkout: (id: string) => call('pauseWorkout', id),
  resumeWorkout: (id: string) => call('resumeWorkout', id),
  stopWorkout: (id: string) => call('stopWorkout', id),
  /** Trạng thái bài tập (bấm trên thiết bị hoặc xác nhận lệnh app) và số liệu thời gian thực. */
  onWorkoutEvent: (cb: (e: WorkoutEvent) => void) => on('workout', cb),
  /** Thiết bị xin vị trí điện thoại (`start`) hoặc thôi xin. Khi đang xin, app gọi `sendLocation` định kỳ (~1 s). */
  onLocationRequest: (cb: (e: LocationRequest) => void) => on('locationRequest', cb),
  sendLocation: (id: string, location: PhoneLocation) => call('sendLocation', id, location),

  // ---------- Báo thức ----------

  /** Danh sách báo thức đọc từ thiết bị (`features.alarms`). */
  getAlarms: (id: string) => call<Alarm[]>('getAlarms', id),
  /** Thêm (id < 0 hoặc id chưa có) hoặc sửa theo `id`. Tối đa `features.maxAlarms`. */
  setAlarm: (id: string, alarm: Alarm) => call('setAlarm', id, alarm),
  deleteAlarm: (id: string, alarmId: number) => call('deleteAlarm', id, { id: alarmId }),

  // ---------- Camera từ xa, nút thiết bị ----------

  /** Báo thiết bị app đã mở / đóng màn chụp (thiết bị hiện / ẩn nút chụp). */
  setRemoteCamera: (id: string, open: boolean) => call('setRemoteCamera', id, { open }),
  onRemoteCamera: (cb: (e: { deviceId: string; event: RemoteCameraEvent }) => void) => on('remoteCamera', cb),
  onDeviceEvent: (cb: (e: { deviceId: string; event: DeviceEventName }) => void) => on('deviceEvent', cb),

  // ---------- Firmware (Android, chỉ image chính hãng) ----------

  /** Kiểm file firmware (`path` trên máy) có hợp lệ và đúng thiết bị không, không kết nối. */
  checkFirmware: (id: string, path: string) => call<FirmwareCheck>('checkFirmware', id, { path }),
  /** Nạp firmware chính hãng. Tiến độ qua `onTransferProgress` (`what: 'firmware'`). Có thể mất ~20 phút. */
  updateFirmware: (id: string, path: string) => call<boolean>('updateFirmware', id, { path }),
  cancelFirmwareUpdate: (id: string) => call('cancelFirmwareUpdate', id),
};

/** Mã WMO (Open-Meteo `weather_code`) → hiện tượng chung (giống `WeatherCondition.fromWmo` của SDK). */
export function weatherFromWmo(code: number): WeatherCondition {
  if (code === 0) return 'SUNNY';
  if (code === 1 || code === 2) return 'CLOUDY';
  if (code === 3) return 'OVERCAST';
  if (code === 45 || code === 48) return 'FOG';
  if ([51, 53, 55, 61, 63].includes(code)) return 'LIGHT_RAIN';
  if ([56, 57, 66, 67].includes(code)) return 'SLEET';
  if (code === 65 || code === 82) return 'HEAVY_RAIN';
  if ([71, 73, 75, 77, 85, 86].includes(code)) return 'SNOW';
  if (code === 80 || code === 81) return 'SHOWER';
  if ([95, 96, 99].includes(code)) return 'THUNDERSTORM';
  return 'CLOUDY';
}

/**
 * Dự báo 7 ngày từ Open-Meteo (miễn phí, không cần khoá) cho toạ độ app cung cấp; toạ độ được làm tròn 2 chữ số
 * (~1 km). `city` hiển thị trên đồng hồ (tối đa 8 ký tự ASCII, SDK tự bỏ dấu).
 */
export async function fetchOpenMeteoForecast(latitude: number, longitude: number, city = ''): Promise<WeatherForecast> {
  const lat = Math.round(latitude * 100) / 100;
  const lon = Math.round(longitude * 100) / 100;
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
    '&current=temperature_2m,relative_humidity_2m,weather_code,uv_index' +
    '&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=7';
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Open-Meteo trả mã ${res.status}`);
  const j = await res.json();
  const days = (j.daily.weather_code as number[]).map((c, i) => ({
    condition: weatherFromWmo(c),
    highC: Math.round(j.daily.temperature_2m_max[i]),
    lowC: Math.round(j.daily.temperature_2m_min[i]),
  }));
  if (days.length > 0) days[0].condition = weatherFromWmo(j.current.weather_code);
  return {
    city,
    currentC: Math.round(j.current.temperature_2m),
    humidity: Math.round(j.current.relative_humidity_2m),
    uvIndex: Math.round(j.current.uv_index ?? 0),
    days,
  };
}

export default SmartWear;
