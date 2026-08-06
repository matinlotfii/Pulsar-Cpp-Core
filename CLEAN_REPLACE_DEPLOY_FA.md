# استقرار Clean Replace روی کامپیوتر Pulsar

اجرای پیش‌فرض `./run.sh` اکنون پس از Commit/Push موفق به GitHub، کامپیوتر پروژه را برای نسخه جدید کاملاً آماده می‌کند:

1. سرویس `pulsar-kiosk.service` متوقف می‌شود تا Xorg، رابط Kiosk، مرورگر و `pulsar-core` بسته شوند.
2. سرویس همگام‌سازی قدیمی کاربر (`pulsar-dev-sync.service`) متوقف، غیرفعال و حذف می‌شود.
3. پردازش‌های باقی‌مانده مخصوص مسیر پروژه قبلی Terminate و در صورت نیاز Kill می‌شوند.
4. پوشه قبلی `/home/matin/Pulsar-Cpp-Core`، Build، UI data، Browser profile و Git mirror قبلی پاک می‌شوند.
5. پوشه‌های rollback قدیمی با نام‌های `Pulsar-Cpp-Core.before-*` و مشابه پاک می‌شوند.
6. فقط Cache و فایل‌های موقت مخصوص Pulsar پاک می‌شوند؛ Cacheهای نامرتبط سیستم دست‌نخورده می‌مانند.
7. مقصد خالی ساخته می‌شود و سپس فقط پروژه جدید Sync می‌شود.
8. UI و C++/CUDA از پروژه جدید Build، سرویس Restart و سلامت API و هر دو دوربین بررسی می‌شود.

## اجرا

```bash
chmod +x run.sh
./run.sh
```

این حالت تخریبی است و نسخه قبلی روی کامپیوتر پروژه را نگه نمی‌دارد. Backup Git محلی و Push به GitHub قبل از حذف Remote انجام می‌شوند.

برای غیرفعال‌کردن موقت پاک‌سازی کامل:

```bash
RUN_REMOTE_PURGE_FIRST=0 ./run.sh
```

برای پاک‌سازی دستی بدون Deploy:

```bash
./run.sh purge-remote
```
