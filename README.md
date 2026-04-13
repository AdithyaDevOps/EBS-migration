# EBS Mount-Preserving Migration

This repository migrates EBS-backed filesystems between EC2 instances
while preserving **actual mount points**.

Mount intent is transported using **AWS tags**.

---

## Execution model (IMPORTANT)

| Code | Where it runs | Why |
|----|----|----|
| Code 1 | Source EC2 instance | Needs OS mount info |
| Code 3 | Pipeline / CLI | AWS-only operations |
| Code 4 | Destination EC2 instance | Creates mounts |

---

## High-level flow

1. **Code 1**
   - Discovers mounted filesystems (excluding root)
   - Creates snapshots
   - Creates new volumes from snapshots
   - Tags snapshots & volumes with mount metadata

2. **Code 3**
   - Finds volumes created by Code 1
   - Attaches them to destination instance

3. **Code 4**
   - Reads volume tags
   - Creates mount directories
   - Mounts volumes using UUIDs
   - (fstab-ready)

---

## Tags used

| Tag | Purpose |
|----|----|
| SourceInstanceId | Groups migration set |
| MountPoint | Target mount path |
| UUID | Filesystem UUID |
| FsType | Filesystem type |
| SourceAZ | Availability Zone |

---

## Safety features

- Root volume automatically excluded
- DRY_RUN support
- Idempotent mounting
- Nitro-safe device handling

---

## Requirements

- AWS CLI v2
- EC2 instance profile
- Bash, lsblk, blkid, findmnt

---

## Example (manual run)

```bash
curl -fsSL https://github.com/<org>/ebs-migration/raw/main/scripts/code1_snapshot_prepare_volumes.sh | bash
