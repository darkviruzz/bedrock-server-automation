# CurseForge API Application

This file contains the prepared content for the CurseForge API application for this project.

## Personal fields to fill manually

**Your nickname**  
<YOUR NICKNAME>

**Your real name**  
<YOUR REAL NAME>

**Email**  
<YOUR EMAIL>

**Your full Discord username**  
<YOUR DISCORD USERNAME>

## Project fields

**Project name**  
Bedrock Server Automation

**Describe the project goal and scope**

A private, non-commercial automation project for deploying and maintaining a Minecraft Bedrock Dedicated Server on my personal Proxmox homelab.

The project creates an Ubuntu LXC container, installs and configures the official Minecraft Bedrock Dedicated Server, downloads a small predefined selection of CurseForge Bedrock add-ons, configures them for the server world, and performs automated backups, compatibility checks, health checks and server updates.

The CurseForge API is used only to query metadata and obtain approved download URLs for a small number of explicitly selected Minecraft Bedrock add-ons. The project does not provide a general-purpose CurseForge client, search engine, mirror or mod download service.

Expected usage is very low: one private server with only occasional API requests during initial installation and periodic update checks.

**Why are you building this project?**

I am building this project to automate the administration of a private Minecraft Bedrock server for family and friends.

The goal is to make a cross-platform Minecraft server usable from devices such as Windows PCs and iPads while keeping server administration reproducible and safe. The automation handles installation, updates, backups, add-on configuration, compatibility checks and rollback in case an update fails.

Using the CurseForge API allows the server to obtain supported add-ons from their official source instead of relying on unofficial download links, scraping, mirrors or manually maintained URLs.

This is a personal hobby and homelab project and is not intended as a commercial service or public mod distribution platform.

**Supported games**  
Minecraft

**Website URL**  
https://github.com/darkviruzz/bedrock-server-automation

**Git URL**  
https://github.com/darkviruzz/bedrock-server-automation.git

**I understand that file distribution through the API is subjected to the mod author's approval**  
Yes

**Are you looking to monetize the project?**  
No

**If you have a business model please describe it**

No business model. This is a private, non-commercial hobby project for personal and family use. There are no advertisements, subscriptions, donations, paid services or other forms of monetization.

**If you're planning to distribute mods, how would you contribute to the mod authors?**

The project is not intended to publicly redistribute, mirror or re-host mods.

Add-on files are obtained directly from CurseForge using the official API and only when the mod author's CurseForge distribution settings permit API downloads. The project will respect the author's distribution permissions and will not provide alternative public download links or copies of the files.

The downloaded add-ons are used only on my private Minecraft server for a small group of authorized players.

Where Minecraft itself needs to provide a resource pack to an authenticated player joining the private server, this is limited to the normal private-server gameplay process and is not offered as a public download or distribution service.

**I understand that above certain volumes I might be required to reduce API calls, or alternatively, pay associated bandwidth costs**  
Yes

**I have read and agree to the API's TOS**  
Yes

**Additional notes**

This project is intentionally designed to minimize CurseForge API and CDN usage.

It manages one private Minecraft Bedrock server and a small fixed set of add-ons. Update checks are performed periodically rather than continuously, and downloads occur only when installation or an actual add-on update requires them.

The project does not expose the CurseForge API key to server users. The key is stored locally with restricted permissions and is used only by the server administration scripts.

The automation also checks release status and add-on compatibility before applying updates and keeps backups so that failed updates can be rolled back without repeatedly downloading files.
