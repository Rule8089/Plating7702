#!/bin/bash
set -e

echo "🚀 Starting X-UI + nginx reverse proxy..."

# nginx همیشه روی پورت ثابت 3000 گوش می‌دهد
export NGINX_PORT=3000

cd /usr/local/x-ui

echo "ℹ️  x-ui version: $(./x-ui -v 2>/dev/null || echo unknown)"

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port 2053 -webBasePath /managepanel/ || true

# --- fail2ban برای قابلیت IP Limit ---
# پنل فقط وقتی کادر IP Limit را فعال می‌کند که fail2ban-client در دسترس باشد،
# وگرنه مقدار limitIp همه‌ی کلاینت‌ها را صفر می‌کند.
if [ "$XUI_ENABLE_FAIL2BAN" = "true" ]; then
    echo "🔧 Setting up fail2ban (3x-ipl jail)..."
    LOG_FOLDER="${XUI_LOG_FOLDER:-/var/log/x-ui}"
    mkdir -p "$LOG_FOLDER" /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d /var/run/fail2ban
    touch "$LOG_FOLDER/3xipl.log" "$LOG_FOLDER/3xipl-banned.log"

    cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=$LOG_FOLDER/3xipl.log
maxretry=1
findtime=32
bantime=30m
EOF

    cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # پورت پنل و nginx از بن معاف می‌شوند تا خودتان قفل بیرون نمانید
    cat > /etc/fail2ban/action.d/3x-ipl.conf << EOF
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $LOG_FOLDER/3xipl-banned.log

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> $LOG_FOLDER/3xipl-banned.log

[Init]
name = default
chain = INPUT
exemptports = 2053,3000
EOF

    # روی Railway معمولاً iptables اجازه ندارد؛ اگر استارت شکست خورد ادامه می‌دهیم
    # چون صرفِ در دسترس بودن fail2ban-client کادر IP Limit را فعال نگه می‌دارد.
    if fail2ban-client -x start 2>/dev/null; then
        echo "✅ fail2ban started (IP limit fully enforced)"
    else
        echo "⚠️  fail2ban could not start (no iptables permission on this host)."
        echo "   کادر IP Limit در پنل فعال می‌ماند و مقادیر ذخیره می‌شوند،"
        echo "   ولی بن کردن خودکار انجام نمی‌شود."
    fi
fi

echo "🔧 Building nginx.conf for fixed port: $NGINX_PORT"
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "▶️  Starting x-ui in background..."
./x-ui &
X_UI_PID=$!

# ناظر خودکار: هر اینباند جدیدی که بسازید را با trustedXForwardedFor تنظیم می‌کند
# تا IP واقعی کاربرها ثبت شود و لازم نباشد دستی ست کنید.
if [ "${XUI_AUTO_SOCKOPT:-true}" = "true" ]; then
    /auto-sockopt.sh &
fi

sleep 2

echo "▶️  Starting nginx in foreground on port $NGINX_PORT..."
nginx -t
exec nginx -g "daemon off;"
