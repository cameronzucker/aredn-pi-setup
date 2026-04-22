# Simplifying AREDN Service Deployment through Scripting
Setup tools to automate the deployment of practical services on a Pi 5, specifically for use with the AREDN network.

Scripts are meant to be run with a Pi 5/CM5 (untested) unless otherwise expressly indicated.

## Usage Instructions

Image your Pi 5 boot media with the official Pi imager utility: https://github.com/raspberrypi/rpi-imager

Select the Pi 5 and Raspbian 64-bit options. The media will be your USB-adapted M.2 drive (or other boot media).

![raspberry pi imager main setup dialogue](https://github.com/cameronzucker/aredn-pi-setup/blob/main/images/aredn-pi-imager-setup-main.jpg)

If the boot media doesn't show up, format it with [Rufus](https://rufus.ie/en/) as a non-bootable disk, then relaunch the imager and try again.

You'll be asked to customize your image. Click yes, then configure as shown below with your unique hostname, username, password, and time zone. Make sure SSH with password auth is enabled so it can be setup/shelled into from any device, and turn off telemetry at your discretion.

![raspberry pi imager OS customization dialogue](https://github.com/cameronzucker/aredn-pi-setup/blob/main/images/aredn-pi-imager-OS-customization-composite.jpg)

Boot your Pi, then SSH in:

```
ssh yourUsername@yourPi'sIP
```

Clone the repo and run the greenfield setup script:

```
git clone https://github.com/cameronzucker/aredn-pi-setup.git
cd aredn-pi-setup
chmod +x pi5-greenfield-setup.sh
sudo ./pi5-greenfield-setup.sh
```

The script will prompt for a WiFi hotspot SSID, channel, and passphrase up front, then run the rest unattended. It targets **Raspberry Pi 5** running **Raspberry Pi OS Trixie (64-bit Desktop)**. Re-running is safe — most steps are idempotent.

### What the script sets up

| Step | What happens |
|------|-------------|
| System | Enables VNC, I2C, and UART; disables fake-hwclock (Pi 5 has a native RTC) |
| Boot config | Sets `usb_max_current_enable=1` and PCIe Gen 3 (`dtparam=pciex1_gen=3`) |
| Firewall | UFW with deny-inbound defaults; allows SSH, HTTP/S, VNC, hotspot subnet, Tailscale |
| GPS / NTP | Installs `gpsd`, `gpsd-clients`, `pps-tools`, and `chrony` (manual GPS config required) |
| Tools | `tmux`, `git`, `gh`, `jq`, `ripgrep`, `fd`, `btop`, `nvme-cli`, and more |
| CAD | KiCad, FreeCAD, OpenSCAD, Inkscape (~1 GB, takes a while) |
| VS Code | Installed from Microsoft's apt repo with Claude Code and Codex extensions |
| AI CLIs | `claude` and `codex` via npm |
| Tailscale | Installed; prompts to run `tailscale up` at the end |
| Hotspot | Creates a WPA2 WiFi AP on `wlan0` sharing the `eth0` uplink via NetworkManager |
| Dark mode | GTK 3/4 dark theme preference written to user config |
## Hardware

This project is based on the Pi 5 for a few important reasons:
* Built-in Real Time Clock (RTC) which doens't consume GPIO pins<br>
* PCIe 3.0 bus for fast booting, responsive operation, and more robust network file server storage<br>
* Native support for booting from M.2 SSDs<br>
* Enough raw performance to plausibly act as a micro server for small numbers of concurrent users
* Class-leading software support using off-the-shelf Ubuntu distros (as opposed to alternatives like Orange Pi, Radxa, etc.)
* Excellent performance per Watt

## Parts List

Scripts are intended for the following reference hardware. They will probably work with other parts, but other combinations are untested. Bolded line items are the recommended configuration.

I have no affiliation with any linked vendors, and any particular link is not a directive to buy that part there. Copy your desired SKUs and shop around to combine orders and get the best deal.

### Base Pis
* Raspberry Pi 5 8 GB: https://www.pishop.us/product/raspberry-pi-5-8gb/<br>
* **Raspberry Pi 5 16 GB:** https://www.pishop.us/product/raspberry-pi-5-16gb/

### Combination M.2/PoE hats:
There are a few PoE hats which will work depending on the desired overall footprint. 2280 drives are recommended if form factor isn't an issue.

* Waveshare POE M.2 HAT+: https://www.waveshare.com/product/raspberry-pi/hats/poe-m.2-hat-plus.htm<br>
* 52Pi M.2 NVME M-KEY PoE+ Hat: https://52pi.com/products/m-2-nvme-m-key-poe-hat-with-official-pi-5-active-cooler-for-raspberry-pi-5-support-m-2-nvme-ssd-2230-2242<br>
* **52Pi P33 M.2 NVMe 2280 PoE+ HAT�:** https://52pi.com/products/p33-m-2-nvme-2280-poe-hat-extension-board-for-raspberry-pi-5

�This hat also provides 3.3/5/12V out on six pins (one hot for each voltage with adjacent ground), which is potentially useful for powering other small devices.

### Storage
This project makes use of M.2 drives for their quantum leap in speed and reliability over Micro SD cards. Since these Pis will be used as web application servers, including a file serve function which incurs frequent writes, this is an important factor and worth the relatively minor price increase. 2230/2242 drives are more expensive than larger 2280 drives and have worse sustained performance due to lacking DRAM cache, but they'll fit in smaller cases. The obstacle precluding use of truly robust enterprise SATA SSDs like the Intel P4610 is lack of boot support.

* For 2230/2242 - Samsung PM991a�: https://www.amazon.com/dp/B0BDWCC47L<br>
* 2230/2242 alternate - Official Raspberry Pi NVMe SSD: https://www.pishop.us/product/raspberry-pi-nvme-ssd-512gb/<br>
* **For 2280 - Crucial P3 Plus 500GB:** https://www.amazon.com/dp/B0B25NTRGD

�The PM991a is a high quality SSD which probably outperforms the official Pi 2230 SSD, but since the Pi 5 only offers PCIe 3.0 x1, the real world beneift of the better part may be negligible.

### RTC Battery Backup
If the Pi is shutdown or loses power, especially for extended periods, keeping the RTC running and accurate is valuable for expediting redeployment without relying on a GPS fix. While the Pi 5 has a built-in RTC chip, it needs an external battery connected to a dedicated header to supply power.

* Panasonic ML-2020 lithium manganese dioxide rechargeable battery: https://www.pishop.us/product/rtc-battery-for-raspberry-pi-5/<br>
* **RTCBattery Box Real Time Clock Holder for Pi 5�:** https://www.amazon.com/dp/B0CRKQ2MG1

�This option requires you to furnish a common CR2032 battery. This may be preferable due to their abundance if something should happen to the RTC battery. They are also higher capacity than rechargeable options, allowing for extended shutdown standby time (potentially years).

### Coolers
These Pis are intended for remote deployment in hot Southwest desert conditions and require active cooling. The following are known to work well:

* **Official Raspberry Pi 5 Active Cooler:** https://www.amazon.com/dp/B0CZLPX2HC<br>
* GeeekPi Active Cooler for Raspberry Pi 5: https://www.amazon.com/dp/B0CNVFCWQR

### Cases
There is some room for creativity here depending on whether additional hats on top of the M.2/PoE hat are desired. The choice will come down to personal preference.

* 52Pi makes a first party aluminum/acrylic case which fits their hat with some room to spare: https://52pi.com/collections/cases/products/case-for-raspberry-pi-5?variant=43067599749272<br>

However, an all-metal case offers better protection against RFI, which may be desirable in a radio-oriented environment. Geekworm makes some which fit their NVMe hats, which have the same footprint as 52Pi full length M.2/PoE hats:

* Geekworm P579: https://geekworm.com/products/p579

### Supporting Hardware
The script setup workflow involves creating the base Raspbian OS x64 image using the Pi imager utility. To do this efficiently, it should be imaged directly to an M.2 drive over a USB 3.0 or faster connection using an enclosure or adapter.

This is what I've used:<br>
* Sabrent USB 3.2 Type-C Tool-Free Enclosure for M.2 PCIe NVMe: https://www.amazon.com/dp/B08RVC6F9Y

But, any similar device will work.

## WIP - Onboard GPS
Including GPS directly on the board frees up a USB port and provides access to much more precise PPS timing. I haven't had a chance to test this on top of the M.2/PoE boards, so it's not included in the script yet.

* Waveshare LC29H Series Dual-band GPS Module for Raspberry Pi�: https://www.waveshare.com/lc29h-gps-hat.htm?sku=25278

�Requires an ML1220 rechargeable cell which is not included.

## Future Hardware
The ideal Pi hat would combine a UPS, PCIe 3.0 NVMe adapter, full 40 pin GPIO passthrough, and 24V *passive* PoE support (most AREDN hardware runs on 24V PoE). I recently found such a part from Pi Modules Technologies in Greece, and will create a branch for it if the hardware does what it says on the tin.

* M.2 � UPS and Power Management HAT Advanced/PPoE: https://pimodules.com/product/m-2-ups-and-power-management-hat-advanced-ppoe
