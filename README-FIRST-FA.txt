Pulsar Observable Realtime V9
=============================

هدف این بسته:
- کیفیت کامل سنسور 4024x3036 برای مسیر اصلی دوربین
- خروجی مستقل و هم‌زمان برای مانیتور و عینک‌ها با یک Viewer چندپنله
- Preview سبک 512x288 / 10fps فقط برای UI
- انیمیشن‌های UI فعال با افکت‌های compositor-friendly
- پاک‌سازی کامل پروژه و تنظیمات قبلی در هر ./run.sh
- لاگ زنده و خلاصه‌ی خودکار گلوگاه روی کامپیوتر شخصی

اجرا:
  chmod +x run.sh core/scripts/*.sh
  ./run.sh

آخرین گزارش روی کامپیوتر شخصی:
  cat diagnostics/live/latest/SUMMARY.txt

لاگ کامل همان اجرا:
  tail -f diagnostics/live/latest/deploy.log

راهنمای فنی:
  OBSERVABLE_REALTIME_V9_FA.md
