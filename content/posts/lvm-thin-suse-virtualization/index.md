---
title: "LVM thin storage on SUSE Virtualization: chunk sizes, tuning knobs and encryption"
date: 2026-10-09
draft: false
tags: ["harvester", "suse-virtualization", "lvm", "csi", "storage", "performance"]
summary: "What a summer of work on SUSE Virtualization's LVM CSI driver taught me: why a thin pool's chunk size can cost you 98% of your IOPS, what changed upstream, the new VM storage settings in 1.9.1, and what encryption at rest costs."
images: ["og.jpg"]
# canonicalURL: ""
---

SUSE Virtualization (Harvester) can store VM disks on local LVM through its LVM CSI
driver, as an alternative to Longhorn. There's no replication, so it suits workloads
that replicate themselves or can be rebuilt, but the data path is short: a VM disk is a
logical volume on a local disk or RAID set. With thin provisioning (`lvm-thin`), volumes
take space only when written, and snapshots are cheap.

I spent much of the summer on this driver: benchmarking it, chasing a customer's
performance problem, and contributing fixes and features upstream. Here's what I
learned.

## Finding 1: chunk size can cost you 98% of your IOPS

A dm-thin pool allocates space in **chunks**. When a VM writes 4 KiB to a part of a thin
volume that has never been written, the pool allocates a whole chunk. With zeroing on,
it also writes zeros over the rest of that chunk.

LVM picks the chunk size automatically, and its default policy *scales the chunk with
the pool*. On a multi-terabyte pool, one customer ended up with 8–16 MiB chunks. Every
first 4 KiB write turned into megabytes of allocation, roughly 4,000 to 1 write
amplification, and random 4K writes managed **326 IOPS** where more than 15,000 were
expected.

Check yours on any node:

```bash
lvs -o lv_name,lv_size,chunk_size,lv_metadata_size,zero --units m
```

### What changed upstream

I proposed making chunk size, metadata size and zeroing StorageClass parameters
([csi-driver-lvm#57](https://github.com/harvester/csi-driver-lvm/pull/57)). The
maintainers pointed out, correctly, that pool geometry covers the whole pool and can't
change after creation, so a per-StorageClass setting is the wrong shape. They redirected
it into a smaller fix that has now merged and been backported
([csi-driver-lvm#68](https://github.com/harvester/csi-driver-lvm/pull/68)): pools the
driver creates now use **512 KiB chunks, 16 GiB of metadata and 90% of the volume
group's free space**.
[Webber Huang](https://github.com/WebberHuang1118) did that rework, and he also hardened
the snapshot lifecycle ([csi-driver-lvm#64](https://github.com/harvester/csi-driver-lvm/pull/64)).

My one caveat: on hardware RAID, the chunk should cover a full RAID stripe. On a
four-disk RAID set with 256 KiB strips, a 1 MiB chunk avoids partial-stripe writes,
while 512 KiB doesn't. My tuning guidance for that case is in review as
[docs#1083](https://github.com/harvester/docs/pull/1083). A proper thin-pool
configuration and status API is tracked in
[harvester#11335](https://github.com/harvester/harvester/issues/11335).

### What thin provisioning costs on RAID

I measured plain LVM against thin LVM on a Dell R640, with a 4-disk RAID virtual disk
at two strip sizes (fio, 15 GiB file, 60 s per test):

| RAID set | Seq. write 1 MiB, plain → thin | Random read 4K QD32×4, plain → thin |
|---|--:|--:|
| RAID0, 1 MiB strip | 2,137 → 1,562 MiB/s | 166k → 168k IOPS |
| RAID0, 512 KiB strip | 2,653 → 2,177 MiB/s | 163k → 177k IOPS |
| RAID10, 1 MiB strip | 977 → 695 MiB/s | 128k → 128k IOPS |
| RAID10, 512 KiB strip | 943 → **468** MiB/s | 126k → 127k IOPS |

Thin provisioning costs nothing on reads. On writes, its cost depends on how chunks line
up with the RAID layout, and it peaks at half the throughput on the worst combination.
Switching the I/O scheduler between `mq-deadline` and `none` made no measurable
difference.

## Finding 2: pool zeroing doubles the writes

In a 10-VM fleet test on a RAID-5 thin pool, writing 150 GiB of data grew the pool by
**336 GiB** with default settings. With zeroing off and a discard-friendly disk bus, the
same writes grew it by **96 GiB**, 3.5 times less.

Zeroing exists so a new volume can never read another volume's old data. If your disks
or RAID controller already return zeros for unwritten blocks, or every guest writes
before it reads, you can turn it off per pool:

```bash
lvchange --zero n <vg>/<thinpool>
```

That same fleet test produced the Windows findings in my
[enlightenments post](/posts/windows-vms-hyperv-enlightenments/): the worst stalls
there turned out to be a guest problem, not a storage one.

## New in 1.9.1: VM storage performance settings

KubeVirt has long had per-disk performance settings, but SUSE Virtualization's UI didn't
expose them. As of 1.9.1, the VM editor has them
([harvester#11550](https://github.com/harvester/harvester/issues/11550)). In YAML:

```yaml
spec:
  template:
    spec:
      domain:
        ioThreadsPolicy: auto            # spread disks across I/O threads
        devices:
          blockMultiQueue: true          # one virtqueue per vCPU
          disks:
            - name: rootdisk
              disk: { bus: virtio }
              cache: none                # bypass the host page cache
              io: native                 # Linux native AIO; requires cache: none
              dedicatedIOThread: true    # give this disk its own I/O thread
```

One combination is a trap: `io: native` with any cache mode other than `none` is
accepted today, but the VM then fails to start. A webhook that rejects it up front is
in review ([harvester#11806](https://github.com/harvester/harvester/pull/11806)).

## In review: encryption at rest

[csi-driver-lvm#67](https://github.com/harvester/csi-driver-lvm/pull/67) adds LUKS2
encryption to LVM volumes. You opt in per StorageClass with `encrypted: "true"`. The
driver opens the dm-crypt mapping when a node stages the volume and closes it when the
node unstages it, and the per-volume passphrases come from a Kubernetes Secret.

What it costs, measured from a Windows Server 2022 guest (4 vCPU, 16 GiB) with
`diskspd`, mean of two runs:

| Workload | Plain | Encrypted | Change |
|---|--:|--:|--:|
| Sequential read, 1 MiB, QD32 | 4,376 MB/s | 2,042 MB/s | **−53%** |
| Random read, 4 KiB, QD32×4 | 105k IOPS | 49.5k IOPS | **−53%** |
| Random write, 4 KiB, QD32×4 | 32.9k IOPS | 30.6k IOPS | −7% |
| Random 70/30, 4 KiB | 36.4k IOPS | 33.8k IOPS | −7% |

Writes are nearly free, but reads lose about half their throughput because decryption
is CPU-bound on the host. For read-heavy volumes, give the VM more vCPUs or keep those
volumes on a plain StorageClass. Attaching an encrypted volume adds 2–5 seconds;
guest boot time doesn't change.

## A bug worth knowing: the endless disk wipe

On a 1.9.0 release candidate, I found the node disk manager stuck wiping an LVM disk
about every 6 seconds, forever: 35 wipes in a few minutes and about 400 I/O operations
every 30 seconds on an otherwise idle disk. Disabling the LVM add-on doesn't stop it.

It comes from a mismatch between the LVM volume group object's spec and its status.
Clearing the stale status unwedges it:

```bash
kubectl -n harvester-system patch lvmvolumegroup <vg-object-name> \
  --subresource=status --type=merge -p '{"status":{"devices":null}}'
```

Confirm it stopped by watching the disk's counters in `/proc/diskstats`, not the logs.
Its logs say "Updated LVMVolumeGroup" whether or not anything changed.

## Status of my contributions

- **Merged upstream (by the maintainers, from my proposal):** standard pool geometry
  ([#68](https://github.com/harvester/csi-driver-lvm/pull/68), backported).
- **Fixed in 1.9.1:** a crash deleting snapshots
  ([harvester#11105](https://github.com/harvester/harvester/issues/11105)).
- **Shipping in 1.9.1:** VM storage performance settings in the UI (#11550).
- **In review:** encryption at rest (#67), the `io`/`cache` webhook (#11806), chunk-size
  tuning docs (docs#1083).
- **Planned upstream:** a thin-pool status API (#11335) and capacity safeguards
  ([#11332](https://github.com/harvester/harvester/issues/11332)).

## Takeaways

- **Check your thin pool's chunk size.** If it's in megabytes, small random writes are
  paying for it.
- **On RAID, align chunks to the full stripe**, and test with your workload before
  committing a pool. Its geometry can't change later.
- **Turn pool zeroing off only when** guests can't read stale data.
- **Use the new storage settings in 1.9.1** (`cache: none`, `io: native`, I/O threads)
  for latency-sensitive VMs.
- **Encryption is cheap for writes and expensive for reads.** Plan vCPUs accordingly.

## Thanks

Many thanks to [Webber Huang](https://github.com/WebberHuang1118) for reviewing my pull
requests so carefully, and for reworking and improving them into changes that fit the
driver better than my originals did. Several of the improvements in this post exist in
their current form because of his work.
