<!-- Keep README.md and README.ru.md in sync when editing. -->

[English](README.md) | [Русский](README.ru.md)

# tg-balance-notifications

Bash-based cron job that polls one or more Anti-Captcha API keys, compares each balance against a shared threshold, and sends a Telegram alert when a key falls below it.

One instance of this repo serves one client. A client may own one or several Anti-Captcha API keys; all of them share the same balance threshold and notify the same Telegram chat.

## Prerequisites

- `bash` 4+
- `curl`
- `jq`
- Repo cloned to the host that will run the cron

## Set up the Telegram bot

### Create the bot

1. Open Telegram, start a chat with [@BotFather](https://t.me/BotFather).
2. Send `/newbot`.
3. Choose a display name (any), then a username ending in `bot` (e.g. `myteam_balance_bot`).
4. BotFather replies with the token — a string like `8037205173:AAGAn...` — this is `TELEGRAM_BOT_TOKEN`. Keep it secret.

### Find the chat ID

Alerts can go either to your personal DM with the bot, or to a group. In both cases the simplest way is to ask a public bot whose only job is to print IDs.

**Personal DM**

1. In Telegram, start a chat with [@userinfobot](https://t.me/userinfobot) and send `/start`.
2. It instantly replies with your numeric user ID — that is your `TELEGRAM_CHAT_ID`.
3. Also press **Start** on your own bot once (search by its `@username`) — otherwise it can't DM you.

**Group chat**

1. Add your bot to the group (Group → group settings → **Add Members** → search by `@username`). No admin rights needed.
2. Add [@getidsbot](https://t.me/getidsbot) to the same group — it immediately posts the group's `Chat ID: -100…`.
3. Copy that negative number (**with the minus sign**) — that is your `TELEGRAM_CHAT_ID`.
4. Remove `@getidsbot` from the group.

> **Heads-up:** third-party ID bots see group messages while they're members — only add them to a chat whose content is fine to expose, and remove them right after grabbing the ID.
>
> **Gotcha:** if a basic group is later upgraded to a supergroup (often happens automatically), the chat ID changes — typically from a small negative number to one starting with `-100`. Re-run the lookup if alerts stop arriving.

## Configure `.env`

`.env` lives next to the scripts. It is **committed** to the repo with placeholder values; replace them with real ones.

### Fields

| Variable | Purpose |
| --- | --- |
| `BALANCE_THRESHOLD` | Threshold in USD. A key triggers an alert if its balance is strictly less than this. Applies to every key. |
| `TELEGRAM_BOT_TOKEN` | Bot token from BotFather, e.g. `123456:ABC-DEF...`. |
| `TELEGRAM_CHAT_ID` | Destination chat ID (positive integer for DM, negative — typically starts with `-100` — for groups). |
| `KEY1`, `KEY2`, ... | Anti-Captcha client keys. The script iterates `KEY1`, `KEY2`, ... and stops at the first unset (or commented-out) variable, so numbering must be contiguous from `KEY1`. |

### Example — client with a single key

```env
BALANCE_THRESHOLD=2.00

TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
TELEGRAM_CHAT_ID=-1001234567890

KEY1=11111111111111111111111111111111
# KEY2=22222222222222222222222222222222
# KEY3=33333333333333333333333333333333
# KEY4=44444444444444444444444444444444
```

Only `KEY1` is uncommented, so `check_balance.sh` polls one key per run.

### Example — client with four keys

```env
BALANCE_THRESHOLD=2.00

TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
TELEGRAM_CHAT_ID=-1001234567890

KEY1=11111111111111111111111111111111
KEY2=22222222222222222222222222222222
KEY3=33333333333333333333333333333333
KEY4=44444444444444444444444444444444
```

All four keys are uncommented; the script processes them sequentially. Need more than four? Just add `KEY5=...`, `KEY6=...`.

## Validate and run

### Validate the configuration

```sh
./validate_env.sh
```

Performs, in order:

1. Required variables are present.
2. `BALANCE_THRESHOLD` parses as a positive number.
3. `TELEGRAM_BOT_TOKEN` is accepted by `getMe`.
4. Sends a test message to `TELEGRAM_CHAT_ID` (also verifies the bot can post in that chat).
5. For each `KEY<N>`: calls Anti-Captcha `getBalance` and reports balance or error.

Each line is either `✅` or `❌`. Exit code is `0` only if every check passes.

### Run a balance check

```sh
./check_balance.sh
```

Silent on success (intended for cron). Sends a Telegram message per key only when:

- the balance is below `BALANCE_THRESHOLD`, or
- the Anti-Captcha API returns an error for that key.

Exits non-zero only on configuration or local errors (missing `.env`, missing required tool). Per-key network/API failures log a warning to stderr and continue with the remaining keys — they never abort the run.

### Schedule via cron

```cron
*/30 * * * * /path/to/tg-balance-notifications/check_balance.sh >> /var/log/tg-balance.log 2>&1
```

Pick a cadence that fits how fast the client burns balance — every 15–60 minutes is typical.

## Telegram message format

All Telegram messages are in English regardless of the README language. The key is shown with its middle replaced by dots — first 6 characters, `...`, last 4. For a 32-char Anti-Captcha key that exposes 10 characters total — enough to identify the key without leaking it.

Low balance:

```
⚠️ Anti-Captcha low balance

Key: 5dc7c0...f516
Balance: $0.42
Threshold: $2.00
```

API error:

```
❌ Anti-Captcha balance check failed

Key: 5dc7c0...f516
Code: ERROR_KEY_DOES_NOT_EXIST
Description: Account authentication key doesn't exist
```

Test message from `validate_env.sh`:

```
✅ tg-balance-notifications: test message from validate_env.sh (server-01 2026-05-23T01:15:42Z)
```

One message per key — issues are easy to read and you immediately see which key was affected.
