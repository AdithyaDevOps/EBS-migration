#!/usr/bin/env bash
set -euo pipefail

############################################
# CODE 4 (v2) — Attach-time mount configurator
# - Discovers attached EBS volumes
# - Maps VolumeId -> device (Nitro/NVMe)
# - Reads tags (PartitionMap preferred; or MountPoints/UUIDs/FsTypes)
# - Creates mount points, updates /etc/fstab, mounts
# - Idempotent and logged
############################################

LOG_FILE="mount_volumes_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "----------------------------------------------------"
echo "LOGGING SESSION TO: $LOG_FILE"
echo "DATE: $(date)"
echo "----------------------------------------------------"

# -------- Instance metadata (region, instance id) --------
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F\" '/region/ {print $4}')
export AWS_DEFAULT_REGION="$REGION"

echo "TARGET INSTANCE: $INSTANCE_ID ($REGION)"

# -------- Helpers --------
get_physical_disk() {
  local src="$1"
  local real
  real=$(readlink -f "$src")
  lsblk -no PATH,TYPE -s "$real" 2>/dev/null | awk '$2=="disk"{print $1; exit}'
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf "%s" "$s"; }

# Sanitize semicolon separated value (already semicolon-based in tags from code1v18-semi)
# Left as a placeholder for future normalization if needed.
sanitize_value() { printf "%s" "$1"; }

# Idempotently ensure /etc/fstab has the desired line
ensure_fstab_entry() {
  local uuid="$1" mnt="$2" fstype="$3"
  local line="UUID=$uuid  $mnt  $fstype  defaults,nofail  0  2"

  sudo mkdir -p "$(dirname /etc/fstab)"
  [[ -f /etc/fstab.bak ]] || sudo cp -a /etc/fstab /etc/fstab.bak

  # If an entry already exists for this mount OR this UUID, don't duplicate
  if grep -qE "^[^#]*[[:space:]]$mnt[[:space:]]" /etc/fstab || grep -qE "^UUID=$uuid[[:space:]]" /etc/fstab; then
    echo "fstab: entry already present for $mnt or UUID=$uuid"
  else
    echo "fstab: adding entry -> $line"
    echo "$line" | sudo tee -a /etc/fstab >/dev/null
  fi
}

# -------- Discover volumes attached to this instance --------
VOLUMES=$(aws ec2 describe-volumes \
  --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
  --query "Volumes[].VolumeId" --output text || true)

if [[ -z "$VOLUMES" ]]; then
  echo "No EBS volumes attached to this instance. Exiting."
  exit 0
fi

# -------- Map /dev -> VolumeId via by-id symlinks (Nitro/NVMe) --------
declare -A DISK2VOL VOL2DISK

for id in /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol*; do
  [[ -e "$id" ]] || continue
  base=$(basename "$id")
  # Accept only base disk symlinks (no -part*, -ns-*, _1 suffixes)
  if [[ "$base" =~ ^nvme-Amazon_Elastic_Block_Store_vol([0-9a-fA-F]+)$ ]]; then
    hex="${BASH_REMATCH[1]}"
    vol="vol-$hex"
    real=$(readlink -f "$id")
    typ=$(lsblk -no TYPE "$real" 2>/dev/null || true)
    [[ "$typ" != "disk" ]] && continue
    DISK2VOL["$real"]="$vol"
    VOL2DISK["$vol"]="$real"
  fi
done

# Fallback mapping using SERIAL if any attached vol missing
for disk in $(lsblk -ndpo PATH,TYPE | awk '$2=="disk"{print $1}'); do
  [[ -n "${DISK2VOL[$disk]+isset}" ]] && continue
  serial=$(lsblk -ndo SERIAL "$disk" 2>/dev/null || true)
  if [[ "$serial" =~ vol-?([0-9a-fA-F]+) ]]; then
    vol="vol-${BASH_REMATCH[1]}"
    DISK2VOL["$disk"]="$vol"
    VOL2DISK["$vol"]="$disk"
  fi
done

# -------- Determine root disk to skip --------
ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(get_physical_disk "$ROOT_SRC")

# -------- Build mount plan from tags --------
declare -a MOUNT_PLAN # array of "VOL|MNT|UUID|FSTYPE"

echo -e "\nBuilding plan from volume tags..."
for VOL in $VOLUMES; do
  # Skip if we cannot map to a disk (e.g., EBS not NVMe or unusual state)
  DISK="${VOL2DISK[$VOL]:-}"
  if [[ -z "$DISK" ]]; then
    echo "WARN: Could not map $VOL to a device via by-id/SERIAL. Skipping."
    continue
  fi
  # Skip root disk if somehow mapped
  if [[ -n "$ROOT_DISK" && "$DISK" == "$ROOT_DISK" ]]; then
    echo "INFO: Skipping root disk $DISK ($VOL)."
    continue
  fi

  # Fetch aggregated tags (semicolon-separated)
  PMAP=$(aws ec2 describe-volumes --volume-ids "$VOL" \
         --query "Volumes[0].Tags[?Key=='PartitionMap'].Value | [0]" --output text || echo "None")
  MPTS=$(aws ec2 describe-volumes --volume-ids "$VOL" \
         --query "Volumes[0].Tags[?Key=='MountPoints'].Value | [0]" --output text || echo "None")
  UUIDS=$(aws ec2 describe-volumes --volume-ids "$VOL" \
         --query "Volumes[0].Tags[?Key=='UUIDs'].Value | [0]" --output text || echo "None")
  FSTS=$(aws ec2 describe-volumes --volume-ids "$VOL" \
         --query "Volumes[0].Tags[?Key=='FsTypes'].Value | [0]" --output text || echo "None")

  # Prefer PartitionMap if present
  if [[ -n "$PMAP" && "$PMAP" != "None" ]]; then
    IFS=';' read -ra ENT <<< "$PMAP"
    for entry in "${ENT[@]}"; do
      entry="$(trim "$entry")"
      [[ -z "$entry" ]] && continue
      # /mnt=uuid:fstype
      MNT="${entry%%=*}"; REST="${entry#*=}"
      UUID="${REST%%:*}"; FSTYPE="${REST#*:}"
      MNT="$(trim "$MNT")"; UUID="$(trim "$UUID")"; FSTYPE="$(trim "$FSTYPE")"
      [[ -z "$MNT" || -z "$UUID" || -z "$FSTYPE" ]] && { echo "WARN: Skipping malformed map entry: $entry"; continue; }
      MOUNT_PLAN+=("$VOL|$MNT|$UUID|$FSTYPE")
    done
  else
    # Fallback: parallel lists (semicolon-separated)
    [[ "$MPTS" == "None" || -z "$MPTS" ]] && { echo "INFO: No tags to derive mounts for $VOL. Skipping."; continue; }
    IFS=';' read -ra arrM <<< "$MPTS"
    IFS=';' read -ra arrU <<< "${UUIDS:-}"
    IFS=';' read -ra arrF <<< "${FSTS:-}"

    for i in "${!arrM[@]}"; do
      MNT="$(trim "${arrM[$i]}")"
      UUID="$(trim "${arrU[$i]:-}")"
      FSTYPE="$(trim "${arrF[$i]:-}")"
      [[ -z "$MNT" || -z "$UUID" || -z "$FSTYPE" ]] && { echo "WARN: Skipping incomplete tuple for $VOL idx=$i"; continue; }
      MOUNT_PLAN+=("$VOL|$MNT|$UUID|$FSTYPE")
    done
  fi
done

if [[ ${#MOUNT_PLAN[@]} -eq 0 ]]; then
  echo "No mount actions derived from tags. Exiting."
  exit 0
fi

# -------- Show plan --------
echo -e "\nPROPOSED MOUNT PLAN:"
printf "%-22s | %-25s | %-8s | %s\n" "VOLUME ID" "MOUNT POINT" "FS" "UUID"
echo "-------------------------------------------------------------------------------------"
for ITEM in "${MOUNT_PLAN[@]}"; do
  IFS='|' read -r VOL MNT UUID FSTYPE <<< "$ITEM"
  printf "%-22s | %-25s | %-8s | %s\n" "$VOL" "$MNT" "$FSTYPE" "$UUID"
done

# -------- Confirm --------
echo -ne "\nConfirm: Create directories, update /etc/fstab, and mount? (type 'yes' to continue): "
if ! read -r CONFIRM < /dev/tty 2>/dev/null; then read -r CONFIRM || true; fi
[[ "$CONFIRM" != "yes" ]] && { echo "Cancelled by user."; exit 0; }

# -------- Optional: EBS read pre-warm (disabled by default) --------
ENABLE_FIO="${ENABLE_FIO:-0}"
if [[ "$ENABLE_FIO" == "1" ]]; then
  echo -e "\nStarting optional EBS read pre-warm (fio)..."
  if ! command -v fio >/dev/null 2>&1; then
    echo "fio not found — attempting install..."
    (sudo yum -y install fio || (sudo apt-get update && sudo apt-get -y install fio)) || echo "WARN: fio install failed; skipping pre-warm."
  fi
  if command -v fio >/dev/null 2>&1; then
    declare -A seen
    for ITEM in "${MOUNT_PLAN[@]}"; do
      IFS='|' read -r VOL _ _ _ <<< "$ITEM"
      DISK="${VOL2DISK[$VOL]:-}"
      [[ -z "$DISK" || -n "${seen[$DISK]+isset}" ]] && continue
      seen["$DISK"]=1
      echo "fio read pre-warm on $DISK..."
      sudo fio --name=ebs-init --filename="$DISK" --rw=read --bs=1M --iodepth=32 --numjobs=1 --direct=1 || echo "WARN: fio failed on $DISK, continuing."
    done
  fi
fi

# -------- Execute: mkdir, fstab, mount --------
echo -e "\nApplying mounts..."
for ITEM in "${MOUNT_PLAN[@]}"; do
  IFS='|' read -r VOL MNT UUID FSTYPE <<< "$ITEM"
  echo "[$(date +%T)] $VOL -> $MNT (UUID=$UUID, FS=$FSTYPE)"

  # Create mount dir
  if [[ ! -d "$MNT" ]]; then
    echo "Creating directory $MNT..."
    sudo mkdir -p "$MNT"
  fi

  # Ensure fstab
  ensure_fstab_entry "$UUID" "$MNT" "$FSTYPE"

  # Mount if not already
  if mount | awk '{print $3}' | grep -qx "$MNT"; then
    echo "Already mounted: $MNT"
  else
    echo "Mounting UUID=$UUID at $MNT..."
    if sudo mount -t "$FSTYPE" "UUID=$UUID" "$MNT"; then
      echo "Mounted: $MNT"
    else
      echo "ERROR: Mount failed at $MNT (UUID=$UUID, FS=$FSTYPE)."
    fi
  fi
done

echo -e "\nVerifying with mount -a..."
sudo mount -a || echo "WARN: mount -a reported issues; review /etc/fstab."

echo -e "\nCurrent mounts:"
df -hT | (head -1 && grep -E "(/dev/nvme|Filesystem)" || true)

echo "----------------------------------------------------"
echo "CODE 4 COMPLETE"
echo "----------------------------------------------------"
