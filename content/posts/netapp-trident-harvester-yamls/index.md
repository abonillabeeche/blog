---
title: "NetApp Trident on SUSE Virtualization: just the YAMLs"
date: 2026-10-13
draft: false
tags: ["harvester", "suse-virtualization", "netapp", "trident", "csi", "storage", "iscsi", "nvme-of", "nfs"]
summary: "A copy-paste version of my Harvester knowledge base article on NetApp Trident: every manifest and command for NFS, iSCSI and NVMe/TCP backends, with as little prose as possible."
images: ["og.jpg"]
---

> **Short version.** This post keeps only the manifests and commands. For the full
> explanation, including network design, witness nodes, Fibre Channel notes and
> troubleshooting, read the complete article in the Harvester knowledge base:
> [Using NetApp Storage on Harvester](https://harvesterhci.io/kb/install_netapp_trident_csi).

**Update, 2026-10-21:** a NetApp Consulting Architect reviewed the original manifests
and flagged several things worth tightening: dropping `limitAggregateUsage` (it needs
a cluster-admin login just to read aggregate usage, and isn't a real concern on
all-flash aggregates), dropping `spaceReserve`/`snapshotReserve` and `svm`/`dataLIF`
as redundant given this setup, moving NFS mount options to the StorageClass, and using
`sanType` instead of `storagePools` to pin SAN classes to a protocol. I re-tested every
one of these on the lab cluster before changing anything here; both this post and the
knowledge base article below now reflect the corrected manifests.

Tested with SUSE Virtualization (Harvester) v1.9.0, Trident 26.06.1 (Helm chart
`100.2606.1`) and ONTAP 9.16.1. NFS, iSCSI and NVMe/TCP all support VM boot volumes,
live migration, online expansion and VM snapshots.

You'll need:

- The Harvester kubeconfig, plus `kubectl` and `helm`.
- An ONTAP SVM with a management LIF and data LIFs for each protocol. NVMe/TCP needs the
  `NVMe_oF` license.
- An ONTAP login with `http` and `ontapi` access, SVM-scoped `vsadmin` role. Point
  `managementLIF` at the SVM's own management LIF — Trident infers the SVM from it, so
  the backends below skip the `svm` field.

## 0. Optional: storage network

Keeps storage traffic off the management network. Create a cluster network named
`cn-storage` on your storage NICs in the UI (**Networks → ClusterNetworks/Configs**),
then give each node an address on it:

```yaml
apiVersion: network.harvesterhci.io/v1beta1
kind: HostNetworkConfig
metadata:
  name: netapp-storage
spec:
  clusterNetwork: cn-storage
  vlanID: 150
  mode: static
  nodeSelector:
    matchLabels:
      netapp-trident: enabled     # also keeps witness nodes out
  ips:
    <node-1>: 192.168.150.11/24
    <node-2>: 192.168.150.12/24
```

## 1. multipathd, NetApp LUNs only (iSCSI and FC)

Never start `multipathd` without this configuration, or it claims local and Longhorn
disks. `01-cloudinit-netapp-multipathd.yaml`:

```yaml
apiVersion: node.harvesterhci.io/v1beta1
kind: CloudInit
metadata:
  name: netapp-multipathd
spec:
  matchSelector: {}
  filename: 98_netapp_multipathd.yaml
  contents: |
    name: "enable multipathd for NetApp Trident iSCSI/FC (NETAPP LUNs only)"
    stages:
      initramfs:
        - files:
            - path: /etc/multipath/conf.d/98-netapp.conf
              permissions: 0644
              owner: 0
              group: 0
              content: |
                defaults {
                    user_friendly_names yes
                    find_multipaths no
                    reservation_key file
                    skip_kpartx yes
                }
                blacklist {
                    device {
                        vendor ".*"
                        product ".*"
                    }
                }
                blacklist_exceptions {
                    device {
                        vendor "NETAPP"
                        product "LUN.*"
                    }
                }
      network:
        - name: "enable and start multipathd"
          systemctl:
            enable:
              - multipathd
            start:
              - multipathd
```

```bash
kubectl apply -f 01-cloudinit-netapp-multipathd.yaml
```

Despite the `initramfs` stage name, this applies immediately — no reboot. Verify it
actually merged into the running config (don't trust an empty `multipath -ll` alone):

```bash
multipathd -k"show config" | grep -A6 '^blacklist {'   # must show vendor ".*" / product ".*"
```

NVMe/TCP uses native NVMe multipath and NFS needs nothing on the host.

## 2. Trident operator

```bash
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart
helm repo update

# Optional: run the node plugin only on labelled nodes (e.g. skip a witness node)
kubectl label node <node-1> <node-2> netapp-trident=enabled --overwrite

helm upgrade --install trident netapp-trident/trident-operator --version <chart version> \
  --namespace trident --create-namespace --wait \
  --set tridentNodePluginNodeSelector.netapp-trident=enabled

kubectl -n trident get pods -o wide
```

Drop the label and the `--set` line to run Trident on every node. Pick a version from
`helm search repo netapp-trident --versions`; tested here with chart `100.2606.1`
(Trident 26.06.1) — don't pin a version in your own docs, versions ship monthly.

## 3. ONTAP credentials

```bash
kubectl -n trident create secret generic netapp-creds \
  --from-literal=username=<ontap user> \
  --from-literal=password='<ontap password>'
```

## 4. Backends

One `TridentBackendConfig` per protocol; delete the ones you don't need. SAN backends
discover every LIF in the SVM, so they take no `dataLIF`. If several clusters share an
SVM, give each a unique `backendName` and a `storagePrefix` such as `hv1_`.

Left out on purpose: `spaceReserve`/`snapshotReserve` (already Trident's defaults),
`limitAggregateUsage` (needs a cluster-admin login just to read aggregate usage — more
access than Trident needs, and not a real problem on flash anyway), and `nfsMountOptions`
(a fallback that doesn't even show up in the PV's `mountOptions` — set it on the
StorageClass instead, step 5).

`03-backends.yaml`:

```yaml
# NFS
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: netapp-nas
  namespace: trident
spec:
  version: 1
  storageDriverName: ontap-nas
  backendName: netapp-nas
  managementLIF: <SVM management LIF IP>
  autoExportPolicy: true
  autoExportCIDRs: ["<storage network CIDR>"]
  credentials:
    name: netapp-creds
---
# iSCSI
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: netapp-iscsi
  namespace: trident
spec:
  version: 1
  storageDriverName: ontap-san
  sanType: iscsi
  backendName: netapp-iscsi
  managementLIF: <SVM management LIF IP>
  credentials:
    name: netapp-creds
---
# NVMe/TCP
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: netapp-nvme
  namespace: trident
spec:
  version: 1
  storageDriverName: ontap-san
  sanType: nvme
  backendName: netapp-nvme
  managementLIF: <SVM management LIF IP>
  credentials:
    name: netapp-creds
```

For Fibre Channel, copy the iSCSI backend with `sanType: fcp` and a new name.

```bash
kubectl apply -f 03-backends.yaml
kubectl -n trident get tridentbackendconfigs    # PHASE Bound, STATUS Success
```

## 5. StorageClasses and VolumeSnapshotClass

Pin each class to a protocol with `sanType` (`iscsi`/`nvme`/`fcp`), not `storagePools` by
backend name — it's the direct mechanism Trident gives you for exactly this, and survives
a backend rename. `storagePools` is for steering across multiple SVMs instead. Add
`fsType: "nfs"` to the NFS class too: without it, Kubernetes silently skips applying a
pod's `fsGroup` to the volume.

`04-storageclasses.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: netapp-nfs
provisioner: csi.trident.netapp.io
parameters:
  backendType: "ontap-nas"
  fsType: "nfs"
mountOptions:
  - nfsvers=4.1
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: netapp-iscsi
provisioner: csi.trident.netapp.io
parameters:
  backendType: "ontap-san"
  sanType: "iscsi"
  fsType: "ext4"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: netapp-nvme
provisioner: csi.trident.netapp.io
parameters:
  backendType: "ontap-san"
  sanType: "nvme"
  fsType: "ext4"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: trident-snapshotclass
driver: csi.trident.netapp.io
deletionPolicy: Delete
```

```bash
kubectl apply -f 04-storageclasses.yaml
```

No CDI annotation is needed: CDI already maps `ontap-san` to `ReadWriteMany` block and
`ontap-nas` to `ReadWriteMany` filesystem, which is what live migration needs — check
`kubectl get storageprofile <class> -o yaml` and `status` is already filled in. The
`storageclass.kubevirt.io/is-default-virt-class` annotation you may see elsewhere is
unrelated; it only matters if you want a NetApp class to replace Longhorn as the default.

## 6. Register the snapshot class with Harvester

In **Advanced → Settings → csi-driver-config**, add this entry. Leave the backup class
empty: in v1.9, VM backups only support Longhorn volumes, while VM snapshots work.

```json
"csi.trident.netapp.io": {
  "volumeSnapshotClassName": "trident-snapshotclass",
  "backupVolumeSnapshotClassName": ""
}
```

## 7. Verify

```bash
kubectl get sc | grep netapp
# create a VM on netapp-iscsi / netapp-nvme / netapp-nfs, live-migrate it, snapshot it
multipath -ll                     # on the VM's node: iSCSI LUNs
ls /sys/class/nvme-subsystem      # on the VM's node: NVMe subsystems
```

## Gotchas

- **Unique iSCSI initiator names.** Cloned nodes can share an IQN in
  `/etc/iscsi/initiatorname.iscsi`. After changing one, restart that node's
  `trident-node-linux` pod, or staging fails with `no devices present yet`.
- **Offline backends after an ONTAP outage:**
  `kubectl -n trident rollout restart deploy/trident-controller`.
- **Space not freed after deletes.** ONTAP holds deleted volumes for 12 hours. To purge:
  `set -privilege advanced; volume recovery-queue purge-all -vserver <svm name>`.
- **`multipath -ll` shows local disks.** Put `98-netapp.conf` in place, run
  `multipath -F`, then restart `multipathd`.

For everything else, see the
[full knowledge base article](https://harvesterhci.io/kb/install_netapp_trident_csi).
