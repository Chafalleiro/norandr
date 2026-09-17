# xorg-mode-tools

Two small Free Pascal console programs for fixing broken Xorg display
configuration on old hardware **from a text TTY**, without depending on
`xrandr`, a running X session, or Wayland.

- `xorgmode` — generic Xorg fix. Calls `cvt`, finds the active DRM
  connector, detects the kernel driver, and writes
  `/etc/X11/xorg.conf.d/10-monitor.conf`.
- `nvidia-norandr` — NVIDIA-specific fix. Patches an existing
  `/etc/X11/xorg.conf` (the one `nvidia-settings` generates) so that
  `HorizSync`, `VertRefresh` and `metamodes` are forced to values you
  choose, bypassing the driver's own EDID-based calculations.

Both are intended to be run **from `tty1`–`tty6` as root**, while the
broken X session is dead or stopped.
They can also be ran in ssh sessions or even X11 forwarded ones. Note that the latter will probably mess with your Desktop icons and panels.

---

## 1. Why not `xrandr`, and why not Wayland

### `xrandr` fails when you need it most

`xrandr` talks to the running X server. That is exactly the problem:

1. **If the X session is unusable, `xrandr` cannot run.** On old GPUs
   with no working EDID, X either comes up at a wrong resolution, or the
   screen is black. In the black-screen case you cannot open a terminal
   inside the session to type `xrandr` — there is nothing to type into.
   You are already forced to switch to a TTY, and once you are there
   `xrandr` is useless because there is no X server to talk to.

2. **Even when it works, it can make the desktop unusable.** On some
   hardware combinations (typically old GPUs paired with quirky
   monitors, and especially with modes the driver synthesises on the
   fly), applying a mode via `xrandr` makes the X server spend so much
   time re-validating the mode that the desktop becomes extremely
   sluggish — sometimes a keystroke takes seconds to appear. The effect
   is not a crash; it is worse, because you cannot do anything.

3. **`xrandr` changes are not persistent.** They live for the lifetime
   of the X session. Every reboot or display-manager restart reverts
   them.

The two programs here write an **Xorg configuration file**, which is
read once when the X server starts, before any session exists. That is
the only place where a fix can live if the goal is "the machine boots
to the right mode every time, even after a reboot."

### Wayland

Wayland solves the EDID problem differently but not necessarily better
for this use case. The author does not use it for two reasons:

1. The machines in question are old, often reassembled from parts, and
   the Wayland compositors on those systems were less predictable than
   Xorg in reproducing the desired mode.
2. Personal preference. Xorg with an explicit `xorg.conf` is a known,
   inspectable, text-editable system, which matters a lot when you are
   fixing things from a TTY.

If you are running a Wayland session these tools will not help. Log out
to a TTY, make sure the display manager will start an Xorg session
(`/etc/gdm/custom.conf` → `WaylandEnable=false`, or the equivalent for
your DM), then use them.

---

## 2. Building

Requires Free Pascal (`fpc`) and, for the generic tool, `cvt` from
`xorg-server` / `xorg-x11-server-utils`.

```bash
sudo apt install fpc x11-xserver-utils      # Debian/Ubuntu
sudo dnf install fpc xorg-x11-server-utils  # Fedora
sudo pacman -S fpc xorg-xrandr xorg-server  # Arch (cvt is in xorg-server)

fpc xorgmode.pas
fpc nvidia-norandr.pas
```

You get two binaries: `xorgmode` and `nvidia-norandr`.

---

## 3. `xorgmode` — generic Xorg fix

Use this when the GPU driver is `intel`, `amdgpu`, `radeon`,
`nouveau`, `modesetting`, or any driver that respects a Modeline
written in `xorg.conf.d/`.

### What it does, step by step

1. **`cvt WIDTH HEIGHT [REFRESH]`**
   Generates a standard VESA/CVT modeline. The output is a comment line
   with timings and a `Modeline "WxH_RR" ...` line that goes verbatim
   into the config.

   Example:
   ```
   # 1920x1080 59.96 Hz (CVT 2.07M9) hsync: 67.16 kHz; pclk: 173.00 MHz
   Modeline "1920x1080_60.00"  173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync
   ```

2. **`ls -1 /sys/class/drm/card*-*/status`** then `cat` each.
   Enumerates DRM connectors. A connector whose status is `connected`
   is the monitor we want. If none is `connected` (which happens with
   some legacy or proprietary drivers, or when a forwarded SSH session
   holds a connector open), the first non-`disconnected` one (e.g.
   `unknown`) is used as a fallback.

   The connector name is extracted with a regex from the directory
   name (`card0-VGA-1` → `VGA-1`), rather than with a chain of
   `basename | cut | sed`.

3. **`lspci | grep -i VGA`**, then `lspci -vv -s <PCI>`.
   Gets the PCI address from the first line (e.g. `01:00.0`) and reads
   `Kernel driver in use:` from the verbose dump. The kernel driver is
   mapped to an Xorg driver (`i915` → `intel`, `nvidia` → `nvidia`,
   `amdgpu` → `amdgpu`, and so on).

4. **Writes `/etc/X11/xorg.conf.d/10-monitor.conf`** with three
   sections (`Monitor`, `Screen`, `Device`) using the connector name,
   the modeline from `cvt`, and the Xorg driver from step 3. Any
   existing file of that name is copied to
   `10-monitor.conf.bak.<timestamp>` first.

5. **Optional restart** of the display manager with `systemctl`
   fallbacks (`display-manager`, `lightdm`, `gdm`, `sddm`).

### Example generated file

```conf
Section "Monitor"
    Identifier "VGA-1"
    Modeline "1280x1024_60.00"  109.00  1280 1368 1496 1712  1024 1027 1034 1063 -hsync +vsync
    Option "PreferredMode" "1280x1024_60.00"
EndSection

Section "Screen"
    Identifier "Screen0"
    Monitor "VGA-1"
    DefaultDepth 24
    SubSection "Display"
        Modes "1280x1024_60.00"
    EndSubSection
EndSection

Section "Device"
    Identifier "Device0"
    Driver "intel"
EndSection
```

### Keys

```
Tab / Shift+Tab   cycle Width -> Height -> Refresh -> resolution grid
Arrows            move in the grid (Up/Down jump one row)
Enter             in text field: call cvt; in grid: apply resolution
C                 call cvt with current values
F                 find active DRM display
D                 find VGA driver
W                 write the config (backs up first)
R                 restart display manager
Q                 quit
```

### When to use `xorgmode`

- Intel / AMD / Nouveau / modesetting machines where the correct mode
  can be forced via a Modeline.
- Machines whose monitor EDID is bad or missing and where you know (or
  can guess) the native resolution.

### When **not** to use it

- NVIDIA proprietary driver. It ignores `xorg.conf.d` modelines in most
  cases; see the next section.

---

## 4. `nvidia-norandr` — NVIDIA fix

Use this with the NVIDIA proprietary driver (`nvidia`, including the
390 legacy branch).

### Why a different tool

The NVIDIA driver ignores the `Monitor` modeline section in the way
Xorg's generic drivers use it. It reads `HorizSync` and `VertRefresh`
from the `Monitor` section **only** for validation, then computes
timings itself for whatever `metamodes` list it finds, or from EDID if
`metamodes` is absent. On a monitor whose EDID is missing or wrong, the
result is a mode that the panel cannot lock onto — often a black screen.

The workaround, discovered by trial and error, is:

1. Provide a full `/etc/X11/xorg.conf` generated by `nvidia-settings`
   (or a hand-made template — the program will create one if none
   exists).
2. Force `HorizSync` and `VertRefresh` to ranges you know the monitor
   accepts (typical safe values for a generic CRT/LCD:
   `30.0 - 80.0` and `55.0 - 75.0`).
3. Force `Option "metamodes" "WIDTHxHEIGHT +0 +0"` to a mode you know
   the monitor accepts.

The driver then synthesises timings inside the accepted ranges instead
of trying to honour a bogus EDID.

#### NOTES
 - To know the exact timing of the monitor you can search for its specs. This patterns worked for me in several seach engines. "(monitor_name) specs datasheet vertrefresh horsync"
 - You can also create your own EDID, there are helpful links in archwiki and the net. But this worked and is less scary.

### What it does

On startup it reads `/etc/X11/xorg.conf` if present, pre-filling
`HorizSync`, `VertRefresh`, and matching the current `metamodes`
resolution against the built-in list.

On `W`:

- **If `/etc/X11/xorg.conf` exists**, it is copied to
  `xorg.conf.bak.<timestamp>`, then three lines are rewritten by regex:
  - `HorizSync ...`
  - `VertRefresh ...`
  - `Option "metamodes" "..."` → `"WIDTHxHEIGHT +0 +0"`

  Everything else (`Device`, `BoardName`, `SLI`, `Stereo`,
  `nvidiaXineramaInfoOrder`, input devices, etc.) is left untouched, so
  a config produced by `nvidia-settings` keeps all its customisations.

- **If it does not exist**, a complete working template is written with
  the chosen values.

### Keys

```
Tab / Shift+Tab   cycle HorizSync -> VertRefresh -> resolution grid
Arrows            move in the grid
Enter             in text field: move focus; in grid: select resolution
Backspace         delete a character in the focused text field
W                 write / patch /etc/X11/xorg.conf
R                 restart display manager
Q                 quit
```

### Fields

- **HorizSync** — horizontal sync range in kHz, e.g. `30.0 - 80.0`.
- **VertRefresh** — vertical refresh range in Hz, e.g. `55.0 - 75.0`.

Both are free text: you can type any range the monitor accepts. The
defaults (`30.0 - 80.0` / `55.0 - 75.0`) are safe for almost any
CRT-era or early-LCD panel and are a good starting point.

### Example patched section

```conf
Section "Monitor"
    # HorizSync source: builtin, VertRefresh source: builtin
    Identifier     "Monitor0"
    VendorName     "Unknown"
    ModelName      "CRT-1"
    HorizSync       30.0 - 80.0
    VertRefresh     55.0 - 75.0
    Option         "DPMS"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    Option         "Stereo" "0"
    Option         "nvidiaXineramaInfoOrder" "CRT-1"
    Option         "metamodes" "1920x1080 +0 +0"
    Option         "SLI" "Off"
    Option         "MultiGPU" "Off"
    Option         "BaseMosaic" "off"
    SubSection     "Display"
        Depth       24
    EndSubSection
EndSection
```

### Notes specific to NVIDIA

- The `+0 +0` suffix on `metamodes` anchors the mode at the top-left.
  Without it the driver may try to centre or scale, which reintroduces
  the timing guesses we are trying to avoid.
- `nvidiaXineramaInfoOrder` is left alone. If your actual connector is
  not `CRT-1` (common values: `DFP-0`, `DFP-1`, `CRT-0`), edit that one
  line manually **once**. The patcher will not touch it afterwards.
- The metamodes regex is anchored on the literal `Option "metamodes" "`
  prefix, so it will not match `nvidiaXineramaInfoOrder` or any other
  option that happens to contain similar text.
- If you are on the 390 legacy branch (last supported for Kepler and
  older), keep the backup files. If a future driver update changes the
  option parser, the old file is the way back.

---

## 5. Recovering a working desktop after the fix

Sometimes the Xorg fix works — X starts, the login screen appears, and
you can log in — but the desktop session itself comes up broken:
toolbars missing, panels frozen, windows not repainting, or the whole
session hanging on a black background with a cursor. The display is
correct; the session's cached state is not.

This happens because desktop environments cache display-dependent
geometry and let stale values override the new mode. Both XFCE and MATE
are known for this.

### XFCE

The offending state lives in the per-channel XML files under
`~/.config/xfce4/xfconf/xfce-perchannel-xml/`. The usual culprits are:

- `displays.xml`
- `xfwm4.xml`
- `xfce4-session.xml`
- `xsettings.xml`

**Fix (from a TTY, as your normal user, not root):**

```bash
# log out of the broken session first, or at least kill xfce4-session
mkdir -p ~/.config/xfce4/xfconf/xfce-perchannel-xml/backup.$(date +%F)
cd ~/.config/xfce4/xfconf/xfce-perchannel-xml/
mv displays.xml       backup.$(date +%F)/ 2>/dev/null
mv xfwm4.xml          backup.$(date +%F)/ 2>/dev/null
mv xfce4-session.xml  backup.$(date +%F)/ 2>/dev/null
mv xsettings.xml      backup.$(date +%F)/ 2>/dev/null
```

Then restart the display manager or log back in. XFCE will regenerate
fresh files with the correct geometry.

If you want to be surgical, move only `displays.xml` and `xfwm4.xml`
first. Those two cover the majority of cases. `xfce4-session.xml` and
`xsettings.xml` are a second pass if the first does not help.

**If the session does not even come up**, switch to a TTY, log in as
the user, and run:

```bash
pkill -u $USER xfce4-session
pkill -u $USER xfwm4
```

Then go back to the display manager, or start X manually with
`startx` to see the raw errors.

### MATE

MATE's window manager is **Marco**, and Marco caches display state in a
place that is not a simple XML file. You can confirm Marco is the
problem:

```bash
# from a TTY, as the user whose session is broken
pkill -u $USER marco
```

If the desktop immediately becomes usable, Marco was the cause. This is
**temporary** — Marco respawns and the problem returns on the next
session. The reliable fix, in practice, is to **reinstall the MATE
packages**:

```bash
sudo apt install --reinstall mate-desktop-environment mate-desktop-environment-extras marco
# or, for a minimal set:
sudo apt install --reinstall marco mate-panel mate-session-manager
```

The reason a reinstall works where config deletion does not is that the
broken state is not always in `~/.config` — some of it lives in
compiled schema or in the dconf database. Reinstalling the packages
resets the schema side, and on next login the session rebuilds its
state cleanly. If you want to try the cheaper route first:

```bash
dconf reset -f /org/mate/
rm -rf ~/.config/mate ~/.cache/mate
```

Then log in again. This is worth trying before a reinstall.

---

## 6. Troubleshooting the fix itself

### Black screen after writing the config

Switch to a TTY with `Ctrl+Alt+F2` (or `F3`–`F6`). Then:

```bash
# restore the previous config
ls -l /etc/X11/xorg.conf.d/10-monitor.conf.bak.*   # generic tool
ls -l /etc/X11/xorg.conf.bak.*                     # nvidia tool

mv /etc/X11/xorg.conf.d/10-monitor.conf /tmp/      # remove the generic one
# or
cp /etc/X11/xorg.conf.bak.YYYYMMDDHHMMSS /etc/X11/xorg.conf  # restore nvidia
```

Then restart the display manager (`sudo systemctl restart display-manager`
or the appropriate one for your distro).

### X does not start at all

Read the log:

```bash
less /var/log/Xorg.0.log
# or, depending on distro:
journalctl -u display-manager -b
```

Look for `(EE)` lines. Common ones:

- `No devices detected` — wrong `Driver` value in the `Device`
  section. Re-run the tool and pick the right one, or edit by hand.
- `No matching Mode` — the modeline is not accepted by the driver. Try
  a lower resolution, or a different refresh rate.
- `Failed to load module "nvidia"` — the NVIDIA kernel module is not
  loaded. Check `dmesg | grep -i nvidia` and `modprobe nvidia`.

### The mode is applied but the picture is off-centre or flickering

The monitor is being driven outside its tolerance. Lower `HorizSync`
or `VertRefresh` at the top of the accepted range; for the generic
tool, drop the refresh rate (or pick a lower resolution from the grid).

### The tool cannot find a display

If `F` reports `No active display found`, no DRM connector reported
`connected` and none reported anything other than `disconnected`.
Check:

```bash
ls -1 /sys/class/drm/
for f in /sys/class/drm/card*-*/status; do echo "$f: $(cat $f)"; done
```

If nothing is `connected` or `unknown`, the monitor genuinely is not
being seen by the kernel. That is a cable, KVM, or kernel-driver
problem, not an Xorg one — no config file will fix it.

### "Systemd says the unit is masked" when pressing R

Some distros name the display manager differently. Restart manually:

```bash
sudo systemctl restart lightdm    # or gdm, sddm, lxdm, xdm
```

and then go back to the tool to continue.

### The desktop is slow after applying the mode

This is the reason the author avoids `xrandr` in the first place; if it
happens with the Xorg config approach, the mode is at the edge of what
the hardware can handle. Reduce the resolution one step, or drop the
refresh rate by 5–10 Hz. On NVIDIA, narrowing the `VertRefresh` range
(e.g. `56.0 - 60.0`) sometimes helps the driver pick a cheaper timing.

---

## 7. Files written and where

| Tool              | File                                   | Backup pattern                        |
|-------------------|----------------------------------------|---------------------------------------|
| `norandr`        | `/etc/X11/xorg.conf.d/10-monitor.conf` | `10-monitor.conf.bak.YYYYMMDDHHMMSS`  |
| `nvidia-norandr`  | `/etc/X11/xorg.conf`                   | `xorg.conf.bak.YYYYMMDDHHMMSS`        |

Nothing else is touched. No user config is modified by the tools; the
XFCE/MATE cleanup in section 5 is manual on purpose, so you can see
exactly which files were removed.

---

## 8. Quick recipe

Generic Intel / AMD machine, monitor not detected:

1. `sudo ./xorgmode`
2. Type width/height, press `C`, `F`, `D`, `W`.
3. Press `R`.
4. If the desktop comes up broken: section 5.
5. If the screen is black: section 6, restore backup, try a lower mode.

NVIDIA proprietary machine, monitor not detected:

1. `sudo ./nvidia-norandr`
2. Set `HorizSync` / `VertRefresh` if the defaults do not work.
3. Pick a resolution, press `W`.
4. Press `R`.
5. If the desktop comes up broken: section 5.
6. If the screen is black: `Ctrl+Alt+F2`, restore
   `/etc/X11/xorg.conf.bak.*`, restart the DM, and try narrower ranges.

---

## 9. Credits

## 9. Credits

- **Code and documentation:** DeepSeek (AI assistant).
- **Design, requirements, and field testing:** Chafalleiro,
  who specified the exact commands, the Xorg and NVIDIA config
  formats, the desktop-recovery workarounds for XFCE and MATE, and the
  rationale for avoiding `xrandr` and Wayland on the hardware in
  question. Everything in sections 3, 4, and 5 that is not Pascal is a
  direct transcription of that experience.
- **Built with:** Free Pascal (`fpc`) and the standard `RegExpr`
  library that ships with it. No external Pascal dependencies.
- **Tested on:** Debian-family systems with `cvt` from
  `x11-xserver-utils` and NVIDIA 390 legacy, plus generic Intel and
  AMD machines.

If you fork this and change it, feel free to adjust the first bullet;
the second is the one that should stay, because that is where the
actual knowledge lives.

## 10. Machines tested
*****************************
- MB: Asus M4A78-AM.
- CPU: AMD Athlon(tm) 64 X2 Dual Core Processor 6000+
- Memory: 8GB DDR2 800MHz.
- GPU: Nvidia Geforce GT 430, 2GB VRAM version.
- OS Debian 13 "Trixie".
- XFCE4
- Driver: Nvidia legacy 390.157
*****************************
- MB: Abit KN9(NF-MCP55 series).
- CPU: AMD Athlon(tm) 64 X2 Dual Core Processor 4600+
- Memory: 8GB DDR2 667MHz.
- GPU: XFX Nvidia Geforce 7300LE.
- OS Debian 13 "Trixie".
- XFCE4, Mate, LXDE. LXWT, Openbox, IceWM
- Driver: noveau
*****************************
- MB: Asus AM1B-ITX.
- CPU: AMD Sempron(tm) 3850 APU with Radeon(tm) R3
- Memory: 20GB DDR3 800MHz.
- GPU: Kabini [Radeon HD 8280 / R3 Series].
- OS Debian 12 "Bookworm".
- XFCE4, Mate, Kodi
- Driver: radeon
*****************************


## 11. TODO

I have 3 AGP boards assembled,  1 64bit micro and 2 32. But only 1 GPU card and no cases, when I decide to make a case I'll test them. Still to test in a DDR1 board, same as above no case and too much sloth.

Tested only in Debian13. I dream about testing this in other distros, but fortunately the dream the drifts to volcanoes of beer and that stuff and I forget it.
