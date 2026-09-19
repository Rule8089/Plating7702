#!/bin/bash
# ---------------------------------------------------------------------------
# auto-sockopt.sh
#
# پنل پشت nginx است، پس Xray فقط 127.0.0.1 را می‌بیند. برای اینکه IP واقعی
# کاربر ثبت شود، هر اینباند باید sockopt.trustedXForwardedFor داشته باشد.
#
# این اسکریپت دیتابیس را می‌پاید و هر اینباند جدیدی که بدون این تنظیم ساخته
# شود را خودکار اصلاح می‌کند، تا لازم نباشد دستی ست کنید.
#
# فقط اینباندهای ws / xhttp / httpupgrade را دست می‌زند (همان‌هایی که از
# nginx عبور می‌کنند). بقیه دست‌نخورده می‌مانند.
# ---------------------------------------------------------------------------
set -u

DB="${XUI_DB_FOLDER:-/etc/x-ui}/x-ui.db"
TRUSTED="${XUI_TRUSTED_XFF:-127.0.0.1}"
INTERVAL="${XUI_SOCKOPT_INTERVAL:-20}"

echo "🔧 auto-sockopt: watching $DB (trustedXForwardedFor=$TRUSTED, every ${INTERVAL}s)"

# صبر تا ساخته شدن دیتابیس در اولین اجرا
for _ in $(seq 1 60); do
    [ -f "$DB" ] && break
    sleep 2
done
[ -f "$DB" ] || { echo "⚠️  auto-sockopt: database not found, exiting"; exit 0; }

fix_once() {
    # اینباندهایی که transport شان از nginx رد می‌شود ولی trustedXForwardedFor ندارند
    local rows
    rows=$(sqlite3 "$DB" "
        SELECT id FROM inbounds
        WHERE json_valid(stream_settings)
          AND json_extract(stream_settings, '\$.network') IN ('ws','xhttp','httpupgrade')
          AND (
                json_extract(stream_settings, '\$.sockopt.trustedXForwardedFor') IS NULL
             OR json_array_length(json_extract(stream_settings, '\$.sockopt.trustedXForwardedFor')) = 0
          );
    " 2>/dev/null)

    [ -z "$rows" ] && return 1

    local changed=0
    for id in $rows; do
        sqlite3 "$DB" "
            UPDATE inbounds
            SET stream_settings = json_set(
                    stream_settings,
                    '\$.sockopt.trustedXForwardedFor',
                    json_array('$TRUSTED')
                )
            WHERE id = $id;
        " 2>/dev/null && {
            echo "✅ auto-sockopt: applied trustedXForwardedFor to inbound id=$id"
            changed=1
        }
    done
    return $((1 - changed))
}

while true; do
    if fix_once; then
        # چیزی عوض شد → به Xray بگو کانفیگ را دوباره بخواند
        pkill -SIGHUP -f '/usr/local/x-ui/x-ui' 2>/dev/null || true
    fi
    sleep "$INTERVAL"
done
