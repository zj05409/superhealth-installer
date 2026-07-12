#!/usr/bin/env bash
set -euo pipefail

# telemetry_report.sh — Collects privacy-safe, aggregate health metrics from a
# customer's SuperHealth installation and POSTs them to the Ops server.
# Designed to fail silently so it never disrupts the customer environment.

###############################################################################
# Logging
###############################################################################
LOG_DIR="${HOME}/.superhealth/logs"
LOG_FILE="${LOG_DIR}/telemetry.log"

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$(date -Iseconds) $*" >> "$LOG_FILE" 2>/dev/null || true
}

###############################################################################
# Main — wrapped in a trap so ANY error results in a quiet exit 0.
###############################################################################
main() {
  log "telemetry_report started"

  ##############################################################################
  # 1. Load config
  ##############################################################################
  INSTALLER_ENV="${HOME}/.superhealth/installer.env"
  if [[ ! -f "$INSTALLER_ENV" ]]; then
    log "installer.env not found — exiting silently"
    return 0
  fi

  # Source only the keys we need (safe: file is owned by the user)
  # shellcheck disable=SC1090
  source <(grep -E '^(SUPERHEALTH_ACTIVATION_TOKEN|SUPERHEALTH_INSTALL_EVENT_URL|SUPERHEALTH_MACHINE_FINGERPRINT)=' "$INSTALLER_ENV" 2>/dev/null) || true

  local ACTIVATION_TOKEN="${SUPERHEALTH_ACTIVATION_TOKEN:-}"
  local INSTALL_EVENT_URL="${SUPERHEALTH_INSTALL_EVENT_URL:-}"
  local MACHINE_FINGERPRINT="${SUPERHEALTH_MACHINE_FINGERPRINT:-}"

  if [[ -z "$ACTIVATION_TOKEN" || -z "$INSTALL_EVENT_URL" ]]; then
    log "missing ACTIVATION_TOKEN or INSTALL_EVENT_URL — exiting silently"
    return 0
  fi

  # Derive OPS_BASE_URL by stripping /api/install-events/... from the event URL
  local OPS_BASE_URL
  OPS_BASE_URL=$(echo "$INSTALL_EVENT_URL" | sed 's|/api/install-events/.*||')

  if [[ -z "$OPS_BASE_URL" ]]; then
    log "could not derive OPS_BASE_URL — exiting silently"
    return 0
  fi

  log "OPS_BASE_URL=$OPS_BASE_URL"

  ##############################################################################
  # 2. Find the health database
  ##############################################################################
  local HEALTH_DB=""
  if [[ -f "${HOME}/superHealth/data/health.db" ]]; then
    HEALTH_DB="${HOME}/superHealth/data/health.db"
  else
    HEALTH_DB=$(find "${HOME}/superHealth" -name "health.db" -type f 2>/dev/null | head -1 || true)
  fi

  # Helper: run a sqlite3 query, return empty string on failure
  db_query() {
    if [[ -n "$HEALTH_DB" && -f "$HEALTH_DB" ]]; then
      sqlite3 "$HEALTH_DB" "$1" 2>/dev/null || echo ""
    else
      echo ""
    fi
  }

  ##############################################################################
  # 3. Collect metrics
  ##############################################################################

  # --- Service statuses (as a dict matching web UI expectations) ---
  local dashboard_status vitals_receiver_status
  dashboard_status=$(systemctl --user is-active superhealth-dashboard.service 2>/dev/null || echo "inactive")
  vitals_receiver_status=$(systemctl --user is-active superhealth-vitals-receiver.service 2>/dev/null || echo "inactive")

  # --- Timer statuses ---
  local daily_timer_status weekly_timer_status
  daily_timer_status=$(systemctl --user is-active superhealth-daily-pipeline.timer 2>/dev/null || echo "inactive")
  weekly_timer_status=$(systemctl --user is-active superhealth-weekly-pipeline.timer 2>/dev/null || echo "inactive")

  # --- Garmin last sync date (date only, no raw data) ---
  local garmin_last_sync
  garmin_last_sync=$(db_query "SELECT MAX(date) FROM daily_health;")
  garmin_last_sync="${garmin_last_sync:-}"

  # --- Daily report status (last 50 lines of log) ---
  local daily_log="${HOME}/.superhealth/logs/services/daily_pipeline.out.log"
  local daily_status="unknown"
  local daily_last_date=""
  if [[ -f "$daily_log" ]]; then
    local daily_tail
    daily_tail=$(tail -n 50 "$daily_log" 2>/dev/null || true)
    if echo "$daily_tail" | grep -qE "(ERROR|error|Traceback|FAILED|failed)" 2>/dev/null; then
      daily_status="failed"
    fi
    # Success overrides failed if both appear (last line wins conceptually)
    if echo "$daily_tail" | grep -q "DAILY_PIPELINE_DONE" 2>/dev/null; then
      daily_status="success"
      daily_last_date=$(grep "DAILY_PIPELINE_DONE" "$daily_log" 2>/dev/null | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || echo "")
    fi
  fi

  # --- Weekly report status (last 50 lines of log) ---
  local weekly_log="${HOME}/.superhealth/logs/services/weekly_pipeline.out.log"
  local weekly_status="unknown"
  local weekly_last_date=""
  if [[ -f "$weekly_log" ]]; then
    local weekly_tail
    weekly_tail=$(tail -n 50 "$weekly_log" 2>/dev/null || true)
    if echo "$weekly_tail" | grep -qE "(ERROR|error|Traceback|FAILED|failed)" 2>/dev/null; then
      weekly_status="failed"
    fi
    if echo "$weekly_tail" | grep -q "WEEKLY_PIPELINE_DONE" 2>/dev/null; then
      weekly_status="success"
      weekly_last_date=$(grep "WEEKLY_PIPELINE_DONE" "$weekly_log" 2>/dev/null | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || echo "")
    fi
  fi

  # --- Push channel configured (boolean only — never send actual values) ---
  local config_toml="${HOME}/.superhealth/config.toml"
  local push_channel_configured="false"
  if [[ -f "$config_toml" ]]; then
    local has_account_id has_target
    has_account_id=$(grep -E '^\s*account_id\s*=\s*"[^"]+"' "$config_toml" 2>/dev/null || true)
    has_target=$(grep -E '^\s*target\s*=\s*"[^"]+"' "$config_toml" 2>/dev/null || true)
    if [[ -n "$has_account_id" && -n "$has_target" ]]; then
      push_channel_configured="true"
    fi
  fi

  # --- Goals (aggregate counts only — no raw goal data) ---
  local goals_active goals_achieved goals_adherence
  goals_active=$(db_query "SELECT COUNT(*) FROM goals WHERE status = 'active';")
  goals_active="${goals_active:-0}"
  goals_achieved=$(db_query "SELECT COUNT(*) FROM goals WHERE status = 'achieved';")
  goals_achieved="${goals_achieved:-0}"
  goals_adherence=$(db_query "SELECT ROUND(AVG(progress_pct),1) FROM goal_progress WHERE goal_id IN (SELECT id FROM goals WHERE status='active') AND date >= date('now','-7 days');")
  goals_adherence="${goals_adherence:-0}"

  # --- Vitals (dates and counts only — no raw biometric values) ---
  local vitals_last_date vitals_count_7d
  vitals_last_date=$(db_query "SELECT MAX(measured_at) FROM vitals;")
  vitals_last_date="${vitals_last_date:-}"
  vitals_count_7d=$(db_query "SELECT COUNT(*) FROM vitals WHERE measured_at >= datetime('now','-7 days');")
  vitals_count_7d="${vitals_count_7d:-0}"

  # --- System uptime ---
  local uptime_hours
  uptime_hours=$(awk '{print int($1/3600)}' /proc/uptime 2>/dev/null || echo "0")

  # --- Error log collection with deduplication ---
  local errors_json="[]"
  local err_logs_dir="${HOME}/.superhealth/logs/services"
  if [[ -d "$err_logs_dir" ]]; then
    local all_errors=""
    for err_file in "$err_logs_dir"/*.err.log; do
      [[ -f "$err_file" && -s "$err_file" ]] || continue
      local svc_name
      svc_name=$(basename "$err_file" .err.log)
      # Read each non-empty line, pair with service name
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        all_errors+="${svc_name}|${line}"$'\n'
      done < "$err_file"
    done

    if [[ -n "$all_errors" ]]; then
      # Deduplicate: group by (service, message_stripped_of_timestamp)
      # Extract: service, message (strip leading timestamp), first_ts, last_ts, count
      local dedup_result
      dedup_result=$(echo "$all_errors" | awk -F'|' '
      {
        svc = $1
        line = $2
        # Strip leading timestamp patterns like "2026-07-12 09:25:33,123" or "[2026-07-12T09:25:33]"
        msg = line
        gsub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}[,.]?[0-9]* ?/, "", msg)
        gsub(/^\[[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}[^\]]*\] ?/, "", msg)
        gsub(/^[ \t]+/, "", msg)
        if (msg == "") next
        # Extract timestamp from the original line
        ts = ""
        if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
          ts = substr(line, RSTART, RLENGTH)
        }
        key = svc "|||" msg
        count[key]++
        if (!(key in first_ts) || ts < first_ts[key]) first_ts[key] = ts
        if (!(key in last_ts) || ts > last_ts[key]) last_ts[key] = ts
        if (!(key in svc_name)) svc_name[key] = svc
        if (!(key in msg_text)) msg_text[key] = msg
      }
      END {
        # Sort by count descending, emit top 10
        n = 0
        for (key in count) {
          n++
          keys[n] = key
          counts[n] = count[key]
        }
        # Simple selection sort for top 10
        for (i = 1; i <= n && i <= 10; i++) {
          max_idx = i
          for (j = i+1; j <= n; j++) {
            if (counts[j] > counts[max_idx]) max_idx = j
          }
          if (max_idx != i) {
            tmp = keys[i]; keys[i] = keys[max_idx]; keys[max_idx] = tmp
            tmp = counts[i]; counts[i] = counts[max_idx]; counts[max_idx] = tmp
          }
        }
        limit = (n < 10) ? n : 10
        for (i = 1; i <= limit; i++) {
          key = keys[i]
          # Truncate message to 200 chars
          m = substr(msg_text[key], 1, 200)
          gsub(/\\/, "\\\\\\\\\\\\\\\\", m)
          gsub(/"/, "\\\\\"" , m)
          gsub(/\n/, "\\n", m)
          gsub(/\r/, "", m)
          printf "%s|%s|%s|%d|%s\n", svc_name[key], m, first_ts[key], counts[key], last_ts[key]
        }
      }
      ' 2>/dev/null || true)

      if [[ -n "$dedup_result" ]]; then
        local err_items=""
        while IFS='|' read -r e_svc e_msg e_first e_count e_last; do
          [[ -z "$e_svc" ]] && continue
          err_items+="$(printf '{"service":"%s","message":"%s","first_seen":"%s","last_seen":"%s","count":%d}' \
            "$(json_str "$e_svc")" "$(json_str "$e_msg")" "$(json_str "$e_first")" "$(json_str "$e_last")" "$e_count")"
          err_items+=","
        done <<< "$dedup_result"
        # Remove trailing comma
        err_items="${err_items%,}"
        errors_json="[${err_items}]"
      fi
    fi
  fi
  log "collected $(echo "$errors_json" | grep -o '"service"' | wc -l) unique errors"

  ##############################################################################
  # 4. Build JSON payload and POST
  ##############################################################################
  # json_str: escapes a value for safe inclusion in a JSON string.
  json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

  # JSON numeric: emit the value as-is if it looks numeric, else null.
  json_num() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      echo "$v"
    else
      echo "null"
    fi
  }

  # JSON nullable string: emit "value" or null.
  json_nstr() {
    local v="$1"
    if [[ -n "$v" ]]; then
      printf '"%s"' "$(json_str "$v")"
    else
      echo "null"
    fi
  }

  local services_json
  services_json=$(printf '{"superhealth-dashboard":"%s","superhealth-vitals-receiver":"%s","superhealth-daily-pipeline":"%s","superhealth-weekly-pipeline":"%s"}' \
    "$(json_str "$dashboard_status")" "$(json_str "$vitals_receiver_status")" \
    "$(json_str "$daily_timer_status")" "$(json_str "$weekly_timer_status")")

  local JSON_PAYLOAD
  JSON_PAYLOAD=$(cat <<EOJSON
{
  "services": ${services_json},
  "garmin_last_sync_date": $(json_nstr "$garmin_last_sync"),
  "daily_report_status": "$(json_str "$daily_status")",
  "daily_report_last_date": $(json_nstr "$daily_last_date"),
  "weekly_report_status": "$(json_str "$weekly_status")",
  "weekly_report_last_date": $(json_nstr "$weekly_last_date"),
  "push_channel_ok": ${push_channel_configured},
  "goals_active_count": $(json_num "$goals_active"),
  "goals_achieved_count": $(json_num "$goals_achieved"),
  "goals_adherence_pct": $(json_num "$goals_adherence"),
  "vitals_last_reading_date": $(json_nstr "$vitals_last_date"),
  "vitals_readings_7d_count": $(json_num "$vitals_count_7d"),
  "system_uptime_hours": $(json_num "$uptime_hours"),
  "errors": ${errors_json}
}
EOJSON
)

  log "sending telemetry payload"

  curl -fsS --connect-timeout 5 --max-time 15 \
    -H "Content-Type: application/json" \
    -H "X-SuperHealth-Machine: ${MACHINE_FINGERPRINT}" \
    -d "$JSON_PAYLOAD" \
    "${OPS_BASE_URL}/api/telemetry/${ACTIVATION_TOKEN}" 2>/dev/null || true

  log "telemetry_report completed"
}

# Run main; on ANY error, log and exit 0 so the customer system is never disrupted.
main "$@" 2>>"${LOG_FILE:-/dev/null}" || {
  log "telemetry_report encountered an error — exiting silently"
  exit 0
}
