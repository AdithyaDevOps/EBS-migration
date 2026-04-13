#!/usr/bin/env bash
set -euo pipefail

PRIVATE_IP="<+pipeline.variables.TF_VAR_private_ip>"
SOURCE_INSTANCE_ID="<+pipeline.variables.SOURCE_INSTANCE_ID>"

[[ -z "$PRIVATE_IP" ]] && echo "Missing TF_VAR_private_ip" && exit 1
[[ -z "$SOURCE_INSTANCE_ID" ]] && echo "Missing SOURCE_INSTANCE_ID" && exit 1

echo "Resolving destination instance from private IP: $PRIVATE_IP"

DEST_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$PRIVATE_IP" \
            "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].Instances[].InstanceId" \
  --output text)

[[ -z "$DEST_INSTANCE_ID" ]] && echo "No instance found for IP $PRIVATE_IP" && exit 1

echo "Destination instance ID: $DEST_INSTANCE_ID"
echo "Looking for AVAILABLE volumes tagged SourceInstanceId=$SOURCE_INSTANCE_ID"

VOLUMES=$(aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
            "Name=tag:SourceInstanceId,Values=$SOURCE_INSTANCE_ID" \
  --query "Volumes[].VolumeId" \
  --output text)

if [[ -z "$VOLUMES" ]]; then
  echo "No matching available volumes found — nothing to attach"
  exit 0
fi

DEVICES=(f g h i j k l m n)
IDX=0

for VOL in $VOLUMES; do
  DEVICE="/dev/sd${DEVICES[$IDX]}"
  echo "Attaching volume $VOL to $DEST_INSTANCE_ID as $DEVICE"

  aws ec2 attach-volume \
    --volume-id "$VOL" \
    --instance-id "$DEST_INSTANCE_ID" \
    --device "$DEVICE"

  ((IDX++))
done

echo "CODE 3 COMPLETE"
