# Pulsar Observable Realtime V9

این نسخه سه مشکل نسخه‌ی قبلی را هم‌زمان اصلاح می‌کند:

1. انیمیشن‌های UI دوباره فعال‌اند، اما فقط افکت‌های سبک مبتنی بر `transform` و
   `opacity` اجرا می‌شوند. Blur و transitionهای سنگین که باعث repaint گسترده
   می‌شدند غیرفعال شده‌اند.
2. مسیر نمایش مانیتور و عینک‌ها از حالت «یک fullscreen روی یک نمایشگر» به یک
   پنجره‌ی دقیق X11 با چند پنل مستقل تغییر کرده است. هر پنل مانیتور یا عینک
   همان textureهای GPU را دوباره استفاده می‌کند و کپی دوربین جدیدی ایجاد
   نمی‌شود.
3. `./run.sh` از شروع Deploy تا پایان تست واقعی، روی کامپیوتر شخصی لاگ زنده و
   خلاصه‌ی تشخیص گلوگاه ذخیره می‌کند.

## مسیرهای تصویر

### مسیر پزشکی مانیتور و عینک

```text
Galaxy SDK → newest frame → pinned staging → CUDA/NPP → RGB display frame
→ reusable OpenGL PBO → one multi-output X11 viewer → monitor/glass panels
```

Renderer فقط هنگام رسیدن فریم جدید یا تغییر تنظیمات دوباره Present می‌کند.
نمایش چندباره‌ی همان فریم حذف شده تا CPU/GPU و Chrome بی‌دلیل درگیر نشوند.

### مسیر Preview داخل UI

```text
latest frame → 512×288 → JPEG quality 42 → 10 fps maximum
→ latest-only HTTP → Web Worker decode → requestAnimationFrame Canvas
```

برای Preview هیچ صفی وجود ندارد. فریم decode‌شده‌ی قدیمی با رسیدن فریم جدید
بسته و دور انداخته می‌شود. تغییر React state نیز فقط هنگام تغییر وضعیت
Connecting/Live/Offline انجام می‌شود، نه برای هر فریم.

## لاگ سراسری کم‌سربار

در هر اجرای `./run.sh` این پوشه روی کامپیوتر شخصی ایجاد می‌شود:

```text
diagnostics/live/run-YYYYMMDD-HHMMSS/
```

فایل‌ها:

- `deploy.log`: تمام خروجی Git، پاک‌سازی، انتقال، Build و Restart.
- `runtime-live.log`: لاگ زنده‌ی Camera، CUDA، Renderer، UI، Chrome، GPU، CPU و
  وضعیت خروجی‌های XRandR.
- `SUMMARY.txt`: تشخیص خودکار مرحله‌ی کند.
- `systemwide/`: گزارش کم‌سربار تکمیلی که از کامپیوتر پروژه کپی می‌شود.

لینک `diagnostics/live/latest` همیشه به آخرین اجرا اشاره می‌کند. حداکثر ۸ اجرا
و مجموعاً ۲۵۰ مگابایت نگه‌داری می‌شود. لاگ‌های Runtime روی کامپیوتر پروژه نیز
در صورت عبور از ۲۴ مگابایت در همان inode به ۶ مگابایت آخر کاهش پیدا می‌کنند؛
بنابراین فایل باز Core خراب یا جدا نمی‌شود.

## اندازه‌گیری‌های موجود

- Camera acquisition FPS و dequeue wait
- raw staging copy
- CUDA H2D، Debayer، Resize، D2H و GPU total
- publish copy و host pipeline
- سن فریم هنگام Render و stereo skew
- texture upload، renderer prepare، render-copy، Present و loop total
- Preview resize/JPEG
- UI request، source age، worker decode، Canvas draw و dropped frames
- UI animation FPS، missed frames، long tasks و `/api/state` latency
- CPU پردازش‌های Core/Xorg/Chrome، GPU load، RAM و topology خروجی‌ها
- هندسه‌ی واقعی پنجره و نمونه‌برداری پیکسل هر پنل مانیتور/عینک

این اندازه‌گیری‌ها تجمیعی و با فاصله‌ی زمانی هستند. هیچ فریم خامی ذخیره نمی‌شود
و هیچ Log per-frame داخل مسیر پزشکی اضافه نشده است.

## پاک‌سازی هر Run

قبل از انتقال، Runtime و UI قدیمی متوقف می‌شوند و پروژه، Build، data، Browser
profile، local config، display routing، cacheهای Pulsar، Git mirror و کپی‌های
قدیمی Deploy پاک می‌شوند. Unit سرویس systemd حفظ می‌شود چون برای اجرای نسخه‌ی
جدید لازم است، اما تنظیمات قبلی پروژه Restore نمی‌شوند.

## محدودیت صداقت فنی

Build CPU و UI این بسته بررسی شده‌اند. CUDA 13.2، دوربین‌های واقعی و پیکسل‌های
عینک فقط هنگام اجرای بسته روی دستگاه `pulsar` قابل تأییدند. Verifier در صورت
ندیدن عینک، پنجره‌ی اشتباه یا پنل سیاه Deploy را Fail اعلام می‌کند.
