# usbip-scripts

Windows helper scripts to cleanly start, connect to, and disconnect from a remote `usbipd` server (such as a Raspberry Pi sharing a laser engraver, camera, or other USB peripherals) using [usbip-win2](https://github.com/cezanne/usbip-win2).

## What It Does

- **`usbipattach.bat`** (runs elevated as Administrator):
  1. Enables the Windows USB/IP Emulated Host Controller (`usbip2_ude`).
  2. Detaches any stale local USB/IP ports and restarts `usbipd` on the remote host over SSH.
  3. Discovers all exported USB devices on the remote host and attaches them.
  4. Displays active USB/IP ports and Windows COM devices.

- **`usbipdetach.bat`** (runs elevated as Administrator):
  1. Detaches all active local USB/IP ports.
  2. Stops `usbipd` on the remote host over SSH so USB devices are cleanly released back to the Pi.
  3. Disables the `usbip2_ude` emulated host controller driver on Windows.

## Configuration

The scripts read configuration from Windows environment variables **or** a gitignored `.env` file in the same directory as the scripts (Windows environment variables take precedence if both are set).

| Variable | Required | Description | Default |
| --- | --- | --- | --- |
| `USBIP_HOST` | Yes | Hostname or IP address of the USB/IP server | — |
| `USBIP_USER` | Yes | SSH username on the remote server | — |
| `USBIP_SSH_KEY` | Yes | Path to the SSH private key (supports `%USERPROFILE%`, etc.) | — |
| `USBIP_EXE` | No | Path to `usbip.exe` on Windows | `C:\Program Files\USBip\usbip.exe` |

### Option 1: `.env` file (recommended for double-clicking `.bat` files)

```powershell
Copy-Item .env.example .env
```

Edit `.env` with your Raspberry Pi's IP, SSH username, and SSH key path.

### Option 2: Windows Environment Variables

Set persistent user/system environment variables (note: UAC elevation does not carry over temporary session-only shell variables, so use `setx` or System Properties):

```powershell
setx USBIP_HOST "192.168.1.100"
setx USBIP_USER "pi"
setx USBIP_SSH_KEY "%USERPROFILE%\.ssh\usbipd_key"
```

## Prerequisites

- **Windows**: `usbip-win2` installed (`usbip.exe` + `usbip2_ude` driver) and OpenSSH client (`ssh`).
- **Remote Server (Raspberry Pi)**:
  - `usbip` installed and `usbipd` configured as a systemd service with the desired USB devices bound.
  - Passwordless SSH key access for `USBIP_USER` and passwordless `sudo` for `/bin/systemctl restart usbipd` and `/bin/systemctl stop usbipd`, e.g. via `/etc/sudoers.d/usbipd`:
    ```text
    <user> ALL=(root) NOPASSWD: /bin/systemctl restart usbipd, /bin/systemctl stop usbipd
    ```

## Usage

Double-click `usbipattach.bat` or `usbipdetach.bat` (or run from PowerShell/CMD). Both scripts automatically prompt for Administrator elevation via UAC and close after 5 seconds (or on any key press).
