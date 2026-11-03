---
title: "NetApp to NetApp: SnapMirror between two ONTAP simulators for SUSE Virtualization disaster recovery"
date: 2026-11-03T01:00:00Z
draft: false
tags: ["netapp", "ontap", "snapmirror", "trident", "suse-virtualization", "harvester", "disaster-recovery", "kubevirt"]
summary: "A second ONTAP simulator, cluster and SVM peering, and Trident volume replication between two SUSE Virtualization clusters: what it takes, how far behind the replica runs with a one-minute schedule, and the gotchas, including a Trident promote quirk and VM disks cloned from images."
images: ["og.jpg"]
---

![Diagram of NetApp SnapMirror between two ONTAP 9.16.1 simulators: primary SUSE Virtualization cluster with VMs and FlexClone disks, Trident TridentMirrorRelationship replication to replica PVCs on the DR cluster, one-minute schedule with 7 to 41 seconds of lag, and callouts for async-only replication, per-disk consistency and the promote gotcha](netapp-snapmirror-suse-virtualization-dr.jpg)

**TL;DR**

- I built a second ONTAP 9.16.1 simulator as a SnapMirror destination for my first one. Its license file already contains a full set of codes for a second serial number, so nothing extra was needed: change the serial and system ID at the boot loader, apply the second set of codes, and SnapMirror (including synchronous SnapMirror) is licensed.
- Cluster peering and SVM peering took a few minutes. One trap: the peering passphrase prompt does not accept piped input over SSH, so I used the ONTAP REST API for that step.
- Each VM disk on the primary SUSE Virtualization cluster is replicated with a Trident `TridentMirrorRelationship` (TMR) to a PVC on the DR cluster. Disks of VMs created from images are FlexClones of the image volume; SnapMirror sends them as full, independent copies, and that works.
- With a one-minute SnapMirror schedule the DR copy ran **7 to 41 seconds behind** in steady state (51 samples). A planned failover with a final update lost no data. NetApp's review pointed out that **five minutes is the minimum schedule NetApp supports**; one minute works but is not supported.
- Gotchas: Trident replication is asynchronous only, each disk is its own consistency point, the simulator stalls transfers when it runs low on memory, and Trident 26.06 can report a mirror as promoted while ONTAP still has the volume read-only (NetApp is trying to reproduce that one).
- NetApp also pointed me to **Trident Protect**, which can replicate and fail over the whole VM, metadata included. I will try it on SUSE Virtualization, configured the way NetApp recommends, in a separate post.

I wanted VM disaster recovery between two [SUSE Virtualization](https://www.suse.com/products/rancher/virtualization/) (Harvester) clusters with the storage array doing the heavy lifting: replicate the disks with SnapMirror, keep a stopped copy of each VM on the DR side, and fail over in a couple of minutes. Both clusters already used NetApp Trident against an ONTAP simulator (see [NetApp Trident on SUSE Virtualization: just the YAMLs](/posts/netapp-trident-harvester-yamls/)). This post covers the storage half: a second simulator, peering, replication through Trident, and what I measured. Orchestration, done by a small CLI called Harvey that moves the VM definitions and runs failover and failback, is covered in the companion post: [VM failover and failback with Harvey and NetApp SnapMirror](/posts/harvey-vm-failover-netapp-snapmirror-suse-virtualization/).

**Update (November 3):** NetApp engineers reviewed this post. Their feedback is folded into the sections below and summarized in [What NetApp said](#what-netapp-said).

## Setup

| Item | Primary site | DR site |
|---|---|---|
| SUSE Virtualization | 1.9.0, 3 nodes | 1.10.0-rc1, 3 nodes |
| Trident | 26.06.1 | 26.06.1 |
| ONTAP | Simulator 9.16.1P1, single node | Simulator 9.16.1P1, single node |
| SVM | `svm0` | `svm_dr` |
| Data aggregate | 19 disks, RAID-DP, 134.5 GB | 19 disks, RAID-DP, 134.5 GB |

Both simulators run on one small ESXi host (Xeon E5-1620 v2, 4 threads, 64 GB), 2 vCPU and 6 GB of RAM each. Each simulator has 23 virtual disks of 9 GB (207 GB), close to the simulator's limit of 220 GB of raw disk per node.

## Why active/passive

ONTAP offers an active/active option, SnapMirror active sync, and the policies (`AutomatedFailOver`, `AutomatedFailOverDuplex`) are present on the simulator. It does not fit this design:

- It needs ONTAP Mediator in a third failure domain for automatic failover.
- NetApp lists it for AFF and ASA systems; the simulator behaves like a FAS system.
- It is built for one set of hosts that sees both copies of a LUN (VMware vMSC, Hyper-V stretch clusters). Two separate Kubernetes clusters, each with its own Trident, do not share hosts.

Every Kubernetes-level NetApp option I found is active/passive and asynchronous: Trident volume replication (TMR), Trident Protect (`AppMirrorRelationship`) and SVM disaster recovery. The [Trident replication documentation](https://docs.netapp.com/us-en/trident/trident-use/vol-volume-replicate.html) states it directly: "Only SnapMirror asynchronous protection is supported."

## Step 1: Build the second simulator with the second serial number

A fresh simulator OVA always boots as serial number 4082368-50-7. Two clusters with the same serial and system ID are asking for trouble, and the license codes are bound to the serial. The Simulate ONTAP installation guide describes how to boot a second node with a different identity; the same works for a second single-node cluster. Stop at the `VLOADER>` prompt on the first boot (press the space bar during the countdown) and set:

```console
VLOADER> setenv SYS_SERIAL_NUM 4034389-06-2
VLOADER> setenv bootarg.nvram.sysid 4034389062
VLOADER> setenv bootarg.vm.sim.vdevinit "36:14:0,36:9:1"
VLOADER> setenv bootarg.sim.vdevinit "36:14:0,36:9:1"
VLOADER> boot
```

Those last two lines give the simulator 23 disks of 9 GB instead of the default small ones; I used the same layout on both simulators. Serial number and system ID survive reboots.

After `cluster setup` on the console, I applied the second set of codes from the simulator license file (section "Licenses for the second node in a cluster"): 11 packages, including NFS, iSCSI, FlexClone, SnapMirror and NVMe_oF.

In that file, the SnapMirror code is described as "SnapMirror, including synchronous SnapMirror". No separate replication license was needed.

## Step 2: Create a uniquely named SVM

Trident requires **unique SVM names** on the two sides of a replication relationship, so the DR SVM is `svm_dr`, not a second `svm0`. It gets the same protocols and LIF types as the primary:

```console
vserver create -vserver svm_dr -rootvolume svm_dr_root -aggregate <data-aggr> -rootvolume-security-style unix
vserver add-protocols -vserver svm_dr -protocols nfs,iscsi,nvme
vserver nfs create -vserver svm_dr -v3 enabled -v4.0 enabled -v4.1 enabled
vserver iscsi create -vserver svm_dr -status-admin up
vserver nvme create -vserver svm_dr -status-admin up
network interface create -vserver svm_dr -lif lif_svm_dr_nfs   -service-policy default-data-files    -home-port e0b -address 192.0.2.28 -netmask 255.255.255.0
network interface create -vserver svm_dr -lif lif_svm_dr_iscsi -service-policy default-data-blocks   -home-port e0b -address 192.0.2.29 -netmask 255.255.255.0
network interface create -vserver svm_dr -lif lif_svm_dr_nvme  -service-policy default-data-nvme-tcp -home-port e0d -address 192.0.2.30 -netmask 255.255.255.0
network interface create -vserver svm_dr -lif lif_svm_dr_mgmt  -service-policy default-management    -home-port e0a -address 192.0.2.31 -netmask 255.255.255.0
```

Trident on the DR cluster authenticates with an SVM-scoped `vsadmin` login through the SVM management LIF, the same pattern as on the primary. I also replaced the self-signed certificates (they expire after a year) with ten-year ones on both the cluster and the SVM.

## Step 3: Peer the clusters and the SVMs

Replication needs one intercluster LIF per node on each cluster:

```console
ontap-a::> network interface create -vserver ontap-a -lif ontap-a-01_ic1 -service-policy default-intercluster -home-port e0a -address 192.0.2.45 -netmask 255.255.255.0
ontap-b::> network interface create -vserver ontap-b -lif ontap-b-01_ic1 -service-policy default-intercluster -home-port e0a -address 192.0.2.33 -netmask 255.255.255.0
ontap-a::> network ping -lif ontap-a-01_ic1 -vserver ontap-a -destination 192.0.2.33
192.0.2.33 is alive
```

`cluster peer create` asks for the passphrase on a masked prompt that reads from the terminal, so scripted SSH input is silently dropped. The REST API takes it as a field. Generate it on the first cluster:

```console
POST https://<ontap-a>/api/cluster/peers?return_records=true
{"name": "ontap-b", "remote": {"ip_addresses": ["192.0.2.33"]},
 "authentication": {"generate_passphrase": true, "expiry_time": "PT1H"}}
```

and hand the returned passphrase to the second:

```console
POST https://<ontap-b>/api/cluster/peers
{"name": "ontap-a", "remote": {"ip_addresses": ["192.0.2.45"]},
 "authentication": {"passphrase": "<from the first response>"}}
```

```console
ontap-a::> cluster peer show
Peer Cluster Name         Cluster Serial Number Availability   Authentication
------------------------- --------------------- -------------- --------------
ontap-b                   1-80-000008           Available      ok
```

Then peer the SVMs for SnapMirror only. A request shows up as `pending` on the remote side about 30 seconds later and has to be accepted there:

```console
ontap-a::> vserver peer create -vserver svm0 -peer-vserver svm_dr -applications snapmirror -peer-cluster ontap-b
ontap-b::> vserver peer accept -vserver svm_dr -peer-vserver svm0
ontap-b::> vserver peer show -fields peer-state,applications
vserver peer-vserver peer-state applications
------- ------------ ---------- ------------
svm_dr  svm0         peered     snapmirror
```

## Step 4: Smoke test SnapMirror by hand

Before involving Kubernetes, a throwaway volume confirmed every operation a failover needs, run on the destination cluster:

```console
volume create -vserver svm_dr -volume smtest_dst -aggregate <data-aggr> -size 200m -type DP
snapmirror create -source-path svm0:smtest -destination-path svm_dr:smtest_dst -policy MirrorAllSnapshots -schedule 5min
snapmirror initialize -destination-path svm_dr:smtest_dst    # baseline
snapmirror update     -destination-path svm_dr:smtest_dst    # incremental
snapmirror quiesce    -destination-path svm_dr:smtest_dst
snapmirror break      -destination-path svm_dr:smtest_dst    # failover: the DP volume becomes RW
snapmirror resync     -destination-path svm_dr:smtest_dst    # re-protect
```

Repeating it with `-policy Sync` reached `Snapmirrored`, status `InSync`, on the simulators. Synchronous replication works between the two clusters, but Trident does not manage it: NetApp has deliberately not integrated SnapMirror synchronous or active sync with Trident yet. For zero data loss with automatic failover, NetApp's usual answer is MetroCluster, which mirrors and fails over transparently below the hosts.

One cleanup lesson: release the relationship on the **source** (`snapmirror release`) before deleting the destination volume. Otherwise the source keeps a stale destination entry and refuses to delete the volume; `snapmirror release -relationship-info-only true` clears it, and only while the volume is online.

## Step 5: Replicate VM disks with Trident

A `TridentMirrorRelationship` (TMR) represents one end of a SnapMirror relationship between two PVCs. On the primary cluster, a TMR in state `promoted` for an existing PVC returns the ONTAP volume handle:

```yaml
apiVersion: trident.netapp.io/v1
kind: TridentMirrorRelationship
metadata: {name: dr-demo-1-root, namespace: harvey-dr-demo}
spec:
  state: promoted
  volumeMappings:
  - localPVCName: dr-demo-1-root
# status.conditions[0].localVolumeHandle: svm0:rs_pvc_83b5a8b8_777a_49d5_a752_55d4f915a69e
```

On the DR cluster, a TMR in state `established` points at that handle, and a PVC annotated with the TMR name becomes the SnapMirror destination. Trident places it on the SVM that is peered with the source:

```yaml
apiVersion: trident.netapp.io/v1
kind: TridentMirrorRelationship
metadata: {name: dr-demo-1-root, namespace: harvey-dr-demo}
spec:
  state: established
  replicationPolicy: MirrorAllSnapshots
  replicationSchedule: harvey-1min
  volumeMappings:
  - localPVCName: dr-demo-1-root
    remoteVolumeHandle: "svm0:rs_pvc_83b5a8b8_777a_49d5_a752_55d4f915a69e"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dr-demo-1-root
  namespace: harvey-dr-demo
  annotations: {trident.netapp.io/mirrorRelationship: dr-demo-1-root}
spec:
  accessModes: [ReadWriteMany]
  volumeMode: Block
  resources: {requests: {storage: 5Gi}}
  storageClassName: netapp-iscsi
```

`harvey-1min` is an ONTAP cron schedule that fires every minute, created on both simulators because a failback reverses the direction:

```console
job schedule cron create -name harvey-1min -minute 0,1,2,3,...,59
```

NetApp's documentation adds `trident.netapp.io/replication: "true"` to the StorageClasses. In this lab the existing StorageClasses without that parameter worked on both sides, for iSCSI and NFS.

Failover sets the DR TMR to `promoted` (SnapMirror break, the volume becomes read-write). Reprotect sets the old source's TMR to `reestablished` with the new source handle, which reverse-resyncs and overwrites the old copy. Trident accepted adding `replicationPolicy` and `replicationSchedule` at that point to a TMR that was created without them.

### VM disks cloned from images

On SUSE Virtualization, a VM created from an image on a Trident StorageClass gets a root disk that is a FlexClone of the image volume:

```console
ontap-a::> volume clone show -vserver svm0
Vserver FlexClone                                   Parent Volume                               Parent Snapshot
------- ------------------------------------------- ------------------------------------------- --------------------
svm0    rs_pvc_83b5a8b8_777a_49d5_a752_55d4f915a69e rs_pvc_b6e17bf2_8fe9_466d_9def_11dd295b221f snapshot-3de7215c-...
```

I expected trouble here. There was none: SnapMirror transferred the clone as a full, independent 731 MB copy, starting from the image's base snapshot, and the DR side needs no copy of the image.

## How far behind the replica runs

Lag is the age of the newest snapshot that reached the destination, so it is also the most data an unplanned failover can lose. I sampled `snapmirror show -fields lag-time` every 30 seconds on the destination while a test VM wrote to its three disks (an image-cloned root disk on iSCSI, an iSCSI data disk and an NFS data disk):

| Schedule | Samples | Min | Median | Mean | Max |
|---|---|---|---|---|---|
| Every minute (`harvey-1min`) | 51 over ~9 min | 7 s | 36 s | 24 s | 41 s |

Scheduled transfers for this light workload took a few seconds each (for example, 4.09 MB in 8 s). With a one-minute schedule the worst case is roughly one minute plus the transfer time; with the built-in `5min` schedule, expect up to five minutes plus transfer time. A planned failover stops the VM first and then runs one more update per disk, which took 6 to 15 seconds per volume here, so nothing is lost.

**Use five minutes, not one.** NetApp supports five minutes as the minimum SnapMirror schedule; one minute works, as above, but is not supported. Even five minutes deserves care on a busy array: every volume can have a SnapMirror relationship (up to 5,000 volumes per system), but only 100 or 250 transfers run concurrently, depending on the platform. A handful of volumes on a quiet system is easy; thousands of volumes on a loaded one is not. My one-minute lab schedule also made the simulator's memory problems and the promote race below more likely.

## Gotchas

**Trident marks a mirror promoted while ONTAP still has it read-only.** With Trident 26.06.1 and ONTAP 9.16.1, I saw a destination TMR reach status `promoted` while the volume was still a DP (read-only) volume. The VM then failed to start with `AttachVolume.Attach failed ... volume is not read-write`. It happened in two situations:

- A scheduled transfer was running when the promote arrived. Trident logged `Snapmirror break failed: snapmirror transfer already in progress`, requeued, and still reported `promoted`.
- A relationship that was already quiesced (paused) before the promote. Trident set `promoted` without breaking it.

NetApp had not seen this in support cases and is trying to reproduce it. Harvey's workaround: abort a running transfer before promoting, then check the volume type through the ONTAP REST API (`GET /api/storage/volumes?fields=type`) and, if it is still `dp`, quiesce and break the relationship directly (`PATCH /api/snapmirror/relationships/{uuid}` with `state: paused`, then `broken_off`). With a one-minute schedule a transfer is running a good part of the time, so this matters.

**Each disk is its own consistency point.** Every PVC is a separate relationship on its own schedule. In an unplanned failover test, the data disks of one VM came back from 03:56:57 and the root disk from 03:56:02. A planned failover is not affected because the VM is stopped before the final update. In Trident, crash-consistent groups of volumes come from the VolumeGroupSnapshot functionality, but according to NetApp that does not work together with replication yet.

**Simulator memory.** With 6 GB of RAM the primary simulator served three Kubernetes clusters and logged `wafl.memory.statusVeryLowMemory: WAFL is running very low on memory, with 27MB remaining`. Transfers then stopped making progress without failing. `snapmirror abort` followed by a new update or `snapmirror initialize` resumed them from their checkpoint. Harvey now aborts and retries a transfer that makes no progress for two minutes. A production array would not behave like this, but a lab simulator does.

**Scheduled-update noise.** While a relationship is quiesced, broken or still initializing, every scheduled update fails and logs `smc.snapmir.update.fail`. With a one-minute schedule that adds up quickly in the event log; it is expected.

## Takeaways

- Two ONTAP simulators are enough to build and test SnapMirror-based VM disaster recovery end to end, licensing included.
- Trident TMRs give you mirrored PVCs on the DR cluster that behave like any other PVC after promotion. The VM definitions, Secrets and networks still have to get there some other way; that is what Harvey does.
- With a one-minute schedule the DR copy stayed well under a minute behind for a light workload, and planned failovers were lossless. For anything beyond a lab, use NetApp's supported minimum of five minutes and keep the concurrent-transfer limit in mind.
- Verify promotions in ONTAP rather than trusting the TMR status alone.
- Trident Protect is NetApp's own way to cover the whole workflow; I will set it up the way NetApp's documentation recommends in a separate post.

## What NetApp said

I sent this post to NetApp engineers for review. In short:

- **Schedule:** five minutes is the minimum NetApp supports for asynchronous SnapMirror. One minute works but is not supported, and on a loaded array with many volumes even five minutes needs care, because only 100 or 250 transfers run concurrently, depending on the platform.
- **Synchronous and active sync:** there is no Trident integration (yet), by design. Customers who need that usually get MetroCluster, which does the mirroring and failover automatically and transparently.
- **Consistency groups:** covered in Trident by the VolumeGroupSnapshot functionality, which does not yet work in combination with replication.
- **Promote quirk:** not a known issue and not seen in support cases; NetApp support is trying to reproduce it.
- **Trident Protect:** it can cover the whole workflow, including the VM failover, without an additional orchestration tool. Yves at NetApp has a [KubeVirt scenario](https://github.com/YvosOnTheHub/LabNetApp/tree/master/Kubernetes_v6/Trident_Protect_Scenarios/Scenario11) in his lab repository. It should work on SUSE Virtualization too; I will cover that in a separate post.

Thanks to the NetApp team for the quick and candid review.
