#!/usr/bin/env bash
# Nightly backup of the shard volume to the NAS, keeping seven days.
set -euo pipefail
rsync -a --delete /data/shards/ nas:/backups/shards/
find /backups/shards -mtime +7 -delete
