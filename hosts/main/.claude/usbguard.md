## USBGuard: Adding a New USB Device

New sticks, peripherals, or adapters are blocked by default and must be
explicitly enrolled in `hosts/main/default.nix`.

**Step 1 — identify the device**

Plug in the device; USBGuard will block it. Read its attributes:

```bash
sudo usbguard list-devices --blocked
# Example output:
# 12: block id 0781:5591 serial "4C530001..." name "Ultra Flair" ...
#     with-interface equals { 08:06:50 }
```

Note the `id` (VID:PID), `serial`, `name`, and `with-interface` class.

**Step 2 — determine the interface class**

The `with-interface` field uses `class:subclass:protocol` notation. Common classes:

| Class               | Meaning                         |
| ------------------- | ------------------------------- |
| `08:*:*`            | Mass storage                    |
| `03:*:*`            | HID (keyboard, mouse, receiver) |
| `01:*:*`            | Audio                           |
| `02:*:*` / `0a:*:*` | CDC / USB networking            |
| `e0:01:01`          | Bluetooth                       |

**Step 3 — add the rule**

For removable storage, always pin the serial and name to prevent a spoofed
device from inheriting the rule:

```nix
# In hosts/main/default.nix, inside services.usbguard.rules:
allow id 0781:5591 serial "4C530001..." name "Ultra Flair" with-interface equals { 08:06:50 }
```

For peripherals without stable serials (e.g. wireless receivers), constrain by
interface class instead:

```nix
allow id 046d:c52b with-interface equals { 03:*:* }
```

**Step 4 — rebuild and verify**

```bash
nh os switch --hostname main .
sudo usbguard list-devices   # device should now show "allow"
```

`/var/lib/usbguard` is persisted and backed up, so enrolled rules survive reboots and rollbacks.
