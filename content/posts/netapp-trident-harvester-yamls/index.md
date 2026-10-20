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

Tested with SUSE Virtualization (Harvester) v1.9.0, Trident 26.06.1 (Helm chart
`100.2606.1`) and ONTAP 9.16.1. NFS, iSCSI and NVMe/TCP all support VM boot volumes,
live migration, online expansion and VM snapshots.

You'll need:

- The Harvester kubeconfig, plus `kubectl` and `helm`.
- An ONTAP SVM with a management LIF and data LIFs for each protocol. NVMe/TCP needs the
  `NVMe_oF` license.
- An ONTAP login with `http` and `ontapi` access. My backends below use
  `limitAggregateUsage`, which needs a cluster-scoped `admin` login; with an SVM-scoped
  `vsadmin`, drop that field and point `managementLIF` at the SVM.

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

It takes effect at each node's next boot. To apply it now, write the same
`98-netapp.conf` on each node as root, then:

```bash
systemctl enable --now multipathd
multipath -ll    # must not list any local disk
```

NVMe/TCP uses native NVMe multipath and NFS needs nothing on the host.

## 2. Trident operator

```bash
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart
helm repo update

# Optional: run the node plugin only on labelled nodes (e.g. skip a witness node)
kubectl label node <node-1> <node-2> netapp-trident=enabled --overwrite

helm upgrade --install trident netapp-trident/trident-operator --version 100.2606.1 \
  --namespace trident --create-namespace --wait \
  --set tridentNodePluginNodeSelector.netapp-trident=enabled

kubectl -n trident get pods -o wide
```

Drop the label and the `--set` line to run Trident on every node.

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
  managementLIF: <management LIF IP>
  dataLIF: <NFS data LIF IP>          # optional
  svm: <svm name>
  autoExportPolicy: true
  autoExportCIDRs: ["<storage network CIDR>"]
  nfsMountOptions: "nfsvers=4.1"
  limitAggregateUsage: "80%"
  credentials:
    name: netapp-creds
  defaults:
    spaceReserve: none
    snapshotReserve: "0"
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
  managementLIF: <management LIF IP>
  svm: <svm name>
  limitAggregateUsage: "80%"
  credentials:
    name: netapp-creds
  defaults:
    spaceReserve: none
    snapshotReserve: "0"
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
  managementLIF: <management LIF IP>
  svm: <svm name>
  limitAggregateUsage: "80%"
  credentials:
    name: netapp-creds
  defaults:
    spaceReserve: none
    snapshotReserve: "0"
```

For Fibre Channel, copy the iSCSI backend with `sanType: fcp` and a new name.

```bash
kubectl apply -f 03-backends.yaml
kubectl -n trident get tridentbackendconfigs    # PHASE Bound, STATUS Success
```

## 5. StorageClasses and VolumeSnapshotClass

Pin each class to its backend with `storagePools`. Otherwise `backendType: ontap-san`
can land a volume on any SAN backend.

`04-storageclasses.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: netapp-nfs
provisioner: csi.trident.netapp.io
parameters:
  backendType: "ontap-nas"
  storagePools: "netapp-nas:.*"
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
  storagePools: "netapp-iscsi:.*"
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
  storagePools: "netapp-nvme:.*"
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
`ontap-nas` to `ReadWriteMany` filesystem, which is what live migration needs.

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
