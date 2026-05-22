#!/usr/bin/env bash
set -uo pipefail

# Ensure standard binary locations are on PATH (cron uses a minimal PATH).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "error: .env not found at $ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

for cmd in curl jq awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: required command not found: $cmd" >&2
        exit 1
    fi
done

for var in BALANCE_THRESHOLD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
    if [ -z "${!var:-}" ]; then
        echo "error: $var is not set in .env" >&2
        exit 1
    fi
done

if ! awk -v t="$BALANCE_THRESHOLD" 'BEGIN{exit !(t+0==t && t>=0)}' 2>/dev/null; then
    echo "error: BALANCE_THRESHOLD is not a valid non-negative number: '$BALANCE_THRESHOLD'" >&2
    exit 1
fi

mask_key() {
    local k="$1"
    if [ "${#k}" -lt 12 ]; then
        echo "***"
    else
        echo "${k:0:6}...${k: -4}"
    fi
}

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

send_tg() {
    local text="$1"
    local payload resp ok
    if ! payload=$(jq -n \
        --arg chat "$TELEGRAM_CHAT_ID" \
        --arg text "$text" \
        '{chat_id:$chat, text:$text, parse_mode:"HTML"}' 2>/dev/null); then
        echo "warning: failed to build telegram payload" >&2
        return 1
    fi
    if ! resp=$(curl -sS --max-time 15 \
        -H 'Content-Type: application/json' \
        -X POST -d "$payload" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>/dev/null); then
        echo "warning: telegram request failed (network or timeout)" >&2
        return 1
    fi
    ok=$(echo "$resp" | jq -r '.ok' 2>/dev/null || echo "")
    if [ "$ok" != "true" ]; then
        local desc
        desc=$(echo "$resp" | jq -r '.description // "no description"' 2>/dev/null || echo "unparseable response")
        echo "warning: telegram API returned not-ok: $desc" >&2
        return 1
    fi
    return 0
}

check_key() {
    local key="$1"
    local masked
    masked=$(mask_key "$key")

    local resp
    if ! resp=$(curl -sS --max-time 15 \
        -H 'Content-Type: application/json' \
        -X POST -d "{\"clientKey\":\"$key\"}" \
        https://api.anti-captcha.com/getBalance 2>/dev/null); then
        echo "warning: anti-captcha request failed for $masked (network or timeout)" >&2
        return 0
    fi

    if [ -z "$resp" ]; then
        echo "warning: empty response from anti-captcha for $masked" >&2
        return 0
    fi

    local err_id
    err_id=$(echo "$resp" | jq -r '.errorId' 2>/dev/null || echo "")
    if [ -z "$err_id" ] || [ "$err_id" = "null" ]; then
        echo "warning: unparseable response from anti-captcha for $masked: $resp" >&2
        return 0
    fi

    if [ "$err_id" != "0" ]; then
        local code desc
        code=$(echo "$resp" | jq -r '.errorCode // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
        desc=$(echo "$resp" | jq -r '.errorDescription // ""' 2>/dev/null || echo "")
        local msg
        msg=$(printf '%s\n\nKey: <code>%s</code>\nCode: %s\nDescription: %s' \
            "❌ <b>Anti-Captcha balance check failed</b>" \
            "$(html_escape "$masked")" \
            "$(html_escape "$code")" \
            "$(html_escape "$desc")")
        send_tg "$msg" || echo "warning: failed to deliver error notification for $masked" >&2
        return 0
    fi

    local balance
    balance=$(echo "$resp" | jq -r '.balance' 2>/dev/null || echo "")
    if [ -z "$balance" ] || [ "$balance" = "null" ]; then
        echo "warning: missing balance in response for $masked: $resp" >&2
        return 0
    fi
    if ! awk -v b="$balance" 'BEGIN{exit !(b+0==b)}' 2>/dev/null; then
        echo "warning: non-numeric balance for $masked: '$balance'" >&2
        return 0
    fi

    if awk -v b="$balance" -v t="$BALANCE_THRESHOLD" 'BEGIN{exit !(b<t)}'; then
        local msg
        msg=$(printf '%s\n\nKey: <code>%s</code>\nBalance: <b>$%.2f</b>\nThreshold: $%.2f' \
            "⚠️ <b>Anti-Captcha low balance</b>" \
            "$(html_escape "$masked")" \
            "$balance" \
            "$BALANCE_THRESHOLD")
        send_tg "$msg" || echo "warning: failed to deliver low-balance notification for $masked" >&2
    fi
    return 0
}

KEY_FOUND=0
i=1
while true; do
    var="KEY$i"
    key="${!var:-}"
    [ -z "$key" ] && break
    KEY_FOUND=1
    check_key "$key" || true
    i=$((i+1))
done

if [ "$KEY_FOUND" = "0" ]; then
    echo "error: no KEY<N> variables defined in .env (expected at least KEY1)" >&2
    exit 1
fi
