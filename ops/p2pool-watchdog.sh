#!/bin/sh
# =============================================================================
# salvium-p2pool mode watchdog  (v4 — restricted host control)
#
# Keeps p2pool on the PUBLIC sidechain ("home") and falls back to the PRIVATE
# sidechain when public stops earning, then returns once public is healthy
# again. Mining continues either way -- the stratum port never changes, so the
# rigs are unaware a switch happened.
#
# CONTROL FILES  (/control, bind-mounted, also readable from Y:\)
#   mode            auto | public | private   -- what YOU want
#                     auto    = watchdog decides
#                     public  = pinned, watchdog will not move it
#                     private = pinned, watchdog will not move it
#   active          public | private          -- what is running RIGHT NOW
#                     written by this watchdog (and salvium-mode), read by
#                     switch-entrypoint.sh at container start
#   state.json      current status + PERSISTED decision timers (epochs).
#                     Reloaded at startup so a watchdog restart does not
#                     forget an outage in progress or grant a fresh dwell.
#   switch.log      append-only history of every mode change
#   public-peers.txt  probe targets, one host:port per line (# = comment).
#                     CR/whitespace is stripped, so Windows edits are safe.
#
# When mode/active files are ABSENT the convention everywhere (this script,
# switch-entrypoint.sh, salvium-mode) is PUBLIC. The migration script seeds
# them to private explicitly; the watchdog itself never seeds files.
#
# HEALTH MODEL
#   public mode   unhealthy if the container is crash-looping (including an
#                 intermittent crash pattern -- 3+ crashes chained within
#                 CRASH_WINDOW keep the verdict bad between crashes), stats go
#                 stale, peer count hits 0, or the sidechain height stops
#                 advancing. Sustained FAIL_AFTER -> fall back to private.
#   private mode  the same container-level checks apply; sustained failure
#                 triggers a REMEDIAL RESTART in place (never a mode switch).
#                 Public recovery is judged by TCP-probing known public peers
#                 (static list + the live public/p2pool_peers.txt p2pool
#                 maintains, merged, deduped, capped, probed in parallel).
#                 Once the probe has passed RECOVER_AFTER (scaled by an
#                 exponential backoff after failed trials), do a TRIAL return.
#
#   A trial passes only if the public sidechain height ADVANCES at least
#   twice during the window (measured from stats written after the switch),
#   with one automatic window extension for slow syncs / collided restarts.
#   A failed trial increments the backoff counter; a pass resets it.
#
#   DWELL enforces a minimum time in any mode. Timers are persisted to
#   state.json and reloaded on start, so restarts of this watchdog neither
#   reset an outage clock nor bypass anti-flap.
# =============================================================================
set -u

BROKER_CLIENT_FILE=${BROKER_CLIENT_FILE:-/ops/request-docker-restart.sh}
if [ ! -r "$BROKER_CLIENT_FILE" ]; then
    echo "watchdog: broker client is unavailable: $BROKER_CLIENT_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$BROKER_CLIENT_FILE"

CONTROL=${CONTROL_DIR:-/control}
STATS=${STATS_DIR:-/stats}
LIVE_PEERS=${LIVE_PEERS_DIR:-/peers-live}
PRIVATE_PEERS_FILE=${PRIVATE_PEERS_FILE:-/private-peers/p2pool_peers.txt}
TARGET=${TARGET_CONTAINER:-salvium-p2pool}

CHECK_INTERVAL=${CHECK_INTERVAL:-60}      # seconds between evaluations
FAIL_AFTER=${FAIL_AFTER:-900}             # 15m unhealthy  -> act
RECOVER_AFTER=${RECOVER_AFTER:-1800}      # 30m probe-good -> trial return
DWELL=${DWELL:-3600}                      # 1h minimum in a mode
TRIAL_WINDOW=${TRIAL_WINDOW:-300}         # 5m for a trial to prove itself
STALE_STATS=${STALE_STATS:-300}           # stats older than this = unhealthy
HEIGHT_STALL=${HEIGHT_STALL:-600}         # height frozen this long = unhealthy
PROBE_MIN_OK=${PROBE_MIN_OK:-2}           # peers that must answer for a pass
PRIVATE_PROBE_MIN_OK=${PRIVATE_PROBE_MIN_OK:-1}
PROBE_MAX=${PROBE_MAX:-24}                # cap on probe targets per pass
CRASH_WINDOW=${CRASH_WINDOW:-1800}        # crashes within this chain a streak

now() { date +%s; }
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[watchdog $(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# Tiny JSON scalar reader (no jq dependency). Tolerates optional whitespace
# after the colon so it can read both p2pool's compact stats and our own
# state.json.
# ---------------------------------------------------------------------------
json_num() {  # json_num <file> <regex-anchored-key>
    [ -r "$1" ] || { echo ""; return; }
    sed -n "s/.*$2:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" 2>/dev/null | head -1
}

peers()      { json_num "$STATS/local/p2p"   '[{,]"connections"'; }
sc_height()  { json_num "$STATS/pool/stats"  '"sidechainHeight"'; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

# The root-owned host broker publishes only P2Pool status and restart count.
# The watchdog has no Docker socket and treats a missing/stale snapshot as an
# unknown container state.
dk_state() {  # sets DK_STATUS / DK_RESTARTS
    if broker_read_p2pool_state; then
        DK_STATUS=$BROKER_CONTAINER_STATUS
        DK_RESTARTS=$BROKER_CONTAINER_RESTARTS
    else
        DK_STATUS=unknown
        DK_RESTARTS=-1
    fi
}

read_ctl() {  # read_ctl <file> <default>
    if [ -r "$CONTROL/$1" ]; then
        _v=$(tr -d '[:space:]' < "$CONTROL/$1")
        [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
    else
        printf '%s' "$2"
    fi
}

still_auto() { [ "$(read_ctl mode public)" = "auto" ]; }

# ---------------------------------------------------------------------------
# TCP-probe the public p2pool peer set: the hand-maintained control list
# MERGED with the live peer list p2pool itself maintains whenever public mode
# runs. Lines are whitespace/CR-stripped (Windows-edit safe), deduped, capped
# at PROBE_MAX, and probed in PARALLEL so a fully-dead list costs ~3s, not
# 3s per target. Requires PROBE_MIN_OK successes.
# ---------------------------------------------------------------------------
probe_public() {
    _list=$( { cat "$CONTROL/public-peers.txt" 2>/dev/null; \
               cat "$LIVE_PEERS/p2pool_peers.txt" 2>/dev/null; } \
             | sed 's/[[:space:]]//g' | grep -v '^#' | grep -v '^$' \
             | sort -u | head -n "$PROBE_MAX" )
    [ -n "$_list" ] || return 1
    _tmp=$(mktemp /tmp/probe.XXXXXX) || return 1
    for _t in $_list; do
        _h=${_t%:*}
        _p=${_t##*:}
        [ -n "$_h" ] && [ -n "$_p" ] && [ "$_h" != "$_p" ] || continue
        ( nc -z -w 3 "$_h" "$_p" >/dev/null 2>&1 && echo ok >> "$_tmp" ) &
    done
    wait
    _ok=$(wc -l < "$_tmp" 2>/dev/null | tr -d ' ')
    rm -f "$_tmp"
    [ "${_ok:-0}" -ge "$PROBE_MIN_OK" ]
}

# Do not automatically leave a degraded public instance for a private
# sidechain that has no reachable peer. Manual private pinning remains
# available for planned maintenance and first-time peer bootstrap work.
probe_private() {
    _list=$(sed 's/[[:space:]]//g' "$PRIVATE_PEERS_FILE" 2>/dev/null \
             | grep -v '^#' | grep -v '^$' | sort -u | head -n "$PROBE_MAX")
    [ -n "$_list" ] || return 1
    _tmp=$(mktemp /tmp/private-probe.XXXXXX) || return 1
    for _t in $_list; do
        _h=${_t%:*}
        _p=${_t##*:}
        [ -n "$_h" ] && [ -n "$_p" ] && [ "$_h" != "$_p" ] || continue
        ( nc -z -w 3 "$_h" "$_p" >/dev/null 2>&1 && echo ok >> "$_tmp" ) &
    done
    wait
    _ok=$(wc -l < "$_tmp" 2>/dev/null | tr -d ' ')
    rm -f "$_tmp"
    [ "${_ok:-0}" -ge "$PRIVATE_PROBE_MIN_OK" ]
}

# ---------------------------------------------------------------------------
# Health of the CURRENTLY ACTIVE mode. Sets $VERDICT to "ok" or a reason.
#
# Called bare, never as $(assess ...) -- command substitution would run it in
# a subshell and silently discard the state updates below.
#
# Crash accounting: crashes chained within CRASH_WINDOW build crash_count;
# at >=3 the verdict STAYS bad between crashes (until FAIL_AFTER of quiet),
# so an intermittent crash cycle accumulates unhealthy time instead of being
# reset by every healthy-looking sample between crashes.
#
# Warm-up: right after a restart we initiated, stats predate the instance;
# they are neither trusted nor flagged stale until STALE_STATS has passed.
# ---------------------------------------------------------------------------
VERDICT=ok
assess() {  # assess <mode>  -> sets $VERDICT
    _mode=$1
    dk_state
    _crash=0
    if [ "$DK_STATUS" = "restarting" ]; then
        VERDICT="container restarting (crash-loop)"; _crash=1
    elif [ "$DK_STATUS" != "running" ]; then
        VERDICT="container status=$DK_STATUS"; _crash=1
    elif [ "$last_restarts" -ge 0 ] && [ "$DK_RESTARTS" -gt "$last_restarts" ]; then
        VERDICT="restart count rose to ${DK_RESTARTS} (crashed)"; _crash=1
    fi
    last_restarts=$DK_RESTARTS

    if [ "$_crash" -eq 1 ]; then
        if [ "$last_crash" -ne 0 ] && [ $(( $(now) - last_crash )) -le "$CRASH_WINDOW" ]; then
            crash_count=$((crash_count + 1))
        else
            crash_count=1
        fi
        last_crash=$(now)
        return
    fi

    # container looks fine right now -- but keep an intermittent-crash streak
    # visible until it has been quiet for a while (review finding D6)
    if [ "$crash_count" -ge 3 ] && [ "$last_crash" -ne 0 ] && [ $(( $(now) - last_crash )) -lt "$FAIL_AFTER" ]; then
        VERDICT="intermittent crash loop (${crash_count} crashes, last $(( $(now) - last_crash ))s ago)"
        return
    fi
    if [ "$last_crash" -ne 0 ] && [ $(( $(now) - last_crash )) -ge $(( FAIL_AFTER * 2 )) ]; then
        crash_count=0; last_crash=0
    fi

    _mt=$(file_mtime "$STATS/local/p2p")
    if [ "$_mt" -le "$last_start" ]; then
        # stats predate the current instance (we just restarted it)
        if [ $(( $(now) - last_start )) -le "$STALE_STATS" ]; then
            VERDICT="ok"   # warming up -- do not judge the old file
            return
        fi
        VERDICT="no stats written since start $(( $(now) - last_start ))s ago"
        return
    fi
    _age=$(( $(now) - _mt ))
    if [ "$_age" -gt "$STALE_STATS" ]; then
        VERDICT="stats stale (${_age}s old)"
        return
    fi

    if [ "$_mode" = "public" ]; then
        _p=$(peers)
        [ -n "$_p" ] || _p=0
        if [ "$_p" -eq 0 ]; then
            VERDICT="zero p2pool peers"
            return
        fi
        _h=$(sc_height)
        [ -n "$_h" ] || _h=0
        if [ "$_h" -ne "$last_height" ]; then
            last_height=$_h
            last_height_change=$(now)
        elif [ $(( $(now) - last_height_change )) -gt "$HEIGHT_STALL" ]; then
            VERDICT="sidechain height frozen at $_h for $(( $(now) - last_height_change ))s"
            return
        fi
    fi

    VERDICT=ok
}

# ---------------------------------------------------------------------------
# Perform a switch. Returns 0 on success. On restart FAILURE the active file
# is REVERTED so it keeps describing the container that is actually running,
# and no timers are reset -- the caller's state is preserved for a retry
# (review finding D2).
# ---------------------------------------------------------------------------
switch_to() {  # switch_to <mode> <reason>
    _to=$1; _why=$2; _from=$active
    log "SWITCHING ${_from} -> ${_to}: ${_why}"
    printf '%s\n' "$_to" > "$CONTROL/active"
    if broker_restart "watchdog mode switch ${_from} -> ${_to}"; then
        printf '%s  %-7s  %s\n' "$(ts)" "$_to" "$_why" >> "$CONTROL/switch.log"
        active=$_to
        known_active=$_to
        last_switch=$(now)
        last_start=$(now)
        unhealthy_since=0
        probe_ok_since=0
        trial_advances=0
        trial_prev_h=""
        trial_extended=0
        dk_state; last_restarts=$DK_RESTARTS
        last_height=0
        last_height_change=$(now)
        return 0
    fi
    printf '%s\n' "$_from" > "$CONTROL/active"
    printf '%s  %-7s  %s\n' "$(ts)" "$_from" "REVERTED: restricted host restart failed during switch to ${_to}" >> "$CONTROL/switch.log"
    log "ERROR: restricted restart of $TARGET failed -- active reverted to ${_from}; will retry"
    return 1
}

# ---------------------------------------------------------------------------
# state.json: status for humans + persisted timers for our own restarts.
# Skips the write when nothing meaningful changed (review finding D12), with
# a heartbeat write every 10 iterations so `updated` stays a liveness signal.
# ---------------------------------------------------------------------------
STATE_SIG=""
state_tick=0
write_state() {  # write_state <health> <detail>
    state_tick=$(( (state_tick + 1) % 10 ))
    _sig="$desired|$active|$1|$2|$last_switch|$last_start|$unhealthy_since|$probe_ok_since|$trial_started|$trial_fail_count"
    [ "$_sig" = "$STATE_SIG" ] && [ "$state_tick" -ne 0 ] && return
    STATE_SIG=$_sig
    cat > "$CONTROL/state.json" <<EOF
{
  "updated": "$(ts)",
  "desired_mode": "$desired",
  "active_mode": "$active",
  "health": "$1",
  "detail": "$2",
  "seconds_in_mode": $(( $(now) - last_switch )),
  "unhealthy_for": $( [ "$unhealthy_since" -eq 0 ] && echo 0 || echo $(( $(now) - unhealthy_since )) ),
  "probe_ok_for": $( [ "$probe_ok_since" -eq 0 ] && echo 0 || echo $(( $(now) - probe_ok_since )) ),
  "trial_active": $( [ "$trial_started" -eq 0 ] && echo false || echo true ),
  "trial_fail_count": $trial_fail_count,
  "last_switch_epoch": $last_switch,
  "last_start_epoch": $last_start,
  "unhealthy_since_epoch": $unhealthy_since,
  "probe_ok_since_epoch": $probe_ok_since,
  "trial_started_epoch": $trial_started,
  "thresholds": { "fail_after": $FAIL_AFTER, "recover_after": $RECOVER_AFTER, "dwell": $DWELL, "trial_window": $TRIAL_WINDOW }
}
EOF
}

# ---------------------------------------------------------------------------
# Bootstrap. No file seeding (the migration seeds private explicitly; absent
# files mean PUBLIC everywhere -- review finding D1). Timers reload from
# state.json so a watchdog restart forgets nothing (review finding D4).
# ---------------------------------------------------------------------------
mkdir -p "$CONTROL"
active=$(read_ctl active public)
desired=$(read_ctl mode public)
known_active=$active

S="$CONTROL/state.json"
last_switch=$(json_num "$S" '"last_switch_epoch"');       [ -n "$last_switch" ] || last_switch=$(now)
last_start=$(json_num "$S" '"last_start_epoch"');         [ -n "$last_start" ] || last_start=0
unhealthy_since=$(json_num "$S" '"unhealthy_since_epoch"'); [ -n "$unhealthy_since" ] || unhealthy_since=0
probe_ok_since=$(json_num "$S" '"probe_ok_since_epoch"'); [ -n "$probe_ok_since" ] || probe_ok_since=0
trial_fail_count=$(json_num "$S" '"trial_fail_count"');   [ -n "$trial_fail_count" ] || trial_fail_count=0
_prev_trial=$(json_num "$S" '"trial_started_epoch"');     [ -n "$_prev_trial" ] || _prev_trial=0

trial_started=0
trial_advances=0
trial_prev_h=""
trial_extended=0
crash_count=0
last_crash=0
dk_state; last_restarts=$DK_RESTARTS
last_height=0
last_height_change=$(now)

if [ "$_prev_trial" -ne 0 ] && [ "$active" = "public" ] && [ "$desired" = "auto" ]; then
    trial_started=$(now)   # interrupted mid-trial: re-arm a fresh window
    log "resuming interrupted trial return with a fresh ${TRIAL_WINDOW}s window"
fi

log "started -- desired=${desired} active=${active} (absent files default to public)"
log "timers: in-mode $(( $(now) - last_switch ))s, unhealthy_since=${unhealthy_since}, probe_ok_since=${probe_ok_since}, trial_fails=${trial_fail_count}"
log "thresholds: fail_after=${FAIL_AFTER}s recover_after=${RECOVER_AFTER}s dwell=${DWELL}s trial_window=${TRIAL_WINDOW}s"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do
    desired=$(read_ctl mode public)
    active=$(read_ctl active public)

    # someone else (salvium-mode) switched the container: adopt reality and
    # restart the anti-flap clocks so a fresh manual switch is respected
    if [ "$active" != "$known_active" ]; then
        log "external mode change detected (${known_active} -> ${active}) -- adopting"
        known_active=$active
        last_switch=$(now)
        last_start=$(now)
        unhealthy_since=0
        probe_ok_since=0
        trial_started=0
    fi

    case "$desired" in
        public|private)
            if [ "$active" != "$desired" ]; then
                switch_to "$desired" "pinned to ${desired} via mode file" \
                    || log "pin enforcement failed -- retrying next cycle"
            fi
            trial_started=0
            trial_fail_count=0
            write_state "pinned" "mode file pins ${desired}; watchdog will not switch"
            sleep "$CHECK_INTERVAL"
            continue
            ;;
        auto) ;;
        *)
            log "unrecognised mode '${desired}' -- treating as 'auto'"
            desired=auto
            ;;
    esac

    assess "$active"
    verdict=$VERDICT
    dwell_ok=$([ $(( $(now) - last_switch )) -ge "$DWELL" ] && echo yes || echo no)

    # ---- trial return in progress (public must PROVE it syncs) ------------
    if [ "$trial_started" -ne 0 ]; then
        elapsed=$(( $(now) - trial_started ))
        _mt=$(file_mtime "$STATS/pool/stats")
        if [ "$_mt" -gt "$trial_started" ]; then
            _h=$(sc_height); [ -n "$_h" ] || _h=0
            if [ -n "$trial_prev_h" ] && [ "$_h" -gt "$trial_prev_h" ]; then
                trial_advances=$((trial_advances + 1))
            fi
            trial_prev_h=$_h
        fi
        if [ "$elapsed" -lt "$TRIAL_WINDOW" ]; then
            log "trial: ${elapsed}/${TRIAL_WINDOW}s advances=${trial_advances} (${verdict})"
            write_state "trial" "$verdict"
        else
            dk_state
            if [ "$trial_advances" -ge 2 ] && [ "$DK_STATUS" = "running" ]; then
                log "trial SUCCEEDED: sidechain advanced ${trial_advances}x in ${elapsed}s -- staying on public"
                printf '%s  %-7s  %s\n' "$(ts)" "public" "trial confirmed (${trial_advances} advances)" >> "$CONTROL/switch.log"
                trial_started=0
                trial_fail_count=0
                unhealthy_since=0
                write_state "healthy" "trial passed"
            elif [ "$trial_extended" -eq 0 ]; then
                # one free extension: slow first sync, or an updater restart
                # collided with the window (review findings D3/D9)
                trial_extended=1
                trial_started=$(now)
                log "trial inconclusive (advances=${trial_advances}, ${verdict}) -- extending one more window"
                write_state "trial" "extended: ${verdict}"
            else
                trial_started=0
                trial_fail_count=$((trial_fail_count + 1))
                if probe_private; then
                    switch_to private "trial return failed (advances=${trial_advances}, ${verdict}) fail#${trial_fail_count}" \
                        || log "fallback after failed trial ALSO failed to restart -- retrying next cycle"
                    write_state "fallback" "trial failed (${verdict})"
                else
                    unhealthy_since=$(now)
                    log "trial failed, but private peers are unavailable -- holding public"
                    write_state "degraded" "trial failed; private peers unavailable"
                fi
            fi
        fi
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ---- steady state ------------------------------------------------------
    if [ "$active" = "public" ]; then
        if [ "$verdict" = "ok" ]; then
            [ "$unhealthy_since" -ne 0 ] && log "public recovered on its own -- clearing timer"
            unhealthy_since=0
            write_state "healthy" "public mining normally"
        else
            [ "$unhealthy_since" -eq 0 ] && { unhealthy_since=$(now); log "public unhealthy: ${verdict}"; }
            bad_for=$(( $(now) - unhealthy_since ))
            if [ "$bad_for" -ge "$FAIL_AFTER" ] && [ "$dwell_ok" = "yes" ] && still_auto; then
                if probe_private; then
                    switch_to private "public unhealthy ${bad_for}s (${verdict})" \
                        || log "fallback switch failed -- retrying next cycle"
                    write_state "fallback" "left public: ${verdict}"
                else
                    log "public unhealthy, but private peers are unavailable -- holding public"
                    write_state "degraded" "${verdict}; private peers unavailable"
                fi
            else
                log "public unhealthy ${bad_for}/${FAIL_AFTER}s (${verdict}) dwell_ok=${dwell_ok}"
                write_state "degraded" "$verdict"
            fi
        fi
    else
        # active=private. The fallback miner itself must not rot (finding D5):
        # container-level ill health earns a remedial restart in place.
        if [ "$verdict" != "ok" ]; then
            [ "$unhealthy_since" -eq 0 ] && { unhealthy_since=$(now); log "private instance unhealthy: ${verdict}"; }
            bad_for=$(( $(now) - unhealthy_since ))
            if [ "$bad_for" -ge "$FAIL_AFTER" ]; then
                log "private instance unhealthy ${bad_for}s (${verdict}) -- remedial restart in place"
                printf '%s  %-7s  %s\n' "$(ts)" "private" "REMEDIAL restart: ${verdict}" >> "$CONTROL/switch.log"
                if broker_restart "watchdog remedial private-mode restart"; then
                    unhealthy_since=0
                    last_start=$(now)
                    dk_state; last_restarts=$DK_RESTARTS
                else
                    log "remedial restricted restart failed -- will retry"
                fi
            fi
            write_state "degraded-private" "$verdict"
        else
            unhealthy_since=0
            # exponential backoff on the recovery clock after failed trials
            _mult=1
            [ "$trial_fail_count" -ge 1 ] && _mult=2
            [ "$trial_fail_count" -ge 2 ] && _mult=4
            [ "$trial_fail_count" -ge 3 ] && _mult=8
            eff_recover=$(( RECOVER_AFTER * _mult ))
            if probe_public; then
                [ "$probe_ok_since" -eq 0 ] && { probe_ok_since=$(now); log "public peers reachable -- starting recovery clock (need ${eff_recover}s)"; }
                good_for=$(( $(now) - probe_ok_since ))
                if [ "$good_for" -ge "$eff_recover" ] && [ "$dwell_ok" = "yes" ] && still_auto; then
                    if switch_to public "probe healthy ${good_for}s -- trial return (attempt #$((trial_fail_count + 1)))"; then
                        trial_started=$(now)
                    fi
                    write_state "trial" "trial return started"
                else
                    log "probe ok ${good_for}/${eff_recover}s dwell_ok=${dwell_ok} -- holding private"
                    write_state "fallback" "probe ok, waiting to return"
                fi
            else
                [ "$probe_ok_since" -ne 0 ] && log "public peers unreachable again -- resetting recovery clock"
                probe_ok_since=0
                write_state "fallback" "public unreachable; mining private"
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
