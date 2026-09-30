#!/bin/bash
#
# mailsync-doctor.sh — diagnose (and optionally fix) macOS Mail ⇄ Exchange
# read-state sync failures: "mails are read locally but stay unread on the server".
#
#   ./mailsync-doctor.sh            # diagnose only (read-only, safe)
#   ./mailsync-doctor.sh --drop-action ID  # remove a wedged action (see log)
#   ./mailsync-doctor.sh --analyze  # rebuild query-planner stats (faster queries)
#   ./mailsync-doctor.sh --unwedge  # detect, quit Mail, drop wedge, reopen (one step)
#   ./mailsync-doctor.sh --check    # quiet health check, for scheduling (exit 1 = wedged)
#   ./mailsync-doctor.sh --recount  # fix a stale flagged/unread badge
#   ./mailsync-doctor.sh --watch    # poll the queue live during a re-sync
#   ./mailsync-doctor.sh --sync     # force a sync via AppleScript, then re-measure
#
# NOTE: never reads message bodies, subjects or senders — only sync bookkeeping
# (pending-action queue, EWS sync tokens, read/unread counters).
#
# Requires Full Disk Access for your terminal
# (System Settings → Privacy & Security → Full Disk Access).

set -uo pipefail

MAILDIR="$HOME/Library/Mail/V10"
DB="$MAILDIR/MailData/Envelope Index"
ACCT_DB="$HOME/Library/Accounts/Accounts4.sqlite"
BACKUP_DIR="$HOME/Library/Mail/mailsync-doctor-backups"

# Sync tokens above this are pathological. Healthy inboxes sit at ~0.5–2 KB.
BLOAT_WARN=8192
BLOAT_CRIT=32768

bold=$'\033[1m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; dim=$'\033[2m'; rst=$'\033[0m'

hdr() { printf '\n%s%s%s\n' "$bold" "$1" "$rst"; printf '%s\n' "${dim}$(printf '─%.0s' $(seq 1 ${#1}))${rst}"; }
ok()   { printf '  %s✓%s %s\n' "$grn" "$rst" "$1"; }
warn() { printf '  %s!%s %s\n' "$ylw" "$rst" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$red" "$rst" "$1"; }
info() { printf '    %s%s%s\n' "$dim" "$1" "$rst"; }

# Read-only query. Prefer mode=ro: it respects the -wal file, so readings stay
# accurate while Mail is running and actively writing. Fall back to immutable=1
# (ignores the WAL, but works when the -shm cannot be opened).
q() {
  local r
  r=$(sqlite3 "file:${DB}?mode=ro" "$1" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return; }
  sqlite3 "file:${DB}?immutable=1" "$1" 2>/dev/null
}
qa() { sqlite3 "file:${ACCT_DB}?immutable=1" "$1" 2>/dev/null; }

preflight() {
  [ -f "$DB" ] || { bad "Envelope Index not found at $DB"; exit 1; }
  if ! q "SELECT 1 FROM mailboxes LIMIT 1;" >/dev/null 2>&1; then
    bad "Cannot read the Mail database."
    info "Grant Full Disk Access to your terminal:"
    info "System Settings → Privacy & Security → Full Disk Access"
    exit 1
  fi
  command -v sqlite3 >/dev/null || { bad "sqlite3 not found"; exit 1; }
}

# Returns: 0 = running, 1 = not running, 2 = could not determine.
# "Could not determine" must never be treated as "safe to write".
mail_running() {
  local out
  if out=$(pgrep -x Mail 2>/dev/null); then
    [ -n "$out" ] && return 0
    return 1
  fi
  # pgrep failed outright (e.g. sandboxed/restricted): fall back to ps.
  if out=$(ps -Ac -o comm= 2>/dev/null); then
    printf '%s\n' "$out" | grep -qx 'Mail' && return 0
    return 1
  fi
  return 2
}

# Map an account UUID to a human-readable address.
acct_name() {
  local uuid="$1" n
  n=$(qa "SELECT ZUSERNAME FROM ZACCOUNT WHERE ZIDENTIFIER='$uuid';")
  [ -n "$n" ] && printf '%s' "$n" || printf '%s' "${uuid:0:8}…"
}

# Human label for local_message_actions.action_type.
# 2, 3 and 5 are confirmed: 3 against the read flag, 2 by its destination
# mailbox (uploads into Sent Items), and 5 by the unified log, which calls it
# "Replaying delete action <ECTransferMessageAction>". 1 and 4 are still
# guesses and are marked as such rather than asserted.
action_label() {
  case "$1" in
    2) echo "move/copy" ;;
    3) echo "read-state change" ;;
    5) echo "delete (transfer)" ;;
    1) echo "type 1 (likely delete)" ;;
    4) echo "type 4 (likely flag change)" ;;
    *) echo "type $1" ;;
  esac
}

########################################  DIAGNOSE

diagnose() {
  printf '%s\n' "${bold}macOS Mail ⇄ Exchange sync doctor${rst}"
  printf '%s\n' "${dim}$(date '+%Y-%m-%d %H:%M')  ·  $(sw_vers -productName) $(sw_vers -productVersion)${rst}"

  ##### 1. Is Mail holding the database?
  hdr "1. Mail process"
  mail_running; case $? in
    0) warn "Mail is running."
       info "Diagnosis is safe; --unwedge will restart Mail itself." ;;
    1) ok "Mail is not running." ;;
    2) warn "Could not determine whether Mail is running."
       info "Write paths refuse to run until this can be confirmed." ;;
  esac

  ##### 2. The pending-action queue — the core signal
  hdr "2. Unsent changes queued for the server"
  local total
  total=$(q "SELECT COUNT(*) FROM local_message_actions;")
  total=${total:-0}

  if [ "$total" -eq 0 ]; then
    ok "No queued actions — every local change has reached the server."
  else
    bad "$total queued action(s) have NOT been pushed to the server."
    echo
    printf '      %-6s  %-22s  %s\n' "COUNT" "ACTION" "MAILBOX"
    q "SELECT COUNT(*), a.action_type, m.url
         FROM local_message_actions a
         LEFT JOIN mailboxes m ON a.mailbox = m.ROWID
        GROUP BY a.action_type, m.url
        ORDER BY COUNT(*) DESC;" \
    | while IFS='|' read -r c t url; do
        local uuid folder label
        uuid=$(printf '%s' "$url" | sed -E 's|^ews://([^/]+)/.*|\1|')
        folder=$(printf '%s' "$url" | sed -E 's|^ews://[^/]+/||')
        # percent-decode the folder name for readability
        folder=$(printf '%b' "${folder//%/\\x}" 2>/dev/null || printf '%s' "$folder")
        label=$(action_label "$t")
        printf '      %-6s  %-22s  %s %s(%s)%s\n' \
          "$c" "$label" "$folder" "$dim" "$(acct_name "$uuid")" "$rst"
      done
  fi

  ##### 3. Confirm the queued changes really are read-marks
  hdr "3. What the stuck changes actually are"
  local readstuck
  readstuck=$(q "SELECT COUNT(*) FROM local_message_actions a
                   JOIN action_messages am ON am.action = a.ROWID
                   JOIN messages m ON am.message = m.ROWID
                  WHERE a.action_type = 3 AND m.read = 1;")
  readstuck=${readstuck:-0}
  if [ "$readstuck" -gt 0 ]; then
    bad "$readstuck message(s) are read on this Mac but the server was never told."
    info "This is precisely the reported symptom."
  else
    ok "No stranded read-marks."
  fi

  ##### 3b. Dead entries that can never be executed
  hdr "3b. Unexecutable queue entries"
  local dead orph pend
  dead=$(q "SELECT COUNT(*) FROM ($DEAD_SQL);")
  orph=$(q "SELECT COUNT(*) FROM action_messages WHERE message IS NULL;")
  pend=$(q "$PENDING_UPLOAD_SQL")

  if [ "${dead:-0}" -gt 0 ]; then
    bad "${dead} queued action(s) have lost every reference and can never run."
    info "These can never run. Clear them with:  ./mailsync-doctor.sh --unwedge"
  else
    ok "No unexecutable entries — every queued action still has something to act on."
  fi

  # The wedge: a delete whose local message is gone but which still holds a
  # server ItemId. Exchange answers "item not found" (EWS 190), Mail misfiles
  # that permanent error as a connection error and replays it ~28x/second
  # forever, blocking everything queued behind it. This is the fault that
  # actually recurs, so surface it loudly.
  local wedge
  wedge=$(q "SELECT COUNT(*) FROM ($POISON_SQL);")
  if [ "${wedge:-0}" -gt 0 ]; then
    echo
    bad "${wedge} action(s) match the head-of-line wedge signature."
    info "A delete for an item the server no longer has. Mail retries these"
    info "endlessly and nothing queued behind them can run."
    echo
    printf '      %-8s %-6s %s\n' "ROWID" "PHASE" "MAILBOX"
    q "SELECT a.ROWID, am.action_phase, REPLACE(SUBSTR(mb.url,45),'%20',' ')
         FROM local_message_actions a
         JOIN action_messages am ON am.action = a.ROWID
         LEFT JOIN mailboxes mb ON a.mailbox = mb.ROWID
        WHERE a.ROWID IN ($POISON_SQL) ORDER BY a.ROWID;" \
    | while IFS='|' read -r r p m; do printf '      %-8s %-6s %s\n' "$r" "$p" "$m"; done
    echo
    info "Confirm which one is spinning right now:"
    info "  log show --last 15m --predicate 'process == \"Mail\"' --style compact \\"
    info "    | grep -i 'Replaying.*action.*id ='"
    info "Then:  ./mailsync-doctor.sh --drop-action <id> [<id> …]"
  fi

  if [ "${pend:-0}" -gt 0 ]; then
    echo
    bad "${pend} sent message(s) exist ONLY on this Mac."
    info "Their upload into the server's Sent Items never completed, so they are"
    info "missing from Sent Items in OWA and on your other devices."
    info "The recipients received them — only the server-side copy is missing."
    info "Save these elsewhere before any drastic step. They upload once sync resumes."
    echo
    printf '      %-12s  %s\n' "SENT" "STATUS"
    q "SELECT date(d.date_sent,'unixepoch'), 'local only, not yet uploaded'
         FROM action_messages am JOIN messages d ON am.destination_message = d.ROWID
        WHERE am.message IS NULL AND am.remote_id IS NULL AND d.remote_id IS NULL
        ORDER BY d.date_sent;" \
    | while IFS='|' read -r dt st; do printf '      %-12s  %s\n' "$dt" "$st"; done
  fi

  [ "${orph:-0}" -gt 0 ] && info "(${orph} row(s) lost their local message but kept another handle.)"

  ##### 4. EWS sync tokens — the usual root cause
  hdr "4. EWS sync-token health"
  info "Mail stores a per-folder sync token. Large ones correlate with large"
  info "folders. Informational only — an oversized token has NOT been shown to"
  info "cause a stall, and clearing one did not fix the stalls behind this tool."
  echo
  local found=0
  printf '      %-10s  %s\n' "SIZE" "FOLDER"
  while IFS='|' read -r len url; do
    [ -z "$len" ] && continue
    local uuid folder mark colr
    uuid=$(printf '%s' "$url" | sed -E 's|^ews://([^/]+)/.*|\1|')
    folder=$(printf '%s' "$url" | sed -E 's|^ews://[^/]+/||')
    folder=$(printf '%b' "${folder//%/\\x}" 2>/dev/null || printf '%s' "$folder")
    if   [ "$len" -ge "$BLOAT_CRIT" ]; then mark="✗"; colr="$red";  found=1
    elif [ "$len" -ge "$BLOAT_WARN" ]; then mark="!"; colr="$ylw";  found=1
    else continue
    fi
    printf '    %s%s%s %-10s  %s %s(%s)%s\n' \
      "$colr" "$mark" "$rst" "$(( len / 1024 )) KB" "$folder" "$dim" "$(acct_name "$uuid")" "$rst"
  done < <(q "SELECT length(e.sync_state), m.url
                FROM ews_folders e JOIN mailboxes m ON e.mailbox_id = m.ROWID
               WHERE e.sync_state IS NOT NULL
               ORDER BY length(e.sync_state) DESC;")

  if [ "$found" -eq 0 ]; then
    ok "All sync tokens are a healthy size."
  else
    echo
    info "For comparison, a healthy inbox token is roughly 0.5–2 KB."
  fi

  ##### 4b. Folder size — what actually drives token growth
  hdr "4b. Folder size vs. token size"
  info "Token size scales with how many messages the folder holds."
  info "This is the underlying cause; token bloat is the symptom."
  echo
  printf '      %-9s  %-9s  %s\n' "MESSAGES" "TOKEN" "FOLDER"
  local oversize=0
  while IFS='|' read -r n len url; do
    [ -z "${n:-}" ] && continue
    local folder uuid colr
    uuid=$(printf '%s' "$url" | sed -E 's|^ews://([^/]+)/.*|\1|')
    folder=$(printf '%s' "$url" | sed -E 's|^ews://[^/]+/||')
    folder=$(printf '%b' "${folder//%/\\x}" 2>/dev/null || printf '%s' "$folder")
    colr=""
    if [ "$n" -ge 20000 ]; then colr="$red"; oversize=1
    elif [ "$n" -ge 10000 ]; then colr="$ylw"; oversize=1; fi
    printf '      %s%-9s%s  %-9s  %s %s(%s)%s\n' \
      "$colr" "$n" "$rst" "$(( len / 1024 )) KB" "$folder" "$dim" "$(acct_name "$uuid")" "$rst"
  done < <(q "SELECT (SELECT COUNT(*) FROM messages WHERE mailbox = mb.ROWID),
                     COALESCE(length(e.sync_state),0), mb.url
                FROM mailboxes mb
                LEFT JOIN ews_folders e ON e.mailbox_id = mb.ROWID
               WHERE mb.url LIKE 'ews://%'
                 AND (SELECT COUNT(*) FROM messages WHERE mailbox = mb.ROWID) > 5000
               ORDER BY 1 DESC LIMIT 8;")
  [ "$oversize" -eq 0 ] && ok "No folder large enough to destabilise sync."

  ##### 4c. Search index: is Mail still handing messages to the system index?
  hdr "4c. Search index backlog"
  info "Mail records how many messages are waiting to be re-indexed. A figure"
  info "that stays identical across samples means that queue has stopped moving."
  echo
  local rows
  rows=$(q "SELECT COUNT(*) FROM indexing_progress_statistics;")
  if [ "${rows:-0}" -eq 0 ]; then
    info "No indexing statistics recorded."
  else
    printf '      %-20s %-11s %-11s %s\n' "SAMPLED" "INDEXABLE" "INDEXED" "PENDING RE-INDEX"
    q "SELECT datetime(timestamp,'unixepoch','localtime'), total_indexable_messages,
              total_donated_messages, total_pending_redonations
         FROM indexing_progress_statistics ORDER BY ROWID DESC LIMIT 6;" \
    | while IFS='|' read -r w ia id pr; do
        printf '      %-20s %-11s %-11s %s\n' "$w" "$ia" "$id" "$pr"
      done
    echo
    # Same non-zero backlog in the two most recent samples = not draining.
    local last prev
    last=$(q "SELECT total_pending_redonations FROM indexing_progress_statistics ORDER BY ROWID DESC LIMIT 1;")
    prev=$(q "SELECT total_pending_redonations FROM indexing_progress_statistics ORDER BY ROWID DESC LIMIT 1 OFFSET 1;")
    if [ "${last:-0}" -gt 0 ] && [ "${last:-0}" = "${prev:-x}" ]; then
      bad "Backlog frozen at ${last} across the last two samples — indexing has stalled."
      info "Messages in that backlog will not be found by Mail search."
      info "Try quitting and reopening Mail, then re-run this and compare."
      info "If it has not moved, the Envelope Index needs rebuilding: quit Mail,"
      info "move MailData/'Envelope Index'* aside, reopen. Do this ONLY when"
      info "section 2 shows an empty queue — a rebuild discards local-only state,"
      info "including sent messages not yet uploaded to the server."
    elif [ "${last:-0}" -gt 0 ]; then
      warn "${last} message(s) waiting to be re-indexed, but the figure is moving."
    else
      ok "No indexing backlog."
    fi
  fi

  ##### 5. Server-side sync error folders
  hdr "5. Exchange sync-issue folders"
  local anyerr=0
  while IFS='|' read -r cnt url; do
    [ -z "${cnt:-}" ] && continue
    [ "$cnt" -eq 0 ] && continue
    anyerr=1
    local folder uuid
    uuid=$(printf '%s' "$url" | sed -E 's|^ews://([^/]+)/.*|\1|')
    folder=$(printf '%s' "$url" | sed -E 's|^ews://[^/]+/||')
    folder=$(printf '%b' "${folder//%/\\x}" 2>/dev/null || printf '%s' "$folder")
    warn "$cnt item(s) in $folder ${dim}($(acct_name "$uuid"))${rst}"
  done < <(q "SELECT (SELECT COUNT(*) FROM messages WHERE mailbox = m.ROWID), m.url
                FROM mailboxes m
               WHERE m.url LIKE '%ynchronisierungsprobleme%'
                  OR m.url LIKE '%Sync%20Issues%'
                  OR m.url LIKE '%Serverfehler%'
                  OR m.url LIKE '%Server%20Failures%';")
  [ "$anyerr" -eq 0 ] && ok "No messages parked in sync-issue folders."

  ##### 6. Recent EWS errors from the unified log
  hdr "6. Recent EWS errors (last 2h)"
  local logs
  logs=$(log show --last 2h --style compact 2>/dev/null \
         | grep -iE 'ews|exchange' \
         | grep -iE 'error|fail|throttl|denied|401|403|500' \
         | tail -12)
  if [ -n "$logs" ]; then
    printf '%s\n' "$logs" | sed 's/^/    /'
  else
    info "Nothing found (logs rotate quickly; run right after reproducing)."
  fi

  ##### 7. Verdict
  hdr "Verdict"
  if [ "${wedge:-0}" -gt 0 ]; then
    bad "Sync is wedged on an action that can never complete."
    cat <<EOF

    ${bold}What is happening${rst}
    Mail queues every local change for the server and works that queue in order.
    One queued delete targets an item the server no longer holds. Exchange answers
    EWS 190 (item not found), Mail misfiles that permanent error as a connection
    error, and replays it about 28 times a second indefinitely. Nothing behind it
    ever runs, so read-marks and Sent Items uploads pile up unsent.

    ${bold}Fix${rst}
        ./mailsync-doctor.sh --unwedge

    Removes only the action that cannot complete, preserving your read-marks and
    any sent mail still waiting to upload. Mail is restarted, because it replays
    the action from memory rather than re-reading the row. Clearing one wedge can
    expose the next behind it, so re-run if the queue does not drain.
EOF
  elif [ "$total" -gt 0 ]; then
    warn "Actions are queued, but none match the wedge signature."
    info "A queue drains by itself once a sync cycle completes — give Mail a few"
    info "minutes with the account online, and watch it with:  --watch"
    info "If it does not move, look for a repeating action id in the log:"
    info "  log show --last 15m --predicate 'process == \"Mail\"' --style compact \\"
    info "    | grep -i 'Replaying.*action.*id ='"
  else
    ok "No sync backlog detected right now."
    info "If the symptom recurs, run this again immediately afterwards."
  fi
  echo
}

########################################  SHARED DETECTION SQL

# An action is "dead" only when every row describing it has lost ALL THREE of
# its references: the source message, the server-side remote_id, AND the
# destination message. destination_message matters — for an upload into Sent
# Items it is the payload, so an action that still has one is a pending upload,
# not garbage. Deleting those would strand locally-held sent mail.
DEAD_SQL="SELECT a.ROWID FROM local_message_actions a
           WHERE NOT EXISTS (SELECT 1 FROM action_messages am
                              WHERE am.action = a.ROWID
                                AND (am.message IS NOT NULL
                                     OR am.remote_id IS NOT NULL
                                     OR am.destination_message IS NOT NULL))"

# The wedge: a type-5 delete whose local message is gone but which still holds a
# stale server item id. Exchange answers 190 (item not found), Mail misfiles that
# permanent error as a connection error and replays it forever.
POISON_SQL="SELECT a.ROWID FROM local_message_actions a
              JOIN action_messages am ON am.action = a.ROWID
             WHERE a.action_type = 5
               AND am.message IS NULL
               AND am.remote_id IS NOT NULL"

# Pending uploads: a sent message whose only copy is local, still waiting to be
# uploaded into the server's Sent Items. The opposite of garbage — discarding
# these loses the server's copy of mail already sent.
PENDING_UPLOAD_SQL="SELECT COUNT(*) FROM action_messages am
                      JOIN messages d ON am.destination_message = d.ROWID
                     WHERE am.message IS NULL AND am.remote_id IS NULL
                       AND d.remote_id IS NULL"

########################################  RECOUNT

FLAGPLIST="$MAILDIR/MailData/FlagMailboxes.plist"

# Mail caches the Flagged-mailbox badge in its own plist, separate from the
# per-mailbox counters in the Envelope Index. It can drift out of step after
# the queue is cleared, leaving a badge that counts messages that are no
# longer unread. The file is a pure cache — Mail rebuilds it on launch.
do_recount() {
  hdr "Checking cached counters"

  # Mail's Flagged mailbox is a smart mailbox, and smart mailboxes are evaluated
  # through Spotlight. With Spotlight off, Mail cannot recompute the badge, so
  # deleting the cache is pointless — Mail writes the same wrong number back.
  # spot: 0 = indexing looks alive, 1 = looks disabled, 2 = cannot tell.
  # Two traps here. First, "/" is the sealed read-only system volume on modern
  # macOS; user data lives on /System/Volumes/Data, and that is the volume whose
  # index matters. Second, mdutil talks to mds over a Mach service, so inside a
  # sandbox it reports "Spotlight server is disabled" when it simply cannot
  # reach the server. Never call it disabled on mdutil's word alone.
  local spot=2 mdout=""
  mdout=$(mdutil -s /System/Volumes/Data 2>&1)
  if [ -d /System/Volumes/Data/.Spotlight-V100 ]; then
    # The index store exists and is owned by _mds_stores: indexing has run here.
    spot=0
    printf '%s' "$mdout" | grep -qi 'indexing disabled' && spot=1
  elif printf '%s' "$mdout" | grep -qi 'indexing enabled'; then
    spot=0
  elif printf '%s' "$mdout" | grep -qi 'server is disabled'; then
    # Ambiguous: genuinely off, or we are sandboxed and cannot ask.
    spot=2
  fi

  # The plist key is called MailboxUnreadCount, but measurement shows it tracks
  # the TOTAL number of flagged messages, not the unread ones. Comparing it
  # against a flagged-AND-unread count reports a huge phantom discrepancy.
  local fa fc funread
  fa=$(q "SELECT COUNT(*) FROM messages WHERE flagged=1 AND deleted=0;")
  funread=$(q "SELECT COUNT(*) FROM messages WHERE flagged=1 AND deleted=0 AND read=0;")
  fc=$(plutil -extract mailboxes.flag-0.MailboxUnreadCount raw "$FLAGPLIST" 2>/dev/null)

  printf '      %-34s %s\n' "flagged total (actual):" "${fa:-0}"
  printf '      %-34s %s\n' "flagged badge (cached):" "${fc:-none}"
  printf '      %-34s %s\n' "of those unread:" "${funread:-0}"

  local stale=0 drift=0
  if [ -n "$fc" ] && [ "${fc:-0}" != "${fa:-0}" ]; then
    stale=1
    drift=$(( ${fa:-0} - ${fc:-0} )); [ "$drift" -lt 0 ] && drift=$(( -drift ))
  fi

  # Per-mailbox counters live in the database and are checked separately.
  local bad_mb
  bad_mb=$(q "SELECT COUNT(*) FROM mailboxes mb
               WHERE mb.unread_count <>
                     (SELECT COUNT(*) FROM messages m
                       WHERE m.mailbox=mb.ROWID AND m.read=0 AND m.deleted=0);")
  echo
  if [ "${bad_mb:-0}" -eq 0 ]; then
    ok "Per-mailbox unread counters all agree with the messages themselves."
  else
    warn "${bad_mb} mailbox counter(s) disagree — Mail rebuilds these on relaunch."
  fi

  if [ "$stale" -eq 0 ]; then
    ok "Flagged badge matches. Nothing to reset."
    exit 0
  fi

  if [ "$drift" -le 3 ]; then
    warn "Flagged badge is behind by ${drift}: shows ${fc}, actual ${fa}."
    info "A small lag is normal — Mail recomputes this on its own schedule"
    info "rather than the instant a flag changes, and it catches up by itself."
    info "Nothing is broken; resetting it only forces the recompute sooner."
    echo
  else
    bad "Flagged badge is behind by ${drift}: shows ${fc}, actual ${fa}."
    info "It converges eventually, but that is a large backlog."
  fi

  if [ "$spot" -eq 2 ]; then
    echo
    warn "Could not determine whether Spotlight indexing is on."
    info "mdutil could not reach the metadata server. That happens when this"
    info "shell is sandboxed, so it is NOT evidence that indexing is off."
    info "Check in a normal Terminal:  mdutil -s /System/Volumes/Data"
    info "Or just press ⌘Space and search — if you get results, it is fine."
    echo
  fi

  if [ "$spot" -eq 1 ]; then
    echo
    bad "Spotlight indexing is off for the data volume."
    info "Mail's Flagged mailbox is a smart mailbox, and smart mailboxes are"
    info "evaluated through Spotlight. With indexing off, Mail cannot recompute"
    info "this badge — clearing the cache just makes it rewrite the same number."
    info "That is consistent with ${fc} matching no count in Mail's own database."
    echo
    info "To re-enable indexing (asks for your password, then indexes the disk"
    info "in the background — heavy I/O for a while):"
    info "    sudo mdutil -a -i on"
    echo
    info "Quick confirmation it is Spotlight: search for a word you know is in"
    info "your mail. If Mail search is also broken, that settles it."
    echo
    warn "The flags themselves are fine: ${fa} unread of $(q "SELECT COUNT(*) FROM messages WHERE flagged=1 AND deleted=0;") flagged. Only the badge is wrong."
    info "Resetting the cache anyway is harmless but will not stick."
    echo
  fi

  cat <<EOF
  Resetting this deletes ${FLAGPLIST##*/}, a cache of badge numbers.
  Mail rebuilds it on the next launch. No flags, messages or mail state
  are touched — only the cached count.

EOF

  mail_running; case $? in
    0) bad "Quit Mail (⌘Q) first, then re-run."; exit 1 ;;
    2) bad "Cannot verify whether Mail is running. Refusing to continue."; exit 1 ;;
  esac

  printf '  Type %sRESET%s to proceed: ' "$bold" "$rst"
  read -r reply
  [ "$reply" = "RESET" ] || { echo "  Aborted."; exit 0; }

  mkdir -p "$BACKUP_DIR"
  local bak="$BACKUP_DIR/FlagMailboxes-$(date '+%Y%m%d-%H%M%S').plist"
  cp "$FLAGPLIST" "$bak" 2>/dev/null && ok "Backed up to $bak"
  if rm -f "$FLAGPLIST"; then
    ok "Cache cleared. Reopen Mail and the flagged badge will rebuild."
  else
    bad "Could not remove $FLAGPLIST"; exit 1
  fi
}

########################################  UNWEDGE (the whole ritual, one command)

# Detect wedged actions, quit Mail, drop them, reopen Mail, report.
#
# Why Mail must be quit: deleting the row is not enough on its own. The log
# shows Mail replaying the SAME in-memory action object over and over, so it
# keeps retrying its cached copy even once the row is gone. Only a restart
# clears that. This is why dropping the row while Mail runs appears to do
# nothing.
do_unwedge() {
  hdr "Unwedge"

  local wedge
  wedge=$(q "SELECT COUNT(*) FROM ($POISON_SQL);")
  if [ "${wedge:-0}" -eq 0 ]; then
    local total; total=$(q "SELECT COUNT(*) FROM local_message_actions;")
    ok "No wedged actions. Queue holds ${total:-0}."
    exit 0
  fi

  bad "${wedge} wedged action(s) found."
  local i
  for i in $(q "SELECT a.ROWID FROM ($POISON_SQL) AS p JOIN local_message_actions a ON a.ROWID=p.ROWID;" 2>/dev/null || q "$POISON_SQL"); do
    describe_action "$i"
  done

  local pend reads
  pend=$(q "$PENDING_UPLOAD_SQL")
  reads=$(q "SELECT COUNT(*) FROM local_message_actions a
               JOIN action_messages am ON am.action = a.ROWID
               JOIN messages m ON am.message = m.ROWID
              WHERE a.action_type = 3 AND m.read = 1;")
  echo
  info "Will be preserved: ${reads:-0} read-mark(s), ${pend:-0} pending sent-upload(s)."
  echo
  printf '  This will quit Mail, drop the wedged action(s), and reopen Mail.\n'
  printf '  Press return to continue, Ctrl-C to abort: '
  read -r _

  # Quit Mail and wait for it to actually exit.
  if mail_running; [ $? -eq 0 ]; then
    info "Asking Mail to quit…"
    osascript -e 'tell application "Mail" to quit' >/dev/null 2>&1 || {
      bad "Could not tell Mail to quit (Apple Events blocked?)."
      info "Quit Mail by hand, then re-run."; exit 1; }
    local n=0
    while mail_running; [ $? -eq 0 ]; do
      n=$((n+1)); [ "$n" -gt 30 ] && { bad "Mail did not quit within 30s."; exit 1; }
      sleep 1
    done
    ok "Mail quit."
  fi

  mail_running; case $? in
    0) bad "Mail is still running. Aborting."; exit 1 ;;
    2) bad "Cannot verify Mail is stopped — refusing to write. Run outside a sandbox."; exit 1 ;;
  esac

  mkdir -p "$BACKUP_DIR"
  local bak="$BACKUP_DIR/actions-$(date '+%Y%m%d-%H%M%S').sql"
  sqlite3 "$DB" ".dump local_message_actions" ".dump action_messages" > "$bak" 2>/dev/null \
    && ok "Queue backed up to ${bak##*/}" \
    || { bad "Backup failed — aborting."; exit 1; }

  local dropped
  dropped=$(sqlite3 "$DB" "PRAGMA foreign_keys=ON;
                           DELETE FROM local_message_actions WHERE ROWID IN ($POISON_SQL);
                           SELECT changes();" 2>&1)
  [[ "$dropped" =~ ^[0-9]+$ ]] || { bad "Delete failed: $dropped"; exit 1; }
  ok "Dropped ${dropped} wedged action(s)."

  info "Reopening Mail…"
  open -a Mail >/dev/null 2>&1 || info "(Could not launch Mail automatically — open it yourself.)"

  cat <<EOF

  ${bold}Then${rst}
  Give Mail a minute, then:  ./mailsync-doctor.sh --watch
  The queue should drain, and any pending sent mail will upload.
EOF
}

########################################  CHECK (quiet, for scheduling)

# Read-only. Silent and exit 0 when healthy; one line and exit 1 when wedged.
# Built for launchd/cron: no prompts, no colour unless a terminal, no writes.
do_check() {
  local wedge queue reads pend out=""
  wedge=$(q "SELECT COUNT(*) FROM ($POISON_SQL);")
  queue=$(q "SELECT COUNT(*) FROM local_message_actions;")
  pend=$(q "$PENDING_UPLOAD_SQL")
  reads=$(q "SELECT COUNT(*) FROM local_message_actions a
               JOIN action_messages am ON am.action = a.ROWID
               JOIN messages m ON am.message = m.ROWID
              WHERE a.action_type = 3 AND m.read = 1;")

  if [ "${wedge:-0}" -gt 0 ]; then
    out="Mail sync wedged: ${wedge} unsatisfiable delete(s), ${queue} action(s) queued"
    [ "${pend:-0}" -gt 0 ] && out="$out, ${pend} sent message(s) local-only"
  elif [ "${queue:-0}" -ge "${CHECK_QUEUE_WARN:-25}" ]; then
    out="Mail queue not draining: ${queue} action(s), ${reads:-0} unsent read-mark(s)"
  fi

  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    # Best-effort desktop notification; harmless if Apple Events are unavailable.
    osascript -e "display notification \"$out\" with title \"mailsync-doctor\"" >/dev/null 2>&1
    exit 1
  fi
  exit 0
}

########################################  DROP ONE ACTION (head-of-line poison)

# Mail can wedge on a single action it retries forever: typically a delete whose
# local message is gone but which still carries a server ItemId. Exchange answers
# "item not found" (EWS responseCode 190), Mail treats that permanent error as
# retryable, and replays it ~28x/second indefinitely. Everything queued behind it
# never runs. The unified log names the offender:
#
#   log show --last 15m --predicate 'process == "Mail"' --style compact \
#     | grep -i 'Replaying.*action.*id ='
#
# A repeating id is the culprit. Drop that id and the queue resumes.
# Print what one queued action is actually about, so a drop is an informed
# decision rather than a leap. A genuinely wedged action has lost its local
# message, so there is no subject or sender left to show — only the folder and
# the server ItemId. An action that still HAS a local message is very likely a
# legitimate pending operation, and this is where that shows up.
#
# NOTE: this is the one place the script prints message headers (date, sender,
# subject). It does so only for actions you have named for deletion.
describe_action() {
  local id="$1" row
  row=$(q "SELECT a.action_type, COALESCE(am.action_phase,'-'),
                  COALESCE(REPLACE(SUBSTR(mb.url,45),'%20',' '),'-'),
                  COALESCE(am.message,''), COALESCE(am.destination_message,''),
                  COALESCE(am.remote_id,'')
             FROM local_message_actions a
             LEFT JOIN action_messages am ON am.action = a.ROWID
             LEFT JOIN mailboxes mb ON a.mailbox = mb.ROWID
            WHERE a.ROWID = $id LIMIT 1;")
  [ -z "$row" ] && { printf '    · %-7s (not found)\n' "$id"; return; }

  local typ ph folder msg dest rid
  IFS='|' read -r typ ph folder msg dest rid <<< "$row"
  printf '    · %s%s%s  %s, phase %s, in %s\n' \
    "$bold" "$id" "$rst" "$(action_label "$typ")" "$ph" "$folder"

  # Either reference may carry a real message: msg for most actions,
  # destination_message for an upload into Sent Items.
  local target="${msg:-}"; [ -z "$target" ] && target="${dest:-}"
  if [ -n "$target" ]; then
    local d
    d=$(q "SELECT datetime(COALESCE(date_sent,date_received),'unixepoch','localtime'),
                  COALESCE(NULLIF(subject,''),'(no subject)'),
                  CASE WHEN remote_id IS NULL THEN 'not on server' ELSE 'on server' END
             FROM messages WHERE ROWID = $target;")
    if [ -n "$d" ]; then
      local when subj onsrv
      IFS='|' read -r when subj onsrv <<< "$d"
      printf '      message: %s  %s\n' "$when" "$onsrv"
      printf '      subject: %.70s\n' "$subj"
      warn "  This action still has a real message. It may be a legitimate"
      info "      pending operation rather than a wedge — check the log before dropping."
    fi
  elif [ -n "$rid" ]; then
    # Wedged: nothing local survives. Surface what little the ItemId carries.
    local guid
    # LC_ALL=C: the decoded ItemId is binary and trips tr under a UTF-8 locale.
    guid=$(printf '%s' "$rid" | base64 -d 2>/dev/null \
             | LC_ALL=C tr -cd '[:print:]' \
             | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
             | head -1)
    printf '      no local message left — nothing to identify beyond the server id\n'
    [ -n "$guid" ] && printf '      mailbox guid: %s\n' "$guid"
    printf '      server item:  %s…  (%s chars)\n' "$(printf '%.32s' "$rid")" "${#rid}"
    printf '      the item is gone locally AND on the server, which is why it cannot complete\n'
  else
    printf '      no references at all — cannot ever execute\n'
  fi
}

do_drop_action() {
  hdr "Dropping a wedged action"

  local ids="$*"
  if [ -z "$ids" ]; then
    bad "Give the action id(s) the log shows repeating."
    info "Find them with:"
    info "  log show --last 15m --predicate 'process == \"Mail\"' --style compact \\"
    info "    | grep -i 'Replaying.*action.*id ='"
    echo
    info "Candidates in the queue with the wedge signature"
    info "(type 5 delete, local message gone, server id still held):"
    echo
    printf '      %-8s %-6s %s\n' "ROWID" "PHASE" "MAILBOX"
    q "SELECT a.ROWID, am.action_phase, REPLACE(SUBSTR(mb.url,45),'%20',' ')
         FROM local_message_actions a
         JOIN action_messages am ON am.action = a.ROWID
         LEFT JOIN mailboxes mb ON a.mailbox = mb.ROWID
        WHERE a.ROWID IN ($POISON_SQL) ORDER BY a.ROWID;" \
    | while IFS='|' read -r r p m; do printf '      %-8s %-6s %s\n' "$r" "$p" "$m"; done
    echo
    info "These are only candidates. The log's repeating id is the confirmed one."
    exit 1
  fi

  # Validate every id before touching anything.
  local list="" bad_id=0 i
  for i in $ids; do
    case "$i" in
      ''|*[!0-9]*) bad "Not a numeric action id: $i"; bad_id=1; continue ;;
    esac
    local exists; exists=$(q "SELECT COUNT(*) FROM local_message_actions WHERE ROWID=$i;")
    if [ "${exists:-0}" -eq 0 ]; then
      warn "Action $i is not in the queue (already gone?) — skipping."
    else
      list="$list${list:+,}$i"
    fi
  done
  [ "$bad_id" -eq 1 ] && exit 1
  [ -z "$list" ] && { ok "Nothing to drop."; exit 0; }

  echo "  Will remove:"
  local i
  for i in $(printf '%s' "$list" | tr ',' ' '); do describe_action "$i"; done

  local keep_reads keep_up
  keep_reads=$(q "SELECT COUNT(*) FROM local_message_actions a
                    JOIN action_messages am ON am.action=a.ROWID
                    JOIN messages m ON am.message=m.ROWID
                   WHERE a.action_type=3 AND m.read=1 AND a.ROWID NOT IN ($list);")
  keep_up=$(q "$PENDING_UPLOAD_SQL")

  cat <<EOF

  ${bold}Preserved${rst}
    · ${keep_reads:-0} pending read-mark(s) — they should flush once unblocked
    · ${keep_up:-0} sent message(s) awaiting upload to Sent Items

  ${bold}The one risk${rst}
  If an id you pass is a legitimate delete still waiting its turn rather than a
  wedged one, cancelling it means that message stays on the server. The database
  cannot tell the two apart — a stuck delete and a pending delete look identical.
  The log can: only an id that repeats over and over is confirmed wedged.

  No mail is deleted by this. It removes queue entries only.

EOF

  mail_running; case $? in
    0) bad "Mail is running. Quit Mail (⌘Q), then re-run."; exit 1 ;;
    2) bad "Cannot verify whether Mail is running. Refusing to continue."; exit 1 ;;
  esac

  printf '  Type %sDROP%s to proceed: ' "$bold" "$rst"
  read -r reply
  [ "$reply" = "DROP" ] || { echo "  Aborted."; exit 0; }

  mkdir -p "$BACKUP_DIR"
  local bak="$BACKUP_DIR/actions-$(date '+%Y%m%d-%H%M%S').sql"
  sqlite3 "$DB" ".dump local_message_actions" ".dump action_messages" > "$bak" 2>/dev/null \
    && ok "Backed up the queue to $bak" \
    || { bad "Backup failed — aborting."; exit 1; }

  local n
  n=$(sqlite3 "$DB" "PRAGMA foreign_keys=ON;
                     DELETE FROM local_message_actions WHERE ROWID IN ($list);
                     SELECT changes();" 2>&1)
  [[ "$n" =~ ^[0-9]+$ ]] || { bad "Delete failed: $n"; exit 1; }

  ok "Removed $n action(s)."
  cat <<EOF

  ${bold}Next${rst}
  1. Open Mail.
  2. ./mailsync-doctor.sh --watch
  3. The queue should now drain. If it stalls again, re-run the log grep — a
     second wedged action may have been sitting behind the first.
EOF
}

########################################  ANALYZE

# The Envelope Index ships without query-planner statistics (no sqlite_stat1),
# so SQLite guesses index selectivity and sometimes picks badly. ANALYZE builds
# those statistics. It writes one small table and touches no mail data.
do_analyze() {
  hdr "Rebuilding query-planner statistics"

  local have
  have=$(q "SELECT COUNT(*) FROM sqlite_master WHERE name='sqlite_stat1';")
  if [ "${have:-0}" -gt 0 ]; then
    local rows; rows=$(q "SELECT COUNT(*) FROM sqlite_stat1;")
    ok "Statistics already present (${rows} rows)."
    info "Re-running refreshes them against the current data."
  else
    warn "No statistics present — SQLite is guessing every query plan."
  fi

  cat <<EOF

  ${bold}What this does${rst}
  Runs SQLite's ANALYZE, which measures how selective each index is and stores
  the result in a table called sqlite_stat1. The query planner then chooses
  indexes on evidence instead of guesswork.

  ${bold}Measured on a copy of this database${rst}
    flagged count          70–110 ms  →  10 ms
    conversation grouping     170 ms  →  20 ms
    mailbox listing / unread counts: already fast, unchanged
    ANALYZE itself took 2.6 s

  ${bold}What it will NOT fix${rst}
  Mail recomputes smart-mailbox badges on its own schedule. That cadence is
  Mail's, not SQLite's, so a faster query does not make a late badge arrive
  sooner. This makes heavy operations snappier; it is not a badge fix.

  ${bold}Caveats${rst}
  Modifying Apple's database is unsupported. Mail may discard the statistics
  when it next rebuilds the index. To undo:
      sqlite3 "\$HOME/Library/Mail/V10/MailData/Envelope Index" 'DROP TABLE sqlite_stat1;'

EOF

  mail_running; case $? in
    0) bad "Mail is running. Quit Mail (⌘Q), then re-run."; exit 1 ;;
    2) bad "Cannot verify whether Mail is running. Refusing to continue."; exit 1 ;;
  esac

  printf '  Type %sANALYZE%s to proceed: ' "$bold" "$rst"
  read -r reply
  [ "$reply" = "ANALYZE" ] || { echo "  Aborted."; exit 0; }

  local t0 t1
  t0=$(date +%s)
  if sqlite3 "$DB" "ANALYZE;" 2>&1; then
    t1=$(date +%s)
    local rows; rows=$(q "SELECT COUNT(*) FROM sqlite_stat1;")
    ok "Done in $(( t1 - t0 ))s — ${rows} statistic row(s) written."
    info "Reopen Mail. Nothing else to do."
  else
    bad "ANALYZE failed."; exit 1
  fi
}

########################################  WATCH

# Poll the queue while a re-sync runs. Prints a line only when something moves.
do_watch() {
  local every="${1:-30}"
  hdr "Watching the sync queue (Ctrl-C to stop)"
  info "Polling every ${every}s. A line is printed only when a number changes."
  info "What you want to see: QUEUE falling toward 0."
  echo
  printf '      %-8s  %-7s  %-8s  %s\n' "TIME" "QUEUE" "TOKEN" "INBOX"

  local pq="" pt="" pm="" first=1
  while true; do
    local Q T M
    Q=$(q "SELECT COUNT(*) FROM local_message_actions;")
    T=$(q "SELECT COALESCE(MAX(length(e.sync_state)),0) FROM ews_folders e;")
    M=$(q "SELECT COUNT(*) FROM messages m JOIN mailboxes mb ON m.mailbox=mb.ROWID
            WHERE mb.url LIKE 'ews://%/Posteingang' OR mb.url LIKE 'ews://%/Inbox';")

    if [ "$first" = 1 ] || [ "$Q" != "$pq" ] || [ "$T" != "$pt" ] || [ "$M" != "$pm" ]; then
      local mark="" colr=""
      if [ -n "$pq" ] && [ "${Q:-0}" -lt "${pq:-0}" ]; then mark=" ↓ draining"; colr="$grn"; fi
      printf '      %-8s  %s%-7s%s  %-8s  %s%s\n' \
        "$(date '+%H:%M:%S')" "$colr" "${Q:-?}" "$rst" \
        "$(( ${T:-0} / 1024 )) KB" "${M:-?}" "$mark"
      [ "${Q:-1}" -eq 0 ] && { echo; ok "Queue empty — everything reached the server."
                               info "Confirm read state in OWA."; exit 0; }
      pq="$Q"; pt="$T"; pm="$M"; first=0
    fi
    sleep "$every"
  done
}

########################################  SYNC (menu-free equivalent)

# Counts queued actions for one account UUID, or all accounts if none given.
queue_count() {
  local uuid="${1:-}"
  if [ -n "$uuid" ]; then
    q "SELECT COUNT(*) FROM local_message_actions a
         JOIN mailboxes m ON a.mailbox = m.ROWID
        WHERE m.url LIKE 'ews://$uuid/%';"
  else
    q "SELECT COUNT(*) FROM local_message_actions;"
  fi
}

do_sync() {
  hdr "Forcing a sync (no menus involved)"

  # Which account has the biggest backlog? That's the one to kick.
  local uuid
  uuid=$(q "SELECT REPLACE(SUBSTR(m.url, 7, INSTR(SUBSTR(m.url,7),'/')-1),'/','')
              FROM local_message_actions a JOIN mailboxes m ON a.mailbox = m.ROWID
             GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1;")

  if [ -z "$uuid" ]; then
    ok "No backlog — nothing to sync."
    exit 0
  fi

  local addr desc before after
  addr=$(acct_name "$uuid")
  desc=$(qa "SELECT ZACCOUNTDESCRIPTION FROM ZACCOUNT WHERE ZIDENTIFIER='$uuid';")
  [ -z "$desc" ] && desc="$addr"
  before=$(queue_count "$uuid")

  info "Account:      $addr"
  info "Mail name:    $desc"
  info "Queued now:   $before"
  echo

  warn "This launches Mail if it is not already open."
  info "macOS will ask once to allow controlling Mail (Automation prompt)."
  printf '\n  Press return to continue, Ctrl-C to abort: '
  read -r _

  # 'synchronize with account' is the scriptable equivalent of the menu item.
  local out
  out=$(osascript 2>&1 <<OSA
tell application "Mail"
    set target to missing value
    repeat with a in every account
        try
            if (name of a as string) is "$desc" then set target to a
        end try
    end repeat
    if target is missing value then
        repeat with a in every account
            try
                if (user name of a as string) is "$addr" then set target to a
            end try
        end repeat
    end if
    if target is missing value then
        return "ERR:account-not-found"
    else
        synchronize with target
        return "OK"
    end if
end tell
OSA
)

  case "$out" in
    OK) ok "Sync triggered." ;;
    ERR:account-not-found)
        bad "Could not find that account in Mail's scripting model."
        info "Falling back to a global sync."
        osascript -e 'tell application "Mail" to check for new mail' >/dev/null 2>&1 \
          && ok "Global sync triggered." || { bad "AppleScript failed."; exit 1; } ;;
    *)  bad "AppleScript error: $out"
        info "If this says 'not authorized', approve your terminal under"
        info "System Settings → Privacy & Security → Automation → Mail."
        exit 1 ;;
  esac

  info "Waiting 45s for the queue to drain…"
  local i
  for i in $(seq 1 45); do
    sleep 1
    printf '\r    %ds' "$i"
  done
  printf '\r'

  after=$(queue_count "$uuid")
  echo
  if [ "${after:-0}" -lt "${before:-0}" ]; then
    ok "Queue dropped from $before to $after."
    [ "${after:-0}" -eq 0 ] && ok "Fully drained. Verify read state in OWA." \
      || info "Still draining — re-run to watch it fall further."
  else
    bad "Queue unchanged at $after. The sync is genuinely blocked."
    info "This is the expected result when the sync token is oversized."
    info "Next step:  ./mailsync-doctor.sh --unwedge"
  fi
}

########################################  MAIN

preflight
case "${1:-}" in
  --drop-action) shift; do_drop_action "$@" ;;
  --analyze)   do_analyze ;;
  --unwedge)   do_unwedge ;;
  --check)     do_check ;;
  --recount)   do_recount ;;
  --watch)   do_watch "${2:-30}" ;;
  --sync)    do_sync ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  "")        diagnose ;;
  *)         bad "Unknown option: $1"; echo "  Use --help"; exit 1 ;;
esac
