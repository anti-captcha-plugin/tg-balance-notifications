<!-- Keep README.md and README.ru.md in sync when editing. -->

[English](README.md) | [Русский](README.ru.md)

# tg-balance-notifications

Bash-based cron job that polls one or more Anti-Captcha API keys, compares each balance against a shared threshold, and sends a Telegram alert when a key falls below it.

One instance of this repo serves one client. A client may own one or several Anti-Captcha API keys; all of them share the same balance threshold and notify the same Telegram chat.

## Prerequisites

- `bash` 4+
- `curl`
- `jq`

## Setting up the Telegram bot

### 1. Create the bot

1. Open Telegram, start a chat with [@BotFather](https://t.me/BotFather).
2. Send `/newbot`.
3. Choose a display name (any), then a username ending in `bot` (e.g. `myteam_balance_bot`).
4. BotFather replies with the token — a string like `8037205173:AAGAn...` — this is `TELEGRAM_BOT_TOKEN`. Keep it secret.

### 2. Pick the destination chat

You can send alerts either to your personal DM with the bot or to a group. Pick one and follow the matching sub-section below to obtain `TELEGRAM_CHAT_ID`.

#### Personal DM

1. In Telegram, open the bot's profile (search by its `@username`) and press **Start** (or just send any message).
2. In a browser, open: `https://api.telegram.org/bot<TOKEN>/getUpdates` (replace `<TOKEN>`).
3. Find the field `"chat":{"id":NUMBER,"type":"private", ...}` — that `NUMBER` (a positive integer) is your `TELEGRAM_CHAT_ID`.

#### Group chat

1. Open the destination group → group settings → **Add Members** → search the bot by `@username` → add it. The bot needs no admin rights — just membership.
2. In the group, send a message that explicitly addresses the bot, e.g. `/start@your_botname`. (By default, Telegram bots only see messages that mention them; this one line is enough to make the chat visible in `getUpdates`.)
3. In a browser, open: `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. Find `"chat":{"id":-100NUMBER..., "type":"supergroup", "title":"..."}` (or `"type":"group"` with a smaller negative ID). That negative number — **with the minus sign** — is your `TELEGRAM_CHAT_ID`.

If `getUpdates` returns `{"ok":true,"result":[]}`, the bot hasn't received anything yet — send another `/start@your_botname` in the chat and refresh the page.

## Setup

1. Clone the repo on the server that will run the cron.
2. Edit `.env` (committed with placeholders) — see [Configuration](#configuration) below.
3. Run `./validate_env.sh` to verify credentials and receive a test message in the chat.
4. Add to cron — see [Scheduling](#scheduling).

## Configuration

`.env` lives next to the scripts. It is **committed** to the repo with placeholder values; replace them with real ones.

### Fields

| Variable | Purpose |
| --- | --- |
| `BALANCE_THRESHOLD` | Threshold in USD. A key triggers an alert if its balance is strictly less than this. Applies to every key. |
| `TELEGRAM_BOT_TOKEN` | Bot token from BotFather, e.g. `123456:ABC-DEF...`. |
| `TELEGRAM_CHAT_ID` | Destination chat ID. For groups it usually starts with `-100`. Bot must already be a member of the chat. |
| `KEY1`, `KEY2`, ... | Anti-Captcha client keys. The script iterates `KEY1`, `KEY2`, ... and stops at the first unset (or commented-out) variable. |

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

All four keys are uncommented; the script processes them sequentially. Need more than four? Just add `KEY5=...`, `KEY6=...` — numbering must be contiguous starting from `KEY1`.

## Usage

### Validate the configuration

```sh
./validate_env.sh
```

Performs, in order:

1. Required variables are present.
2. `BALANCE_THRESHOLD` parses as a positive number.
3. `TELEGRAM_BOT_TOKEN` is accepted by `getMe`.
4. Sends a test message to `TELEGRAM_CHAT_ID` — verifies the bot is in the chat.
5. For each `KEY<N>`: calls Anti-Captcha `getBalance` and reports balance or error.

Each line is either `✅` or `❌`. Exit code is `0` only if every check passes.

### Run a balance check

```sh
./check_balance.sh
```

Silent on success (intended for cron). Sends a Telegram message per key only when:

- the balance is below `BALANCE_THRESHOLD`, or
- the Anti-Captcha API returns an error for that key.

Exits non-zero only on configuration or local errors (missing `.env`, missing required tool). Low-balance events themselves are not treated as failures.

## Telegram message format

All Telegram messages are in English regardless of the README language. Each message uses HTML formatting and contains the key with its middle replaced by dots — first 6 characters, `...`, last 4. For a 32-char key this exposes 10 characters total, enough to identify the key without leaking it.

Low balance:

```
⚠️ Anti-Captcha low balance

Key: abc123...wxyz
Balance: $0.42
Threshold: $2.00
```

API error:

```
❌ Anti-Captcha balance check failed

Key: abc123...wxyz
Code: ERROR_KEY_DOES_NOT_EXIST
Description: Account authentication key doesn't exist
```

Test message from `validate_env.sh`:

```
✅ tg-balance-notifications: test message from validate_env.sh (<host> <UTC timestamp>)
```

One message per key — issues are easy to read in the chat and you immediately see which key was affected.

## Scheduling

Run via cron, e.g. every 30 minutes:

```cron
*/30 * * * * /path/to/tg-balance-notifications/check_balance.sh >> /var/log/tg-balance.log 2>&1
```

Pick a cadence that fits how fast the client burns balance — every 15–60 minutes is typical.
