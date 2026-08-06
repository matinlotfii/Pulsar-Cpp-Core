# نسخه کم‌تأخیر Pulsar

## اجرای معمول

روی کامپیوتر شخصی، داخل پوشه پروژه:

```bash
./run.sh
```

این فرمان روی کامپیوتر شخصی برنامه را Build یا اجرا نمی‌کند. ترتیب آن:

1. بررسی SSH، CUDA 13.2 و دسترسی محدود `sudo` روی کامپیوتر پروژه
2. ثبت تغییرات در Git و Push به GitHub
3. انتقال سورس به `matin@192.168.1.123:/home/matin/Pulsar-Cpp-Core`
4. Build رابط کاربری روی کامپیوتر پروژه
5. Build اجباری CUDA/NPP برای RTX 3080
6. Restart سرویس `pulsar-kiosk.service`
7. بررسی Health و آنلاین‌شدن هر دو دوربین

## راه‌اندازی یک‌باره sudo

فقط اگر preflight خطای sudo داد:

```bash
./run.sh setup-remote
```

رمز فقط توسط `sudo` روی کامپیوتر پروژه پرسیده می‌شود و داخل پروژه ذخیره نمی‌شود.

## تنظیمات تصویر

پروفایل‌های GalaxyView داخل `camera/profiles` نور، Exposure، رنگ و White Balance شناخته‌شده را حفظ می‌کنند. سپس مسیر متعادل کم‌تأخیر اعمال می‌شود:

- Average binning دو در دو
- ROI مرکزی 1920x1080
- دو بافر Acquisition و حالت NewestOnly
- حذف فریم‌های قدیمی
- CUDA/NPP، حافظه pinned و CUDA stream جدا برای هر دوربین
- VSync خاموش و Stereo pairing روی جدیدترین فریم

فایل `core/config/pulsar.local.env` روی کامپیوتر پروژه هنگام Sync حفظ می‌شود تا تنظیمات مخصوص همان دستگاه از بین نرود.
