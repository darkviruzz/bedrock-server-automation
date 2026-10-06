# Bedrock Server Automation

Automated deployment and maintenance of a private **Minecraft Bedrock Dedicated Server** in an Ubuntu 24.04 LXC on **Proxmox VE**.

The project is intended for a small private/family server and emphasizes reproducible setup, stable releases, backups, health checks, and rollback rather than a large modpack.

## What it installs

The Proxmox host script creates an unprivileged Ubuntu 24.04 LXC and copies the server setup script into it.

The server setup installs and configures:

- Official Minecraft Bedrock Dedicated Server (stable Linux release)
- Bedrock Essentials+
- Advanced Gravestone
- Lilium Dynamic Light
- Epic Machinery
- Better on Bedrock
- systemd service
- Daily offline backups with retention
- Guarded automatic BDS updates with backup, health check, and rollback
- Weekly CurseForge add-on update checks
- Optional guarded automatic add-on release updates
- Bedrock allowlist helper
- Add-on manifest validation that rejects Beta/Preview/Experimental dependencies

## Requirements

### Proxmox host

- Proxmox VE with an active LXC-capable storage
- Ubuntu 24.04 LXC template availability through `pveam`
- Working bridge, normally `vmbr0`
- Internet access from the container
- Run the host script as `root`

### CurseForge

A personal CurseForge API key is required for automated add-on downloads.

**Never commit the API key to this repository.** The setup script asks for it interactively and stores it only inside the server container at:

```
/etc/minecraft-bedrock/curseforge.key
```

with root-only permissions.

## Installation

Clone or download this repository onto the Proxmox node and keep both scripts in the same directory.

```bash
chmod +x 01_proxmox_create_mcbedrock_ct.sh 02_mcbedrock_setup.sh
./01_proxmox_create_mcbedrock_ct.sh
```

The first script interactively asks only for host-specific settings and provides safe defaults for CTID, hostname, CPU, RAM, storage, bridge, and networking.

After the container has been created:

```bash
pct enter <CTID>
/root/02_mcbedrock_setup.sh
```

The second script asks for the Minecraft server settings, initial Xbox/Microsoft gamertags for the allowlist, and the CurseForge API key.

## Default server settings

- Survival
- Normal difficulty
- 10 players
- Cheats disabled
- Allowlist enabled
- IPv4 UDP 19132
- IPv6 UDP 19133
- View distance 16
- Tick distance 6
- Daily backups, 14-day retention
- Automatic stable BDS updates enabled
- Automatic add-on updates disabled by default; weekly update check enabled

## Allowlist

Bedrock uses the player's **Xbox Live / Microsoft Gamertag**.

After installation:

```bash
mc-bedrock-allowlist list
mc-bedrock-allowlist add "Gamertag"
mc-bedrock-allowlist remove "Gamertag"
```

## Administration

Useful commands inside the LXC:

```bash
mc-bedrock-status
mc-bedrock-test
mc-bedrock-backup
mc-bedrock-update-bds
mc-bedrock-update-addons
mc-bedrock-update-addons --apply
journalctl -u minecraft-bedrock -f
systemctl list-timers 'mc-bedrock-*'
```

## iPad / Bedrock clients

On an iPad connected to the same network:

1. Open Minecraft.
2. Choose **Play → Servers → Add Server**.
3. Enter the LXC IP address.
4. Use UDP port **19132**.

Required resource packs are provided by the server. No manual client-side mod installation is intended.

For access from outside the LAN, UDP 19132 must additionally be forwarded by the router to the LXC address.

## Update safety

BDS updates are transactional:

1. Stop server.
2. Create offline backup.
3. Install stable BDS update.
4. Start and run health checks.
5. Roll back to the previous release and backup if the update fails.

Add-on automatic updates are disabled by default. When explicitly enabled, only CurseForge **Release** files are selected, and the same backup/test/rollback approach is used.

## Scope

This is a private, non-commercial hobby/homelab project. It does not mirror or re-host CurseForge files and does not provide a public mod distribution service. Add-on downloads use the official CurseForge API and respect the file's API distribution availability.

## Files

- `01_proxmox_create_mcbedrock_ct.sh` — creates the Proxmox LXC.
- `02_mcbedrock_setup.sh` — installs and configures BDS and add-ons inside the LXC.
