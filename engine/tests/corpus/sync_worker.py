"""Batch sync worker: reads shards from the queue and writes them to the volume."""
import os
import shutil


def write_shard(shard_id, payload, root="/data/shards"):
    path = os.path.join(root, f"shard_{shard_id:04d}.bin")
    with open(path, "wb") as fh:
        fh.write(payload)
    return path


def free_space(root="/data/shards"):
    return shutil.disk_usage(root).free
