import type { TurboModule } from 'react-native';
import type { EventEmitter, UnsafeObject } from 'react-native/Libraries/Types/CodegenTypes';
import { TurboModuleRegistry } from 'react-native';

/**
 * Đặc tả TurboModule (codegen). Dữ liệu phức tạp đi dạng `UnsafeObject` (dictionary), kiểu chi tiết ở `types.ts`;
 * dùng API trong `index.ts` thay vì gọi trực tiếp.
 */
export interface Spec extends TurboModule {
  /** Bật Bluetooth, dựng lại thiết bị đã lưu và tự nối lại thiết bị đang giữ kết nối. Gọi một lần khi app mở. */
  start(): void;
  startScan(seconds: number): void;
  stopScan(): void;
  getDiscovered(): Promise<UnsafeObject[]>;
  getDevices(): Promise<UnsafeObject[]>;
  /** Kết nối và (mặc định) giữ kết nối: tự nối lại khi mất, cả lần mở app sau. */
  connect(id: string, keep: boolean): Promise<void>;
  /** Ngắt theo ý người dùng (bỏ giữ kết nối). */
  disconnect(id: string): void;
  /** Quên thiết bị (ngắt, xoá khỏi danh sách đã lưu). */
  forget(id: string): void;
  setKeepConnected(id: string, keep: boolean): void;
  submitPairingCode(id: string, code: string): void;

  measure(id: string, capability: string): void;
  stopMeasure(id: string, capability: string): void;
  syncHistory(id: string, days: number): Promise<UnsafeObject>;

  getControls(id: string): Promise<UnsafeObject[]>;
  /** `value`: `{ value: boolean | number | { from, to } }`. */
  setControl(id: string, controlId: string, value: UnsafeObject): Promise<void>;
  runAction(id: string, actionId: string): Promise<void>;

  setWeather(id: string, forecast: UnsafeObject): Promise<void>;
  syncContacts(id: string, contacts: UnsafeObject[]): Promise<number>;
  getCallBluetoothState(id: string): Promise<UnsafeObject>;
  /** Android: ghép kênh gọi điện ngay trong app. iOS: báo lỗi kèm hướng dẫn (phải ghép trong Cài đặt → Bluetooth). */
  pairCallBluetooth(id: string): Promise<boolean>;
  /** Báo thiết bị điện thoại đang / đã thôi đổ chuông (sau `onFindPhone`), để đồng hồ tắt màn "đang tìm điện thoại". */
  setPhoneRinging(id: string, ringing: boolean): Promise<void>;

  /**
   * Cổng chung cho các tính năng điện thoại ↔ thiết bị (thông báo, cuộc gọi, nhạc, SMS, danh bạ, mặt đồng hồ, bài tập,
   * camera, OTA, cấu hình). `deviceId` rỗng = lệnh cấp module. Tên `method` và hình dạng `args`/kết quả: xem `index.ts`.
   * Lỗi: `unsupported` (thiết bị / nền tảng không có), `not_found`, `failed`.
   */
  invoke(method: string, deviceId: string, args: UnsafeObject): Promise<UnsafeObject>;

  readonly onDevicesChanged: EventEmitter<UnsafeObject>;
  readonly onDiscovered: EventEmitter<UnsafeObject>;
  readonly onReading: EventEmitter<UnsafeObject>;
  readonly onFindPhone: EventEmitter<UnsafeObject>;
  readonly onSyncProgress: EventEmitter<UnsafeObject>;
  /** Sự kiện của `invoke`: `{ type, deviceId, ... }`, `type` ∈ musicCommand | rejectCall | smsReplyRequest | workout |
   *  locationRequest | deviceEvent | remoteCamera | transferProgress | scanState. */
  readonly onEvent: EventEmitter<UnsafeObject>;
}

/** `null` khi binary không có module native (vd. JS mới tải qua OTA lên bản build cũ). Không ném lỗi lúc import. */
export default TurboModuleRegistry.get<Spec>('SmartWear');
