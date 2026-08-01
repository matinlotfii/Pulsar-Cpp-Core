# Pulsar C++ Core

نسخه‌ی تمیز و سبک پروژه برای اجرای مستقیم روی **Ubuntu Server** بدون GNOME و بدون هیچ سرویس Python.

## ساختار پروژه

فقط سه پوشه‌ی اصلی وجود دارد:

```text
core/      هسته‌ی C++، مدیریت وضعیت، منابع سیستم، اسکریپت اجرا و سرویس systemd
camera/    اتصال Galaxy SDK، دریافت دو دوربین، تبدیل تصویر، SBS، ضبط و Snapshot
ui/        Backend کاملاً C++ و Frontend ماژولار TSX/CSS به‌همراه خروجی آماده‌ی اجرا
```

فایل‌های ریشه فقط برای build و اجرا هستند: `CMakeLists.txt`، `run.sh` و همین راهنما.

## اجرای سریع

```bash
chmod +x run.sh
./run.sh
```

در اجرای اول، `run.sh` بسته‌های لازم را نصب، C++ را با حالت Release کامپایل و سرویس kiosk را راه‌اندازی می‌کند. برنامه هیچ رمز، صفحه‌ی ورود یا احراز هویت داخلی ندارد. فقط نصب بسته‌های Ubuntu ممکن است طبق تنظیمات سیستم از `sudo` استفاده کند.

در Ubuntu Desktop با X11، برنامه در همان نشست گرافیکی اجرا می‌شود. در Ubuntu Server بدون Desktop، یک نشست سبک `Xorg + Openbox` و سرویس `pulsar-kiosk.service` ساخته می‌شود.

## رفتار دو مانیتور

- کوچک‌ترین مانیتور: رابط تنظیمات لمسی در Chrome/Chromium kiosk
- مانیتور دوم/بزرگ‌تر: خروجی Native C++/SDL2 به‌صورت Side-by-Side
- در صورت هم‌اندازه بودن مانیتورها، دو خروجی جدا انتخاب می‌شوند.
- در حالت تک‌مانیتور، UI اجرا و خروجی Native SBS غیرفعال می‌شود تا پنجره‌ها روی هم نیفتند.

## دوربین‌های واقعی

حالت پیش‌فرض `real` است و Galaxy SDK داخل `camera/vendor/galaxy` قرار دارد. دوربین اول به Left و دوربین دوم به Right اختصاص داده می‌شود. برای جلوگیری از جابه‌جایی دوربین‌ها بعد از reboot، فایل زیر را بسازید:

```bash
cp core/config/pulsar.local.env.example core/config/pulsar.local.env
```

سپس شماره‌سریال‌ها را وارد کنید:

```bash
PULSAR_LEFT_CAMERA_SERIAL=SERIAL_LEFT
PULSAR_RIGHT_CAMERA_SERIAL=SERIAL_RIGHT
```

برای تست بدون سخت‌افزار:

```bash
PULSAR_CAMERA_MODE=mock PULSAR_HEADLESS=1 ./run.sh
```

## فایل‌های UI قابل ویرایش

هر بخش فایل TSX و CSS مستقل دارد:

```text
ui/frontend/src/pages/Home/
ui/frontend/src/pages/LeftCamera/
ui/frontend/src/pages/RightCamera/
ui/frontend/src/pages/Stereo3D/
ui/frontend/src/pages/DisplaySettings/
ui/frontend/src/pages/Recording/
ui/frontend/src/pages/RoboticArm/
ui/frontend/src/pages/Pedals/
ui/frontend/src/pages/System/
```

استایل مشترک در `ui/frontend/src/styles/global.css` است. بعد از تغییر UI:

```bash
./run.sh build-ui
./run.sh restart
```

`ui/dist` از قبل ساخته شده است؛ بنابراین اجرای عادی به Node.js وابسته نیست. TypeScript فقط هنگام rebuild رابط استفاده می‌شود.

## سینک لحظه‌ای روی Ubuntu Server

اگر می‌خواهید همین پوشه به‌صورت لحظه‌ای روی یک Ubuntu Server mirror شود، فایل زیر را بسازید:

```bash
cp core/config/dev-sync.env.example core/config/dev-sync.env
```

مقادیر `SYNC_REMOTE_*` را بررسی کنید و سپس:

```bash
./run.sh sync-bootstrap
./run.sh sync-start
```

- `sync-bootstrap` روی سرور مقصد پوشه‌ی پروژه را می‌سازد، آن را به یک repo قابل `git push` تبدیل می‌کند و `origin` محلی را تنظیم می‌کند.
- `sync-bootstrap` روی سرور مقصد یک repo `bare` جدا برای `git push` می‌سازد و `origin` محلی را به آن وصل می‌کند؛ mirror لحظه‌ای همچنان داخل `SYNC_REMOTE_DIR` انجام می‌شود.
- `sync-start` یک user service می‌سازد که تغییرات این پوشه را با `rsync` از طریق `ssh` روی سرور mirror می‌کند.
- برای توقف سرویس:

```bash
./run.sh sync-stop
```

تا وقتی SSH بدون پرسش رمز یا با کلید مجاز نشده باشد، bootstrap و sync اجرا نمی‌شوند.

## فرمان‌ها

```bash
./run.sh start           # نصب موردنیاز، build و اجرا
./run.sh test            # تست C++، UI، API، دوربین Mock، JPEG و تنظیمات
./run.sh status          # وضعیت build و Core
./run.sh logs            # لاگ زنده
./run.sh restart         # راه‌اندازی مجدد
./run.sh stop            # توقف
./run.sh clean           # حذف build و داده‌های runtime
```

## تنظیمات مهم

تنظیمات پیش‌فرض در `core/config/pulsar.env` است. تغییرات مخصوص هر دستگاه را فقط در `core/config/pulsar.local.env` قرار دهید؛ از جمله FPS، کیفیت JPEG، اندازه‌ی پردازش، شماره‌سریال دوربین و override نمایشگر.

برای touch، در صورت نیاز می‌توانید نام دستگاه را با `PULSAR_TOUCH_DEVICE_NAME` قفل کنید و برای ریزتنظیم auto-calibration از `PULSAR_TOUCH_INSET_LEFT/RIGHT/TOP/BOTTOM` استفاده کنید.

اگر touch اصلاً در X11 دیده نشود، فایل `core/data/touch.log` را بررسی کنید. اگر `lsusb` دستگاه را با شناسه‌ی `4348:55e0` نشان دهد، کنترلر WCH در حالت bootloader/ISP است و تا زمان restore شدن firmware، mapping و calibration نرم‌افزاری عمل نخواهند کرد.

## مسیر ضبط

ویدئوها و Snapshotها در `core/data/recordings/` ذخیره می‌شوند. ضبط با C++ مدیریت و تصویر خام SBS از طریق pipe مستقیم به FFmpeg داده می‌شود؛ Python یا سرور جداگانه‌ای در مسیر تصویر وجود ندارد.
