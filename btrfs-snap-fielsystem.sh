#!/bin/bash
display_help() {
    echo "Usage: $0 [OPTIONS] MOUNTPOINT SNAPSHOT_DIR TARGET_DIR"
    echo
    echo "Create and send Btrfs snapshots."
    echo
    echo "Options:"
    echo "  -s SECONDS   Set the threshold in seconds. If a snapshot was taken or sent less than this many seconds ago, skip the operation."
    echo "  -t MINUTES   Set the threshold in minutes. If a snapshot was taken or sent less than this many minutes ago, skip the operation."
    echo "  -h, --help   Display this help message and exit."
    echo
    echo "Arguments:"
    echo "  MOUNTPOINT   Btrfs mount point."
    echo "  SNAPSHOT_DIR Directory where local snapshots will be stored."
    echo "  TARGET_DIR   Directory on the target Btrfs drive where snapshots will be received."
    exit 1
}

# Find parent snapshot
find_parent_snapshot() {
    local subvolume_path="$1"
    local parent_snapshot=""
    local parent_timestamp=""
    
    snapshot_info=$(sudo btrfs subvolume show "$subvolume_path")
    
    # Extract snapshots from snapshot_info
    snapshots=$(echo "$snapshot_info" | grep "full-" | awk '{print $NF}')
    
    for snapshot in $snapshots; do
        snapshot_timestamp=$(echo "$snapshot" | grep -oE '[0-9]{14}')
        
        if [ -z "$parent_snapshot" ] || [ "$snapshot_timestamp" -gt "$parent_timestamp" ]; then
            parent_snapshot="$snapshot"
            parent_timestamp="$snapshot_timestamp"
        fi
    done
    
    echo "$parent_snapshot"
}

    # Function to send snapshot and handle success/failure
send_snapshot() {
    local source_snapshot="$1"
    local target_subvolume="$2"
    local parent="$3"
    
    if [ -n "$parent" ]; then
        if sudo btrfs send -p "$parent" "$source_snapshot" | pv -s "$(du -sb "$source_snapshot" | awk '{print $1}')" | sudo btrfs receive "$target_subvolume"; then
            echo "Incremental Snapshot of $SUBVOLUME_PATH from $PARENT_SNAPSHOT sent to $TARGET_DIR"
            return 0
        else
            echo "Sending snapshot failed."
            return 1
        fi
    else
        if sudo btrfs send "$source_snapshot" | pv -s "$(du -sb "$source_snapshot" | awk '{print $1}')" | sudo btrfs receive "$target_subvolume"; then
            echo "Snapshot of $SUBVOLUME_PATH sent to $TARGET_DIR"
            return 0
        else
            echo "Sending snapshot failed."
            return 1
        fi
    fi
}

if [ $# -lt 3 ]; then
    echo "Error: Insufficient arguments provided."
    display_help
fi

# Check if the script is run as root, if not, re-run it with sudo
if [ "$EUID" -ne 0 ]; then
    sudo "$0" "$@"
    exit $?
fi
START_TIME=$(date +%s)



THRESHOLD_SECONDS=300  # Default to 5 minutes
IGNORE_READ_ONLY=true
IGNORE_SNAPSHOT_DIR=true




# Parse command line options for -s, -t, -r, and -h
while getopts ":s:t:wh-" opt; do
  case $opt in
    s)
      THRESHOLD_SECONDS="$OPTARG"
      ;;
    t)
      THRESHOLD_SECONDS=$((OPTARG * 60))
      ;;
    w)
      IGNORE_READ_ONLY=false
      ;;
    h)
      display_help
      exit 0
      ;;
    -)
      case "$OPTARG" in
        help)
          display_help
          exit 0
          ;;
        *)
          echo "Invalid option: --$OPTARG" >&2
          exit 1
          ;;
      esac
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

# Shift to get the remaining arguments after parsing options
shift $((OPTIND-1))

MOUNTPOINT="$1"  # Btrfs mount point
SNAPSHOT_DIR="$2"  # Directory where local snapshots will be stored
TARGET_DIR="$3"  # Directory on the target Btrfs drive where snapshots will be received

# Ensure snapshot and target directories exist
mkdir -p "$SNAPSHOT_DIR"
mkdir -p "$TARGET_DIR"
DIFF_SUBVOLUMES=$(comm -23 <(sudo btrfs subvolume list "$MOUNTPOINT" | awk '{print $NF}' | sort) <(sudo btrfs subvolume list -r "$MOUNTPOINT" | awk '{print $NF}' | sort))
echo $DIFF_SUBVOLUMES
# List all subvolumes and create a snapshot for each one
for SUBVOLUME_PATH in $DIFF_SUBVOLUMES; do

    echo $SUBVOLUME_PATH
    echo $SNAPSHOT_DIR
   
    # Determine the most recent snapshot (parent)
    
    PARENT_SNAPSHOT=$(find_parent_snapshot "$MOUNTPOINT/$SUBVOLUME_PATH")
    echo $PARENT_SNAPSHOT
    FULL_PATH_PARENT_SNAPSHOT="$MOUNTPOINT/$PARENT_SNAPSHOT"
  
    # Create a snapshot name based on the subvolume name and current timestamp
    TIMESTAMP=$(date "+%Y%m%d%H%M%S")
    SNAPSHOT_NAME=$(basename $SUBVOLUME_PATH)_$TIMESTAMP
    
    # Create the directory structure within the snapshot directory
    SNAPSHOT_PATH="$SNAPSHOT_DIR/$(dirname $SUBVOLUME_PATH)"
    TARGET_SUBVOLUME_PATH="$TARGET_DIR/$(dirname $SUBVOLUME_PATH)"
    mkdir -p "$SNAPSHOT_PATH"
    mkdir -p "$TARGET_SUBVOLUME_PATH"
    
    # Create the snapshot
    sudo btrfs subvolume snapshot -r "$MOUNTPOINT/$SUBVOLUME_PATH" "$SNAPSHOT_PATH/$SNAPSHOT_NAME"
    echo "Local snapshot of $SUBVOLUME_PATH created as $SNAPSHOT_PATH/$SNAPSHOT_NAME"
    
    # Rename the snapshot by adding "uncomp" at the beginning before sending
    sudo mv "$SNAPSHOT_PATH/$SNAPSHOT_NAME" "$SNAPSHOT_PATH/uncomp-$SNAPSHOT_NAME"
    echo "Renamed snapshot to uncomp-$SNAPSHOT_NAME before sending"
    
    # Send snapshot to target
    if [ -n "$PARENT_SNAPSHOT" ]; then
        if send_snapshot "$SNAPSHOT_PATH/uncomp-$SNAPSHOT_NAME" "$TARGET_SUBVOLUME_PATH" "$FULL_PATH_PARENT_SNAPSHOT"; then
            echo "Incremental Snapshot of $SUBVOLUME_PATH from $FULL_PATH_PARENT_SNAPSHOT sent to $TARGET_DIR"
            
            # Rename snapshots on success
            sudo mv "$SNAPSHOT_PATH/uncomp-$SNAPSHOT_NAME" "$SNAPSHOT_PATH/full-$SNAPSHOT_NAME"
            sudo mv "$TARGET_SUBVOLUME_PATH/uncomp-$SNAPSHOT_NAME" "$TARGET_SUBVOLUME_PATH/full-$SNAPSHOT_NAME"
            echo "Renamed snapshots to full-$SUBVOLUME_PATH-$SNAPSHOT_NAME after sending"
        else
            echo "Failed to send snapshot, renaming not performed."
        fi
    else
        if send_snapshot "$SNAPSHOT_PATH/uncomp-$SNAPSHOT_NAME" "$TARGET_SUBVOLUME_PATH"; then
            echo "Snapshot of $SUBVOLUME_PATH sent to $TARGET_DIR"
            
            # Rename snapshots on success
            sudo mv "$SNAPSHOT_PATH/uncomp-$SNAPSHOT_NAME" "$SNAPSHOT_PATH/full-$SNAPSHOT_NAME"
            sudo mv "$TARGET_SUBVOLUME_PATH/uncomp-$SNAPSHOT_NAME" "$TARGET_SUBVOLUME_PATH/full-$SNAPSHOT_NAME"
            echo "Renamed snapshots to full-$SUBVOLUME_PATH-$SNAPSHOT_NAME after sending"
        else
            echo "Failed to send snapshot, renaming not performed."
        fi
    fi
    



    echo "
    
    //////////////////
    
    "
done

# Record end time
END_TIME=$(date +%s)

# Calculate elapsed time
ELAPSED_TIME=$((END_TIME - START_TIME))

# Display elapsed time
echo "Script execution took $ELAPSED_TIME seconds."
