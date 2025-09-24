#!/usr/bin/env bash
# Forward incoming SMS (ModemManager) to a Telegram chat
# Requires: curl, awk, sed, xxd, iconv, mmcli
# Env file: /etc/sms2tg.env  (BOT_TOKEN, CHAT_ID, optional: OTP_ONLY, FORWARD_RAW_ON_EMPTY, RAW_PREVIEW_BYTES, DEBUG_DUMP_FILE)

set -Eeuo pipefail
umask 077

# ====== mmcli default timeout (most commands) ======
MM="mmcli --timeout=8"

# ====== Utilities ======
log(){ echo "[sms2tg] $(date '+%F %T') $*" >&2; }

load_env(){
  [[ -f /etc/sms2tg.env ]] || { log "WARN: /etc/sms2tg.env not found"; return 1; }
  # shellcheck disable=SC1091
  . /etc/sms2tg.env || { log "WARN: failed to source /etc/sms2tg.env"; return 1; }

  BOT_TOKEN="${BOT_TOKEN:-}"; CHAT_ID="${CHAT_ID:-}"
  OTP_ONLY="${OTP_ONLY:-no}"
  FORWARD_RAW_ON_EMPTY="${FORWARD_RAW_ON_EMPTY:-yes}"
  RAW_PREVIEW_BYTES="${RAW_PREVIEW_BYTES:-220}"
  DEBUG_DUMP_FILE="${DEBUG_DUMP_FILE:-/var/log/sms2tg.last}"

  [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]] || { log "WARN: BOT_TOKEN/CHAT_ID missing"; return 1; }
  return 0
}

html_escape(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

send_tg_html(){
  # $1: HTML text
  curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=${1}" \
    --data "disable_web_page_preview=true" >/dev/null
}

valid_path(){ [[ "$1" =~ ^/org/freedesktop/ModemManager1/SMS/[0-9]+$ ]]; }
kvget(){ awk -F'=' -v k="$1" '$1==k { sub(/^[[:space:]]*/,"",$2); print $2; exit }'; }

# mmcli 版本百搭刪除
delete_sms(){
  local P="$1"; local ID="${P##*/}"
  $MM -m any --messaging-delete-sms="$ID" >/dev/null 2>&1 && return 0
  $MM       --messaging-delete-sms="$ID"  >/dev/null 2>&1 && return 0
  $MM -s "$ID" --delete                   >/dev/null 2>&1 && return 0
  $MM -m any --messaging-delete-sms="$P"  >/dev/null 2>&1 && return 0
  $MM       --messaging-delete-sms="$P"   >/dev/null 2>&1 && return 0
  $MM -s "$P" --delete                    >/dev/null 2>&1 && return 0
  return 1
}

decode_data_hex_to_text(){
  # 將 content.data（HEX）嘗試解為 UCS-2BE → binary
  local hex; hex="$(tr -d '[:space:]')"
  [[ -z "$hex" ]] && return 1
  if printf '%s' "$hex" | xxd -r -p 2>/dev/null | iconv -f UCS-2BE -t UTF-8 2>/dev/null; then
    return 0
  elif printf '%s' "$hex" | xxd -r -p 2>/dev/null; then
    return 0
  fi
  return 1
}

raw_get_field(){
  # $1: RAW text, $2: field name (text | number | timestamp | state)
  awk -v f="$2" -F':' '
    BEGIN{IGNORECASE=1}
    $0 ~ f"[[:space:]]*:" { sub(/^[^:]*:[[:space:]]*/,"",$0); print; exit }
  ' <<<"$1" | sed 's/^[[:space:]]*//'
}

# ====== SMS handling ======
handle_sms_path(){
  local SMS_PATH="$1"
  valid_path "$SMS_PATH" || { log "SKIP invalid path: $SMS_PATH"; return 1; }

  local KV RAW FROM TEXT TS STATE DATAHEX
  KV="$($MM -s "$SMS_PATH" --output-keyvalue 2>/dev/null || true)"
  RAW="$($MM -s "$SMS_PATH"                    2>/dev/null || true)"

  # dump for debugging
  { echo "=== $(date '+%F %T') $SMS_PATH ==="; echo "[KV]"; echo "$KV"; echo "[RAW]"; echo "$RAW"; echo; } >"$DEBUG_DUMP_FILE" 2>/dev/null || true

  FROM="$(echo "$KV" | kvget 'content.number')"
  TEXT="$(echo "$KV" | kvget 'content.text')"
  TS="$(echo "$KV" | kvget 'properties.timestamp')"
  STATE="$(echo "$KV" | awk -F= '$1 ~ /(^|[.])state$/ {print $2; exit}')"
  DATAHEX="$(echo "$KV" | kvget 'content.data')"

  # 填補欄位（必要時從 RAW 表格抓）
  [[ -z "${FROM:-}"  ]] && FROM="$(raw_get_field "$RAW" "number")"
  [[ -z "${TS:-}"    ]] && TS="$(raw_get_field "$RAW" "timestamp")"
  [[ -z "${STATE:-}" ]] && STATE="$(raw_get_field "$RAW" "state")"

  # 若 text 空、但有 data（HEX），嘗試解碼
  if [[ -z "${TEXT:-}" && -n "${DATAHEX:-}" ]]; then
    local DECODED; DECODED="$(printf '%s\n' "$DATAHEX" | decode_data_hex_to_text || true)"
    if [[ -n "$DECODED" ]]; then TEXT="$DECODED"; log "decoded content.data for $SMS_PATH"; fi
  fi

  # 最後一招：從 RAW 抓 "text:"
  if [[ -z "${TEXT:-}" ]]; then
    local RAW_TEXT; RAW_TEXT="$(raw_get_field "$RAW" "text")"
    [[ -n "$RAW_TEXT" ]] && TEXT="$RAW_TEXT"
  fi

  # 仍沒有文字：視設定轉發摘要或丟棄
  if [[ -z "${TEXT:-}" ]]; then
    if [[ -n "${DATAHEX:-}" ]]; then
      local HEX_PREVIEW; HEX_PREVIEW="$(echo "$DATAHEX" | tr -d '[:space:]' | head -c "$RAW_PREVIEW_BYTES")"
      local body; body="$(printf '⚠️ 未解碼 SMS（HEX 摘要）\n<b>From:</b> %s\n<b>Time:</b> %s\n<b>State:</b> %s\n<b>Hex:</b> %s…' \
        "$(printf '%s' "${FROM:-unknown}" | html_escape)" \
        "$(printf '%s' "${TS:-unknown}"   | html_escape)" \
        "$(printf '%s' "${STATE:-unknown}"| html_escape)" \
        "$(printf '%s' "$HEX_PREVIEW"     | html_escape)")"
      send_tg_html "$body" || log "ERROR telegram send failed (hex preview)"
      log "FORWARDED hex preview & deleting: $SMS_PATH"
      delete_sms "$SMS_PATH" || log "WARN failed to delete (hex preview): $SMS_PATH"
      return 0
    else
      if [[ "${FORWARD_RAW_ON_EMPTY}" == "yes" ]]; then
        local RAW_PREVIEW; RAW_PREVIEW="$(echo "$RAW" | head -n 10 | html_escape)"
        local body; body="$(printf 'ℹ️ 空白/狀態 SMS\n<b>From:</b> %s\n<b>Time:</b> %s\n<b>State:</b> %s\n<pre>%s</pre>' \
          "$(printf '%s' "${FROM:-unknown}" | html_escape)" \
          "$(printf '%s' "${TS:-unknown}"   | html_escape)" \
          "$(printf '%s' "${STATE:-unknown}"| html_escape)" \
          "$RAW_PREVIEW")"
        send_tg_html "$body" || log "ERROR telegram send failed (raw preview)"
        log "FORWARDED raw preview & deleting: $SMS_PATH"
      else
        log "DROP empty/status SMS: $SMS_PATH"
      fi
      delete_sms "$SMS_PATH" || log "WARN failed to delete (empty/status): $SMS_PATH"
      return 0
    fi
  fi

  # 只轉發 OTP（若開啟）
  if [[ "${OTP_ONLY}" == "yes" ]] && ! echo "$TEXT" | grep -Eq '\b[0-9]{4,8}\b'; then
    log "SKIP non-OTP by policy: $SMS_PATH"
    delete_sms "$SMS_PATH" || log "WARN failed to delete (policy): $SMS_PATH"
    return 4
  fi

  # 正常轉發
  local body; body="$(printf '📩 <b>SMS</b>\n<b>From:</b> %s\n<b>Time:</b> %s\n<b>State:</b> %s\n\n%s' \
      "$(printf '%s' "${FROM:-unknown}" | html_escape)" \
      "$(printf '%s' "${TS:-unknown}"   | html_escape)" \
      "$(printf '%s' "${STATE:-unknown}"| html_escape)" \
      "$(printf '%s' "${TEXT}"          | html_escape)")"
  if send_tg_html "$body"; then
    log "forwarded & deleting: $SMS_PATH"
    delete_sms "$SMS_PATH" || log "WARN delete failed after forward: $SMS_PATH"
    return 0
  else
    log "ERROR telegram send failed, keeping: $SMS_PATH"
    return 5
  fi
}

# ====== Main loop ======
STATE_FILE="/var/lib/sms2tg.seen"
mkdir -p "$(dirname "$STATE_FILE")"
# 啟動時清空，避免 seen 無限成長
: > "$STATE_FILE"

FAILS=0
MODE="monitor"
LAST_SWITCH=$(( $(date +%s) - 3600 ))

trap 'log "terminated"; exit 0' INT TERM

while true; do
  until load_env; do sleep 5; done

  # 等待 modem 就緒（存在 + messaging 可用），不要用 AT（Fibocom 需 debug 模式才允許）
  for i in $(seq 1 60); do
    if $MM -L 2>/dev/null | grep -q "ModemManager1/Modem/" \
       && $MM -m any --messaging-status >/dev/null 2>&1; then
      break
    fi
    log "waiting for modem... ($i/60)"
    sleep 1
  done

  if [[ "$MODE" == "monitor" ]]; then
    log "starting SMS monitor"
    # 監看需不逾時；其餘 mmcli 用全域 timeout
    if mmcli -m any --monitor-sms --timeout=0 2>&1 | while read -r line; do
         if [[ "$line" =~ (/org/freedesktop/ModemManager1/SMS/[0-9]+) ]]; then
           SMS_PATH="${BASH_REMATCH[1]}"
           valid_path "$SMS_PATH" || { log "MON invalid path: $SMS_PATH"; continue; }
           if grep -qx "$SMS_PATH" "$STATE_FILE"; then
             log "MON already seen: $SMS_PATH"
             continue
           fi
           if handle_sms_path "$SMS_PATH"; then
             echo "$SMS_PATH" >> "$STATE_FILE"
             # 限制 seen 檔大小（取最後 500 條）
             if [[ $(wc -l < "$STATE_FILE") -gt 500 ]]; then
               tail -n 300 "$STATE_FILE" > "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
             fi
           fi
         else
           log "MON: $line"
         fi
       done
    then
      : # 正常結束（罕見）
    else
      : # non-zero exit — 下面會重試
    fi

    log "monitor stopped, retry in 3s..."
    sleep 3
    FAILS=$((FAILS+1))
    if [[ $FAILS -ge 3 ]]; then
      MODE="poll"
      LAST_SWITCH=$(date +%s)
      log "switching to POLL mode (mmcli monitor kept stopping)"
    fi

  else
    # POLL：列出所有 SMS 路徑，逐一處理
    PATHS="$($MM -m any --messaging-list-sms 2>/dev/null | awk '/\/org\/freedesktop\/ModemManager1\/SMS\//{print $1}')"
    COUNT=0
    for p in $PATHS; do
      valid_path "$p" || { log "POLL invalid path: $p"; continue; }
      if grep -qx "$p" "$STATE_FILE"; then
        log "POLL already seen: $p"; continue
      fi
      log "POLL handling: $p"
      if handle_sms_path "$p"; then
        echo "$p" >> "$STATE_FILE"
        COUNT=$((COUNT+1))
        if [[ $(wc -l < "$STATE_FILE") -gt 500 ]]; then
          tail -n 300 "$STATE_FILE" > "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
      fi
    done
    log "POLL round: $COUNT message(s) handled"
    sleep 5

    NOW=$(date +%s)
    if (( NOW - LAST_SWITCH >= 60 )); then
      MODE="monitor"; FAILS=0
      log "trying to return to MONITOR mode"
    fi
  fi
done
