نسخه Pulsar Full-Sensor Realtime V3

اجرا روی کامپیوتر شخصی:
  chmod +x run.sh
  ./run.sh

رفتار ./run.sh:
  1) هیچ Build محلی انجام نمی‌دهد.
  2) تغییرات را Commit و به GitHub Push می‌کند.
  3) سورس را به matin@192.168.1.123:/home/matin/Pulsar-Cpp-Core می‌فرستد.
  4) روی کامپیوتر پروژه Build تمیز CUDA 13.2 انجام می‌دهد.
  5) pulsar-kiosk.service را Restart می‌کند.
  6) Health و آنلاین بودن هر دو دوربین را بررسی می‌کند.

پروفایل تصویر:
  سنسور کامل 4024x3036 / BayerRG8 / Exposure=30000 / Gain=0
  خروجی CUDA برای نمایشگر و عینک: حداکثر 1920x1080

این تفاوت مهم است: ابعاد 1920x1080 کیفیت دریافت سنسور را کم نمی‌کند؛
Debayer و Resize بعد از دریافت کامل سنسور روی RTX 3080 انجام می‌شود تا انتقال D2H
و Upload یک RGB کامل 36MB باعث تأخیر نشود.

برای بررسی بعد از اجرا:
  ssh matin@192.168.1.123 'cd /home/matin/Pulsar-Cpp-Core && DISPLAY=:0 ./core/scripts/realtime-20s-diagnose.sh 20'
