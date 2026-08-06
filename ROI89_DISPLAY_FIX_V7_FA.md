# Pulsar ROI89 + Display Settings Fix V7

این نسخه دو مشکل را جداگانه اصلاح می‌کند:

1. اسکریپت کامل مدیریت نمایشگرها و Display Routing بازگردانی شده است. انتخاب‌های UI در
   `core/data/display-routing.env` ذخیره می‌شوند، توسط `configure-displays.sh` محترم شمرده
   می‌شوند و هنگام Clean Replace از بین نمی‌روند.
2. دوربین‌ها پس از Import شدن Profile رنگ، فقط از نظر Geometry و Timing روی ROI مرکزی
   `1920x1080`، نرخ هدف `89 fps` و Exposure برابر `9000 us` قرار می‌گیرند.

## مسیر دوربین

- BayerRG8
- ROI مرکزی 1920x1080
- Target FPS: 89
- Exposure: 9000 us
- Gain و Color Calibration از Profile موجود حفظ می‌شود
- Pinned host staging و CUDA/NPP فعال
- NewestOnly و دو Acquisition Buffer
- VSync خاموش و OpenGL PBO فعال
- Software parallel start برای نزدیک کردن فاز شروع دو دوربین

## نکته فیزیکی Sync

Software start، نرخ و شروع دو دوربین را نزدیک می‌کند؛ هم‌زمانی قطعی لحظه Exposure فقط با
Trigger سخت‌افزاری مشترک ممکن است. در 89 fps زمان هر فریم حدود 11.24 ms است، بنابراین
حتی بدون Trigger سخت‌افزاری، skew نرم‌افزاری باید بسیار کمتر از مسیر 25 fps قبلی باشد.

## راستی‌آزمایی

پس از Deploy، `core/scripts/verify-roi89-display.sh` اجرا می‌شود و موارد زیر را می‌سنجد:

- آنلاین بودن هر دو دوربین
- ROI واقعی 1920x1080 در API و لاگ دستگاه
- Median FPS هر دوربین، پیش‌فرض حداقل 84
- اختلاف FPS دو دوربین
- سن فریم، Stereo skew، Raw Copy، H2D و Texture Upload
- وجود نسخه کامل Display Settings script و فایل Display Routing

گزارش در `core/data/latency-reports/` ذخیره می‌شود. موفقیت Build به معنی تأیید 89 fps
روی سخت‌افزار نیست؛ نتیجه نهایی را فقط گزارش همین راستی‌آزمایی روی کامپیوتر پروژه تعیین می‌کند.
