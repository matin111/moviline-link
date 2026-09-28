# Moviline Link v1.0.0

Moviline Link یک تونل لایه ۳ بین سرور ایران و خارج است. هدف این نسخه این است که ترافیک IP کاربران VPN بعد از terminate شدن روی سرور ایران، مستقل از پروتکل کاربر، از سرور خارج NAT شود.

هسته بر پایه GOST v3.3.0 و TUN است:

- Primary: TUN روی UDP/443
- Backup: TUN over Relay + WSS روی TCP/443
- دو interface مستقل: `mlp0` و `mlb0`
- Policy Routing فقط برای subnetهایی که خودتان مشخص می‌کنید
- Watchdog و failover خودکار
- مسیر مدیریت و SSH سرور ایران تغییر نمی‌کند
- X-UI، UUIDها و دیتابیس کاربران دست‌کاری نمی‌شوند

## پروتکل‌های کاربر

چون انتقال در لایه IP انجام می‌شود، ترافیک TCP/UDP/ICMP عبور می‌کند. در معماری استاندارد v1، سرویس‌های client-facing روی ایران terminate می‌شوند؛ بنابراین Cisco/OpenConnect، OpenVPN TCP/UDP و L2TP/IPsec می‌توانند ترافیک کاربران خود را از این تونل route کنند. Xray/V2Ray فعلی نیز می‌تواند تا زمان مهاجرت روی مسیر HAProxy موجود باقی بماند.

> Moviline Link جایگزین خود Cisco/OpenVPN/L2TP/Xray نیست؛ مسیر بین ایران و Exit است.

## نصب آزمایشی امن

ابتدا `--routes` را خالی بگذارید تا هیچ ترافیک production وارد تونل نشود. بعد از اینکه `moviline-link test` هر دو peer را سالم نشان داد، subnetهای واقعی کاربران را اضافه کنید.

### خارج

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/matin111/moviline-link/v1.0.0/install.sh) exit \
  --domain sub1.in88.sbs \
  --cert /root/cert/sub1.in88.sbs/fullchain.pem \
  --key /root/cert/sub1.in88.sbs/privkey.pem
```

در پایان `Shared secret` نمایش داده می‌شود.

### ایران

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/matin111/moviline-link/v1.0.0/install.sh) iran \
  --exit-ip 92.119.166.113 \
  --domain sub1.in88.sbs \
  --secret YOUR_SHARED_SECRET
```

## وضعیت و تست

```bash
moviline-link status
moviline-link test
moviline-link doctor
moviline-link logs
```

## انتخاب مسیر

```bash
moviline-link auto
moviline-link primary
moviline-link backup
```

حالت `auto` ابتدا Primary را استفاده می‌کند. اگر Primary از دسترس خارج شود Backup فعال می‌شود. برای جلوگیری از flap، بازگشت از Backup به Primary بعد از چند health check موفق انجام می‌شود.

## فعال‌کردن subnetهای کاربران

نمونه:

```text
OpenVPN: 10.8.0.0/24
Cisco:   10.9.0.0/24
L2TP:    10.10.0.0/24
```

هنگام نصب/آپدیت:

```bash
--routes 10.8.0.0/24,10.9.0.0/24,10.10.0.0/24
```

Subnetها را حدس نزنید. قبل از فعال‌سازی production با `ip addr`, `ip route` و تنظیمات سرویس VPN مقدار واقعی را مشخص کنید.

## پورت‌ها

روی Exit، UDP/443 برای Primary و TCP/443 برای Backup استفاده می‌شود. TCP و UDP می‌توانند شماره پورت یکسان داشته باشند. اگر روی Exit از قبل سرویسی روی TCP/443 گوش می‌دهد، قبل از نصب Backup باید پورت دیگری انتخاب شود، مثلاً:

```bash
--backup-port 9443
```

و همین مقدار روی هر دو سمت یکسان باشد.

## فایل‌ها

```text
/etc/moviline-link/config.env
/etc/moviline-link/primary.yml
/etc/moviline-link/backup.yml
/usr/local/lib/moviline-link/
/usr/local/sbin/moviline-link
```

## Update / Uninstall

```bash
moviline-link update v1.0.0
moviline-link uninstall
```

## نکته برای Xray فعلی

مسیر فعلی HAProxy ایران → Xray خارج را در زمان تست تغییر ندهید. بعد از پایدار شدن TUN، در صورت نیاز backend می‌تواند به IP تونل Exit (`10.250.0.1`) منتقل شود؛ این تغییر باید جداگانه و با تست live انجام شود.
