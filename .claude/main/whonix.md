## Whonix KVM

Whonix-Gateway and Whonix-Workstation are installed as persistent KVM/libvirt
VMs. Images live at `/var/lib/libvirt/images/` (bind-mounted from
`/persist/var/lib/libvirt/` so they survive the ephemeral-root rollback).
`/var/lib/libvirt` is included in the main B2 restic backup so configured VMs
survive disk loss; large transient artifacts are excluded in
`hosts/main/backups.nix`.

```bash
# Check VM and network state
sudo virsh list --all
sudo virsh net-list --all

# Start/stop
sudo virsh start Whonix-Gateway
sudo virsh start Whonix-Workstation
sudo virsh shutdown Whonix-Workstation
sudo virsh shutdown Whonix-Gateway
```

Updates inside the VMs: log out of the `user` session, log in as `sysmaint`
(no password), run `upgrade-nonroot`. The `user-sysmaint-split` feature blocks
`sudo` from the normal `user` account by design.
