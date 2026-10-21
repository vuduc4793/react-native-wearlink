/**
 * App mẫu cho react-native-wearlink: quét, kết nối (giữ kết nối), đo, đồng bộ lịch sử, cài đặt, thời tiết, danh bạ,
 * tìm điện thoại, thông báo/cuộc gọi/nhạc/SMS (Android), mặt đồng hồ, bài tập, camera từ xa, nhịp tim liên tục, đường GPS do
 * đồng hồ ghi, AGPS, chọn môn tập hiện trên đồng hồ. Mọi thao tác đi qua API trong
 * `react-native-wearlink`. Nút "Kiểm tra API" chạy lần lượt các lệnh không phá dữ liệu và ghi `SWTEST …` ra log
 * (Android: `adb logcat -s ReactNativeJS`).
 */
import React, {useCallback, useEffect, useState} from 'react';
import {
  Alert,
  PermissionsAndroid,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import SmartWear, {
  fetchOpenMeteoForecast,
  type Device,
  type DeviceControl,
  type DiscoveredDevice,
  type HeartRateEvent,
  type Reading,
  type SportListLimits,
  type SportType,
  type Workout,
} from 'react-native-wearlink';

async function requestAndroidPermissions() {
  if (Platform.OS !== 'android') return;
  const perms =
    Number(Platform.Version) >= 31
      ? [PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN, PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT]
      : [PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION];
  if (Number(Platform.Version) >= 33) perms.push(PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS);
  await PermissionsAndroid.requestMultiple(perms);
}

/** Quyền cho cầu nối điện thoại (cuộc gọi, tên danh bạ, trả lời SMS). App phải khai báo trong manifest (xem README). */
async function requestPhoneLinkPermissions() {
  if (Platform.OS !== 'android') return;
  const P = PermissionsAndroid.PERMISSIONS;
  await PermissionsAndroid.requestMultiple([P.READ_PHONE_STATE, P.READ_CALL_LOG, P.ANSWER_PHONE_CALLS, P.READ_CONTACTS, P.SEND_SMS]);
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

/**
 * Chạy lần lượt các lệnh không phá dữ liệu trên thiết bị và ghi kết quả. Mỗi bước: `SWTEST <bước> OK|SKIP|FAIL …`.
 * Hiện lên thiết bị: một thông báo, tên bài hát, màn chụp ảnh 2 s. Không xoá dữ liệu, không nạp firmware.
 */
async function selfTest(d: Device, log: (s: string) => void) {
  const out = (step: string, status: string, v?: unknown) => {
    const line = `SWTEST ${step} ${status}${v === undefined ? '' : ' ' + JSON.stringify(v).slice(0, 600)}`;
    console.log(line);
    log(line);
  };
  const step = async (name: string, enabled: boolean, f: () => Promise<unknown>) => {
    if (!enabled) return out(name, 'SKIP');
    try {
      out(name, 'OK', await f());
    } catch (e: any) {
      out(name, 'FAIL', `${e?.code ?? ''} ${e?.message ?? e}`);
    }
  };
  const f = d.features;
  out('device', 'OK', {name: d.name, state: d.state, firmware: d.firmware, hardware: d.hardware, battery: d.battery, features: f});
  await step('getScanState', true, () => SmartWear.getScanState());
  await step('refreshBattery', true, () => SmartWear.refreshBattery(d.id));
  await step('getControls', d.controlCount > 0, async () => {
    const c = await SmartWear.getControls(d.id);
    return {count: c.length, ids: c.map(x => x.id), confirm: c.filter(x => x.confirm).map(x => `${x.id}: ${x.confirm}`)};
  });
  await step('getWatchFaceInfo', f.watchFace, () => SmartWear.getWatchFaceInfo(d.id));
  await step('getWatchFaceSlots', f.watchFaceSlots, () => SmartWear.getWatchFaceSlots(d.id));
  await step('getSportTypes', f.sportList, () => SmartWear.getSportTypes(d.id));
  await step('getSportListLimits', f.sportList, () => SmartWear.getSportListLimits(d.id));
  await step('getSportCatalog', f.sportList, async () => (await SmartWear.getSportCatalog(d.id)).length);
  await step('getAlarms', f.alarms, async () => ({max: f.maxAlarms, alarms: await SmartWear.getAlarms(d.id)}));
  await step('getNotificationApps', f.notifications, async () => (await SmartWear.getNotificationApps(d.id)).map(a => a.key));
  await step('getSmsReply', f.smsReply, () => SmartWear.getSmsReply(d.id));
  await step('getCallBluetoothState', f.callAudio, () => SmartWear.getCallBluetoothState(d.id));
  await step('getPhoneLinkConfig', true, () => SmartWear.getPhoneLinkConfig());
  await step('hasNotificationAccess', true, () => SmartWear.hasNotificationAccess());
  await step('setMusicState', f.trackInfo || f.musicControl, () =>
    SmartWear.setMusicState(d.id, {playing: true, title: 'SmartWear RN', artist: 'Kiem tra'}));
  await step('sendNotification', f.notifications, async () => {
    const apps = await SmartWear.getNotificationApps(d.id);
    const app = apps.find(a => a.hasIcon) ?? apps[0];
    return SmartWear.sendNotification(d.id, {appKey: app.key, title: 'SmartWear RN', text: 'Kiểm tra thông báo từ React Native'});
  });
  await step('setRemoteCamera', f.remoteCamera, async () => {
    await SmartWear.setRemoteCamera(d.id, true);
    await sleep(2000);
    await SmartWear.setRemoteCamera(d.id, false);
  });
  await step('getHistory', d.supportsHistory, async () => {
    const h = await SmartWear.getHistory(d.id);
    return h && {syncedAt: h.syncedAt, series: Object.keys(h.series)};
  });
  await step('syncHistory', d.supportsHistory, async () => {
    const h = await SmartWear.syncHistory(d.id, 2);
    const bp = h.series.BLOOD_PRESSURE?.[0];
    return {
      today: h.today, series: Object.fromEntries(Object.entries(h.series).map(([k, v]) => [k, v?.length])),
      bloodPressureSample: bp, sleep: h.sleep.length, workouts: h.workouts.length, errors: h.errors,
    };
  });
  await step('heartRateStream', f.heartRateStream, async () => {
    // 15 s: đếm mẫu, lấy bpm cuối. Luồng không tạo bài tập trên thiết bị.
    const got: number[] = [];
    const sub = SmartWear.onHeartRate(e => e.deviceId === d.id && e.bpm != null && got.push(e.bpm));
    try {
      await SmartWear.startHeartRateStream(d.id);
      await sleep(15000);
    } finally {
      sub.remove();
      await SmartWear.stopHeartRateStream(d.id);
    }
    return {samples: got.length, last: got[got.length - 1] ?? null};
  });
  await step('getAgpsStatus', f.agps, () => SmartWear.getAgpsStatus(d.id));
  await step('workoutTracks', d.supportsHistory, async () => {
    const h = await SmartWear.getHistory(d.id);
    return (h?.workouts ?? []).map(w => ({name: w.name, samples: w.samples?.length ?? 0, track: w.track?.length ?? 0}));
  });
  out('done', 'OK');
}

/** Một dòng tóm tắt bài tập: môn, giờ bắt đầu, thời lượng, quãng đường, nhịp tim, số điểm GPS do đồng hồ ghi. */
function workoutLine(w: Workout) {
  const start = new Date(w.start).toLocaleString();
  const km = w.distanceMeters ? ` · ${(w.distanceMeters / 1000).toFixed(2)} km` : '';
  const hr = w.avgHeartRate ? ` · HR ${w.avgHeartRate}` : '';
  const gps = w.track?.length ? ` · GPS ${w.track.length} điểm` : '';
  return `${w.name} · ${start} · ${Math.round(w.activeSeconds / 60)} phút${km}${hr}${gps}`;
}

/** Môn hiện trước (theo `position`), môn ẩn sau, giữ thứ tự thiết bị trả về. */
function sortSports(list: SportType[]) {
  const shown = list.filter(x => x.shown).sort((a, b) => (a.position || 999) - (b.position || 999));
  return [...shown, ...list.filter(x => !x.shown)];
}

/**
 * Môn tập trên đồng hồ: bật/tắt hiện, đổi thứ tự môn hiện, Lưu (hỏi lại trước khi ghi). Chỉ chọn trong danh sách đồng hồ giữ
 * (Y25: 50 môn); danh mục 245 môn của hãng chỉ để tra tên, không thêm được vào đồng hồ.
 */
function SportListEditor({d, note}: {d: Device; note: (s: string) => void}) {
  const [sports, setSports] = useState<SportType[] | null>(null);
  const [limits, setLimits] = useState<SportListLimits | null>(null);
  const [catalog, setCatalog] = useState(0);
  const load = () =>
    Promise.all([SmartWear.getSportTypes(d.id), SmartWear.getSportListLimits(d.id), SmartWear.getSportCatalog(d.id)])
      .then(([list, l, cat]) => {
        setSports(sortSports(list));
        setLimits(l);
        setCatalog(cat.length);
      })
      .catch(e => note(`môn tập LỖI ${e?.message ?? e}`));
  if (!sports) return <Button title="Môn tập" onPress={load} />;

  const shownCount = sports.filter(x => x.shown).length;
  const ok = !limits || (shownCount >= limits.minShown && shownCount <= limits.maxShown);
  const toggle = (type: number) => setSports(sortSports(sports.map(x => (x.type === type ? {...x, shown: !x.shown, position: x.shown ? 0 : 999} : x))));
  const move = (i: number, by: number) => {
    const shown = sports.filter(x => x.shown);
    const j = i + by;
    if (j < 0 || j >= shown.length) return;
    [shown[i], shown[j]] = [shown[j], shown[i]];
    setSports([...shown.map((x, k) => ({...x, position: k + 1})), ...sports.filter(x => !x.shown)]);
  };
  const save = () =>
    Alert.alert('Ghi danh sách môn', `Hiện ${shownCount} môn trên ${d.name}?`, [
      {text: 'Huỷ', style: 'cancel'},
      {
        text: 'Ghi',
        onPress: () => {
          let n = 0;
          const out = sports.map(x => (x.shown ? {...x, position: ++n} : {...x, position: 0}));
          SmartWear.setSportList(d.id, out).then(() => note('môn tập ✓ đã ghi')).then(load)
            .catch(e => note(`môn tập LỖI ${e?.message ?? e}`));
        },
      },
    ]);
  let shownIndex = -1;
  return (
    <View style={{marginTop: 10}}>
      <Text style={styles.section}>Môn tập trên đồng hồ ({sports.length} môn)</Text>
      <Text style={[styles.sub, !ok && {color: '#ff453a'}]}>
        Đang hiện {shownCount}{limits ? ` · cho phép ${limits.minShown}–${limits.maxShown}` : ''}
        {catalog ? ` · danh mục hãng ${catalog} môn (đồng hồ chỉ giữ ${sports.length})` : ''}
      </Text>
      {sports.map(x => {
        const i = x.shown ? ++shownIndex : -1;
        return (
          <View key={x.type} style={styles.controlRow}>
            <Text style={[styles.sub, {flex: 1}, !x.shown && {opacity: 0.5}]}>
              {x.shown ? `${i + 1}. ` : ''}{x.name}{x.nameEn ? ` · ${x.nameEn}` : ''}
            </Text>
            {x.shown && <Button title="↑" onPress={() => move(i, -1)} disabled={i === 0} />}
            {x.shown && <Button title="↓" onPress={() => move(i, 1)} disabled={i === shownCount - 1} />}
            <Button title={x.shown ? 'Ẩn' : 'Hiện'} onPress={() => toggle(x.type)} />
          </View>
        );
      })}
      <View style={styles.row}>
        <Button title="Lưu lên đồng hồ" onPress={save} disabled={!ok} />
        <Button title="Đọc lại" onPress={load} />
        <Button title="Đóng" onPress={() => setSports(null)} />
      </View>
    </View>
  );
}

function Button({title, onPress, disabled}: {title: string; onPress: () => void; disabled?: boolean}) {
  return (
    <Pressable onPress={onPress} disabled={disabled} style={[styles.button, disabled && {opacity: 0.4}]}>
      <Text style={styles.buttonText}>{title}</Text>
    </Pressable>
  );
}

export default function App() {
  const [devices, setDevices] = useState<Device[]>([]);
  const [found, setFound] = useState<DiscoveredDevice[]>([]);
  const [readings, setReadings] = useState<Record<string, Reading>>({});
  const [log, setLog] = useState<string[]>([]);
  const [controls, setControls] = useState<Record<string, DeviceControl[]>>({});
  /** Mẫu nhịp tim mới nhất theo thiết bị; có khoá = luồng đang mở. */
  const [hr, setHr] = useState<Record<string, HeartRateEvent | null>>({});
  const [workouts, setWorkouts] = useState<Record<string, Workout[]>>({});
  const note = useCallback((s: string) => {
    if (s.startsWith('SWEVENT')) console.log(s);
    setLog(l => [`${new Date().toLocaleTimeString()} ${s}`, ...l].slice(0, 60));
  }, []);

  useEffect(() => {
    requestAndroidPermissions().then(() => SmartWear.start());
    const subs = [
      SmartWear.onDevicesChanged(setDevices),
      SmartWear.onDiscovered(setFound),
      SmartWear.onReading(r => setReadings(m => ({...m, [`${r.deviceId}/${r.capability}`]: r}))),
      SmartWear.onFindPhone(e => {
        if (!e.ringing) return;
        SmartWear.setPhoneRinging(e.deviceId, true);
        Alert.alert('Đang tìm điện thoại', 'Thiết bị đang tìm điện thoại này', [
          {text: 'Đã tìm thấy', onPress: () => SmartWear.setPhoneRinging(e.deviceId, false)},
        ]);
      }),
      SmartWear.onSyncProgress(p => note(`đồng bộ ${p.step} ${p.done}/${p.total}`)),
      SmartWear.onScanState(s => console.log(`SWEVENT scanState ${JSON.stringify(s)}`)),
      SmartWear.onMusicCommand(e => note(`SWEVENT nhạc ${e.command}`)),
      SmartWear.onRejectCall(() => note('SWEVENT từ chối cuộc gọi')),
      SmartWear.onSmsReplyRequest(e => note(`SWEVENT trả lời SMS ${e.number}: ${e.text}`)),
      SmartWear.onRemoteCamera(e => note(`SWEVENT camera ${e.event}`)),
      SmartWear.onDeviceEvent(e => note(`SWEVENT nút ${e.event}`)),
      SmartWear.onWorkoutEvent(e => note(`SWEVENT bài tập ${JSON.stringify(e)}`)),
      SmartWear.onLocationRequest(e => note(`SWEVENT xin vị trí ${JSON.stringify(e)}`)),
      SmartWear.onTransferProgress(p => p.fraction >= 1 && note(`SWEVENT truyền ${p.what} xong`)),
      SmartWear.onReading(r => console.log(`SWEVENT reading ${r.capability} ${r.status} ${r.value ?? ''}`)),
      SmartWear.onHeartRate(e => {
        console.log(`SWEVENT heartRate ${e.bpm ?? '-'} connected=${e.connected} rr=${e.rrMs.length} ${e.error ?? ''}`);
        setHr(m => (e.deviceId in m ? {...m, [e.deviceId]: e} : m));
      }),
      SmartWear.onAgpsRequest(e => note(`SWEVENT AGPS ${e.request}${e.handled ? ' (đã trả lời)' : ''}`)),
    ];
    return () => subs.forEach(s => s.remove());
  }, [note]);

  const run = (label: string, p: Promise<unknown>) =>
    p.then(r => note(`${label} ✓ ${r === undefined || r === null ? '' : JSON.stringify(r).slice(0, 200)}`))
      .catch(e => note(`${label} LỖI ${e?.message ?? e}`));

  const known = new Set(devices.map(d => d.id));
  return (
    <SafeAreaView style={styles.root}>
      <ScrollView contentContainerStyle={{padding: 16}}>
        <Text style={styles.h1}>SmartWear RN</Text>
        <View style={styles.row}>
          <Button title="Quét 20 s" onPress={() => SmartWear.startScan(20)} />
          <Button title="Dừng quét" onPress={() => SmartWear.stopScan()} />
        </View>
        {Platform.OS === 'android' && (
          <View style={styles.row}>
            <Button title="Quyền điện thoại" onPress={() => requestPhoneLinkPermissions()} />
            <Button title="Quyền thông báo" onPress={() => SmartWear.openNotificationAccessSettings()} />
          </View>
        )}

        {found.filter(f => !known.has(f.id)).map(f => (
          <View key={f.id} style={styles.card}>
            <Text style={styles.title}>{f.model ?? f.name ?? f.id}</Text>
            <Text style={styles.sub}>{f.driver} · {f.rssi} dBm</Text>
            <Button title="Kết nối + giữ" onPress={() => run(`kết nối ${f.name}`, SmartWear.connect(f.id))} />
          </View>
        ))}

        {devices.map(d => (
          <View key={d.id} style={styles.card}>
            <Text style={styles.title}>{d.name}</Text>
            <Text style={styles.sub}>
              {d.state} · {d.kept ? 'giữ kết nối' : 'không giữ'} · pin {d.battery ?? '-'}% · {d.rssi ?? '-'} dBm
            </Text>
            <Text style={styles.sub}>{d.capabilities.join(', ')}</Text>
            <View style={styles.row}>
              {d.state === 'CONNECTED' ? (
                <Button title="Ngắt" onPress={() => SmartWear.disconnect(d.id)} />
              ) : (
                <Button title="Kết nối" onPress={() => run(`kết nối ${d.name}`, SmartWear.connect(d.id))} />
              )}
              <Button title="Quên" onPress={() => SmartWear.forget(d.id)} />
            </View>
            {d.state === 'CONNECTED' && (
              <>
                <View style={styles.row}>
                  {d.measurable.map(c => {
                    const r = readings[`${d.id}/${c}`];
                    const v = r?.systolic ? `${r.systolic}/${r.diastolic}` : r?.value ?? r?.status ?? '';
                    return <Button key={c} title={`${c} ${v}`} onPress={() => SmartWear.measure(d.id, c)} />;
                  })}
                </View>
                <View style={styles.row}>
                  {d.supportsHistory && (
                    <Button
                      title="Đồng bộ 7 ngày"
                      onPress={() =>
                        run(
                          `lịch sử ${d.name}`,
                          SmartWear.syncHistory(d.id, 7).then(h => {
                            setWorkouts(m => ({...m, [d.id]: h.workouts}));
                            return {
                            today: h.today,
                            series: Object.fromEntries(Object.entries(h.series).map(([k, v]) => [k, v?.length])),
                            sleep: h.sleep.length,
                            workouts: h.workouts.length,
                            };
                          }),
                        )
                      }
                    />
                  )}
                  {d.controlCount > 0 && (
                    <Button
                      title="Cài đặt"
                      onPress={() => SmartWear.getControls(d.id).then(c => setControls(m => ({...m, [d.id]: c})))}
                    />
                  )}
                  {d.supportsWeather && (
                    <Button
                      title="Thời tiết Hà Nội"
                      onPress={() =>
                        run('thời tiết', fetchOpenMeteoForecast(21.03, 105.85, 'Ha Noi').then(f => SmartWear.setWeather(d.id, f)))
                      }
                    />
                  )}
                  {d.supportsCallBluetooth && (
                    <Button title="Kênh gọi" onPress={() => run('kênh gọi', SmartWear.getCallBluetoothState(d.id))} />
                  )}
                  <Button title="Kiểm tra API" onPress={() => selfTest(d, note)} />
                  {d.features.heartRateStream && (
                    d.id in hr ? (
                      <Button
                        title="Dừng nhịp tim"
                        onPress={() => {
                          setHr(({[d.id]: _, ...rest}) => rest);
                          run('dừng nhịp tim', SmartWear.stopHeartRateStream(d.id));
                        }}
                      />
                    ) : (
                      <Button
                        title="Nhịp tim liên tục"
                        onPress={() => {
                          setHr(m => ({...m, [d.id]: null}));
                          run('nhịp tim liên tục', SmartWear.startHeartRateStream(d.id));
                        }}
                      />
                    )
                  )}
                  {d.features.agps && (
                    <Button title="AGPS" onPress={() => run('AGPS', SmartWear.getAgpsStatus(d.id))} />
                  )}
                  {d.features.workoutControl && (
                    <Button
                      title="Bài tập 10 s"
                      onPress={() =>
                        run('bài tập', SmartWear.startWorkout(d.id, 1).then(() => sleep(10000)).then(() => SmartWear.stopWorkout(d.id)))
                      }
                    />
                  )}
                  {d.features.notifications && (
                    <Button
                      title="Chuyển thông báo"
                      onPress={() =>
                        run('cấu hình', SmartWear.getNotificationApps(d.id).then(apps =>
                          SmartWear.setPhoneLinkConfig({apps: apps.map(a => a.key), sms: true, calls: true, music: true})))
                      }
                    />
                  )}
                </View>
                {d.id in hr && (
                  <View style={styles.hrBox}>
                    <Text style={styles.hrValue}>{hr[d.id]?.bpm ?? '--'}</Text>
                    <Text style={styles.sub}>
                      bpm · {hr[d.id] == null ? 'đang mở luồng…' : hr[d.id]!.connected
                        ? `${new Date(hr[d.id]!.t).toLocaleTimeString()}${hr[d.id]!.rrMs.length ? ` · RR ${hr[d.id]!.rrMs.join('/')} ms` : ''}`
                        : 'mất kết nối, đang nối lại'}
                      {hr[d.id]?.error ? ` · ${hr[d.id]!.error}` : ''}
                    </Text>
                  </View>
                )}
                {d.features.sportList && <SportListEditor d={d} note={note} />}
                {(workouts[d.id] ?? []).length > 0 && (
                  <View style={{marginTop: 10}}>
                    <Text style={styles.section}>Bài tập ({workouts[d.id].length})</Text>
                    {workouts[d.id].slice(0, 10).map((w, i) => (
                      <Text key={i} style={styles.sub}>{workoutLine(w)}</Text>
                    ))}
                  </View>
                )}
                {(controls[d.id] ?? []).map(c => (
                  <View key={c.id} style={styles.controlRow}>
                    <Text style={[styles.sub, {flex: 1}]}>
                      {c.group} · {c.title}: {c.value === null ? '' : JSON.stringify(c.value)} {c.unit}
                    </Text>
                    {c.kind === 'action' && (
                      <Button title="Chạy" onPress={() => run(c.title, SmartWear.runAction(d.id, c.id))} />
                    )}
                    {c.kind === 'toggle' && (
                      <Button
                        title={c.value ? 'Tắt' : 'Bật'}
                        onPress={() =>
                          run(c.title, SmartWear.setControl(d.id, c.id, !c.value).then(() => SmartWear.getControls(d.id))
                            .then((list: DeviceControl[]) => setControls(m => ({...m, [d.id]: list}))))
                        }
                      />
                    )}
                  </View>
                ))}
              </>
            )}
          </View>
        ))}

        <Text style={styles.h2}>Nhật ký</Text>
        {log.map((l, i) => (
          <Text key={i} style={styles.log}>{l}</Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#0b0b0d'},
  h1: {color: 'white', fontSize: 28, fontWeight: '700', marginBottom: 12},
  h2: {color: 'white', fontSize: 18, fontWeight: '600', marginTop: 16},
  card: {backgroundColor: '#1c1c1f', borderRadius: 16, padding: 14, marginTop: 12},
  title: {color: 'white', fontSize: 17, fontWeight: '600'},
  sub: {color: '#a1a1a6', fontSize: 13, marginTop: 2},
  row: {flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 8},
  controlRow: {flexDirection: 'row', alignItems: 'center', marginTop: 6, gap: 8},
  button: {backgroundColor: 'white', borderRadius: 999, paddingHorizontal: 14, paddingVertical: 8},
  buttonText: {color: 'black', fontWeight: '600'},
  section: {color: 'white', fontSize: 14, fontWeight: '600'},
  hrBox: {flexDirection: 'row', alignItems: 'baseline', gap: 8, marginTop: 10},
  hrValue: {color: '#ff453a', fontSize: 40, fontWeight: '700', fontVariant: ['tabular-nums']},
  log: {color: '#a1a1a6', fontSize: 12, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace', marginTop: 4},
});
