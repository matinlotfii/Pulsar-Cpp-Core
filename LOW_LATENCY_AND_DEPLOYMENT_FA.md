# تغییرات کم‌تأخیر و استقرار Pulsar

این نسخه برای سیستم هدف زیر تنظیم شده است:

- Ubuntu 22.04
- Intel Core i7-10700K
- NVIDIA RTX 3080 10GB
- دو دوربین DAHENG MER2-1220-32U3C / IMX226
- مقصد اجرا: `matin@192.168.1.123:/home/matin/Pulsar-Cpp-Core`
- GitHub: `ssh://git@ssh.github.com:443/matinlotfii/Pulsar-Cpp-Core.git`

## اصلاحات اصلی

- پروفایل قدیمی ۱۲ مگاپیکسلی به‌صورت پیش‌فرض غیرفعال شده است.
- ROI واقعی دوربین روی حداکثر `1920x1080` تنظیم می‌شود؛ resize بعد از انتقال USB جای ROI سنسور را نمی‌گیرد.
- نرخ هدف 60fps و Exposure پیش‌فرض 12ms است و Exposure از بودجه زمانی فریم بیشتر نمی‌شود.
- صف دریافت دوربین روی `NewestOnly` یا نزدیک‌ترین حالت قابل‌پشتیبانی تنظیم می‌شود.
- تعداد بافرهای acquisition به 3 کاهش یافته است تا صف قدیمی ساخته نشود.
- CUDA برای هر دوربین به‌صورت پیش‌فرض فعال است و خروجی page-locked مستقیماً در Frame نگه داشته می‌شود؛ کپی اضافه به `std::vector` حذف شده است.
- آپلود OpenGL با PBO دو‌بافره فعال است.
- VSync به‌صورت پیش‌فرض خاموش است.
- Stereo pairing روی `latest` است و برای جفت قدیمی تا 18ms منتظر نمی‌ماند.
- Renderer به‌جای busy-loop روی فریم جدید منتظر می‌ماند.
- کنترل‌های Camera، Snapshot و Recording در UI به API واقعی Backend متصل شده‌اند.
- فرمان ربات تا زمانی که mapping سخت‌افزار تعریف نشده، دیگر موفقیت جعلی نشان نمی‌دهد.
- `run.sh` فقط پس از build و smoke-test موفق، commit/tag/push و deploy انجام می‌دهد.

## پیش‌نیاز اولین اجرا

CUDA Toolkit 13.2 باید نصب و `nvcc` قابل‌دسترسی باشد:

```bash
nvcc --version
```

اگر نصب نیست و فایل local repository در Home وجود دارد:

```bash
cd ~
sudo dpkg -i ./cuda-repo-ubuntu2204-13-2-local_13.2.2-595.71.05-1_amd64.deb
KEY_FILE="$(sudo find /var/cuda-repo-ubuntu2204-13-2-local* -name 'cuda-*-keyring.gpg' -print -quit)"
sudo cp "$KEY_FILE" /usr/share/keyrings/
sudo apt update
sudo apt install -y cuda-toolkit-13-2

echo 'export CUDA_HOME=/usr/local/cuda-13.2' >> ~/.bashrc
echo 'export PATH="$CUDA_HOME/bin:$PATH"' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' >> ~/.bashrc
source ~/.bashrc
nvcc --version
```

بسته‌های `cuda` و `cuda-drivers` لازم نیستند؛ `run.sh` فقط Toolkit را لازم دارد و نباید درایور سالم NVIDIA را بی‌دلیل عوض کرد.

## SSH موردنیاز

باید هر دو اتصال بدون درخواست رمز کار کنند:

```bash
ssh -T -p 443 git@ssh.github.com
ssh matin@192.168.1.123 true
```

روی سیستم مقصد، کاربر `matin` باید برای نصب/restart سرویس مجوز `sudo -n` داشته باشد. بررسی:

```bash
ssh matin@192.168.1.123 'sudo -n true && echo sudo-ok'
```

## اجرای کامل

```bash
cd ~/Pulsar-Cpp-Core
chmod +x run.sh core/scripts/*.sh
./run.sh
```

ترتیب عملیات:

1. نصب dependencyهای گمشده
2. build رابط و C++ در حالت Release
3. smoke-test با دو دوربین Mock، API، JPEG، Snapshot و H.264
4. بررسی SSH مقصد
5. fetch و بررسی تاریخچه GitHub
6. commit و tag خودکار
7. ساخت backup محلی bundle و source archive
8. push اتمیک branch و tag
9. rsync به `192.168.1.123`
10. build روی مقصد
11. نصب سرویس در صورت نبودن و restart `pulsar-kiosk.service`

پیام commit اختیاری:

```bash
RUN_GIT_COMMIT_MESSAGE="Tune camera latency" ./run.sh
```

برای تست CPU بدون CUDA، فقط به‌صورت موقت:

```bash
RUN_REQUIRE_CUDA=0 ./run.sh build
```

این حالت برای اجرای اصلی توصیه نمی‌شود.

## اندازه‌گیری بعد از نصب

لاگ Renderer هر دو ثانیه این موارد را چاپ می‌کند:

- عمر فریم چپ و راست روی host
- skew دو دوربین
- زمان texture upload
- زمان present
- مسیر `gl-pbo` یا fallback SDL
- تعداد loopهایی که pair قدیمی نگه داشته شده است

```bash
./run.sh logs
```

## محدودیت مهم

هیچ زنجیره تصویری تأخیر صفر فیزیکی ندارد. این نسخه صف‌ها و کپی‌های غیرضروری مهم را حذف یا کاهش می‌دهد، اما تأخیر نهایی باید روی همان دو دوربین و XREAL با روش LED/photodiode یا دوربین پرسرعت اندازه‌گیری شود. همگام‌سازی فعلی شروع نرم‌افزاری است؛ برای استریوی exposure-level باید دو دوربین با Trigger سخت‌افزاری Master/Slave سیم‌کشی و تنظیم شوند.
