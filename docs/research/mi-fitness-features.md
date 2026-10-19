# Mi Fitness 9.8.348: kiểm kê tính năng (để làm lại trong SmartWear Lab cho Y25)

> Ngày: 16/10/2026. Chỉ đọc mã đã dịch ngược, không chạy app, không kết nối thiết bị.
>
> **Nguồn**
> - jadx của `mifit.apk` (bản quốc tế, flavor `playDevelopmentRelease`). Đường dẫn class bên dưới tính từ `sources/`.
> - Chuỗi giao diện giải mã bằng `jadx --no-src`: `res/values/strings.xml` và `values-zh-rCN/strings.xml`.
> - Asset: `assets/mi_stage_model_0_1_1.tflite`, `assets/plugin/app.bundle`, `assets/plugin_rn_sdk/`.
>
> **Viết tắt đường dẫn**
> - `H/` = `com/xiaomi/fitness/health/`
> - `D/` = `com/xiaomi/fit/fitness/export/data/`
> - `R/` = `com/xiaomi/fitness/repo/`
> - `DS/` = `com/xiaomi/fitness/devicesettings/`
> - `WF/` = `com/xiaomi/fitness/watch/face/`
>
> **Cách đọc HTTP:** annotation Retrofit bị làm rối tên. `@sm7("…")` là GET, `@t2c("…")` là POST, tham số thường là
> một trường `data` chứa JSON.
>
> Mục nào không đọc thẳng được từ mã thì ghi **chưa chắc**.

**Ký hiệu cột "Tính ở đâu"**

| Ký hiệu | Nghĩa |
|---|---|
| **W** | Đồng hồ tính, app chỉ parse và hiển thị |
| **P** | Điện thoại tính (Java/Kotlin, hoặc thư viện native `.so` hay TFLite) |
| **S** | Server Xiaomi tính, app lấy kết quả về |
| **3P** | Dịch vụ bên thứ ba |

**Cột "Y25"** (theo `docs/feature-matrix.md`)

| Ký hiệu | Nghĩa |
|---|---|
| ✓ | Y25 có dữ liệu đầu vào |
| ½ | Có một phần |
| ✗ | Phần cứng/firmware không có (stress, HRV, ECG, nhiệt độ, nhịp thở đều tắt) |

---

## 0. Kết luận nhanh

1. **Bản 9.8.348 quốc tế không có "báo cáo sức khoẻ AI" sinh bằng LLM.** Đã quét:
   - 84 interface có `@BaseUrl` (khoảng 334 endpoint);
   - mọi URL viết cứng trong mã;
   - chuỗi giao diện tiếng Anh và tiếng Trung;
   - hai bundle React Native đi kèm.

   Không có endpoint kiểu `ai_report`, `health_report`, `llm`, `insight/generate`.

2. **Thứ người dùng thấy là "báo cáo AI" gần như chắc chắn là một trong các tính năng sau** (chi tiết §2):
   - **Sleep insight report / Sleep animal** (睡眠洞察报告): server phân loại "con vật ngủ" (chronotype) sau 7 đêm, còn điện
     thoại tự tính 5 chỉ số insight.
   - **Sleep interpretation and suggestions** (睡眠解读与建议): luật cứng trên điện thoại, cộng kho câu chữ JSON tải từ CDN.
   - **Điểm ngủ và nhận xét ngày/tuần**: thư viện native `libjni_xiaomi_sleep_algorithm.so` chạy trên điện thoại.
   - **Weekly summary** (周报): trang H5 do server dựng.

   Nếu người dùng thấy một màn "AI" kiểu chat hoặc tóm tắt bằng văn xuôi, thì đó là bản Trung Quốc hoặc bản mới hơn, hoặc
   **AFlash** (dưới đây). **Chưa chắc**, nên hỏi lại ảnh chụp màn hình.

3. **LLM thật duy nhất trong app là AFlash** (`com/xiaomi/fitness/aishan`):
   - SDK bên thứ ba `com.zhzn.lib.AFlash`, gọi `https://api.aiwatchzhzn.pro/zh/{init,chat,stt,tts,smart,health}`.
   - Feature flag của thiết bị tên là `"chatgpt"`.
   - Dùng để hỏi đáp bằng giọng nói trên đồng hồ và vẽ ảnh làm mặt đồng hồ từ câu lệnh.
   - SDK có hàm `analyzeData(jsonObject)` gọi `/zh/health` (phân tích sức khoẻ bằng AI), nhưng **app Xiaomi không gọi hàm
     này**.

4. **Phân bố tính toán**
   - **Đồng hồ:** phần lớn chỉ số (PAI, Vitality, Energy, VO2max, training load, stress, giai đoạn ngủ).
   - **Điện thoại:**
     - phân vùng nhịp tim, mức stress và năng lượng;
     - điểm ngủ (native) và giai đoạn ngủ (TFLite, chỉ cho máy gửi dữ liệu thô);
     - luật giải thích giấc ngủ;
     - dự đoán chu kỳ kinh;
     - đánh giá chỉ số cân.
   - **Server:**
     - đồng bộ dữ liệu;
     - con vật ngủ và phân phối điểm ngủ (percentile);
     - báo cáo tuần;
     - giáo án chạy;
     - huy chương, PK, chia sẻ người thân.

5. **Với Y25**, phần làm lại được ngay chỉ dựa vào dữ liệu đồng hồ đã có:

   | Y25 có | Làm được |
   |---|---|
   | Nhịp tim 24h, SpO2 | Biểu đồ, cảnh báo, phân vùng nhịp tim |
   | Giấc ngủ có REM, ngủ trưa | Điểm ngủ, giải thích giấc ngủ, sleep insight, chronotype |
   | Bước, calo, quãng đường | Mục tiêu, vòng hoạt động, PAI kiểu tự tính |
   | Huyết áp ước lượng | Biểu đồ và phân loại huyết áp |
   | Kinh nguyệt | Dự đoán chu kỳ |
   | Bài tập | Chi tiết bài tập |

   "Báo cáo AI" thật thì **tự xây**: tổng hợp số liệu trên điện thoại, rồi gửi LLM qua dịch vụ của project `runpod-ai`
   (§2.9).

---

## 1. Kiến trúc dữ liệu và máy chủ

| Thành phần | Bằng chứng | Ghi chú |
|---|---|---|
| Đồng bộ đồng hồ → điện thoại | `com/xiaomi/fitness/sync/SyncEngine`, `BleDataHandler`; parser `com/xiaomi/fit/fitness/parser/{daily,sport}/*`; Huami ở `com/xiaomi/hm/health/**` | Gói protobuf-nano `defpackage/t1i`: `c` = loại, `d` = lệnh (bảng loại ở §9) |
| Bản ghi theo phút (`ParsedDailyRecord`) | `com/xiaomi/fit/fitness/parser/data/` | Trường: hr, stress, steps, distance, calories, energy, energyState, activityType, activityHILevel, isAbnormalHr |
| Báo cáo ngày (`ParsedDailyReport`) | Cùng package | Trường: avgHr, max/minHr, restHr, avg/max/minStress, intensity vitality theo 3 mức, dayTrainingLoad, recoveryTime, physicalFitness… |
| Báo cáo ngủ (`NightSleepReport`) | Cùng package | Trường: totalScore, qualityScore, durationScore, recoveryScore, nervousScore, sleepAdvice, sleepSummary và thời lượng từng giai đoạn |
| Điện thoại ↔ server | `com/xiaomi/fit/fitness/persist/server/service/FitnessApiService` (`https://hlth.io.mi.com/app/v1/`) | Xem chi tiết ngay dưới bảng |
| Mô hình JSON server | `persist/server/data/FitnessDataModel` | Trường: `sid`, `key`, `time`, `value` (chuỗi JSON), `zoneOffsetInSec`, `zoneName`, `isDeleted` |
| Thống kê server | `persist/server/data/StatDataModel` | Trường: `tag`, `key`, `time`, `value`, `zone_offset`, `update_time`, `deleted` |
| Máy chủ chính | Các `@BaseUrl` | Liệt kê ngay dưới bảng |

**Endpoint đồng bộ** (`FitnessApiService`)
- Tải lên: `data/up_{fitness,aggregated_fitness,medical,project,sport_records,huami_raw,third_raw}_data`
- Tải về: `data/get_*_by_time`, `data/get_*_by_watermark`, `data/get_latest_*`
- Xoá: `data/delete_*`
- Thống kê: `statistics/{get_stat_data_by_time,get_stat_data_by_watermark,trigger_stat,…}`

**Máy chủ chính** (theo các `@BaseUrl`)
- `hlth.io.mi.com`, với path `app/v1/`, `healthapp/` hoặc `ops/v1/`
- `watch.iot.mi.com`, với path `cgi-op/api/v1/…` hoặc `ops/v1/`
- `watch-appstore.iot.mi.com`
- `region.hlth.io.mi.com`
- `i.ai.mi.com` (thời khoá biểu Xiao AI)

**Tính năng Trung Quốc bị stub (hàm rỗng) ở bản quốc tế**
- Tuyến chạy AI và cộng đồng tuyến: `sport/route/detail/server/RouteRepository`, `route/track/server/TrackRepository`.
- Chia sẻ video quỹ đạo: `share/amap/SharePathVideoAmapActivity`.

---

## 2. Tính năng "AI" và báo cáo: thực chất được xây thế nào

### 2.0 Bảng tổng

| # | Tính năng (tên UI) | Tính ở đâu | Kỹ thuật | Đầu vào từ đồng hồ | Y25 | Bằng chứng |
|---|---|---|---|---|---|---|
| 2.1 | Điểm ngủ, nhận xét ngày/tuần | P (native) | Thuật toán đóng trong `libjni_xiaomi_sleep_algorithm.so` | Phân đoạn ngủ: tổng, sâu, nông, REM, thức, số lần thức, giờ lên giường | ✓ | `com/xiaomi/fit/fitness/sleep/algo/evaluation/SleepEvaluation`, `R/sleep/utils/DaySleepReportUtils` |
| 2.2 | Phân giai đoạn ngủ từ dữ liệu thô | P (JNI + TFLite) | Mạng nơ-ron, 4 lớp đầu ra | Byte ngủ thô (chuyển động + HR) | n/a (Y25 tự phân giai đoạn) | `sleep/algo/stage/MiParseModel`, `MiSleepAlgorithmNative`, `assets/mi_stage_model_0_1_1.tflite` |
| 2.3 | Sleep interpretation and suggestions | P | Luật cứng, câu chữ từ CDN | Một phân đoạn ngủ dài và điểm ngủ | ✓ | `H/sleep/utils/SleepInterpretationExtKt`, `SleepInterpretationConstants` |
| 2.4 | Sleep animal và Sleep insight report | Con vật: S. Chỉ số insight: P | Phân loại 6 lớp ở server, 5 chỉ số ở điện thoại | ≥7 đêm ngủ, stress, intensity | ½ (Y25 không có stress) | `R/sleep/net/SleepStatDataRequest`, `R/sleep/utils/SleepAnimalInsightUtils` |
| 2.5 | Weekly summary (H5) | S | Trang web dựng sẵn | Dữ liệu đã lên cloud | ✓ | `com/xiaomi/fitness/mine/weeklyreport/*` |
| 2.6 | Giáo án chạy thông minh, "AI route" | S | Sinh giáo án từ bảng hỏi. AI route bị stub | Bài chạy, pace, quãng đường | ½ | `com/xiaomi/fitness/training_plan/net/TrainingPlanApiService` |
| 2.7 | **AFlash**: trợ lý AI trên đồng hồ, vẽ mặt đồng hồ bằng AI | 3P | LLM chat, STT, TTS, text-to-image | Âm thanh giọng nói, văn bản | ✗ (cần mic) | `com/xiaomi/fitness/aishan/*`, `com/zhzn/lib/*` |
| 2.8 | Bác sĩ giải đọc ECG / báo cáo ngủ (chỉ Trung Quốc) | 3P + bác sĩ | Helowin (好络维), Bệnh viện Quốc tế ĐH Bắc Kinh | Bản ghi ECG, báo cáo ngủ | ✗ | `H/ecg/*`, chuỗi `health_n60_*`, `health_sleep_rhythm_up_remote_remind` |

### 2.1 Điểm ngủ và nhận xét ngày/tuần (điện thoại, native)

**Luồng xử lý**
- `DaySleepReportUtils.computeDaySleepReport()` gọi lần lượt:
  - `computeDaySleepSummaryInfo`
  - `computeDaySleepAssistInfo`
  - `computeDaySleepComment`
- `computeDaySleepComment` dựng `SleepEvaluation.SleepSummary` cho **hôm nay và hôm trước**, rồi gọi
  `MiDevSleepAlgo.getSleepDailyComment()`, tức hàm native `nGetSleepDailyComment(list, preList)`.

**Đầu vào** (`SleepSummary`): `sleepDuration`, `wakeDuration`, `lightDuration`, `deepDuration`, `remDuration`,
`sleepOnBed` (epoch), `wakeCount`, `timeZone`, `lastStage`.

**Đầu ra** (`Comment`)

| Trường | Ý nghĩa |
|---|---|
| `score` | Điểm 0–100 |
| `stage` | `DailySate`: 0 NO_SLEEP, 1 BAD, 2 NORMAL, 3 BETTER, 4 BEST, 5 NO_NIGHT_SLEEP |
| `longSleepCommentCode` | Mã nhận xét giấc ngủ dài; điện thoại tra mã ra chuỗi |
| `dayCommentCode` | Mã nhận xét cả ngày; điện thoại tra mã ra chuỗi |

**Theo tuần**
- `getSleepWeeklyComment(List<DailySleep>)` có sẵn.
- Nhưng điểm tuần trên UI = **trung bình các điểm ngày > 0** (`computeWeeklySleepComment`).

**"Vượt X% người dùng"**
- Lấy `statistics/get_sleep_users_distribution`, tham số tuổi, JSON trả `sleep_score_user_distribute: {điểm: số người}`.
- Phần trăm = tổng số người có điểm < điểm của mình ÷ tổng số người × 100. Ghi vào `scoreOutperformedPercent`.

**Nhãn điểm** (`H/sleep/utils/SleepExtKt.getSleepShortEvaluation`): <60 Poor, 60–79 Fair, 80–89 Good, ≥90 Excellent.

**Nguồn điểm có thể khác nhau**
- Đồng hồ đời mới gửi sẵn `NightSleepReport.totalScore` và các điểm thành phần (quality, duration, recovery, nervous).
- Cloud còn có `CloudSleepReport.sleepScore`.

> **Làm lại cho Y25:** công thức native không đọc được, nên phải tự thiết kế. Gợi ý ở §5.1: dùng các ngưỡng thời lượng
> và tỉ lệ giai đoạn của §2.3 làm thành phần điểm.

### 2.2 Phân giai đoạn ngủ bằng TFLite (điện thoại)

Dùng cho máy chỉ gửi byte ngủ thô (`MiDevSleepAlgo.parseSleep(byte[])`). Các bước:
1. JNI `setSourceSleepData` trích đặc trưng.
2. `callbackFeaturesFromJNI(float[][])` trả đặc trưng lên Java.
3. `MiParseModel.classify()` chạy `mi_stage_model_0_1_1.tflite` (195 KB), đầu ra `float[n][4]` (4 lớp, thứ tự **chưa chắc**).
4. JNI `setSleepStageResult` hậu xử lý.
5. Kết quả là `SleepStageSummary`.

Trường của `SleepStageSummary`:
- `sleepIntoTs`, `sleepOutofTs`
- `deep`/`light`/`rem`/`wakeDuration`, `wakeCount`
- `stages[]`
- `avgBreathRate`, `breathQuality`

Y25 tự phân giai đoạn trên đồng hồ (`isHasResolveSleep`), nên **không cần** phần này.

### 2.3 Sleep interpretation and suggestions (luật cứng, điện thoại)

Nguồn: `H/sleep/utils/SleepInterpretationExtKt`. Chuỗi UI ghi "Supported by the Chinese Sleep Research Society".

| Luật | Điều kiện (phút, tỉ lệ trên `sleepDuration`) | Mã giải thích | Mã lời khuyên |
|---|---|---|---|
| Ngủ quá ngắn | `sleepDuration ≤ 420` | O (4 biến thể) | A (5) |
| Ngủ quá dài | `sleepDuration > 540` | P (1) | B (3) |
| Tỉ lệ sâu/nông bất thường | Sâu < 20% hoặc > 60%. Nếu có REM: nông < 20% hoặc > 60%. Nếu không có REM: nông < 60% hoặc > 80% (hàm dịch ngược hỏng một phần, **chưa chắc**) | Q (3) | C (6) |
| REM bất thường | REM > 0 và (< 10% hoặc > 30%) | R (1) | D (3) |
| Ngủ muộn | `bedTime` trong [mốc ngày − 1h, mốc ngày + 9h], tức sau 23:00 | S (4) | E (5) |
| Thức dậy nhiều lần | `wakeCount ≥ 3` | T (1) | F (5) |
| Bình thường | Không trúng luật nào | M (8) | N (7) |

**Cách chọn câu**
- ID câu = tiền tố + (số ngày kể từ epoch mod số biến thể).
- `findFirstValidId` bỏ qua câu trùng nghĩa (bảng từ đồng nghĩa).
- Nhờ vậy mỗi ngày đổi câu nhưng vẫn tất định.

**Kho câu chữ:** JSON theo ngôn ngữ trên CDN, ví dụ
`https://cdn.web-global.fds.api.mi-img.com/hlth-operate/appres/images/health/sleep/sleep_suggest_vi.json` (có bản `vi`).
Tải một lần, lưu file, đọc thành `Map<id, text>`.

**Câu tóm tắt đầu thẻ:** chọn theo nhóm điểm ≥80, 70–79, <70 (`getOver80OptionList`, `get70To80OptionList`,
`getBelow70OptionList`), ví dụ `health_sleep_quality_last_night_normal` / `_so_so`.

**UI:** `H/sleep/ui/adapter/SleepInterpretationAdapter`, `SleepInterpretationHolder`, layout `sleep_interpretation_card`.

> **Đây là phần "báo cáo thông minh" dễ làm lại nhất cho Y25:** dữ liệu đủ, luật rõ, không cần server.

### 2.4 Sleep animal (chronotype) và Sleep insight report

**Điều kiện**
- Đeo đi ngủ 7 đêm liền (`health_sleep_no_animal_report_content_desc`).
- Bật đồng bộ cloud (`health_sleep_animal_guide_open_cloud_sync`).

**Gọi server tính con vật**
- `SleepStatDataRequest.triggerComputeSleepAnimal()` POST `statistics/trigger_stat` (host `hlth.io.mi.com/app/v1/`) với
  `data = {"tag":"sleep_stat","key":"sleep_animal","zone_offset":<giây>}`.
- Server trả `StatDataModel`. Trong đó `value` chứa `SleepAnimal { type, sample_dates[], stat_time }`.
- Sau đó app kéo lịch sử bằng `statistics/get_stat_data_by_time` / `get_stat_data_by_watermark` (cùng tag và key).
- Xoá bằng `statistics/delete_stat_data`.
- **Thuật toán phân loại nằm ở server, không thấy trong app.**

**Loại con vật** (`D/annotation/SleepAnimalType`): 1 Penguin, 2 Brown bear, 3 Sheep, 4 Night owl, 5 Koala, 6 Shark.

Mô tả con vật (chuỗi UI) cho thấy trục phân loại là **giờ đi ngủ (sớm/muộn) × lượng ngủ (nhiều/ít) × độ dễ thức giấc**:

| Con vật | Mô tả |
|---|---|
| Brown bear | Ngủ đủ, ngon |
| Penguin | Ngủ tốt nhưng dễ thức |
| Sheep | Ngủ sớm, ngủ ít, dễ mệt |
| Owl | Thức khuya, ngủ chập chờn |
| Koala | Ngủ muộn nhưng khó thức |
| Shark | Ngủ muộn, ngủ rất ít |

Ánh xạ cụ thể là **chưa chắc**.

**Các chỉ số insight** (`R/sleep/utils/SleepAnimalInsightUtils`, tính trên **điện thoại** cho các ngày trong `sample_dates`)

| Chỉ số (holder UI) | Cách tính | Y25 |
|---|---|---|
| Lịch ngủ (`SleepInsightScheduleHolder`) | Cặp (bedTime, wakeupTime) của giấc dài (≥180 phút, lên giường 20:00–07:00, `SleepSegmentExtKt.filterLongSleepBedBetween20to7`) | ✓ |
| Độ liền mạch (`SleepInsightContinuityHolder`) | Tổng `wakeCount` của các giấc dài | ✓ |
| Ngủ trưa (`SleepInsightDayNapHolder`) | Tổng thời lượng các giấc lên giường 07:00–20:00 | ✓ (Y25 có ngủ rải rác) |
| Vận động trước ngủ (`SleepInsightStrengthHolder`) | Số phút có bản ghi `intensity` trong 2 giờ trước giờ lên giường | ½ (dùng bước/HR thay thế) |
| Stress trước ngủ (`SleepInsightStressHolder`) | Stress trung bình của ngày trước giờ lên giường. Mức: >80 Severe, >50 Moderate, >25 Mild, còn lại Relaxed (`SleepAnimalExtKt.getSleepInsightStressLevel`) | ✗ |

**UI**
- Màn chính: `H/sleep/ui/SleepAnimalReportActivity`, `SleepAnimalDetectingActivity` (hoạt hình "Finding your sleep
  animal…"), `SleepAnimalAllRecordsFragment` (báo cáo cũ, xoá được), `SleepAnimalShareActivity`.
- Thẻ: `SleepAnimalScheduleSuggestHolder` (gợi ý lịch ngủ), `SleepDayAnimalEntranceHolder` (lối vào từ trang ngủ).
- Ảnh: tải từ CDN `…/sleep/animal/{entrance,schedule,share}/…`.

### 2.5 Weekly summary (báo cáo tuần, server dựng H5)

- **Danh sách tuần:** GET `https://watch.iot.mi.com/cgi-op/api/v1/watch/health/weeklyList`. Mỗi phần tử
  `WeekReportItem { userId, weeklyTimeStamp }`.
- **Nội dung:** mở WebView `HealthWebViewActivity` với
  `https://%swatch.iot.mi.com/libai/weekly-report.html#/report?app_type=health`. `%s` là tiền tố vùng (ví dụ `eu.`,
  `or.`) (`about/utils/MineHtmlUrlsKt.getWeeklyReportHtmlUrl`).
- **Push:** URL có thể đến qua push (`WeeklyReportAuthActivity.pushUrl`, `mine/scheme/WeeklyPageScheme`).
- **Quyền:** cần đồng ý cho xem dữ liệu bài tập tuần (`mine_weekly_report_auth_*`).
- **Cấu trúc báo cáo:** nằm trong trang H5, không thấy trong APK (**chưa chắc**).
- **Báo cáo tháng:** không có màn riêng. Chỉ có `statistics/get_goal_monthly_statistics_data` và phần chia sẻ vòng hoạt động
  theo tháng.

### 2.6 Giáo án chạy thông minh và tuyến chạy AI

Endpoint nằm ở `training_plan/net/TrainingPlanApiService` (`hlth.io.mi.com/app/v1/`).

**Kế hoạch nâng cao năng lực** (`ability_plan/*`)
- Bảng hỏi gửi `smart_running/improve/user_info` với:
  - `running_distance`, `running_frequency`, `running_pace`, `improve_distance`;
  - ngày tập: `running_days`, `strength_days`.
- Sinh giáo án: `improve/generate`.
- Theo dõi và điều chỉnh: `improve/{summary,course_detail,adjust,terminate,user_ability}`.

**Kế hoạch xây thói quen** (`habit_plan/*`): `smart_running/build/{suggest,setting,detail,summary,adjust,improve_check,improve_reply,teminate}`.

**Báo cáo kế hoạch**
- Endpoint: `smart_running/plan_report`, `plan_report/{history,sport_record,click_bubble}`.
- Trường `PlanReportSummary`: `plan_id`, `plan_type`, `total_days`, `total_course`, `finished_course`, `finish_times`,
  `total_distance`, `total_duration`, `total_calorie`.

**Gửi giáo án xuống đồng hồ:** lệnh (8,87)/(8,88).

**AI route:** có chuỗi `sport_route_by_ai` ("AI-generated"), `sport_ai_planning`,
`sport_ai_route_planning_failed_subtitle`, layout `sport_running_route_card`. Nhưng `RouteRepository.getRouteRecommend()`
trả `null`, không có endpoint, tức **stub** ở bản quốc tế.

### 2.7 AFlash: LLM thật duy nhất (bên thứ ba)

**Bật khi nào:** thiết bị báo feature `"chatgpt"` (`AFlashComponent.FEATURE_AFLASH`).

**SDK:** `com.zhzn.lib.AFlash`, host `https://api.aiwatchzhzn.pro/zh/`.

| Path | Hàm SDK | App Xiaomi có dùng không |
|---|---|---|
| `init` | `initialize(uid, WatchInfo[])` | Có. `WatchInfo` mang MAC, tên, độ phân giải màn hình, `PaymentModel.C_END_PAY` |
| `chat` | `textChat`, `voiceChat`, `chat` | Có (`askTextToAnswerText`) |
| `stt` / `tts` | `speechToText*`, `textToSpeech*` | Có (`voiceToText`) |
| `smart` | `fetchAgentList` (danh sách agent) | Không thấy gọi |
| `health` | `analyzeData(requestId, wid, JSONObject)` → `(String, String, MemberInfo)` | **Không** (SDK có, app không gọi). Server trả JSON khoá bị làm rối (`HGZo`, `Ispk`…), nên định dạng **chưa chắc** |

Vẽ ảnh dùng `textDrawingToFile(..., imgFormat="jpeg"|"png", style)`.

**Luồng trên đồng hồ**
1. Đồng hồ gửi âm thanh (gói loại 103: `AUDIO_COMMAND_START`, `…_AUDIO_END`, `…_QUIT`).
2. Điện thoại gọi STT, rồi chat.
3. Câu trả lời văn bản gửi lại đồng hồ qua gói loại 14 (`AFlashPacketSender` (14,0), `AFlashComponent` (14,7)).

**Vẽ mặt đồng hồ**
1. Lệnh văn bản → `askTextToBitmap`.
2. Ảnh nén RGB565 hoặc SiFli ezip.
3. `AFlashWatchFaceManager` gửi file mặt đồng hồ (4,11).

**Hạn mức:** các entity có `freeNum`, `freeDay`, `vipNum`, `sVipNum`, tức có gói miễn phí và trả phí.

### 2.8 Giải đọc bởi chuyên gia (chỉ Trung Quốc)

- **ECG:** người dùng chọn bản ghi (`SelectEcgForAnalyzingFragment`) rồi gửi cho Helowin.
  - Trạng thái: `EcgInterpretationStatus` 0 chưa giải đọc, 1 đang giải đọc, 2 đã giải đọc.
  - Có token/VIP: `ecg/{get_access_token,refresh_access_token,get_vip_info}`.
  - Trang H5: `api.995120.cn/static/hm505/mihealth-h5`.
  - Kết quả sau khoảng 1–15 phút; 6 lần miễn phí.
- **Báo cáo nhịp ngủ:** chuyển cho Bệnh viện Quốc tế ĐH Bắc Kinh (`health_sleep_rhythm_up_remote_*`, `fe.pkucare.com`).
- Không phải AI. Không áp dụng cho Y25 (Y25 không có ECG).

### 2.9 Đề xuất "Báo cáo AI" cho SmartWear Lab (Y25)

Đây là thiết kế đề xuất, **không** phải thứ Mi Fitness có.

**Bước 1. Tổng hợp tất định trên điện thoại** (không cần mạng), theo kỳ ngày/tuần/tháng. Xuất ra một JSON có:
- Nhịp tim: TB, max, min, nhịp tim nghỉ ước lượng (min của các ô 10 phút khi ngủ), phút theo vùng (§5.2), số lần
  cao/thấp vượt ngưỡng.
- SpO2: TB, min, số lần <90%.
- Giấc ngủ: thời lượng, %sâu/nông/REM, số lần thức, giờ lên giường và thức dậy, độ lệch giờ ngủ (std), ngủ trưa, điểm ngủ
  tự tính, các cờ luật của §2.3.
- Hoạt động: bước, calo, quãng đường, % đạt mục tiêu, "PAI tự tính" (nếu làm).
- Huyết áp ước lượng: TB và phân loại.
- Kinh nguyệt: pha hiện tại, ngày dự đoán.
- Xu hướng so với kỳ trước (Δ%).

**Bước 2. Lớp luật** (giống §2.3): sinh danh sách "phát hiện" có mã, mức độ và số liệu. LLM **không** tự đọc chuỗi số
thô.

**Bước 3. LLM viết văn bản.**
- Gửi JSON tổng hợp và danh sách phát hiện. Yêu cầu trả **JSON có cấu trúc**:
  `{summary, sections:[{metric, status, insight, advice}], score?, disclaimer}`.
- Theo quy định dự án, mô hình phải gọi qua dịch vụ của project `runpod-ai`. Đọc catalog `runpod-ai/README.md` trước;
  nếu chưa có endpoint LLM phù hợp thì giao task cho runpod-ai.
- Không tự chạy mô hình trên Mac mini.
- Không gửi định danh người dùng.

**Bước 4. Kích hoạt**
- Báo cáo ngày: sau lần đồng bộ buổi sáng.
- Báo cáo tuần: sáng thứ Hai, tính 7 ngày trước.
- Lưu cache. Có nút "tạo lại".

**Bước 5. UI:** thẻ tóm tắt trên trang chủ, trang chi tiết theo từng mục, ghi chú "không phải chẩn đoán y khoa" (giống
câu miễn trừ của Mi Fitness).

---

## 3. Trang chủ, tab và điều hướng

| Mục | Bằng chứng | Ghi chú |
|---|---|---|
| 4 tab: Sức khoẻ, Vận động, Thiết bị, Tôi | `com/xiaomi/fitness/main/export/MainTab`, `main/MainActivity` | |
| Trang Sức khoẻ | `homepage/HealthV2Fragment`, `v2/HealthAdapterV2`, header vòng hoạt động `homepage/view/DataHeaderV2View` | |
| Loại thẻ trên trang chủ | `D/annotation/HomeDataType` | Danh sách ngay dưới bảng |
| Holder của thẻ | `v2/holder/{BarChart,LineChar,HealthIndicatorCard,BloodGlucoseChart}…`, `homepage/viewholder/SpecialBarChartContentViewHolder` | |
| Sửa thẻ (ẩn/hiện, sắp xếp) | `showalldata/ManageHealthFunctionFragment`, `homepage/ItemSortViewModel` | Lưu cloud (`setting/set_user_device_settings`, key `KEY_HEALTH_DATA`) |
| Luật hiện thẻ | `HealthDataTypeUtilsV2.getAllDataTypeList` | Thẻ hiện nếu thuộc nhóm mặc định, hợp giới tính, đã có dữ liệu, thiết bị hỗ trợ, hoặc được bật trên cloud |
| Banner vận hành | `homepage/banner/HealthBannerView` | `ops/v1/banner/get_banner_list`, `cgi-op/api/v1/watch/health/resource` |
| Widget màn hình chính | `com/mi/health/rainbow/WidgetRainbowProvider_2_2/4_2` | Vòng hoạt động |
| Tab Tôi | `mine/v4/MineFragmentV4` | Widget và mục ngay dưới bảng |

**Các loại thẻ** (`HomeDataType`): RAINBOW, STEP, CALORIE, VALID_STAND, MH_STRENGTH, SLEEP, HR, SPO2, STRESS, ENERGY,
WOMEN_HEALTH, HEARING_HEALTH, PAI, WEIGHT, VITALITY, V02_MAX, BLOOD_PRESSURE, BP_MEDICAL, SPORT_REPORT, TRAINING_LOAD,
TEMPERATURE, PK, RUNNING_INDICATOR, ECG_MEDICAL, BLOOD_SUGAR, PHYSICAL_STATUS, LACTATE_THRESHOLD.

**Tab Tôi**
- Widget: hồ sơ, huy chương, thói quen, báo cáo tuần, PK, khoá học VIP.
- Mục: Tuyến của tôi, Cài đặt app, Quản lý dữ liệu cá nhân, Uỷ quyền thiết bị, Chia sẻ thiết bị, Quyền hệ thống, Trợ giúp
  & phản hồi, Cập nhật, Giới thiệu.

---

## 4. Các trang chỉ số sức khoẻ

Mỗi chỉ số có trang Ngày/Tuần/Tháng (`ViewTag`: days, weeks, months), trang "Tìm hiểu" (Understand…Fragment), danh sách mọi
bản ghi, và nhập tay nếu có.

| Chỉ số | Trang (class) | Trường dữ liệu chính (`D/aggregation`, `D/item`) | Tính ở đâu | Y25 |
|---|---|---|---|---|
| **Nhịp tim** | `H/hrm/HrmFragment`, `HrmDay/Week/MonthFragment`, `HrmRestingFragment`, `HrmAbnormalChartFragment`, `HrmExpandableExtremeHigh/Low/FibRecordsFragment`, `HrmAddFragment` | `DailyHrReport`: avgHr, maxHr, minHr, restHr, hrRecords, abnormalHigh/Low (`SegmentItem`), abnormalFibRecords, hrDistribute (smooth, warmUp, fatBurn, aerobic, anaerobic, extreme) | W (giá trị, nhịp nghỉ, cảnh báo). P (phân vùng: `R/heartrate/HeartRateDistribute`) | ✓ (24h, ô 5–10 phút) |
| **Giấc ngủ** | `H/sleep/ui/SleepFragment`, `SleepDay/Week/MonthFragment`, `SleepSegmentReportDetailFragment`, `SleepQualityDetailFragment`, `SleepHrmDetailFragment`, `SleepSpo2DetailFragment`, `SleepBreathQuality/RateDetailFragment`, `SleepAddRecordFragment`; nhịp và nhật ký ngủ ở `rhythm/**` | `AllDaySleepReport`: score, stage, commentCode, scoreOutperformedPercent, totalDuration, deep/light/rem/awakeDuration, avg/max/minHr, sleepSegments. `SleepSegmentReport`: bedTime, wakeupTime, sleepDuration, …, wakeCount, avgBreathRate, breathQuality, snoreDuration, dreamTalkCount | W (giai đoạn). P (điểm, luật). S (con vật, percentile) | ✓ (có REM, có ngủ rải rác) |
| **SpO2** | `H/spo2/Spo2Fragment`, `Spo2Day/Week/MonthFragment`, `Spo2AbnormalChartFragment`, `Spo2ExpandableExtremeLow/ManualRecordsFragment` | `DailySpo2Report`: avg/max/minSpo2, lackTimes, spo2Records, abnormalRecords | W | ✓ |
| **Stress** | `H/stress/StressFragment`, `StressDay/Week/MonthFragment`, `StressRecordDetailFragment` | `DailyStressReport`: avg/max/minStress, relax, light, medium, heavy (thời lượng) | W (giá trị 1–100 từ HRV). P (chia mức) | ✗ |
| **Energy** ("pin cơ thể") | `H/energy/EnergyFragment`, `EnergyDay/Week/MonthFragment` | `DailyEnergyReport`: avg/max/minEnergy, durationAct, durationStress, durationRecov. `EnergyState`: 0 none, 1 activity, 2 stress, 3 recovery | W. P (thời lượng theo trạng thái: `R/energy/EnergyDistribute`) | ✗ (cần HRV) |
| **PAI** | `H/pai/PaiFragment`, `PaiDayFragment`, `view/PaiProgressView` | `DailyPaiReport`: pai, totalPai, low/medium/highZonePai | W (thuật toán Huami) | ½ (tự tính từ HR) |
| **Vitality** | `H/vitality/VitalityFragment`, `VitalityDayFragment` | `VitalityItem`: high/medium/lowVitality, totalVitality (7 ngày), activityDuration | W | ½ |
| **VO2max** | `H/vo2max/VO2MaxFragment`, Week/Month | `Vo2MaxItem`: vo2Max, level | W (giá trị). P (mức, nếu đồng hồ không gửi) | ✗ (chưa có) |
| **Training load / phục hồi** | `H/trainload/TrainingLoadFragment` | `TrainingLoadItem`: currentDayTL, wtlSum, wtlSumOptimalMin/Max, wtlSumOverreaching, tlLevel; recoveryTime | W | ✗ |
| **Physical status** | `H/physicalstatus/*` | `PhysicalStatusItem`: physicalFitnessLevel (CTL), fatigueLevel (ATL), trainingStress (TSS) | W | ✗ |
| **Running indicator** | `H/runningindicator/*` | runningIndicator, level; `GradePredictionItem` (5 km, 10 km, half, full); `LactateThresholdItem` | W | ✗ |
| **Bước, calo, đứng, cường độ vừa–cao, vòng hoạt động** | `H/step/*`, `H/calorie/*`, `H/stand/*`, `H/mhintensity/*`, `H/threetarget/{SportTargetFragment,ThreeTargetWeekFragment,ShareSportTargetActivity}` | `DailyStepReport`: steps, distance, calories, active. `DailyStandReport`: standCount. `DailyMHStrengthReport`: duration. `DailyGoalReport`: goalList | W. Mục tiêu ở P và tài khoản | ✓ bước, calo, quãng đường. ✗ đứng, cường độ (tự suy từ bước theo phút) |
| **Nhiệt độ cơ thể** | `H/temperature/ui/*` | `DailyTempReport`: avg/max/min body/skinTemp | W hoặc nhập tay | ✗ (bit tắt) |
| **Huyết áp** | `H/bloodpressure/ui/*` (Add, Remind, Understand) | `DailyBloodPressureReport`: avg/max/minHigh, …Low, …Pulse. `BloodPressureItem`: highPressure, lowPressure, pulse | W, máy đo, hoặc nhập tay | ✓ (ước lượng PPG, `C8 FA`) |
| **ECG** | `H/ecg/EcgFragment`, `EcgItemDetailActivity`, `N60EcgRecordsFragment` | `EcgMedicalItemReport`: analysisResult, avgHr, interpretStatus, sampleFrequency, symptomList | W. P (lọc bằng native `libjni_mi_ecg_algo`). 3P (giải đọc) | ✗ |
| **Thính lực, tiếng ồn** | `H/hearing/*` | `DailyHearingReport`: highDuration, noiseList (decibel) | Tai nghe hoặc đồng hồ | ✗ |
| **Sức khoẻ phụ nữ** | `H/curse/CurseMainActivity`, `CurseMonthFragment`, `CurseEditActivity`, `CurseSetActivity`, `CurseNotifyFragment` | `WomenHealthStatus` (START/END), `WomenHealthSymptoms` (hp, mood, pain) | P (dự đoán: `H/curse/CurseManager`). Một số máy tự dự đoán | ✓ (`MENSTRUATION` bit) |
| **Cân nặng, thành phần cơ thể** | `H/weight/ui/*`, cân `com/xiaomi/fitness/electronic/scale/*` | `WeightItem`: weight, bmi, bodyFatRate, muscleMass, moistureRate, visceralFat, basalMetabolism, bodyAge, bodyScore… | Cân hoặc S. P (đánh giá theo bảng) | Nhập tay |
| **Đường huyết (CGM)** | `H/bloodglucose/ui/*`, `com/xiaomi/fitness/blood_sugar/**` | `BloodSugarItem`: bloodSugar, measurePeriod, trend. GMI, AGP | Cảm biến. P (`R/bloodsugar/utils/BloodSugarAnalyzer`) | ✗ |

---

## 5. Thuật toán và ngưỡng đọc được trong mã

### 5.1 Giấc ngủ

| Mục | Giá trị | Class |
|---|---|---|
| Nhãn điểm | <60 Poor, 60–79 Fair, 80–89 Good, ≥90 Excellent | `H/sleep/utils/SleepExtKt.getSleepShortEvaluation` |
| Giấc dài / ngủ trưa | Giấc dài ≥180 phút, lên giường 20:00–07:00. Ngủ trưa: lên giường 07:00–20:00 | `R/sleep/SleepSegmentExtKt` |
| % ngủ sâu "bình thường" | Mã: 20–60%. Chuỗi UI: 20–40% (mâu thuẫn) | `SleepAnalyzeHelper` |
| % nông, % REM, thức | Nông 20–60%, REM 10–30%, thức <5% | Chuỗi UI |
| Số lần thức tốt, SpO2 khi ngủ, chất lượng thở | Thức 0–2 lần. SpO2 95–100%. Chất lượng thở 90–100 | Chuỗi UI |
| Thời lượng | ≤420 phút là ngắn, >540 phút là dài. Mục tiêu mặc định 480 phút | `SleepInterpretationExtKt`, `SleepSettingRepository` |
| Giờ ngủ lý tưởng | 22–23h, độ lệch ≤30 phút (chỉ trong chuỗi; hàm hỏng, **chưa chắc**) | `SleepAnalyzeHelper` |
| Điểm tuần | TB các điểm ngày >0 | `DaySleepReportUtils.computeWeeklySleepComment` |

**Gợi ý điểm ngủ cho Y25** (tự thiết kế, không phải công thức Xiaomi): 100 trừ dần các khoản sau.
- Thời lượng: trừ 0 nếu 7–9h, trừ tuyến tính đến 30 điểm.
- Tỉ lệ sâu ngoài 20–60%: tối đa 15.
- Tỉ lệ REM ngoài 10–30%: tối đa 15.
- Số lần thức ≥3: tối đa 15.
- Giờ lên giường sau 23:00: tối đa 10.
- Lệch giờ ngủ so với TB 7 ngày >30 phút: tối đa 15.

### 5.2 Nhịp tim

| Mục | Giá trị | Class |
|---|---|---|
| Nhịp tối đa | Lấy giá trị đã ghi nhận, nếu không có thì **220 − tuổi** (tuổi mặc định 25) | `com/xiaomi/fitness/account/api/bean/UserProfile.getMaxHrOrDefault` |
| Vùng (% nhịp tối đa) | ≥50 Warm-up, >60 Fat burn, >70 Aerobic, >80 Anaerobic, >90 Extreme, dưới 50 là Smooth | `com/xiaomi/fitness/account/HrZone` |
| Cảnh báo cao | 100–150 bpm, bước 10, hoặc tắt | `DS/bluttooth/healthmonitor/hr/BleHeartRateModel` |
| Cảnh báo thấp | 40, 45, 50 bpm | Như trên |
| Cảnh báo khi tập | 160–200 bpm | Như trên |
| Chu kỳ đo | Tắt, thông minh, 1, 5, 10, 30 phút | Như trên |
| Nhịp nghỉ bình thường | 55–79/80 bpm (chỉ trong chuỗi UI) | `health_hrm_resting_about_desc` |
| Mô tả nhịp tim | 60–100 bình thường, <60 chậm, >100 nhanh (chuỗi `heartrate_report_*`) | – |

### 5.3 Stress, Energy, SpO2

| Mục | Giá trị | Class |
|---|---|---|
| Mức stress (nhánh Xiaomi) | 1–25 Relaxed, 26–50 Mild, 51–80 Moderate, 81–100 High | `com/xiaomi/fitness/chart/entrys/StressEntry.getStressType` |
| Mức stress (nhánh Huami) | ≤39, 40–59, 60–79, ≥80 | Như trên |
| Nhắc thư giãn | Khi stress liên tục >80 | `PressureModel` |
| Mức energy | ≤20 Exhausted, 21–40 Low, 41–60 Moderate, 61–80 Great, >80 Energetic | `defpackage/v43`, `bz5` |
| SpO2 "thiếu" | <90% | `health_spo2_summary_*_lack` |
| Ngưỡng cảnh báo SpO2 thấp | 80, 85, 90% | `BleSpo2Model.blodLowList` |
| Chế độ đo SpO2 | Tắt, khi ngủ, cả ngày; mỗi 10 hoặc 30 phút | `BleSpo2Model` |

### 5.4 Hoạt động, PAI, Vitality, VO2max

| Mục | Giá trị | Class |
|---|---|---|
| Mục tiêu mặc định | 6000 bước, đứng 12 giờ, cường độ vừa–cao 30 phút | `UserProfile`, `account/goal/GoalPreference` |
| Mục tiêu calo | round(cân nặng × 8 × 45 / 60 / 100) × 100 (8 MET × 45 phút; 60 kg cho 400 kcal) | Như trên |
| Calo theo bước (Huami dự phòng) | BMR Mifflin-St Jeor = 10W + 6.25H − 5A (+5 nam / −161 nữ). cal = BMR/1440 × bước × (1.7H − 90)/9000. Sải chân = cao × 0.42 | `com/xiaomi/hm/health/dataprocess/DataAnalysis.getRealCal` |
| PAI | Tối đa 75/ngày. Cửa sổ trượt 7 ngày. Mục tiêu 30/50/100. Công thức nằm trên đồng hồ | `PaiProgressView`, chuỗi `health_pai_*` |
| Vitality | Tối đa 80/ngày (560/7 ngày). Mục tiêu 30/60/100. Dựa trên khuyến nghị WHO 150–300 phút vừa / 75–150 phút mạnh | Chuỗi, `VitalityUtil` |
| VO2max (7 mức) | Nam <25 tuổi: >62/56/50/43/37/32. Nữ <25: >51/46/41/36/31/27. Bậc tuổi 5 năm đến 60+ | `com/xiaomi/fit/fitness/export/utils/SportLevelComputeUtils` |
| Training load | 1 thấp (≤optimalMin), 2 tối ưu (≤optimalMax), 3 cao (≤overreaching), 4 rất cao | `SportLevelComputeUtils.computeTrainingLoadLevel` |
| Running index | <20, <30, <40, <65, còn lại; mức 1–5 | `computeRunningAbilityIndexLevel` |

**Gợi ý "PAI tự tính" cho Y25** (**chưa chắc** giống Huami): cộng điểm theo phút ở vùng ≥60% nhịp tối đa, trọng số tăng
theo vùng, tối đa 75 điểm/ngày, tổng 7 ngày, mục tiêu 100.

### 5.5 Kinh nguyệt, huyết áp, nhiệt độ, cân, đường huyết, tiếng ồn

| Mục | Giá trị | Class |
|---|---|---|
| Chu kỳ / hành kinh mặc định | 28 / 5 ngày | `com/xiaomi/fitness/settingitem/settingitem/CurseSetting` |
| Độ dài hành kinh dự đoán | Từ 3 kỳ gần nhất: nếu 2 giá trị bằng nhau thì lấy giá trị đó, không thì lấy TB | `H/curse/CurseManager` |
| Ngày rụng trứng | Chu kỳ − 13 (khi 20 ≤ chu kỳ < 60). Ngày 6 (khi 12–19) | `CurseManager.initOvumIndex` |
| Cửa sổ thụ thai | Rụng trứng −5 đến +4 | `CurseManager.initRiskRange` |
| Trạng thái ngày | 0 none, 1 đang hành kinh, 2 dự báo, 3 dễ thụ thai, 4 rụng trứng | `CurseManager` |
| Tính độ dài chu kỳ | Hàm `initInterval` dịch ngược hỏng, **chưa chắc** | `CurseManager` |
| Huyết áp | Không có ngưỡng trong mã. Chuỗi theo hướng dẫn TQ 2018: bình thường <120/<80; bình thường cao 120–139/80–89; tăng huyết áp ≥140/≥90; thấp ≤90/≤60 | Chuỗi |
| Huyết áp nhập tay | Tâm thu 30–300, tâm trương 30–200, mạch 30–220 | Chuỗi |
| Nhiệt độ | Thân nhiệt bình thường 35.0–37.3 °C. Nhập tay 34–42 | `TemperatureDayDetailAdapter`, `TemperatureAddFragment` |
| BMI | 18.5 / 24 / 28 | `electronic/scale/util/WeightEvaluationHelper` |
| % mỡ | Nam 18–39 tuổi: 10/21/26. Nữ 18–39: 20/34/39 (có bậc 40–59 và 60+) | Như trên |
| Đường huyết | Mục tiêu 3.9–10.0 mmol/L. GMI = 3.31 + 0.02392 × (TB / 18), cần ≥2880 điểm | `BloodSugarTargetRange`, `BloodSugarAnalyzer` |
| Tiếng ồn | <60 dB dễ chịu, 60–79 cao, ≥80 rất cao | `NoiseLevelUtil` |

---

## 6. Vận động và bài tập

| Tính năng | Bằng chứng | Nguồn dữ liệu | Y25 |
|---|---|---|---|
| Tab Vận động | `sport/sporttab/SportTabV4Fragment`. Thẻ: báo cáo bài tập, chỉ số tập luyện, banner, khoá học, tuyến chạy, Just Dance, giáo án | Hỗn hợp | – |
| 170 môn thể thao | `com/xiaomi/fit/data/common/data/annotation/FitnessSportType` (171 hằng số kể cả NONE); `FitnessProtoSportType` (56) | – | ½ (~20 môn) |
| Tập dùng GPS điện thoại | `sport/view/sporting/{BaseSportingActivity,CommonSportActivity,IndoorRunningActivity}`, `sport_manager/location/SportService` (foreground service), màn khoá `sport/view/lockscreen/*`, bản đồ Mapbox `com/mi/health/data/sportmodel/view/SportPathMapView` | GPS điện thoại, HR đồng hồ | ✓ (điện thoại làm GPS) |
| Mục tiêu, nhắc nhở, nhạc khi tập | `sport/view/goal/*`, `sport_manager/remind/GoalRemind`, `sport_manager/music/SportMusicManager` | P | ✓ |
| Chi tiết bài tập | `com/xiaomi/fitness/detail/SportDetailFragment`, `SportDetailGpsFragment`. Biểu đồ trong `detail/inner/` | Bản ghi bài tập từ đồng hồ | ½ (tuỳ dữ liệu Y25 gửi) |
| Danh sách, thống kê tuần/tháng/năm | `trail/RecordMainActivity`, `RecordListFragment`, `DimenPeriodFragment` | Local + S | ✓ |
| Chia sẻ ảnh báo cáo bài tập | `share/report/SportReportShareActivity`, `EditSportReportCustomShareActivity`, sticker; cấu hình `sportShareConfig` | P | ✓ |
| Nhập/xuất tuyến | Nhập GPX/TCX (`parser/sport/track/parser/GpxHelper`, `TcxHelper`); xuất .gpx/.kml/.tcx (`track/ExportTrackActivity`); đẩy tuyến xuống đồng hồ `route/track/push/TrackPushBleImpl` (8,57/58/60) | P | ½ |
| Giáo án chạy | §2.6 | S | ½ |
| Khoá học (video) | `com/mi/health/course/api/{CourseService,CourseV3Service}`; VIP `ops/v1/courses/memberships`; thanh toán `ops/v1/mall/order/*` | S | – |
| Thiết bị gym, đo FTP xe đạp | `sport/view/launch/gym/*`, `sport_eco/ftp/ui/*` | BT thiết bị ngoài | – |
| Just Dance (Switch) | `sport/view/justdance/*`, `just_dance/static_data(_list)` | Điện thoại làm tay cầm | – |
| PK thách đấu | `active/pk/ui/*`; `ops/v1/pk/{create_invite,accept_invite,get_pk_detail,get_pk_statistics,…}` | S | Cần server riêng |

**Biểu đồ trong chi tiết bài tập** (`detail/inner/`)
- Pace và tốc độ, pace chia đều
- Nhịp tim và vùng nhịp (`model/HrmZoneLevel`), nhịp phục hồi, stress, nhiệt độ
- Cadence, sải chân, các chỉ số dáng chạy (tiếp đất, dao động dọc, công suất chạy)
- Công suất xe đạp
- Bơi: pace, SWOLF, số sải
- Nhảy dây: số lần, độ cao, phân đoạn
- Độ cao, lặn, golf, trượt tuyết, chèo thuyền
- Huy chương trong bài tập

---

## 7. Mục tiêu, huy chương, thói quen, báo cáo

| Tính năng | Bằng chứng, endpoint | Nguồn |
|---|---|---|
| Vòng hoạt động 3 mục tiêu (bước, đứng, cường độ; hoặc calo) | `H/threetarget/*`, `ThreeTargetSourceDialog` (chọn nguồn dữ liệu), chia sẻ theo ngày/tháng | W hoặc P |
| Huy chương | `medal/MedalManagerImpl`; `https://watch.iot.mi.com/ops/v1/medal/{my_all_medal,detail,my_entrance/v3,pop_list}`; popup ở `MainActivity.dealWithMedal` | S |
| Thói quen (điểm danh hằng ngày) | `habit/ui/{HabitTodayActivity,HabitListActivity,AddHabitActivity}`; `cgi-op/api/v1/miwear/habit/{all,my,today,detail,punch,update,delete}` | S + cache Room |
| Thống kê mục tiêu theo tháng | `statistics/get_goal_monthly_statistics_data`, `vitality/get_achievement_data` | S |
| Báo cáo tuần | §2.5 | S (H5) |
| Báo cáo nhịp tim sau khi đo | Chuỗi `heartrate_report_{active,resting,regular}_*_desc`: văn mẫu theo mức nhịp | P (mẫu câu) |

---

## 8. Xã hội, tích hợp, dữ liệu

| Tính năng | Bằng chứng, endpoint | Ghi chú |
|---|---|---|
| Chia sẻ sức khoẻ cho người thân | `com/xiaomi/fitness/relative/ui/*` (mời qua tài khoản hoặc QR, chọn loại dữ liệu và khoảng thời gian, nhãn quan hệ). Trang xem từng chỉ số `relative/{step,sleep,hrm,spo2,bloodpressure,weight,…}/*RFragment` | Chi tiết ngay dưới bảng |
| Cảnh báo bất thường cho người thân | Đăng ký topic; tin nhắn qua trung tâm tin nhắn; `AbnormalDataKey`: `abnormal_heart_beat`, `high_heart_rate` | S + push |
| Trung tâm tin nhắn | `com/mi/health/message/center/*`; `message/{check_new_msg,get_msg_list,batch_get_msg,get_alert_msg}` | MiPush (`push/request/PushService` gọi `mipush/reg`) |
| Google Fit, Strava, Suunto | `access/{GoogleFitAccessActivity,StravaAccessActivity,SuuntoAccessActivity}`; `third/googlefit/*`, `third/strava/*`, `third/bind/oauth2` | **Server** đồng bộ sang bên thứ ba |
| WeChat WeRun, Alipay | `access/{WechatActivity,AlipayActivity}` | Chỉ Trung Quốc |
| Chuyển dữ liệu từ Zepp/Huami | `access/misport/MiSportImportActivity`; `huami/data_migrate/*` | |
| Health Connect | **Không có** (không tham chiếu `androidx.health.connect`) | SmartWear Lab có thể làm hơn |
| Xuất dữ liệu | Chỉ xuất tuyến .gpx/.kml/.tcx. Không có xuất toàn bộ tài khoản | Xoá tài khoản qua H5 |
| Quản lý dữ liệu cá nhân, nghiên cứu | `mine/personal/data/management/*`; `auth/{third_party,lab/grant,lab/revoke,miapp/update_scopes}` | |
| Phản hồi kèm log đồng hồ | `feedback/bugreport/*`; `stat/feedback*`, `user/gen_upload_userfileurl` | |
| Đồng bộ cloud | `persist/server/service/FitnessApiService`, `FDSApiService` (file) | Watermark + theo thời gian |

**Chia sẻ người thân: endpoint** (`relatives/*`)
- `get_relative_list`, `send_invite`, `operate_invite`
- `get_shared_data_types`, `update_shared_data_types`
- `get_settings`, `up_settings`, `get_topic_subscriptions`
- Đọc dữ liệu của người thân: `relatives/{get_aggregated_data,get_fitness_data,get_latest_data}`

**Loại dữ liệu chia sẻ được:** activity, heart_rate, sleep, weight, blood_pressure, curse, intensity, regular_target,
abnormal_event. Danh sách đầy đủ do server quy định.

---

## 9. Cài đặt thiết bị và tính năng phía đồng hồ

**Cách tab Thiết bị dựng danh sách**
- Mỗi dòng là một `TabContentItem`, đăng ký chủ yếu ở `DS/di/FeatureItemModule`.
- Dòng chỉ hiện khi thiết bị báo capability tương ứng (`device/manager/export/bean/Feature`).
- Cột "Gói" bên dưới là (loại, lệnh) protobuf.

**Bảng loại gói** (suy từ cách dùng, **chưa chắc**)

| Loại | Nhóm | Loại | Nhóm |
|---|---|---|---|
| 1 | Bind | 13 | Debug |
| 2 | Hệ thống | 14 | AFlash |
| 4 | Mặt đồng hồ | 16 | GNSS |
| 5 | NFC | 17 | Lịch, báo thức |
| 7 | Thông báo | 18 | Nhạc |
| 8 | Sức khoẻ | 19 | Alexa |
| 9 | eSIM | 20 | Ứng dụng bên thứ ba |
| 10 | Thời tiết | 21 | Danh bạ, SOS |
| 11 | Chứng khoán | 22 | Dữ liệu lớn |
| 12 | Lịch | | |

| Nhóm | Mục (class) | Gói | Tham số, giới hạn | Y25 |
|---|---|---|---|---|
| Giám sát nhịp tim | `DS/bluttooth/healthmonitor/hr/BleHrSettingFragment` | (8,10)/(8,11) | Chu kỳ, cảnh báo cao/thấp/khi tập, nhịp bất thường, hỗ trợ ngủ, chất lượng thở khi ngủ, nhịp ngủ | ✓ (chu kỳ, cảnh báo) |
| Giấc ngủ | `.../sleep/view/BleSleepSettingFragment` | (8,10)/(8,11) | Hỗ trợ ngủ, chất lượng thở, nhịp ngủ, phát hiện ngáy | ½ |
| SpO2 | `.../spo2/BleSpo2SettingFragment` | (8,8)/(8,9) | Tắt, khi ngủ, cả ngày; 10 hoặc 30 phút; cảnh báo 80/85/90% | ½ (Y25 không có SpO2 tự động) |
| Stress | `.../pressure/BlePressureSettingFragment` | (8,14)/(8,15) | Cả ngày; nhắc thư giãn | ✗ |
| Nhắc ngồi lâu, đứng dậy | `DS/base/sedenraty/SedentaryFragment` | (8,12)/(8,13) | Bật/tắt, giờ làm việc, nghỉ trưa (mặc định 12–14h) | ✓ (bit có, **chưa chắc**) |
| Nhắc mục tiêu, Vitality | `DS/huami/goalremind/GoalRemindFragment`, `DS/common/vitality/VitalitySettingFragment` | (8,35)/(8,36) | | ½ |
| Báo thức | `DS/base/clock/AlarmClockFragment` | (17,0)/(17,5)/(17,4) | Tối đa 10; có báo thức thông minh (cửa sổ 10 phút) | ✓ |
| Sự kiện, nhắc việc | `DS/common/eventremind/EventReminderFragment`, `DS/bluttooth/todo/*` | (17,14)/(17,15)/(17,18) | Tối đa 50; nội dung ≤25 ký tự | ½ |
| Đồng bộ lịch | `sync/SyncEngine.postCalendarList` | (12,x) | Tiêu đề, địa điểm, bắt đầu/kết thúc, nhắc trước | ? |
| Thời tiết | `DS/huami/weather/WeatherSetFragment` | (10,5)–(10,10) | Tối đa 4 thành phố; cảnh báo thời tiết; °C/℉ | ✓ |
| Giờ thế giới, chứng khoán | `DS/base/worldclock/*`, `DS/bluttooth/stock/*` | (17,10)/(11,x) | Chứng khoán tối đa 20 mã | – |
| Thông báo ứng dụng | `com/xiaomi/fitness/notify/NotifyFragment` | (7,0)/(7,1); icon (7,15) | Chỉ khi khoá máy, chỉ khi đang đeo, độ trễ | ✓ |
| Cuộc gọi, trả lời SMS nhanh | `notify/callnotify/*`, `smsreply/BleSmsReplyViewModel` | (7,9)/(7,12) | 1–10 câu trả lời nhanh | ✓ cuộc gọi |
| Danh bạ yêu thích | `DS/common/contact/TopContactsActivity` | (21,4)/(21,5)/(21,7) | | ✓ |
| SOS, phát hiện ngã | `DS/bluttooth/falldetection/*`, `emergencycontact/*`; `app/v1/sos/location_report` | (21,0)/(21,1) | | – |
| Không làm phiền | `DS/common/zenmode/ZenModeSettingFragment` | (2,14)/(2,15) | | ✓ |
| Nâng tay sáng màn | `DS/bluttooth/screenwake/*` | (2,24)/(2,25) | Cả ngày hoặc theo giờ; độ nhạy | ✓ |
| AOD, chế độ đêm | `DS/bluttooth/aod/AODSettingFragment`, `DS/huami/nightmode/*` | (2,65)/(2,66) | Tắt, thông minh, theo giờ | – |
| Rung | `DS/huami/vibratemode/*` | (2,46)/(2,47) | Tối đa 50 kiểu rung tự tạo | ? |
| Ngôn ngữ, tay đeo, khoá khi tháo đồng hồ | `DS/common/language/*`, `DS/huami/handletype/*`, `DS/common/lock/*` | (2,6), (2,9)/(2,21) | PIN | ½ |
| Thứ tự môn, widget, ứng dụng, phím tắt | `DS/bluttooth/{sportsort,directcard,appsort,applayout,shortcut,widget}/*` | (2,27)–(2,41), (2,51)/(2,52) | | ? |
| Tìm thiết bị / tìm điện thoại | `DS/common/finddevice/FindDeviceFragment`; `DS/common/findPhone/FindPhoneHelperImpl` | (2,18) / (2,17) | | ✓ |
| Chụp ảnh từ xa | `DS/huami/photo/PhotoSetFragment` | (2,7)/(2,8) (BT HID) | | ? |
| Nhạc | `DS/bluttooth/music/*` (chuyển bài hát, playlist); điều khiển media `media/MediaSyncManager` | (18,1)–(18,13) | | ½ (điều khiển) |
| Mặt đồng hồ | `WF/FaceFragment`, `market/DeviceFaceMarketFragment`, `FaceEditFragment`; ảnh làm mặt `FaceBlePhotoFragment`; trả phí `ops/v1/paidwatchface/*` | (4,0)–(4,11) | Sửa: ảnh, kiểu, nền, vị trí, phông, màu, kim, slot widget (HR, bước, calo, ngủ, SpO2, thời tiết, pin…) | ✓ (đã có trong lab) |
| Mặt đồng hồ AI (AFlash) | §2.7 | (4,11), (14,x) | | ✗ |
| Mi AI (Xiao AI), Alexa | `aivs/di/AivsHelperImpl`, `DS/common/avs/AivsSettingFragment`; `com/xiaomi/wearable/alexa/*` | (19,x) | | ✗ |
| NFC, thẻ giao thông, eSIM | `com/xiaomi/fitness/nfc/*`, `com/mi/fitness/esim/*`, `lpamanagement/*` | (5,x), (9,x) | | ✗ |
| Cập nhật firmware (OTA) | `com/mi/fitness/checkupdate/*`; `healthapp/device/latest_ver` | (2,4)/(2,5) | | ? |
| AGPS | `sync/net/agps/AgpsService`: `agps/get_online_file` / `get_offline_file`, hoặc ublox qua `api.70mai.com.cn`; vị trí điện thoại (16,2) | gửi file | | ✓ (cần làm, xem feature-matrix #18) |
| Kho ứng dụng đồng hồ | `com/xiaomi/xms/wearable/*`; `watch/appstore/*` | (20,x) | | ✗ |
| Mở khoá điện thoại/laptop, chia sẻ mạng BT, bản đồ offline | `DS/base/unlock/*`, `DS/common/hotspot/*`, `DS/common/offlinemap/*` | | | ✗ |

---

## 10. Hệ sinh thái (ngắn)

- **Cân thông minh** (`electronic/scale/*`)
  - Thành viên gia đình ảo, chỉ số theo từng chi, báo cáo thành phần cơ thể tải về được.
  - API qua `eco/api_proxy`.
- **Đường huyết liên tục** (`blood_sugar/*`, mẫu `synaps.watch.m8`): kích hoạt cảm biến bằng NFC, đồ thị AGP.
- Cả hai không liên quan Y25. Chỉ nên làm nhập cân nặng bằng tay.

---

## 11. Gợi ý thứ tự làm lại trong SmartWear Lab (Y25)

| Ưu tiên | Tính năng | Dữ liệu Y25 cần | Phụ thuộc (feature-matrix) |
|---|---|---|---|
| 1 | Trang ngủ: giai đoạn, điểm tự tính, **giải thích và lời khuyên** (§2.3, §5.1) | `EC 01` (CyWee) hoặc `31 01`, REM | Sửa đồng bộ ngủ (#9) |
| 2 | Trang nhịp tim: vùng nhịp, cảnh báo cao/thấp, nhịp nghỉ (§5.2) | `F7 FA`, tham số `A9` | Có sẵn một phần |
| 3 | Vòng hoạt động, mục tiêu, thẻ trang chủ có ẩn/hiện | Bước theo giờ `EB 02 FA`, tổng hôm nay | #9 |
| 4 | SpO2 và huyết áp: biểu đồ, phân loại theo chuỗi Mi Fitness | `34 FA`, `C8 FA` | #16 |
| 5 | Kinh nguyệt: dự đoán theo `CurseManager` (§5.5) | Bit `MENSTRUATION` | #8, #20 |
| 6 | **Báo cáo AI ngày/tuần** (§2.9) | Mọi dữ liệu ở trên | runpod-ai (LLM) |
| 7 | Sleep insight / chronotype tự làm: luật hoá 6 nhóm từ giờ ngủ, thời lượng, số lần thức trong 7 đêm (**tự thiết kế**) | ≥7 đêm | 1 |
| 8 | Chia sẻ người thân, Health Connect (thứ Mi Fitness quốc tế không có) | – | Backend / Android API |

---

## 12. Những điểm chưa chắc

- Người dùng thấy "báo cáo AI" ở bản nào và màn nào: cần ảnh chụp. Bản 9.8.348 quốc tế không có LLM health report.
- Thứ tự 4 lớp đầu ra của `mi_stage_model_0_1_1.tflite`.
- Công thức điểm ngủ (native, đóng).
- Thuật toán phân loại con vật ngủ (server).
- Ánh xạ con vật với đặc điểm giấc ngủ chỉ suy từ mô tả.
- Các hàm dịch ngược hỏng: `ifLightDeepSleepAbnormal` (một phần), `SleepAnalyzeHelper.build{TotalDuration,BedTime,SleepRegular}AnalyzeItem`,
  `CurseManager.initInterval`.
- Ý nghĩa các số loại gói protobuf (§9) suy từ cách dùng.
- Định dạng phản hồi `/zh/health` của AFlash (khoá JSON bị làm rối, app không gọi).
- Nội dung trang báo cáo tuần (H5 phía server).
