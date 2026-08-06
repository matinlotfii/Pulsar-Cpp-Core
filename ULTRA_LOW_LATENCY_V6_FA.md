# Pulsar Ultra Low Latency V6

این بسته برای رفع دقیق گلوگاه ثبت‌شده در گزارش `pulsar-global-profile-20260806-123111` ساخته شده است.

## علت کندی نسخه V5

مسیر `PULSAR_GPU_DIRECT_SDK_H2D=1` بافر Galaxy SDK را مستقیم به CUDA می‌فرستاد. بافر SDK حافظه page-locked نبود و انتقال H2D حدود ۱۳ تا ۱۴ میلی‌ثانیه طول می‌کشید. همان انتقال قبل از `GXQAllBufs` همگام می‌شد و چرخه دریافت را به حدود ۳۹ میلی‌ثانیه و نرخ واقعی را به حدود ۲۵ FPS محدود می‌کرد.

## اصلاح اعمال‌شده

- مسیر دوربین و CUDA از Commit آزمایش‌شده `dc2cee028974dfbd52b13bae5e8e5b2f5e77cbaa` بازگردانی شده است.
- بافر Galaxy ابتدا با یک `memcpy` کوتاه به حافظه page-locked منتقل می‌شود.
- بافر SDK بلافاصله به دوربین برگردانده می‌شود؛ سپس H2D، Debayer، Resize و D2H روی CUDA/NPP انجام می‌شوند.
- `PULSAR_GPU_DIRECT_SDK_H2D=0` اجباری است تا مسیر کند V5 دوباره فعال نشود.
- `NewestOnly`، دو Acquisition Buffer، PBO، حالت Stereo `latest` و VSync خاموش حفظ شده‌اند.
- پروفایل تصویری کامل 4024×3036، Exposure 30000µs و Gain صفر حفظ شده است.
- UI و Backend دست‌کاری نشده‌اند.

## کنترل کیفیت خودکار Deploy

بعد از Build و Restart، اسکریپت `verify-ultra-low-latency.sh` اجرا می‌شود. Deploy فقط وقتی موفق اعلام می‌شود که:

- هر دو دوربین Online باشند.
- Median FPS هر دو دوربین حداقل 29 باشد.
- `raw-copy-ms` و `gpu-h2d-ms` کمتر از 3ms باشند.
- سن فریم هنگام Render کمتر از 70ms باشد.
- فقط یک `pulsar-core` اجرا شود.

گزارش در `core/data/latency-reports` ذخیره می‌شود.

## لاگ سراسری کم‌هزینه

خود برنامه هر دو ثانیه فقط سه خط خلاصه می‌نویسد و داخل حلقه هر فریم Log ندارد. برای جمع‌آوری بیشتر بدون `perf` و بدون Restart:

```bash
./core/scripts/collect-latency-report.sh 30
```

## محدودیت همگام‌سازی

همگام‌سازی نرم‌افزاری شروع دو دوربین را نزدیک می‌کند، اما هم‌زمانی دقیق Exposure را تضمین نمی‌کند. برای Sync قطعی در سطح سنسور، Trigger سخت‌افزاری مشترک لازم است.
