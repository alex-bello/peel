# peel

Turn a Raspberry Pi 3B with a USB-attached DYMO LabelWriter 450 Turbo into a driverless network label printer. Macs, iPhones, Windows 10/11 and Linux machines on the LAN are meant to print to it with their built-in IPP Everywhere / AirPrint / Mopria support, with no DYMO software on the clients.

peel uses [LPrint](https://github.com/michaelrsweet/lprint) (Michael Sweet's label printer application), not CUPS. LPrint runs as a network server, advertises the printer over mDNS and has a built-in web UI. peel runs it natively on Raspberry Pi OS Lite. There is no Docker, and CUPS is deliberately not installed: setup refuses to continue if it finds it.

## Read this first

**Security: printing and the web UI are open to everyone on the LAN.** LPrint's web UI and IPP endpoint have no authentication here (authentication is deferred work). Anyone who can reach the Pi's port can print, and the web UI is not password-protected either. Keep the Pi on a network you trust.

- **The port is pinned.** The server listens on `LISTEN_PORT` (default `8631`), so the URLs survive restarts. Upstream's own default is random, which peel avoids. `setup.sh` prints the port actually in use.
- **apt install: the server runs as a dedicated non-root user** `lprint` (no login shell). **snap install: the server runs as root.** The snap fallback is a documented exception to the non-root rule: the snap runs LPrint as snap-managed root, and `LISTEN_PORT` is ignored there. The snap path has never been run on hardware.
- **The IPP endpoint is the integration point** for a future label designer: `ipp://labels.local:8631/ipp/print/DYMO_LabelWriter_450_Turbo` with the defaults (see [Printing from software](#printing-from-software-the-ipp-endpoint)).

## What has and has not been verified

peel has been run on exactly one machine: a Raspberry Pi 3 Model B Rev 1.2 running Raspberry Pi OS based on Debian 13 "trixie" (aarch64, imaged with Raspberry Pi Imager), `lprint` 1.3.1-1+b1 from apt, and a DYMO LabelWriter 450 Turbo (USB `0922:0021`). Nothing else has been tried: other Pi models, other OS releases, other LPrint versions, Wi-Fi, a second printer.

This README keeps three kinds of statement apart:

- **Observed**: seen on that Pi, as recorded in the project's pull requests (#9, #10, #13) and feature record (issue #1). Only fragments were recorded, so this README quotes fragments; it does not reproduce whole sessions.
- **From the script**: the exact text a peel script prints, copied from its source. This is what to expect, not a capture from the Pi.
- **Unverified**: not run on hardware. Marked as such where it appears.

Unverified in particular: every step on macOS, iOS, Windows and Linux clients; the snap install path; two DYMO printers attached at once; physically unplugging the printer; cloning the repo from the Forgejo URL below on the Pi (the recorded hardware runs used a copy cloned from a mirror); and a custom text label, plus the default test label on matching media (see [Test print](#7-test-print)); and the whole [Recovery](#recovery) section (cloning, rebuild, hardening), none of which has been run.

## What you need

- Raspberry Pi 3B, a microSD card (16 GB or more is a sensible size; not tested against a smaller one), and a power supply
- DYMO LabelWriter 450 Turbo with a USB cable, and a roll of labels
- An Ethernet cable to your router (preferred: a printer should not depend on Wi-Fi; Wi-Fi has not been tested)
- A computer with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

## 1. Flash the SD card

In Raspberry Pi Imager choose **Raspberry Pi 3** and **Raspberry Pi OS Lite (64-bit)**, then open the OS customisation settings. The exact labels differ between Imager versions.

| Setting | Value |
| --- | --- |
| Hostname | `labels` (matches `PRINTER_HOSTNAME` in `config.env`; the Pi is then reachable as `labels.local`) |
| Username / password | your choice (an SSH key is better than a password) |
| Wi-Fi | leave unset and use Ethernet |
| Locale / time zone | yours |
| Enable SSH | on (public-key authentication preferred) |

Write the card, put it in the Pi, connect Ethernet and the DYMO's USB cable, power on the printer, then power on the Pi.

Observed: the test Pi was imaged with Raspberry Pi Imager and uses cloud-init. `setup.sh` renamed it to `labels`, and the new hostname persisted across a reboot, but cloud-init regenerated `/etc/hosts` with the new and the old hostname side by side on the `127.0.1.1` line; `labels` still resolved. That Pi was imaged with a different hostname, so setting `labels` in Imager from the start has not been run. The script's notice says that setting the hostname in Imager avoids the `/etc/hosts` rewrite; that remedy is unverified.

## 2. Give the Pi a stable address

Clients find the printer by name over mDNS, but a stable address avoids surprises and gives you something to fall back on if mDNS fails (see [Troubleshooting](#printer-not-discovered-by-clients)). In your router's DHCP settings, create a DHCP reservation (a static lease) for the Pi's MAC address. Find the MAC and current IP in the router's client list, or on the Pi with `ip -br link` and `ip -br addr`.

## 3. Get the repo onto the Pi and configure it

```sh
ssh <your-user>@labels.local
sudo apt-get update && sudo apt-get install -y git     # skip if `git --version` already works
git clone https://git.dageniusal.top/operator/peel.git
cd peel
cp config.env.example config.env
nano config.env
```

Observed: `git` had to be installed on the test Pi. Unverified: `git clone` from the URL above on the Pi (if that server asks for credentials or is not reachable from your Pi, clone from wherever you host the repository).

`config.env` is gitignored and holds no secrets. The defaults are fine for a first run except `MEDIA_READY` (see [step 6](#6-choose-your-label-size)). Keep a copy of your `config.env` somewhere safe (see [Recovery](#recovery)).

| Key | Default | Meaning |
| --- | --- | --- |
| `PRINTER_HOSTNAME` | `labels` | Hostname the Pi advertises (`<hostname>.local`) |
| `INSTALL_METHOD` | `auto` | `auto` uses apt if `lprint` is packaged, else the snap; or force `apt` or `snap` |
| `SNAP_NAME` | `lprint` | Snap name for the snap path |
| `LISTEN_PORT` | `8631` | Pinned server port (apt path; ignored with the snap; must be 1024 or more) |
| `SERVER_OPTIONS` | empty | Extra `lprint server` arguments (apt path only; not `server-port`) |
| `PRINTER_NAME` | `DYMO_LabelWriter_450_Turbo` | Queue name; it is also part of the IPP and web UI paths |
| `DRIVER`, `DEVICE_URI` | empty | Override discovery (see [Setup failure messages](#setup-failure-messages)) |
| `MEDIA_READY` | empty | The label stock that is loaded |
| `PRINTER_OPTIONS` | empty | Extra `lprint modify` options, `NAME=VALUE` separated by spaces |
| `TEST_PNG_SIZE` | `1050x330` | Test label size in pixels, `WIDTHxHEIGHT` |

## 4. Dry run (optional but recommended)

```sh
DRY_RUN=1 ./setup.sh
```

Prints what it would do and changes nothing. It needs no root. If `config.env` is missing it warns and uses `config.env.example`.

Recorded output: the run ends with `Dry run complete; nothing was changed.` and exits 0. That run was on macOS, so it showed the apt path only and did not exercise real apt, snap or `lprint` discovery. A dry run on the Pi was not recorded.

## 5. Run setup

```sh
./setup.sh      # re-runs itself under sudo
```

What it does, in order, with the text the script prints (from the script) and what was observed:

| Step | From the script | Observed on the Pi |
| --- | --- | --- |
| Preflight | `ok OS: <pretty name> (<arch>)` | not recorded |
| CUPS check | ` ok no CUPS`, or it stops with the `apt-get purge` command to run | With `cups-daemon` installed it exited 1 with the purge instructions before changing anything |
| Hostname | `ok hostname already labels`, or a warning and a rename | Rename to `labels` persisted across a reboot |
| Packages | apt output, then `ok lprint <version> via apt`; with no apt candidate it warns and falls back to the snap | `lprint` 1.3.1-1+b1 via apt. Snap path not run |
| Service user, USB | creates user `lprint`, writes `/etc/udev/rules.d/99-peel-dymo.rules` (USB vendor `0922` to group `lprint`, mode `0660`) | The device node changed from `root:lp 0664` to `root:lprint 0660` |
| systemd | installs `/etc/systemd/system/lprint.service`, which overrides the unit the package ships | The package ships its own `lprint.service` and its install script starts it as root until peel's unit replaces it; peel's unit was in effect afterwards |
| Start | `ok server listening on port 8631`, `ok server process owner: lprint` | Process owner `lprint`; listening on `0.0.0.0:8631`; the web UI answered `HTTP/1.1 200 OK` (page shows `LPrint Version 1.3.1`) |
| Printer | `ok driver: <driver>`, `ok device: usb://DYMO/...`, then the printer is added or reconciled | Driver `dymo_lw-450-turbo`; device URI of the form `usb://DYMO/LabelWriter%20450%20Turbo?serial=<serial>` |
| Media | a warning that lists the valid media names if `MEDIA_READY` is empty or invalid | Invalid and empty values warned, listed the valid names, exited 0 and changed nothing |
| Summary | `ok Done. The LPrint server is running and the printer is configured.` and a block with the web UI and IPP URLs | Summary showed port 8631, owner `lprint` and IPP URI `ipp://labels.local:8631/ipp/print/DYMO_LabelWriter_450_Turbo` |

Setup is safe to re-run. Observed on the final code: a second run changed nothing (same process ID, same state files), printing `printer already added with this name, URI and driver`, `media-ready already <name>` and `active as 'lprint' with the current unit; not restarting`.

A real reboot was also observed: the service came back by itself about 25 seconds later as `lprint`, and the printer was still listed with no manual step.

If setup fails it stops with a `FAIL` message that says what to do; see [Setup failure messages](#setup-failure-messages).

## 6. Choose your label size

LPrint needs to know which label stock is loaded. Media names are LPrint's, so list them:

```sh
sudo ./scripts/discover.sh
```

Look under "Options and media" for the name that matches your roll, then set it in `config.env` and re-run `./setup.sh`:

```sh
MEDIA_READY="<exact name from the list>"
```

Names are self-describing, for example `oe_address-label_1.125x3.5in` (the printer's own default on the test Pi), `oe_shipping-label_2.125x4in` or `oe_sm-multipurpose-label_1x2.125in`. The test Pi's DYMO 30336 roll was set with `MEDIA_READY=oe_sm-multipurpose-label_1x2.125in`; matching other DYMO part numbers to names is up to you and has not been checked.

Observed: `-o media-ready=<name>` on its own sets both the ready media and the default media; an unknown name is accepted silently by LPrint, which is why setup checks the name against the printer's list and reads the result back.

## 7. Test print

```sh
sudo ./scripts/test-print.sh                  # first line "PEEL TEST", second line "<hostname> <date>"
sudo ./scripts/test-print.sh "HELLO WORLD"    # custom first line (quote it if it has spaces)
DRY_RUN=1 ./scripts/test-print.sh             # render and show the command; print nothing
```

LPrint has no text renderer, so the script draws the text into a PNG with standard-library Python and submits it with `lprint submit` as the service user. Output from the script (not a capture from the Pi): `==> Rendering test label (1050x330 px)`, `==> Submitting to 'DYMO_LabelWriter_450_Turbo'` and ` ok Submitted (the command above exited 0; that is not proof of a printed label). ...`.

**The default size fits one media only.** The default image is 1050x330 px, which is 3.5 x 1.1 inches at 300 dpi: sized for the `oe_address-label_1.125x3.5in` media. Observed on the test Pi:

- On a DYMO 30336 roll (`oe_sm-multipurpose-label_1x2.125in`), the default 1050x330 image spread over two labels.
- At 600x270 on that matching media the label fit on one label, upright, with a full border and both lines, no blank feeds, top-left aligned (seen by the user; label measurements were not recorded).

If your label comes out split, cropped or scaled, set `TEST_PNG_SIZE` to match your label at 300 dpi (for example `600x270`) in `config.env`, or for one run with `sudo TEST_PNG_SIZE=600x270 ./scripts/test-print.sh`. Putting it in `config.env` is the safer route: the `sudo VAR=value` form is the one the script documents, but which form was used on the Pi was not recorded. Making the default follow the loaded media is a known gap (follow-up #14).

Not run on the Pi: a custom text argument, the default size on `oe_address-label_1.125x3.5in` media, `TEST_PNG_SIZE` with an invalid value, and a first line that starts with `-`. No `lprint submit` options are passed, because none are confirmed on the Pi.

## 8. Add the printer on your devices

**None of the client steps below has been run.** The client matrix (macOS, iOS, Windows 11 and 10, Linux) is pending hardware verification, so each section is an outline of the built-in driverless flow, not a record of what you will see. If a step differs, trust your system and please report it.

What was observed on the Pi side: its avahi advertises `_ipp._tcp` and `_ipps._tcp` with `rp=ipp/print/DYMO_LabelWriter_450_Turbo`, and the web UI answered at `http://<pi-ip>:8631/` from another machine. Use the values `setup.sh` printed at the end (or run `sudo ./scripts/discover.sh` again):

- Web UI: `http://labels.local:8631/`
- IPP URL: `ipp://labels.local:8631/ipp/print/DYMO_LabelWriter_450_Turbo`

These use the defaults; a different `LISTEN_PORT` or `PRINTER_NAME` changes them. `labels.local` only resolves on the same subnet (see [Troubleshooting](#printer-not-discovered-by-clients)); otherwise use the Pi's IP address in its place.

### macOS (unverified)

1. System Settings, Printers & Scanners, Add Printer, Scanner or Fax.
2. On the Default tab, look for the printer. If it is listed, choose it and add it.
3. If it is not listed, use the IP tab: protocol Internet Printing Protocol (IPP), address `labels.local:8631`, queue `ipp/print/DYMO_LabelWriter_450_Turbo`. If a driver choice is offered, pick AirPrint or Generic IPP Everywhere.

### iPhone and iPad (unverified)

Nothing to install. In any app choose Share, Print, Select Printer; the printer should be listed if the device is on the same network and subnet. Choose the paper size that matches your labels.

### Windows 10 and 11 (unverified)

1. Settings, Bluetooth & devices (Windows 11) or Devices (Windows 10), Printers & scanners, Add device. If the printer is listed, select it; Windows should use its built-in IPP class driver.
2. If it is not listed: "The printer that I want isn't listed", then "Select a shared printer by name", and enter `http://labels.local:8631/ipp/print/DYMO_LabelWriter_450_Turbo` (or use the IP address). Whether Windows accepts the `http://` form here, rather than `ipp://`, has not been tried.

### Linux (unverified)

- Desktop (GNOME, KDE): Settings, Printers, Add; the printer should be discovered automatically.
- Command line, using the CUPS client tools on your own machine (not the Pi):

  ```sh
  lpadmin -p labels -E -v ipp://labels.local:8631/ipp/print/DYMO_LabelWriter_450_Turbo -m everywhere
  lp -d labels somefile.png
  ```

## Printing from software: the IPP endpoint

The printer's IPP URL, `ipp://<host>:<port>/ipp/print/<PRINTER_NAME>` (recorded with the defaults as `ipp://labels.local:8631/ipp/print/DYMO_LabelWriter_450_Turbo`), is the integration point for a future web-based label designer, which would render labels to an image and submit them over IPP. `setup.sh` and `scripts/discover.sh` print the real URL, reading the path from the server's own `printer-uri-supported`, so use that rather than building it by hand.

Not verified: a print job submitted over IPP from software (only `lprint submit` has been used). LPrint's own device id on the Pi lists PWG raster, URF, JPEG and PNG; PDF is not listed there, so do not assume PDF is accepted.

## Troubleshooting

First, the basics. These are the checks `setup.sh` and the scripts themselves point at:

```sh
systemctl status lprint
sudo journalctl -u lprint -b --no-pager | tail -50
sudo ./scripts/discover.sh
```

On the snap path the unit name differs (`systemctl list-unit-files 'snap.lprint.*'`); that path is unverified.

To run `lprint` by hand use the service user: `sudo -u lprint lprint <subcommand>` (for example `printers`, `devices`, `drivers`, `options -d DYMO_LabelWriter_450_Turbo`). Observed: this works, while plain `lprint` as root failed with `Unable to start server: No such file or directory` (a stale root socket existed at the time; the cause was not proven).

### Printer not discovered by clients

Exercised on the Pi: the server listening on its port (`0.0.0.0:8631`, process `lprint`), and avahi advertising `_ipp._tcp` and `_ipps._tcp` for this printer. The client-side commands below are unverified.

- Is the server up and listening? `sudo ss -ltnp | grep lprint` should show the port.
- Is the Pi advertising? Unverified command: on a Linux machine (`sudo apt install avahi-utils`), `avahi-browse -rt _ipp._tcp`; on macOS, `dns-sd -B _ipp._tcp`.
- Can the client resolve the name? Try `ping labels.local`.
- **mDNS does not cross subnets.** Observed: a Mac on one subnet could not resolve `labels.local` for a Pi on another. If your clients are on a different subnet or VLAN from the Pi (or a guest network, or Wi-Fi with client isolation, or a router that filters multicast), discovery will not work. Use the Pi's IP address in the URLs above (the web UI by IP was observed to answer from another machine; adding the printer by IP on each client OS is unverified), or put the clients and the Pi on the same subnet. The DHCP reservation from step 2 keeps that IP stable.
- On the Pi, `systemctl status avahi-daemon` should be active. After a hostname change, `sudo systemctl restart avahi-daemon` (setup already does this when it renames the host).

### Wrong label size, or the label comes out split, cropped or rotated

Exercised on the Pi: listing the media names and applying one (`MEDIA_READY`), and the default test label spreading over two labels on mismatched media.

- `MEDIA_READY` must be the name of the roll that is physically loaded: run `sudo ./scripts/discover.sh`, fix `config.env`, run `./setup.sh` again. Observed: an invalid or empty value only warns and lists the valid names.
- The default test label is sized for one media; use `TEST_PNG_SIZE` as described in [step 7](#7-test-print). Observed: on mismatched media it spread over two labels.
- Clients also choose a paper size per print job; pick the one that matches your label. Unverified, since no client has been run.
- Rotation and scaling options: none are documented or confirmed for `lprint submit` on the Pi, so none are recommended here.

### USB and permission problems

Exercised on the Pi: the udev rule and the resulting device permissions, the `lprint` CLI as the service user, and a device that LPrint could not claim.

- Does the Pi see the printer? `lsusb` should show vendor `0922` (DYMO). If not, check the cable, the port and the printer's power.
- Is the permission rule in place? Setup writes `/etc/udev/rules.d/99-peel-dymo.rules`. Observed: after setup the device node was `root:lprint 0660`; before the rule was applied it was `root:lp 0664`. Re-run `./setup.sh` to rewrite and re-apply it.
- Observed: when LPrint could not claim the device (a USB device deauthorised through sysfs, used as a stand-in for an unplugged printer), `lprint devices` printed `Unable to claim USB interface` and listed nothing, and setup then stopped with `No DYMO USB printer found`. Look for that line in `sudo journalctl -u lprint -b --no-pager`.
- Something else may hold the printer: CUPS (setup refuses to run with it installed), or an `lprint` started by hand. The kernel's `usblp` driver was bound to the printer on the test Pi and the service still read the device and printed.
- Unverified: the snap path. Its USB access is expected to come from the snap's `raw-usb` plug (`snap connections lprint`), which setup tries to connect.

### Setup failure messages

Texts copied from the scripts (each fragment below appears verbatim in them). "Observed" means that failure was triggered on the Pi; the others have not been triggered on hardware (some are covered by unit tests only).

| Message (contains) | What to do | Triggered on the Pi? |
| --- | --- | --- |
| `is installed. CUPS can claim the USB printer` | Preceded by `Package 'cups'` or `'cups-daemon'`. Run the purge command it prints (`sudo apt-get purge -y cups cups-daemon cups-browsed && sudo apt-get autoremove -y`), then re-run | Observed (`cups-daemon`) |
| `No DYMO USB printer found by 'lprint devices'.` | Check power and cable, `lsusb`, then re-run; or set `DEVICE_URI` (and `DRIVER`) | Observed, with a USB-deauthorisation stand-in |
| `Several DYMO USB printers found; peel manages exactly one:` | Set `DEVICE_URI` to the one you want, or unplug the others | Not run on hardware |
| `LPrint did not pair the device` | Set `DRIVER` in `config.env` | Observed, with a `DEVICE_URI` that did not match |
| `is not a driver LPrint knows.` | Fix `DRIVER` or leave it empty | Not run on hardware |
| `not found. Create it with: cp config.env.example config.env` | Create `config.env` | Not run on hardware |
| `must not set server-port` | Remove it from `SERVER_OPTIONS`; use `LISTEN_PORT` | Not run on hardware |
| `is below 1024, and the dedicated user` | Set `LISTEN_PORT` to 1024 or more | Not run on hardware |
| `Nothing is listening on port` | Read the status and journal it prints; if they show permission errors for user `lprint`, stop and report them; do not switch the service to root | Not run on hardware |
| `The lprint server runs as` | The unit was stopped and disabled; inspect `systemctl cat lprint` | Not run on hardware |
| `lprint is not installed. Run ./setup.sh first.` | Run `./setup.sh` (printed by `discover.sh` and `test-print.sh`) | Not run on hardware |
| `No printer '` | `test-print.sh` found no queue named `PRINTER_NAME`: run `./setup.sh` or fix `PRINTER_NAME` | Not run on hardware |
| `' failed (message above) AFTER this run deleted` | A re-add failed after the delete; fix the cause and re-run `./setup.sh` | Not run on hardware (could not be triggered) |
| `TEST_PNG_SIZE='` | Use `WIDTHxHEIGHT` in pixels, for example `1050x330` | Not run on the Pi |

`DEVICE_URI` caveat: `lprint add` accepts a device URI for a printer that is not attached, and setup does not detect it, so a wrong `DEVICE_URI` produces a queue that cannot print and no error. Leave it empty unless you need it (follow-up #12).

If setup stops after installing the package, it prints a notice that the package's own unit may have started a root server, with the commands to inspect and stop it. That notice has not been triggered on hardware.

### Other observation: SSH after a reboot

After real reboots of the test Pi, SSH to port 22 from one Mac was blocked for several minutes (about 14 at the longest) while `ping` and the LPrint port answered, and the Pi's sshd was running throughout. The cause is unknown and was not shown to be peel's. If you cannot SSH right after a reboot but the printer answers, wait and retry.

## Recovery

If the SD card dies, there are two ways back to a working printer: swap in a **cloned spare card** (no setup, if the clone is current), or **rebuild a blank card** from this repository and a saved `config.env`. Pick the clone if you prepared one; the rebuild needs nothing prepared except a saved `config.env`.

**Nothing in this section has been run.** No card has been cloned, no card has been rebuilt from a saved `config.env`, and no recovery drill has been done on the Pi 3B with the DYMO 450 Turbo, so no step count here is a measurement. Every command below is marked unverified; they are the standard tools' usual forms, not captures. The `dd` commands overwrite whatever device you name: read [Choosing the right device](#choosing-the-right-device-unverified) before running one. The recovery drill (a cloned card booting to a working printer, or a blank card rebuilt by the steps below, with the steps and count recorded) is still to be done, and until it is, treat these paths as untested.

What peel keeps on the card, per the setup script and the feature design (not tested as a backup): the OS, the cloned `peel` directory with your `config.env`, LPrint's state under `/var/lib/lprint`, the stamp `/var/lib/peel/printer.state`, the udev rule, the systemd unit and the hostname. `setup.sh` rebuilds all of it from `config.env`, which is what makes the rebuild short. The Pi's Ethernet MAC address belongs to the Pi, not the card, so the DHCP reservation from [step 2](#2-give-the-pi-a-stable-address) should still match after a card swap into the same Pi (unverified).

### Choosing the right device (unverified)

Both paths below copy whole disks with `dd`. Writing to the wrong device destroys its data, and `dd` does not ask. Before every `dd`:

- Shut the Pi down first (`sudo shutdown -h now`), wait until its activity LED stops, unplug the power, and only then take the card out. A card cloned while the Pi was running can be inconsistent.
- Identify the card by its **size and by whether it is removable or external**, comparing the list with the card plugged in and not plugged in. On macOS, `diskutil list external physical` lists only external physical disks; a built-in SD card slot may not appear there, so if the card is not listed, run plain `diskutil list` and identify the card by size and name, never by assumption. On Linux, `lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINT` shows size, model and the removable flag. Never pick the disk your computer boots from.
- `if=` is the source and `of=` is the destination. Swapping them overwrites the good card with the blank one.
- A spare card the **same size or larger** than the source is fine. A smaller one may fail to fit, even if the used space is small, because `dd` copies the whole device. Two cards sold with the same nominal size can differ slightly in real capacity, so prefer the same model or a larger card. On a larger card the extra space is simply unused (the partitions are not enlarged; unverified).
- The commands below use `<N>` (macOS disk number) and `sdX` or `sdY` (Linux device) as placeholders; replace them with what your listing shows. SD card readers on some Linux machines appear as `/dev/mmcblk0` instead of `/dev/sdX`.

### Cloned spare card (unverified)

Do this once the printer works (after [step 7](#7-test-print)), and again after any change you want the spare to have, such as a new `MEDIA_READY`. The clone is a snapshot, not a mirror.

**1. Read the card into an image file** (with the card in a reader on your computer, Pi powered off):

macOS (unverified):

```sh
diskutil list external physical             # find the card, e.g. disk4; check the size
diskutil unmountDisk /dev/disk<N>
sudo dd if=/dev/rdisk<N> of=peel-card.img bs=4m status=progress
diskutil eject /dev/disk<N>
```

`rdisk` is the raw device, which is faster than `disk`. Whether your macOS `dd` accepts `status=progress` depends on the macOS version (check `man dd`); without it, press Ctrl-T for progress.

Linux (unverified):

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINT      # find the card, e.g. sdb; check the size
sudo umount /dev/sdX1 /dev/sdX2                   # only the partitions that are mounted
sudo dd if=/dev/sdX of=peel-card.img bs=4M status=progress
sync
```

`peel-card.img` is as large as the card (for example 32 GB for a 32 GB card), so keep it on a disk with room. Keep it somewhere safe; it holds the Pi's SSH host keys and your user's password hash or authorized keys, so treat it as private (unverified for this card).

**2. Write the image to the spare card.** Either with Raspberry Pi Imager: Choose OS, scroll to "Use custom", pick `peel-card.img`, choose the spare card, and **decline OS customisation** (the image already holds your settings; menu labels differ between Imager versions, and Imager writing a custom image has not been tried here). Imager is for writing images; it is not known to read a card into an image, which is why step 1 uses `dd`. Or with `dd`:

macOS (unverified):

```sh
diskutil unmountDisk /dev/disk<N>            # the SPARE card's number
sudo dd if=peel-card.img of=/dev/rdisk<N> bs=4m status=progress
diskutil eject /dev/disk<N>
```

Linux (unverified):

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINT      # find the SPARE card (sdY below); check the size
sudo umount /dev/sdY1 /dev/sdY2                   # only the partitions that are mounted
sudo dd if=peel-card.img of=/dev/sdY bs=4M status=progress conv=fsync   # sdY = the SPARE card
sync
```

**3. Keep it, and swap it in.** Label the spare and store it with the Pi. To use it: power the Pi off, replace the card, power on. If the old card is still readable, keep it out of any Pi until you know what went wrong with it.

Expected after a swap, unverified: the service starts by itself at boot (observed for the original card, not for a clone), the printer is listed, and clients need no change because the hostname, port and IPP URL are the same. Check with `systemctl status lprint` and `sudo ./scripts/discover.sh`. A re-run of `./setup.sh` is safe and should change nothing if the clone is current; it is the way to apply a newer `config.env`.

**Do not put two cards on the network at once.** A clone has the same hostname (`labels`), the same service settings and the same SSH host keys as the original. With one Pi only one card fits, so this applies when you boot the spare in a second Pi (or any second machine) while the original is still running: the two would advertise the same `labels.local` name (mDNS resolves one of them or renames the other, behavior not tested), clients may print to either, and the DHCP reservation follows the MAC address, so the second Pi gets a different IP. Power off or remove the first before booting the second.

### Blank-card rebuild (unverified)

For when there is no clone. It needs your saved `config.env` (see the next section) and network access on the Pi for apt and the repository. It repeats the README's flash, clone-and-configure and setup steps ([1](#1-flash-the-sd-card), [3](#3-get-the-repo-onto-the-pi-and-configure-it) and [5](#5-run-setup)), with your saved file in place of editing a fresh one.

**6 manual steps are documented** (a count of the steps below, not a measured number; the drill that would time them and check them has not been run):

1. **Flash** a new card in Raspberry Pi Imager with the same settings as [step 1](#1-flash-the-sd-card): Raspberry Pi 3, Raspberry Pi OS Lite (64-bit), hostname `labels`, your user, SSH on.
2. **Connect and power on**: card in the Pi, Ethernet, the DYMO's USB cable and power, printer first, then the Pi.
3. **SSH in**: `ssh <your-user>@labels.local`. The new card has new SSH host keys, so your computer will probably refuse with a "host identification has changed" warning; clear the old entry with `ssh-keygen -R labels.local` and connect again (unverified).
4. **Get the repository**: on the Pi, `sudo apt-get update && sudo apt-get install -y git` (skip if `git --version` works), then `git clone https://git.dageniusal.top/operator/peel.git` (the same clone as README [step 3](#3-get-the-repo-onto-the-pi-and-configure-it), with the same unverified-from-the-Pi caveat).
5. **Restore `config.env`**: from your computer, `scp ~/peel-config.env <your-user>@labels.local:peel/config.env` (this assumes you cloned into your home directory as in step 4 and saved your copy as `~/peel-config.env` on your computer). Do not run `cp config.env.example config.env`; your saved file replaces it.
6. **Run setup**: `cd peel && ./setup.sh`. With a `MEDIA_READY` already in the saved file, the printer should be configured in one run.

Then, optionally and not counted: `sudo ./scripts/test-print.sh` to check that a label comes out (see [step 7](#7-test-print)). There is no step for clients if the hostname, port and queue name are unchanged (unverified), and none for the router if the Pi is the same Pi (same MAC address).

What `setup.sh` does for each of these on a blank card is described in [step 5](#5-run-setup) and was observed on one fresh card, not on a rebuild from a saved `config.env`. If `./setup.sh` fails, it says what to do; see [Setup failure messages](#setup-failure-messages).

### Keep a copy of config.env (copy commands unverified)

`config.env` holds only settings (hostname, port, queue name, media and options) and **no secrets**: the template `config.env.example` says none belong there and defines no password, token or key. It is gitignored and must never be committed, so the repository does not back it up. Keep a copy on a computer you control, outside the Pi, next to your notes about the Pi (the Imager user name, the router's DHCP reservation):

```sh
scp <your-user>@labels.local:peel/config.env ~/peel-config.env     # save a copy from your computer
```

The `scp` command is unverified, like the rest of this section; any way of getting the file off the Pi works. Refresh the copy whenever you change the file, for example after choosing `MEDIA_READY`. `setup.sh` reads `config.env` as a bash script, so only restore a copy that you wrote yourself; if you ever add something secret to it, treat the copy as secret as well. Copying the file onto a cloned card is not needed; it is already there.

### Optional hardening: read-only overlay filesystem (optional, unverified)

**Optional. Not enabled by `setup.sh`, and not planned to be. Not run on the test Pi.** Raspberry Pi OS can mount the root filesystem read-only and keep all changes in RAM, which reduces SD card writes and lets the Pi be powered off without a clean shutdown. It does not replace a spare card: a card can still fail, and RAM-backed changes are lost at reboot.

Unverified outline, from the `raspi-config` tool's documented options (menu names differ between releases; confirm in your version):

1. Finish setup first and confirm the printer works (`./setup.sh`, then a test print).
2. `sudo raspi-config`, then Performance Options, then Overlay File System, answer yes to enabling it, and yes or no to making the boot partition read-only. Reboot to apply.
3. To change anything later (`config.env`, a re-run of `./setup.sh`, apt upgrades), disable the overlay in the same menu, reboot, make the change, then enable it again.

What this probably means for peel, reasoned from the design notes and not tested: LPrint's state file under `/var/lib/lprint` appears to be written at shutdown (some changes were seen in it sooner, a newly added printer only after a restart), and with the overlay on that file would sit in RAM, so a printer or media change made through the web UI or `lprint modify` may be lost on reboot; logs (`journalctl`) and the print spool also live in RAM; and the 1 GB of RAM on a Pi 3B bounds how much changes can accumulate. Whether the pinned port, the udev rule, the `lprint` service and the printer survive a reboot with the overlay on has not been checked. A cloned card (the section above) also clones the overlay setting.

### Optional hardening: USB boot on the Pi 3B (optional, unverified)

**Optional. Not enabled by `setup.sh`. Not run on the test Pi.** The Pi 3B can boot from a USB mass storage device (for example a USB flash drive or SSD) instead of the SD card, which some people prefer to a card for wear. That this is more durable here has not been tested. The Pi 3B (unlike the 3B+) does not have this switched on from the factory; per the Raspberry Pi documentation, it is switched on by a one-time programmable (OTP) bit that **cannot be undone**. Unverified outline:

1. On a Pi 3B booted from the SD card, add `program_usb_boot_mode=1` to `/boot/firmware/config.txt` (the path on recent Raspberry Pi OS; older releases use `/boot/config.txt`), reboot, and check that the bit took with `vcgencmd otp_dump | grep 17:` (the documentation gives `17:3020000a` as the expected value; not seen here). Remove the line from `config.txt` afterwards; it is only needed once.
2. Write the OS to the USB device the same way as to a card (Imager, or the clone steps above with the USB device as the destination; identify it as carefully as in [Choosing the right device](#choosing-the-right-device-unverified)).
3. Boot with the USB device attached and, to be sure which one is used, without the SD card. Whether a bootable SD card is tried first, and how long the Pi 3B waits for the USB device, are not established here.

Things to weigh, all unverified for peel: the Pi 3B's Ethernet and its USB ports share one USB 2.0 bus, and the DYMO is on that bus too; a USB flash drive can wear out as well; and the OTP change is permanent.

## Known limitations

- Web UI and printing are open on the LAN; authentication is not implemented.
- The snap install path is unverified and runs as root; the port is not pinned there.
- The client matrix has not been run; the client sections above are outlines.
- The default test label size is tied to one media (follow-up #14); the `DEVICE_URI` override is not checked against attached devices (follow-up #12); wording and documentation fixes from review, and some remaining hardware evidence for the printer step, are tracked in follow-up #11.
- Not run on hardware: two DYMO printers at once, a physical unplug, the failure message for a failed `lprint add`, and printer options other than media across a reboot.
- [Recovery](#recovery) (cloned spare card, blank-card rebuild, optional hardening) is documented, but none of it has been run: no card was cloned, no rebuild from a saved `config.env` was done, and no recovery drill was run on the Pi.
- No label designer. The IPP endpoint above is where one would connect.

## Repo layout and development

| Path | Purpose |
| --- | --- |
| `setup.sh` | Idempotent install and configure (`DRY_RUN=1` to preview) |
| `config.env.example` | Settings template; copy to the gitignored `config.env` |
| `systemd/lprint.service` | Unit template, installed as `/etc/systemd/system/lprint.service` on the apt path |
| `scripts/discover.sh` | Prints version, drivers, devices, queues, media, port, printer state and the IPP URL |
| `scripts/test-print.sh` | Test text label |
| `scripts/make-test-png.py` | Renders the test label (standard-library Python) |
| `scripts/ipp-attrs.py` | Read-only IPP client used by setup and discovery (standard-library Python) |
| `scripts/lib.sh` | Shared helpers |
| `tests/` | Plain-bash tests (`tests/run.sh` runs each `tests/test-*.sh`) |

Everything is bash plus the Python standard library. Repository tooling uses PNPM and is not part of the Pi's setup or print path. `pnpm run validate` runs the lint (`bash -n` and `shellcheck -x`), the tests and the SDLC config check, and needs `shellcheck` installed (`brew install shellcheck` or `sudo apt-get install shellcheck`). Project rules for contributors are in [`AGENTS.md`](AGENTS.md) and [`SDLC.md`](SDLC.md).
