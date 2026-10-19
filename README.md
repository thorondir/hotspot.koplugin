# hotspot.koplugin

A KOReader plugin that turns your Kobo into a Wi-Fi access point. 'Hotspot' is maybe a little misleading since this access point won't give you internet access, but it's useful for connecting other devices directly to your Kobo — for example, to transfer books over rsync/SSH.

## What it does

- Broadcasts a Wi-Fi AP (SSID, channel, and optional WPA2 password are all configurable)
- Assigns the Kobo the static IP `192.168.42.1` on the AP interface
- Runs a DHCP server so connecting devices get addresses in `192.168.42.10–100`
- Menu lives under **Settings -> Network -> Wi-Fi hotspot**
- Can be set to start automatically with KOReader

## Supported devices

The plugin picks the AP interface from the Wi-Fi driver KOReader reports (`WIFI_MODULE`).

| Device | Wi-Fi driver | AP interface | Status |
|---|---|---|---|
| Kobo Clara 2E | Marvell/NXP 88W8987 (`moal`) | `uap0` | Tested |
| Kobo Libra Colour | MediaTek MT8113 (`wlan_drv_gen4m`) | `ap0` | Tested (firmware 4.46.23836, KOReader v2026.07.2) |
| Kobo Clara BW, Clara Colour | MediaTek MT8113 (`wlan_drv_gen4m`) | `ap0` | Untested (same driver source as the Libra Colour) |

On other devices, **Enable hotspot** reports that the Wi-Fi chip is not supported yet.

## How it works

### hostapd

The plugin writes a minimal `hostapd` config to `/tmp` and starts the bundled `hostapd` binary. hostapd handles the full 802.11 AP management: beacon frames, association, WPA2 handshake, etc.

### IP assignment and DHCP

After hostapd brings the AP interface (`uap0` or `ap0`) into AP mode, the plugin assigns `192.168.42.1/24` via `ip addr add`. It then starts the bundled `udhcpd` (a BusyBox DHCP server) , handing out leases from `.10` to `.100` with the Kobo as the default gateway.

### MediaTek Kobos (Libra Colour and similar)

MediaTek's driver has no always-present AP interface. Writing `A` to `/dev/wmtWifi` switches the chip to AP mode and creates `ap0`. Writing `0` leaves AP mode and powers Wi-Fi off, the same way KOReader's `disable-wifi.sh` does.

The chip cannot be a Wi-Fi client and an access point at the same time. So on these devices:

- **Starting with Wi-Fi on:** if KOReader's Wi-Fi is on, the plugin asks first (**Cancel** / **Turn off Wi-Fi and start hotspot**).
- **Wi-Fi not used since boot:** the plugin first starts MediaTek's firmware daemons (`wmt_loader`, `wmt_launcher`), as Nickel does. Then it loads the Wi-Fi kernel modules by turning Wi-Fi on and off once ("Loading Wi-Fi modules..."). Without the daemons, powering the chip reboots the Kobo (the same bug as [koreader#13197](https://github.com/koreader/koreader/issues/13197); fix from [koreader#16222](https://github.com/koreader/koreader/issues/16222)). If the daemons cannot be started, the plugin asks you to turn Wi-Fi on once from the Kobo home screen instead.
- **Stopping:** stopping the hotspot powers Wi-Fi off. The plugin then asks whether to turn Wi-Fi back on or keep it off.

hostapd logs `Failed to set TX queue parameters` and `Could not set station <name> flags for kernel driver` on this driver. Both are harmless: clients connect and the WPA2 handshake completes.

### Known limitation

KOReader turns Wi-Fi off when the Kobo goes to sleep, which also stops the hotspot. Keep the Kobo awake while the hotspot is in use.

## Porting to a different device

This was made to work with my Kobo Clara 2E, but it should work with most Kobo devices (I think, I haven't tested it on anything other than my own Kobo). The plugin itself is very simple, so it should be fairly easy to port to other devices. The main thing that would need to be done is to check if your device's network card supports broadcasting an AP, and getting `hostapd` and `udhcpd` binaries compatible with your device.

### 1. Check for a virtual AP interface

This plugin is built around the Marvell `uap0` interface. Other chipsets may expose a similar capability under a different name (e.g. `wlan1`, `ap0`). SSH into your device and check:

```bash
ip link show
cat /sys/class/net/*/uevent | grep -i ap
```

If your driver supports simultaneous client + AP mode, you'll see a second interface. If it doesn't, you'd need `hostapd` with a different driver backend (e.g. `driver=nl80211` on a mac80211-based driver) and may need to manage the interface differently.

Add your driver to the `BACKENDS` table in `main.lua`, keyed by the `WIFI_MODULE` value KOReader reports (`echo $WIFI_MODULE` in KOReader's terminal), with the name of its AP interface.

### 2. Obtain hostapd for your architecture

The bundled `hostapd` binary is a statically linked ARMv7 hard-float executable built for Kobo (Freescale i.MX6, `armhf`). For a different architecture you need to cross-compile it.

### 3. Obtain udhcpd for your architecture

The bundled `udhcpd` binary is a copy of the device's own BusyBox binary, renamed so that BusyBox's multi-call dispatch runs it as the `udhcpd` applet. We did not cross-compile this: Kobo already ships BusyBox with the `udhcpd` applet included.

**To check on your target device:**

```bash
busybox --list | grep udhcpd
```

If `udhcpd` is listed, copy the BusyBox binary into the plugin directory and name it `udhcpd`:

```bash
cp $(which busybox) plugins/hotspot.koplugin/udhcpd
```

If the device does not have BusyBox, or has BusyBox without the `udhcpd` applet, you will need to cross-compile BusyBox yourself.

### 4. Verify `ip` is available

The plugin uses the `ip` command (iproute2) to assign the gateway address. Most KOReader-supported devices have this. If yours doesn't, you can substitute `ifconfig uap0 192.168.42.1 netmask 255.255.255.0 up` instead.

### 5. Remove the Kobo guard

`main.lua` has an early return that disables the plugin on non-Kobo devices:

```lua
if not Device:isKobo() then
    return { disabled = true }
end
```

Remove or replace this with whatever device check is appropriate for your target.
