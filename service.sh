#!/system/bin/sh

# Dynamically locate the Magisk module directory
MODDIR=${0%/*}
LOG_FILE="$MODDIR/logging.txt"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

clone_attr() {
    local source_dir="$1"
    local target_dir="$2"
    local attrs=$(stat -Zc "%u %g %a %C" "$source_dir" 2>/dev/null)
    log_msg "[System] clone_attr ($attr) $source_dir -> $target_dir"
    local u_owner=$(echo "$attrs" | awk '{print $1}')
    local u_group=$(echo "$attrs" | awk '{print $2}')
    local u_perms=$(echo "$attrs" | awk '{print $3}')
    local u_context=$(echo "$attrs" | awk '{print $4}')
    chown "$u_owner":"$u_group" "$target_dir" 2>/dev/null
    chmod "$u_perms" "$target_dir" 2>/dev/null
    chcon "$u_context" "$target_dir" 2>/dev/null
}

log_msg "[System] Adoptable Storage AppData Binder service started."

# LAYER 2: Individual daemon monitoring app additions/removals per USER_ID
watch_user_id() {
    local u_id="$1"
    local u_path="$WATCH_DIR/$u_id"
    
    log_msg "[System] Initializing background monitor for USER_ID: $u_id"
    
    # Pre-scan and bind-mount existing application spaces upon unlock/insertion
    for DIR_PATH in "$u_path"/*; do
        [ -d "$DIR_PATH" ] || continue
        local dir_name=$(basename "$DIR_PATH")
        local target_dir="/data/user/$u_id/$dir_name"
        if ! mount | grep -q "$target_dir"; then
            mkdir -p "$target_dir"
            clone_attr "$DIR_PATH" "$target_dir"
            mount --bind "$DIR_PATH" "$target_dir"
            log_msg "[Boot Mount] Bound: $DIR_PATH -> $target_dir"
        fi
    done

    # Listen for structural changes inside this specific user storage pool
    inotifyd - "$u_path":nd | while read -r event parent_dir dir_name; do
        local target_dir="/data/user/$u_id/$dir_name"
        local source_dir="$parent_dir/$dir_name"

        # Lifecycle Check: Exit if user profile or host SD path vanishes abruptly
        if [ ! -d "$u_path" ] || [ ! -d "$CURRENT_EXPAND" ]; then
            log_msg "[System] USER_ID $u_id or core storage disconnected. Terminating child daemon."
            break 
        fi

        case "$event" in
            n) # New application installed
                if [ -d "$source_dir" ]; then
                    mkdir -p "$target_dir"
                    clone_attr "$source_dir" "$target_dir"
                    mount --bind "$source_dir" "$target_dir"
                    log_msg "[Event: Create] Dynamically bound: $source_dir -> $target_dir"
                fi
                ;;
            d) # Application uninstalled
                umount -l "$target_dir" 2>/dev/null
                log_msg "[Event: Delete] Cleaned up target mount point: $target_dir"
                ;;
        esac
    done &
}

# --- MAIN LIFECYCLE LOOP (Handles delayed decryption, Hot-Plugging, and Formats) ---
CURRENT_EXPAND=""

while true; do
    # Scan for any adoptable storage identifier
    DETECTED_SD=$(ls -d /mnt/expand/* 2>/dev/null | head -n 1)
    
    # Scenario 1: Device is locked (FBE encrypted) or SD card is missing entirely
    if [ -z "$DETECTED_SD" ] || [ "$DETECTED_SD" = "/mnt/expand/*" ] || [ ! -d "$DETECTED_SD/user" ]; then
        if [ -n "$CURRENT_EXPAND" ]; then
            log_msg "[Warning] Active Adoptable Storage lost or unmounted: $CURRENT_EXPAND"
            CURRENT_EXPAND=""
        fi
        sleep 4
        continue
    fi

    # Scenario 2: Storage unlocked, newly hot-plugged, or refreshed post-format (New UUID)
    if [ "$DETECTED_SD" != "$CURRENT_EXPAND" ]; then
        if [ -n "$CURRENT_EXPAND" ]; then
            log_msg "[System] Storage UUID shift detected from $CURRENT_EXPAND to $DETECTED_SD"
        fi

        CURRENT_EXPAND="$DETECTED_SD"
        WATCH_DIR="$CURRENT_EXPAND/user"
        log_msg "[Success] Verified active Adoptable Storage at: $CURRENT_EXPAND"

        # Clean out stale inotify processes bound to this scope to prevent process leaks
        pkill -f "inotifyd - $WATCH_DIR" 2>/dev/null 

        # Fire up Layer 2 monitors for existing localized profiles (e.g. User 0)
        for USER_PATH in "$WATCH_DIR"/*; do
            [ -d "$USER_PATH" ] || continue
            USER_ID=$(basename "$USER_PATH")
            watch_user_id "$USER_ID"
        done

        # LAYER 1: Core supervisor watching for newly spawned profiles (e.g., Dual Space / Second Space)
        inotifyd - "$WATCH_DIR":nd | while read -r event parent_dir dir_name; do
            if [ ! -d "$CURRENT_EXPAND" ]; then break; fi

            if [ "$event" = "n" ]; then
                # Give Android framework a brief window to complete profile directories creation
                sleep 2
                if [ -d "$WATCH_DIR/$dir_name" ]; then
                    log_msg "[System] Dynamic profile/space detected: $dir_name"
                    watch_user_id "$dir_name"
                fi
            fi
        done &
    fi

    # Heartbeat check every 5 seconds to ensure system tracking integrity
    sleep 5
done