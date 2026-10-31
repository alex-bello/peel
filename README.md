# peel

Turn a Raspberry Pi 3B with a USB-attached DYMO LabelWriter 450 Turbo into a driverless network label printer. Any Mac, iPhone, Windows 10/11 or Linux machine on the LAN can print to it with its built-in IPP Everywhere / AirPrint / Mopria support. No DYMO software is installed on clients.

peel uses [LPrint](https://github.com/michaelrsweet/lprint) (Michael Sweet's label printer application), not CUPS. LPrint runs as a network server, advertises each printer over mDNS as an IPP Everywhere printer, and has a built-in web UI for administration. It runs natively on Raspberry Pi OS Lite. There's no Docker, and CUPS is deliberately not installed (it can grab the USB printer and conflict with LPrint).

> **Status:** these scripts were written without access to the hardware. They discover details such as the driver name, USB URI, media names and port at run time instead of assuming them, but they have **not yet been run on a Pi**. The "expected output" below is exact for messages peel prints itself (`ok …`, `==> …`) and only *approximate in shape* for output that comes from `lprint`. If something differs, the troubleshooting section and `scripts/discover.sh` are the first stops, and please fix the docs afterwards.

## What you need

- Raspberry Pi 3B, a 16 GB+ microSD card, and a power supply
- DYMO LabelWriter 450 Turbo with a USB cable and a roll of labels
- Ethernet cable to your router (Wi-Fi works, but Ethernet is more reliable for a printer)
- A Mac/PC with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

## 1. Flash the SD card

In Raspberry Pi Imager choose **Raspberry Pi 3** → **Raspberry Pi OS Lite** (the current release; 64-bit is fine on a 3B). Open the OS customisation settings and set:

| Setting | Value |
| --- | --- |
| Hostname | `labels` (must match `PRINTER_HOSTNAME` in `config.env`; reachable as `labels.local`) |
| Username / password | your choice (SSH key is better than a password) |
| Wi-Fi | leave **unset**: use Ethernet |
| Locale / time zone | yours |
| Services → Enable SSH | **on** (public-key authentication preferred) |

Write the card, put it in the Pi, connect **Ethernet** and the **DYMO's USB cable**, power on the printer, then power on the Pi.

## 2. Give the Pi a stable address

Clients find the printer by name over mDNS, but a stable address avoids surprises. In your router's DHCP settings, create a **DHCP reservation** (a.k.a. static lease) for the Pi's MAC address. Find the MAC and current IP in the router's client list, or after step 3 with `ip -br link` on the Pi.

## 3. Get the repo onto the Pi and configure it

```sh
ssh <your-user>@labels.local
sudo apt-get update && sudo apt-get install -y git     # skip if `git --version` already works
git clone https://<forgejo-host>/Operator/peel.git
cd peel
cp config.env.example config.env
nano config.env          # defaults are fine for a first run; see step 6 for MEDIA_READY
```

`config.env` is gitignored. Keep a copy somewhere safe (password manager, another machine) so a reflash doesn't mean re-deriving it.

## 4. Dry run (optional but recommended)

```sh
DRY_RUN=1 ./setup.sh
```

Prints every change it would make and changes nothing. Expect `[dry-run] …` lines for apt installs and the systemd unit, ending with `==> Dry run complete; nothing was changed.`. On the Pi, with `lprint` not yet installed, the printer step only says what it would discover.

## 5. Run setup

```sh
./setup.sh      # re-executes itself under sudo
```

What it does, in order, and what to expect:

| Step | Output you should see |
| --- | --- |
| Preflight | `ok OS: Debian GNU/Linux … (aarch64)` |
| Hostname | `ok hostname already labels` (or it sets it) |
| CUPS check | ` ok no CUPS`. If CUPS is installed it **stops** with the purge command to run. |
| Packages | apt output, then ` ok using /usr/bin/lprint (…)`. Installs `lprint` from apt if this OS release packages it; otherwise it warns *"No 'lprint' package candidate…"* and falls back to the snap. |
| systemd | Either ` ok the package ships its own unit: lprint.service`, or `==> No unit shipped; installing /etc/systemd/system/lprint.service`. Then ` ok server listening on port(s): <port>` |
| Printer | ` ok driver: <name>` and ` ok device: usb://DYMO/…`, then the printer is added |
| Media | A `warn` listing media names if `MEDIA_READY` is empty (expected on the first run) |
| Summary | `ok Done. peel is set up.` with the Web UI and IPP URLs |

The summary prints the actual port. Don't assume it; LPrint's default differs by how it's run, and `setup.sh` reads it from the running server.

It is safe to re-run at any time. It re-applies `config.env`, restarts the service only if the unit file changed, and re-adds the printer only if its USB URI or driver changed.

If it fails, it stops with a `FAIL` message that says what to do. The common ones are covered under [Troubleshooting](#troubleshooting).

## 6. Choose your label size

LPrint needs to know which media is loaded. Names are driver-specific, so list them:

```sh
sudo ./scripts/discover.sh
```

Look in the *Options and media* section for the media names that match your labels (for example, a standard address label is 1-1/8″ × 3-1/2″, DYMO 30252). Put the exact name in `config.env`:

```sh
MEDIA_READY="<exact name from the list>"
```

Re-run `./setup.sh`. It sets both the default `media` and `media-ready` on the printer. If the name isn't valid, setup warns you and prints the media lines again.

## 7. Test print

```sh
sudo ./scripts/test-print.sh                  # "PEEL TEST", hostname and date
sudo ./scripts/test-print.sh "HELLO WORLD"    # custom first line
```

Expect `==> Rendering test label …`, `==> Submitting to 'DYMO_450_Turbo'`, then ` ok Submitted.`, and a label comes out. LPrint has no text renderer, so the script draws the text into a PNG with standard-library Python and submits it. The image defaults to 1050×330 px (3.5″ × 1.1″ at 300 dpi). For other labels set `TEST_PNG_SIZE=WxH` (use `sudo -E`).

## 8. Add the printer on your devices

The web UI is at `http://labels.local:<port>/`, and the printer's IPP URL is `ipp://labels.local:<port>/ipp/print/<PRINTER_NAME>`. Both are printed at the end of `setup.sh` and by `scripts/discover.sh`. Use those exact values below (`<port>` and `<name>`).

### macOS
1. **System Settings → Printers & Scanners → Add Printer, Scanner or Fax…**
2. On the **Default** tab, pick the printer (it appears as `<name> @ labels`). "Use" should say *AirPrint* or *Secure AirPrint*. Click **Add**.
3. If it doesn't appear: the **IP** tab → Protocol *Internet Printing Protocol – IPP*, Address `labels.local:<port>`, Queue `ipp/print/<name>`, Use *AirPrint* if offered (or *Generic IPP Everywhere*).

### iPhone / iPad
Nothing to install. In any app: **Share → Print → Select Printer**. The printer shows up on its own if you're on the same network. Choose the paper size that matches your labels.

### Windows 10 / 11
1. **Settings → Bluetooth & devices (Win 11) / Devices (Win 10) → Printers & scanners → Add device.** Wait for it to appear and select it. Windows uses its built-in IPP class driver.
2. If it doesn't appear: **The printer that I want isn't listed → Select a shared printer by name** and enter `http://labels.local:<port>/ipp/print/<name>`.

### Linux
- **GUI** (GNOME, KDE): Settings → Printers → Add; the printer is auto-discovered.
- **Command line** (needs the CUPS *client*, on your desktop, not the Pi):
  ```sh
  lpadmin -p labels -E -v ipp://labels.local:<port>/ipp/print/<name> -m everywhere
  lp -d labels somefile.pdf
  ```

## Things peel looks up instead of hardcoding

| What | How peel finds it | How you can check |
| --- | --- | --- |
| `lprint` available in apt for this OS release | `apt-cache policy lprint`; falls back to the snap | `apt-cache policy lprint` |
| Driver for the 450 Turbo | first column of the one `lprint drivers` line matching "450 Turbo" (not "Twin Turbo"); fails if 0 or >1 match | `lprint drivers \| grep -i dymo` |
| USB device URI | the one `usb://…` URI on a DYMO line of `lprint devices`; fails if 0 or >1 match | `sudo lprint devices` |
| Valid media names | printed from `lprint options -d <printer>` | `sudo ./scripts/discover.sh` |
| Server port, web UI and IPP URL | the TCP port the running `lprint` process listens on (`ss -ltnp`) | `sudo ./scripts/discover.sh` |
| systemd unit | uses the package's or snap's if it ships one, else installs [`systemd/lprint.service`](systemd/lprint.service) | `systemctl cat lprint` |

Override any of the first three in `config.env` (`DRIVER`, `DEVICE_URI`, `INSTALL_METHOD`) if discovery picks wrong.

## After a reflash

Repeat steps 1, 3 and 5 (copy your saved `config.env` back in step 3). With `MEDIA_READY` already set, the printer comes back fully configured with no further steps. Do 7 to confirm.

## Troubleshooting

First, the basics:

```sh
systemctl status lprint            # (or the snap unit shown at the end of setup)
journalctl -u lprint -b --no-pager | tail -50
sudo ./scripts/discover.sh
```

### Printer not discovered on clients
- Is the server up and listening? `sudo ss -ltnp | grep lprint` should show a port.
- Is the Pi advertising? On any Linux box (`sudo apt install avahi-utils`): `avahi-browse -rt _ipp._tcp` should list the printer. On macOS: `dns-sd -B _ipp._tcp`.
- Can you reach it by name? `ping labels.local`. If that fails, mDNS is blocked: check for Wi-Fi *client isolation*, a separate VLAN/guest network, or a router that filters multicast. mDNS doesn't cross subnets without a reflector.
- On the Pi, `systemctl status avahi-daemon` should be active. After a hostname change, `sudo systemctl restart avahi-daemon`.
- Windows sometimes doesn't auto-discover: use *Select a shared printer by name* (see above). That bypasses mDNS (but `labels.local` must still resolve; use the Pi's IP address if not).

### Wrong label size / prints cropped, scaled or rotated
- `MEDIA_READY` must be the name LPrint uses for the roll that is physically loaded. Re-run `sudo ./scripts/discover.sh`, fix `config.env`, and re-run `./setup.sh`.
- Clients choose a paper size per print job: pick the one matching your label (iOS and macOS show it in the print dialog; in Windows it's under printing preferences).
- For a test print on a different label, set `TEST_PNG_SIZE` to match its aspect ratio.
- LPrint's `print-scaling` option (`auto`, `fit`, `fill`, `none`; see `lprint options -d <printer>`) controls how artwork is scaled; set it with `PRINTER_OPTIONS="print-scaling=fit"` if your build supports it.

### USB / permission problems
- Does the Pi see the printer at all? `lsusb | grep -i 0922` (0922 is DYMO's USB vendor ID). Nothing: try another cable, port or power cycle; check `dmesg | tail -20`.
- `lprint devices` shows nothing but `lsusb` does. This is usually permissions: run it with `sudo`. peel runs the service as root, so the service itself doesn't need extra rules. If you want a non-root service later, you need a udev rule such as `SUBSYSTEM=="usb", ATTR{idVendor}=="0922", MODE="0660", GROUP="<service group>"` in `/etc/udev/rules.d/`.
- Is something else holding the printer? `dpkg -l | grep -E 'cups|cups-daemon'` should be empty (setup refuses to continue otherwise). Also check `lsmod | grep usblp`, since the kernel's `usblp` driver can claim printer-class devices.
- Snap install: `snap connections lprint` and look for an unconnected USB-related plug; `sudo snap connect lprint:raw-usb`.
- A stale URI after swapping the printer for another unit: clear `DEVICE_URI` in `config.env` (or fix it) and re-run `./setup.sh`; it re-adds the printer when the URI changes.

### Setup fails with …
- *"No driver matching '450 Turbo'"*: run `lprint drivers | grep -i dymo`, then set `DRIVER=` in `config.env`.
- *"No DYMO USB printer found"*: see USB above.
- *"Package 'cups' is installed"*: run the `apt-get purge` command it prints, then re-run.
- *"No 'lprint' process is listening after 30s"*: read `journalctl -u lprint -b`. If the unit shipped by peel has the wrong start behaviour on your LPrint version (for example, `lprint server` forks into the background instead of staying in the foreground), change `Type=` in [`systemd/lprint.service`](systemd/lprint.service) and re-run.

## Printing from software: the IPP endpoint

The printer's IPP URL (`ipp://labels.local:<port>/ipp/print/<name>`) is the integration point. A future web-based label designer can render labels to PNG or PDF and submit them over IPP (`Print-Job`) to that URL, with no DYMO-specific code and no printer drivers.

## Repo layout

| Path | Purpose |
| --- | --- |
| `setup.sh` | Idempotent install and configure (`DRY_RUN=1` to preview) |
| `config.env.example` | Settings template; copy to the gitignored `config.env` |
| `systemd/lprint.service` | Unit file, installed only if the package/snap doesn't ship one |
| `scripts/test-print.sh` | Test text label |
| `scripts/discover.sh` | Prints driver, device, media and URL discoveries |
| `scripts/lib.sh` | Shared helpers |
| `scripts/make-test-png.py` | Renders the test label (standard-library Python) |

Everything is bash, plus Python's standard library for the test label. `pnpm run validate` syntax-checks the shell scripts; run `shellcheck setup.sh scripts/*.sh` too if you have it.
