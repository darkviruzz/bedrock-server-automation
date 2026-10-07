# Add-on update workflow

## Normal case: API-visible project

1. The CT checks CurseForge Release metadata once per day.
2. A new Release generates one Gotify notification with a clickable CurseForge file page.
3. The administrator downloads the file through the normal CurseForge website.
4. The local Bash or PowerShell helper uploads the downloaded file to the CT.
5. The CT creates a backup, validates/imports the pack, restarts BDS, health-checks it, and rolls back if necessary.
6. Repeated daily checks do not spam the same Release; reminders are throttled.

## Author disables third-party API distribution

CurseForge's third-party API does not expose that project's project/file information. The server therefore cannot reliably detect a new Release through the official API.

The workflow intentionally does not scrape or bypass that setting. Instead, Gotify sends a throttled reminder containing the normal CurseForge project files page so the administrator can check it manually.

## No API key yet

The BDS server still works. Initial add-ons are presented as manual CurseForge download links. When the API key is later approved, run:

```bash
mc-bedrock-set-curseforge-key
```

The daily metadata watcher immediately becomes active.

## Upload security

The CT exposes a token-authenticated HTTP PUT endpoint on the LAN (default TCP `19134`). It accepts only the five configured add-on slugs and caps upload size. The endpoint must not be port-forwarded to the public Internet.

The token can be displayed on the CT with:

```bash
mc-bedrock-upload-info
```
