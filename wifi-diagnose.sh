#!/bin/bash
# Wi-Fi диагностика за macOS.
# Употреба:  bash wifi-diagnose.sh
# Резултатът се записва в ~/Desktop/wifi-report.txt

REPORT="$HOME/Desktop/wifi-report.txt"
exec > >(tee "$REPORT") 2>&1

section() { printf '\n========== %s ==========\n' "$1"; }

echo "Wi-Fi диагностика — $(date)"
echo "macOS $(sw_vers -productVersion) ($(uname -m))"

# --- Wi-Fi интерфейс ---
WIFI_IF=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
WIFI_IF=${WIFI_IF:-en0}
echo "Wi-Fi интерфейс: $WIFI_IF"

# --- Текуща връзка ---
section "Текуща Wi-Fi връзка"
SP=$(system_profiler SPAirPortDataType 2>/dev/null)
CURRENT=$(echo "$SP" | awk '/Current Network Information:/{f=1; next} f && /Other Local Wi-Fi Networks:/{exit} f')
echo "$CURRENT" | grep -E 'PHY Mode|Channel|Country|Network Type|Security|Signal / Noise|Transmit Rate|MCS Index' | sed 's/^ *//'

SIGNAL=$(echo "$CURRENT" | awk -F'[:/]' '/Signal \/ Noise/{gsub(/[^0-9-]/,"",$3); print $3; exit}')
NOISE=$(echo "$CURRENT"  | awk -F'[:/]' '/Signal \/ Noise/{gsub(/[^0-9-]/,"",$4); print $4; exit}')
CHANNEL_LINE=$(echo "$CURRENT" | awk -F': ' '/Channel:/{print $2; exit}')
CHANNEL=$(echo "$CHANNEL_LINE" | awk '{print $1}')
PHY=$(echo "$CURRENT" | awk -F': ' '/PHY Mode:/{print $2; exit}')
TXRATE=$(echo "$CURRENT" | awk -F': ' '/Transmit Rate:/{print $2; exit}')

# --- Съседни мрежи ---
section "Съседни мрежи"
OTHERS=$(echo "$SP" | awk '/Other Local Wi-Fi Networks:/{f=1; next} f')
echo "$OTHERS" | grep -E 'Channel:' | sed 's/^ *Channel: //' | sort | uniq -c | sort -rn | \
  awk '{c=$1; $1=""; printf "  %2d мрежи на канал%s\n", c, $0}'
SAME_CH=0
if [ -n "$CHANNEL" ]; then
  SAME_CH=$(echo "$OTHERS" | grep -E "Channel: $CHANNEL( |$)" | wc -l | tr -d ' ')
  echo "Мрежи на твоя канал ($CHANNEL): $SAME_CH"
fi

# --- Рутер и DNS ---
section "Рутер и DNS"
GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
echo "Рутер (gateway): ${GATEWAY:-неизвестен}"
echo "DNS сървъри:"; scutil --dns | awk '/nameserver\[/{print "  " $3}' | sort -u

# --- Ping ---
ping_test() {
  local host=$1 label=$2 out loss avg jitter
  out=$(ping -c 30 -i 0.2 -q "$host" 2>&1)
  loss=$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}')
  avg=$(echo "$out" | awk -F'/' '/round-trip/{print $5}')
  jitter=$(echo "$out" | awk -F'/' '/round-trip/{print $7}' | awk '{print $1}')
  printf '%-22s загуба: %-7s средно: %-8s ms  разсейване: %s ms\n' "$label" "${loss:-?}" "${avg:-?}" "${jitter:-?}"
  eval "${3}_LOSS=\${loss%\%}; ${3}_AVG=\${avg%.*}; ${3}_JIT=\${jitter%.*}"
}
section "Ping (30 пакета)"
[ -n "$GATEWAY" ] && ping_test "$GATEWAY" "Към рутера" GW
ping_test 1.1.1.1 "Към интернет (1.1.1.1)" NET

# --- DNS скорост ---
section "DNS"
for d in google.com wikipedia.org abv.bg; do
  t=$(dig +tries=1 +time=3 "$d" 2>/dev/null | awk '/Query time:/{print $4}')
  echo "  $d: ${t:-неуспех} ms"
done

# --- Скорост ---
section "Скорост (networkQuality, ~20 сек)"
if command -v networkQuality >/dev/null; then
  networkQuality -s 2>&1 | grep -vE '^\s*$'
else
  echo "networkQuality не е наличен (нужна е macOS 12+)."
fi

# --- Изводи ---
section "ИЗВОДИ"
ISSUES=0
flag() { ISSUES=$((ISSUES+1)); echo "⚠️  $1"; }

if [ -n "$SIGNAL" ]; then
  if   [ "$SIGNAL" -lt -75 ]; then flag "Много слаб сигнал ($SIGNAL dBm). Приближи се до рутера или помисли за mesh/репийтър."
  elif [ "$SIGNAL" -lt -67 ]; then flag "Среден сигнал ($SIGNAL dBm). Стени/разстояние вероятно намаляват скоростта."
  else echo "✅ Сигналът е добър ($SIGNAL dBm)."; fi
  if [ -n "$NOISE" ]; then
    SNR=$((SIGNAL - NOISE))
    [ "$SNR" -lt 25 ] && flag "Нисък сигнал/шум (SNR $SNR dB) — смущения от други устройства или мрежи."
  fi
fi

case "$CHANNEL_LINE" in
  *2GHz*|*2.4*) flag "Свързан си на 2.4 GHz (канал $CHANNEL). Ако рутерът поддържа 5 GHz, ползвай него — по-бързо и по-малко претоварено." ;;
esac
[ "${SAME_CH:-0}" -ge 4 ] && flag "$SAME_CH съседни мрежи са на същия канал $CHANNEL. Смени канала в настройките на рутера."
case "$PHY" in *802.11n*|*802.11g*|*802.11b*|*802.11a\ *) flag "Стар Wi-Fi стандарт ($PHY). Рутерът или настройките му ограничават скоростта." ;; esac
case "$TXRATE" in ''|*[!0-9]*) ;; *) [ "$TXRATE" -lt 100 ] && flag "Ниска скорост на връзката с рутера ($TXRATE Mbps)." ;; esac

if [ -n "$GW_AVG" ]; then
  if [ "${GW_LOSS%.*}" -gt 1 ] 2>/dev/null || [ "$GW_AVG" -gt 20 ] 2>/dev/null || [ "${GW_JIT:-0}" -gt 15 ] 2>/dev/null; then
    flag "Връзката до рутера е нестабилна (загуба ${GW_LOSS}%, ~${GW_AVG} ms). Проблемът е в Wi-Fi частта, не в доставчика."
  else
    echo "✅ Връзката до рутера е стабилна."
    if [ "${NET_LOSS%.*}" -gt 1 ] 2>/dev/null || [ "${NET_AVG:-0}" -gt 80 ] 2>/dev/null; then
      flag "Wi-Fi е наред, но интернетът след рутера е бавен/губи пакети — вероятно е при доставчика."
    fi
  fi
fi

[ "$ISSUES" -eq 0 ] && echo "Не открих очевиден проблем. Сравни скоростта с договорената с доставчика."
echo
echo "Отчетът е записан в: $REPORT"
