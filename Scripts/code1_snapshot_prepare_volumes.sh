#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# EBS Migration Helper (Interactive Only) - v18-semi
# - Discovers non-root mounted filesystems
# - Resolves EBS Volume IDs (Nitro/NVMe)
# - Creates ONE snapshot per source EBS volume
# - Creates ONE new volume per source EBS volume (same partition table)
# - Tags the new volume with aggregated metadata:
#     MountPoints, UUIDs, FsTypes, PartitionMap  (semicolon-separated)
# - Extra tags via:
#     EXTRA_TAGS_JSON='{"K1":"V1"}' (requires jq/python3; otherwise skipped safely)
#     EXTRA_TAGS_JSON_FILE=/path/file.json (same)
#     EXTRA_TAGS="K1=V1,K2=V2" (KV string; fully supported)
# - Uses AWS CLI shorthand for --tag-specifications
# - Sanitizes commas in ALL extra tag values → ';' to avoid shorthand parse errors
# =========================================================

LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "----------------------------------------------------"
echo "LOGGING SESSION TO: $LOG_FILE"
echo "DATE: $(date)"
echo "----------------------------------------------------"

# -------------------------------
# EC2 metadata (IMDSv2)
# -------------------------------
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || true)
if [[ -z "$REGION" ]]; then
  REGION="${AZ::-1}"
fi
export AWS_DEFAULT_REGION="$REGION"

echo "IDENTIFYING VOLUMES ON: $INSTANCE_ID ($AZ)"

# -------------------------------
# Helpers
# -------------------------------

# Resolve the *physical disk* backing a source (handles LVM/RAID/crypt/partitions)
get_physical_disk() {
  local src="$1"
  local real
  real=$(readlink -f "$src")
  lsblk -no PATH,TYPE -s "$real" 2>/dev/null | awk '$2=="disk"{print $1; exit}'
}

# Normalize any string containing a volume identifier to AWS format: "vol-<hex>"
# Accepts "vol<hex>" or "vol-<hex>", strips any non-hex, enforces minimum length.
normalize_volid() {
  local raw="$1"
  local hex=""
  if [[ "$raw" =~ vol-?([0-9a-fA-F]+) ]]; then
    hex="${BASH_REMATCH[1]}"
    # keep only hex chars
    hex=$(echo "$hex" | tr -cd '0-9a-fA-F')
    if [[ ${#hex} -ge 8 ]]; then
      echo "vol-$hex"
      return 0
    fi
  fi
  echo ""
  return 1
}

# -------- Sanitizer: replace commas with semicolons (for AWS shorthand safety) --------
sanitize_tag_value() {
  local v="$1"
  # Strip surrounding quotes if present
  v="${v%\"}"; v="${v#\"}"
  # Replace commas with semicolons
  v="${v//,/;}"
  # Escape double quotes
  v="${v//\"/\\\"}"
  printf "%s" "$v"
}

# -------- Extra Tags Builders (AWS CLI shorthand) --------
# Returns tags in shorthand format: {Key=K,Value=V},{Key=K2,Value=V2}

# Build from KV string into shorthand entries (sanitized)
build_additional_tags_from_kv() {
  local input="${EXTRA_TAGS:-}"
  local out=""
  [[ -z "$input" ]] && { echo ""; return 0; }

  IFS=',' read -ra kvs <<< "$input"
  for kv in "${kvs[@]}"; do
    kv="${kv#"${kv%%[![:space:]]*}"}"
    kv="${kv%"${kv##*[![:space:]]}"}"
    [[ -z "$kv" ]] && continue

    local key="${kv%%=*}"
    local val="${kv#*=}"
    [[ "$key" == "$val" ]] && continue
    [[ -z "$key" || -z "$val" ]] && continue

    val="$(sanitize_tag_value "$val")"

    if [[ -n "$out" ]]; then out+=", "; fi
    out+="{Key=$key,Value=$val}"
  done
  echo "$out"
}

# Build from JSON string into shorthand entries (sanitized values)
# If jq/python3 are absent, skip JSON extras for safety (avoid bad parsing).
build_additional_tags_from_json_string() {
  local json="${EXTRA_TAGS_JSON:-}"
  [[ -z "$json" ]] && { echo ""; return 0; }

  if command -v jq >/dev/null 2>&1; then
    # Convert to "k=v" pairs, then reuse KV builder (which sanitizes values)
    local raw
    raw="$(jq -rc 'to_entries | map("\(.key)=\(.value|tostring)") | join(",")' <<<"$json" 2>/dev/null || echo "")"
    [[ -z "$raw" ]] && { echo ""; return 0; }
    EXTRA_TAGS="$raw" build_additional_tags_from_kv
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import json, os, sys
from sys import stdout
j = os.environ.get("EXTRA_TAGS_JSON","")
try:
    data = json.loads(j)
    if not isinstance(data, dict):
        print("", end=""); sys.exit(0)
    parts = []
    def sanitize(val: str) -> str:
        if isinstance(val, (int, float)): val = str(val)
        if val is None: val = ""
        val = str(val).strip().strip('"')
        val = val.replace(",", ";").replace('"', '\\"')
        return val
    for k, v in data.items():
        parts.append("{Key=%s,Value=%s}" % (str(k), sanitize(v)))
    print(", ".join(parts), end="")
except Exception:
    print("", end="")
PY
    return 0
  fi

  # No JSON parser available; skip for safety
  echo ""
}

# Build from JSON file using the same logic
build_additional_tags_from_json_file() {
  local file="${EXTRA_TAGS_JSON_FILE:-}"
  [[ -z "$file" || ! -f "$file" ]] && { echo ""; return 0; }
  EXTRA_TAGS_JSON="$(cat "$file")" build_additional_tags_from_json_string
}

# Compose all extras (shorthand)
build_additional_tags() {
  local out_kv out_js out_jsf out=""
  out_kv="$(build_additional_tags_from_kv)"
  out_js="$(build_additional_tags_from_json_string)"
  out_jsf="$(build_additional_tags_from_json_file)"

  for chunk in "$out_kv" "$out_js" "$out_jsf"; do
    [[ -z "$chunk" ]] && continue
    if [[ -n "$out" ]]; then
      out="$out, $chunk"
    else
      out="$chunk"
    fi
  done
  echo "$out"
}

# Build full tag-specification for AWS CLI (shorthand)
# usage: build_tag_spec "snapshot" "<base_tags_shorthand>"
# returns: ResourceType=snapshot,Tags=[<base_tags>,<extras>]
build_tag_spec() {
  local rtype="$1"
  local base="$2"
  local extras; extras="$(build_additional_tags)"

  local tags="$base"
  if [[ -n "$extras" ]]; then
    if [[ -n "$tags" ]]; then
      tags="$tags, $extras"
    else
      tags="$extras"
    fi
  fi
  echo "ResourceType=$rtype,Tags=[$tags]"
}

# -------------------------------
# Determine root disk to skip
# -------------------------------
ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(get_physical_disk "$ROOT_SRC")

# -------------------------------
# Map: physical disk -> AWS Volume ID (clean "vol-<hex>")
# Only accept base symlinks like:
#   nvme-Amazon_Elastic_Block_Store_vol040c6f773173bfec2  -> /dev/nvme1n1 (TYPE=disk)
# Reject any with suffixes (-partN, -ns-*, _1, etc.)
# -------------------------------
declare -A DISK2VOL

for id in /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol*; do
  [[ -e "$id" ]] || continue
  base=$(basename "$id")

  # Match ONLY pure base names (no suffix after the hex tail)
  if [[ "$base" =~ ^nvme-Amazon_Elastic_Block_Store_vol([0-9a-fA-F]+)$ ]]; then
    RAW="${BASH_REMATCH[1]}"

    # Build valid AWS Volume ID
    VOL_ID="$(normalize_volid "vol$RAW")"
    [[ -z "$VOL_ID" ]] && continue

    real=$(readlink -f "$id")
    typ=$(lsblk -no TYPE "$real" 2>/dev/null || true)
    [[ "$typ" != "disk" ]] && continue

    DISK2VOL["$real"]="$VOL_ID"
  fi
done

# -------------------------------
# Discover non-root mounts
# -------------------------------
declare -A MIGRATION_ITEMS

while read -r SRC MNT; do
  [[ "$MNT" == "/" ]] && continue
  [[ "$SRC" != /dev/* ]] && continue

  DISK=$(get_physical_disk "$SRC")
  [[ -z "$DISK" ]] && continue
  [[ "$DISK" == "$ROOT_DISK" ]] && continue

  # Safe lookup under set -u
  VOL_ID=""
  if [[ -n "${DISK2VOL[$DISK]+isset}" ]]; then
    VOL_ID="${DISK2VOL[$DISK]}"
  fi

  # Fallback: use lsblk SERIAL (may be "volXXXXXXXX..." without hyphen)
  if [[ -z "$VOL_ID" ]]; then
    SERIAL=$(lsblk -ndo SERIAL "$DISK" 2>/dev/null || true)
    VOL_ID="$(normalize_volid "$SERIAL")"
  fi

  [[ -z "$VOL_ID" ]] && continue

  UUID=$(blkid -s UUID -o value "$SRC" 2>/dev/null || true)
  FSTYPE=$(blkid -s TYPE -o value "$SRC" 2>/dev/null || true)

  MIGRATION_ITEMS["$VOL_ID|$MNT|$UUID|$FSTYPE"]=1
done < <(findmnt -rn -o SOURCE,TARGET)

# -------------------------------
# Validate discovery
# -------------------------------
if [[ ${#MIGRATION_ITEMS[@]} -eq 0 ]]; then
  echo "No non-root mounted volumes found. Exiting."
  exit 0
fi

# -------------------------------
# Print plan
# -------------------------------
echo -e "\nPROPOSED MIGRATION PLAN:"
printf "%-22s | %-15s | %-10s | %s\n" "VOLUME ID" "MOUNT POINT" "FS TYPE" "UUID"
echo "--------------------------------------------------------------------------------"
for ITEM in "${!MIGRATION_ITEMS[@]}"; do
  IFS='|' read -r VOL MNT UUID FSTYPE <<< "$ITEM"
  printf "%-22s | %-15s | %-10s | %s\n" "$VOL" "$MNT" "$FSTYPE" "$UUID"
done

# Show extra tags if provided (raw)
if [[ -n "${EXTRA_TAGS:-}" || -n "${EXTRA_TAGS_JSON:-}" || -n "${EXTRA_TAGS_JSON_FILE:-}" ]]; then
  echo -e "\nExtra tags supplied (raw):"
  [[ -n "${EXTRA_TAGS:-}" ]] && echo "  EXTRA_TAGS=$EXTRA_TAGS"
  [[ -n "${EXTRA_TAGS_JSON:-}" ]] && echo "  EXTRA_TAGS_JSON=$EXTRA_TAGS_JSON"
  [[ -n "${EXTRA_TAGS_JSON_FILE:-}" ]] && echo "  EXTRA_TAGS_JSON_FILE=$EXTRA_TAGS_JSON_FILE"
  echo "Note: All commas in values will be converted to semicolons for AWS shorthand safety."
fi

# -------------------------------
# Confirm (interactive only; TTY-first with fallback to stdin)
# -------------------------------
CONFIRM="${CONFIRM:-}"  # avoid set -u crash if unset

echo -ne "\nProceed with snapshot & volume creation? (type 'yes'): "
if ! read -r CONFIRM < /dev/tty 2>/dev/null; then
  # Fall back to stdin
  read -r CONFIRM || true
fi

if [[ "${CONFIRM:-}" != "yes" ]]; then
  echo "Cancelled."
  exit 0
fi

# -------------------------------
# Execution
# - De-duplicate snapshots PER VOL_ID
# - Create ONE new volume per unique VOL_ID
# - Tag the new volume with aggregated mount metadata (semicolon-separated)
# -------------------------------
declare -A SNAP_BY_VOL
declare -A UNIQUE_VOLS

# Gather unique volume IDs
for ITEM in "${!MIGRATION_ITEMS[@]}"; do
  IFS='|' read -r VOL _ _ _ <<< "$ITEM"
  UNIQUE_VOLS["$VOL"]=1
done

# Create one snapshot per unique VOL_ID
for VOL in "${!UNIQUE_VOLS[@]}"; do
  echo "Creating snapshot for $VOL..."

  BASE_SNAP_TAGS="{Key=SourceInstanceId,Value=$INSTANCE_ID},{Key=SourceAZ,Value=$AZ},{Key=SourceVolumeId,Value=$VOL}"
  SNAP_TAG_SPEC="$(build_tag_spec "snapshot" "$BASE_SNAP_TAGS")"

  SNAP=$(aws ec2 create-snapshot \
      --volume-id "$VOL" \
      --description "Migration snapshot from $INSTANCE_ID" \
      --tag-specifications "$SNAP_TAG_SPEC" \
      --query SnapshotId --output text)

  echo "Waiting for snapshot $SNAP to complete..."
  aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"
  SNAP_BY_VOL["$VOL"]="$SNAP"
  echo "Snapshot ready: $SNAP (for $VOL)"
done

# -------------------------------------------------------
# Create ONE new volume per unique VOL_ID (aggregated tags, semicolon-separated)
# -------------------------------------------------------

# 1) Aggregate per-mount data into semicolon-separated strings per VOL_ID
declare -A MOUNT_LIST   # VOL -> "/test1;/test2"
declare -A UUID_LIST    # VOL -> "uuid1;uuid2"
declare -A FSTYPE_LIST  # VOL -> "ext4;ext4"
declare -A PARTMAP_LIST # VOL -> "/test1=uuid1:ext4;/test2=uuid2:ext4"

for ITEM in "${!MIGRATION_ITEMS[@]}"; do
  IFS='|' read -r VOL MNT UUID FSTYPE <<< "$ITEM"

  if [[ -n "$MNT" ]]; then
    MOUNT_LIST["$VOL"]+="${MOUNT_LIST[$VOL]:+;}$MNT"
  fi
  if [[ -n "$UUID" ]]; then
    UUID_LIST["$VOL"]+="${UUID_LIST[$VOL]:+;}$UUID"
  fi
  if [[ -n "$FSTYPE" ]]; then
    FSTYPE_LIST["$VOL"]+="${FSTYPE_LIST[$VOL]:+;}$FSTYPE"
  fi

  map_piece="$MNT"
  [[ -n "$UUID"   ]] && map_piece+="=$UUID"
  [[ -n "$FSTYPE" ]] && map_piece+=":$FSTYPE"
  PARTMAP_LIST["$VOL"]+="${PARTMAP_LIST[$VOL]:+;}$map_piece"
done

# 2) Create the new volume from the snapshot per VOL_ID, with aggregated tags
for VOL in "${!UNIQUE_VOLS[@]}"; do
  SNAP="${SNAP_BY_VOL[$VOL]:-}"
  if [[ -z "$SNAP" ]]; then
    echo "ERROR: No snapshot found for $VOL (this should not happen)."
    exit 1
  fi

  MOUNTS="${MOUNT_LIST[$VOL]:-}"
  UUIDS="${UUID_LIST[$VOL]:-}"
  FSTYPES="${FSTYPE_LIST[$VOL]:-}"
  PARTMAP="${PARTMAP_LIST[$VOL]:-}"

  # Base tags (always applied)
  BASE_VOL_TAGS="{Key=SourceInstanceId,Value=$INSTANCE_ID},{Key=SourceAZ,Value=$AZ},{Key=SourceSnapshotId,Value=$SNAP},{Key=SourceVolumeId,Value=$VOL}"

  # Aggregated metadata (semicolon-separated to avoid shorthand parser issues)
  [[ -n "$MOUNTS"  ]] && BASE_VOL_TAGS="$BASE_VOL_TAGS,{Key=MountPoints,Value=$MOUNTS}"
  [[ -n "$UUIDS"   ]] && BASE_VOL_TAGS="$BASE_VOL_TAGS,{Key=UUIDs,Value=$UUIDS}"
  [[ -n "$FSTYPES" ]] && BASE_VOL_TAGS="$BASE_VOL_TAGS,{Key=FsTypes,Value=$FSTYPES}"
  [[ -n "$PARTMAP" ]] && BASE_VOL_TAGS="$BASE_VOL_TAGS,{Key=PartitionMap,Value=$PARTMAP}"

  VOL_TAG_SPEC="$(build_tag_spec "volume" "$BASE_VOL_TAGS")"

  NEW_VOL=$(aws ec2 create-volume \
      --snapshot-id "$SNAP" \
      --availability-zone "$AZ" \
      --tag-specifications "$VOL_TAG_SPEC" \
      --query VolumeId --output text)

  echo "SUCCESS: Created volume $NEW_VOL from $SNAP (source VOL_ID $VOL; mounts: ${MOUNT_LIST[$VOL]:-})"
done

echo "----------------------------------------------------"
echo "MIGRATION COMPLETE"
echo "----------------------------------------------------"
