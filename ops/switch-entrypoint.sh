#!/bin/bash
# =============================================================================
# salvium-p2pool dual-mode entrypoint wrapper
#
# Reads the effective mode from /control/active and appends the mode-specific
# arguments to whatever the compose `command:` supplied, then hands off to the
# image's own entrypoint so the GitLab auto-update logic stays intact.
#
#   public   -> --data-dir .../public                       --p2p 0.0.0.0:38889
#   private  -> --data-dir .../private --sidechain-config .. --p2p 0.0.0.0:38888
#
# Switching modes is therefore: write /control/active, restart this container.
# Nothing here needs an image rebuild -- the script is bind-mounted from
# the repository's ops directory.
# =============================================================================
set -eu

P2POOL_HOME=/home/p2pool/.p2pool
CONTROL=/control
SIDECHAIN_CONFIG="$P2POOL_HOME/sidechain.json"

# ---------------------------------------------------------------------------
# Resolve the effective mode. Anything unrecognised falls back to public --
# public is the "home" mode, and PUBLIC-when-absent is the convention shared
# by every component (this wrapper, p2pool-watchdog.sh, salvium-mode), so an
# unmigrated deploy runs public CONSISTENTLY instead of split-brained. Only
# the migration script seeds these files (to private, explicitly).
# ---------------------------------------------------------------------------
ACTIVE="public"
if [ -r "$CONTROL/active" ]; then
    # tr, not `read`: read exits nonzero on a file with no trailing newline
    # even though it did populate the variable, which would clobber a valid
    # hand-written "private" back to "public".
    ACTIVE="$(tr -d '[:space:]' < "$CONTROL/active")"
    [ -n "$ACTIVE" ] || ACTIVE="public"
fi

case "$ACTIVE" in
    public|private)
        ;;
    *)
        echo "==> [switch] unrecognised mode '${ACTIVE}', defaulting to public"
        ACTIVE="public"
        ;;
esac

# ---------------------------------------------------------------------------
# Build the mode-specific arguments.
#
# The private branch refuses to start if sidechain.json is unreadable. p2pool
# panics with SIGSEGV on a missing config, which produces a silent restart
# loop -- failing loudly here makes the cause obvious in the logs instead.
# ---------------------------------------------------------------------------
case "$ACTIVE" in
    private)
        if [ ! -r "$SIDECHAIN_CONFIG" ]; then
            echo "==> [switch] FATAL: private mode requested but ${SIDECHAIN_CONFIG} is missing or unreadable."
            echo "==> [switch] Refusing to start (p2pool would crash-loop). Fix the file or switch to public mode."
            exit 1
        fi
        mkdir -p "$P2POOL_HOME/private"
        set -- "$@" \
            --data-dir "$P2POOL_HOME/private" \
            --sidechain-config "$SIDECHAIN_CONFIG" \
            --p2p 0.0.0.0:38888
        ;;
    public)
        mkdir -p "$P2POOL_HOME/public"
        set -- "$@" \
            --data-dir "$P2POOL_HOME/public" \
            --p2p 0.0.0.0:38889
        ;;
esac

echo "==> [switch] mode=${ACTIVE}  data-dir=${P2POOL_HOME}/${ACTIVE}"
exec /usr/local/bin/entrypoint.sh "$@"
