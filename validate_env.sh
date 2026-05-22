#!/usr/bin/env bash
set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

FAIL_COUNT=0
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ .env not found at $ENV_FILE"
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

for cmd in curl jq awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ required command not found: $cmd"
        exit 1
    fi
done

# 1. Required vars present
for var in BALANCE_THRESHOLD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
    if [ -z "${!var:-}" ]; then
        fail "$var is not set in .env"
    else
        ok "$var is set"
    fi
done

# 2. Threshold is a positive number
if [ -n "${BALANCE_THRESHOLD:-}" ]; then
    if awk -v t="$BALANCE_THRESHOLD" 'BEGIN{exit !(t+0==t && t>0)}' 2>/dev/null; then
        ok "BALANCE_THRESHOLD is a valid positive number: \$$BALANCE_THRESHOLD"
    else
        fail "BALANCE_THRESHOLD is not a valid positive number: '$BALANCE_THRESHOLD'"
    fi
fi

# 3. Telegram token via getMe
TG_TOKEN_OK=0
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    resp=$(curl -sS --max-time 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || true)
    if [ -z "$resp" ]; then
        fail "Telegram getMe: no response (network error)"
    else
        ok_field=$(echo "$resp" | jq -r '.ok' 2>/dev/null || echo "")
        if [ "$ok_field" = "true" ]; then
            username=$(echo "$resp" | jq -r '.result.username // "<unknown>"' 2>/dev/null || echo "<unknown>")
            ok "Telegram bot OK: @$username"
            TG_TOKEN_OK=1
        elif [ "$ok_field" = "false" ]; then
            desc=$(echo "$resp" | jq -r '.description // "unknown error"' 2>/dev/null || echo "unknown error")
            fail "Telegram bot token rejected: $desc"
        else
            fail "Telegram getMe: unparseable response: $resp"
        fi
    fi
fi

# 4. Telegram chat via sendMessage (test message)
if [ "$TG_TOKEN_OK" = "1" ]; then
    if [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        host=$(hostname 2>/dev/null || echo "unknown-host")
        ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        text="✅ tg-balance-notifications: test message from validate_env.sh (${host} ${ts})"
        payload=$(jq -n \
            --arg chat "$TELEGRAM_CHAT_ID" \
            --arg text "$text" \
            '{chat_id:$chat, text:$text}' 2>/dev/null || echo "")
        if [ -z "$payload" ]; then
            fail "Telegram sendMessage: failed to build payload"
        else
            resp=$(curl -sS --max-time 15 \
                -H 'Content-Type: application/json' \
                -X POST -d "$payload" \
                "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>/dev/null || true)
            if [ -z "$resp" ]; then
                fail "Telegram sendMessage: no response (network error)"
            else
                ok_field=$(echo "$resp" | jq -r '.ok' 2>/dev/null || echo "")
                if [ "$ok_field" = "true" ]; then
                    ok "Test message sent to chat $TELEGRAM_CHAT_ID"
                elif [ "$ok_field" = "false" ]; then
                    desc=$(echo "$resp" | jq -r '.description // "unknown error"' 2>/dev/null || echo "unknown error")
                    fail "Telegram sendMessage rejected: $desc (is the bot a member of the chat?)"
                else
                    fail "Telegram sendMessage: unparseable response: $resp"
                fi
            fi
        fi
    fi
else
    fail "Skipping chat check (Telegram token is invalid or missing)"
fi

# 5. Anti-Captcha keys
mask_key() {
    local k="$1"
    if [ "${#k}" -lt 12 ]; then
        echo "***"
    else
        echo "${k:0:6}...${k: -4}"
    fi
}

KEY_FOUND=0
i=1
while true; do
    var="KEY$i"
    key="${!var:-}"
    [ -z "$key" ] && break
    KEY_FOUND=1
    masked=$(mask_key "$key")
    resp=$(curl -sS --max-time 15 \
        -H 'Content-Type: application/json' \
        -X POST -d "{\"clientKey\":\"$key\"}" \
        https://api.anti-captcha.com/getBalance 2>/dev/null || true)
    if [ -z "$resp" ]; then
        fail "$var ($masked): no response (network error)"
    else
        err_id=$(echo "$resp" | jq -r '.errorId' 2>/dev/null || echo "")
        if [ "$err_id" = "0" ]; then
            balance=$(echo "$resp" | jq -r '.balance' 2>/dev/null || echo "")
            if [ -z "$balance" ] || [ "$balance" = "null" ]; then
                fail "$var ($masked): missing balance in response"
            else
                ok "$(printf '%s (%s): balance $%.2f' "$var" "$masked" "$balance")"
            fi
        elif [ -n "$err_id" ] && [ "$err_id" != "null" ]; then
            code=$(echo "$resp" | jq -r '.errorCode // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
            desc=$(echo "$resp" | jq -r '.errorDescription // ""' 2>/dev/null || echo "")
            fail "$var ($masked): $code — $desc"
        else
            fail "$var ($masked): unparseable response: $resp"
        fi
    fi
    i=$((i+1))
done

if [ "$KEY_FOUND" = "0" ]; then
    fail "No KEY<N> variables defined in .env (expected at least KEY1)"
fi

echo
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "All checks passed"
    exit 0
else
    echo "$FAIL_COUNT check(s) failed"
    exit 1
fi
