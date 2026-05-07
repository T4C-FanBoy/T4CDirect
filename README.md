# T4C Direct Launcher

> An alternative launcher for **The 4th Coming** that respects your machine.

A standalone PowerShell/WPF launcher that replaces `t4c.exe`. Same login, same updates, same client — without the watchdog and without the third-party process scanning.

---

## English

### Why this launcher exists

The original `t4c.exe` does two things it has no business doing:

1. **It scans your system.** It inspects the contents of other processes and files on your PC under the banner of "anti-cheat", without disclosing what it collects or where it's sent.
2. **It kills your client if it disappears.** `T4C Client.bin` runs a watchdog thread that, every 5 seconds, enumerates your Windows processes and calls `ExitProcess` on itself if `t4c.exe` is not in the list. There is no legitimate technical reason for the launcher to remain running while you play.

This launcher does the essentials — login, updates, starting the client — and nothing else.

### Features

- No scanning of third-party processes or files
- 6-byte in-memory patch of the watchdog in `T4C Client.bin` (with reversible `.bak` backup)
- Same official update mechanism as the vanilla launcher (`t4c.hash` + `t4c.version` from `t4c-world.com`)
- Per-server install picker — install only the server packs you actually play
- Credentials encrypted with **Windows DPAPI**, scoped to your Windows account (never leaves your PC, never travels in plain text)
- WPF GUI, single file, fully auditable
- The **Launch Game** button stays disabled while verification or update is in progress — no risk of starting the client mid-patch

### Installation

#### Option A — Pre-built `.exe`

1. Grab the latest `T4CDirect.exe` from [Releases](https://github.com/T4C-FanBoy/T4CDirect/releases).
2. Place it anywhere (Desktop, Start Menu, etc.).
3. Double-click. Accept the UAC prompt (admin is required to patch the client binary in `Program Files`).
4. On first launch, point it at your `T4C Client.bin` if it's not in the default install path.

#### Option B — Run the script directly

Requires PowerShell 5.1+ (default on Windows 10/11).

```powershell
git clone https://github.com/T4C-FanBoy/T4CDirect.git
cd T4CDirect
powershell -ExecutionPolicy Bypass -File .\t4c-direct.ps1
```

### Usage

1. Launcher detects (or asks for) your T4C install directory.
2. It checks for updates against the official manifest, downloads what's missing, and patches the watchdog.
3. Pick a server, enter your account/password, hit **Launch Game**.
4. Close the launcher whenever you want — the client keeps running.

The **Launch Game** button only becomes active when the footer shows `up to date` / `updated`. Failure states keep it locked so you can't launch a half-updated install.

### Building the `.exe`

Uses [PS2EXE](https://github.com/MScholtes/PS2EXE) — a thin .NET wrapper around the script.

```powershell
Install-Module -Name ps2exe -Scope CurrentUser

Invoke-PS2EXE `
  -InputFile  '.\t4c-direct.ps1' `
  -OutputFile '.\T4CDirect.exe' `
  -IconFile   'C:\Program Files (x86)\The4ThComing\t4c.ico' `
  -NoConsole `
  -RequireAdmin `
  -Title       'T4C Direct Launcher' `
  -Version     '1.0.0.0'
```

`-RequireAdmin` embeds a UAC manifest so the `.exe` self-elevates on launch. `-NoConsole` runs it as a pure GUI app.

### How it works (technical notes)

| Topic | Details |
|---|---|
| Watchdog patch | Replaces a 6-byte conditional jump at offset `0x147AF0` in `T4C Client.bin` with `NOP NOP NOP NOP NOP NOP`. Original bytes (`0F 84 ED 01 00 00`) are restored from `.bak` if anything fails. |
| Updates | Fetches `t4c.version` and `t4c.hash` from the official update server. Per-file MD5 verification, gzip-decompressed downloads. |
| Client binaries | `T4C Client.bin` is updated using a rename → download → patch → cleanup-or-revert flow, so a failed patch never leaves you with a broken client. |
| Server selection | Manifest is parsed for all `Server Files\<name>\...` entries. You pick which servers to install/keep up to date. |
| Credentials | Stored in `%LOCALAPPDATA%\T4CDirectLauncher\config.json`, password encrypted via `ConvertTo-SecureString` (DPAPI, current user only). |
| Process launch | The client is started with `CreateProcess` and the watchdog patch in place. The launcher exits cleanly; the client keeps running on its own. |

### File layout

```
%LOCALAPPDATA%\T4CDirectLauncher\
  config.json          # install dir, server, host/port, credentials, enabled servers, last manifest version

<install dir>\
  T4C Client.bin       # patched in place
  T4C Client.bin.bak   # original (only present during update flow)
  Server Files\<name>\ # per-server data
```

### Disclaimer

This is an unofficial, community-maintained tool. It is **not** affiliated with, endorsed by, or supported by the operators of The 4th Coming.

- Use at your own risk. The watchdog patch modifies a file in your install directory.
- The `.bak` backup gives you a one-step revert path; if you want to be extra safe, copy `T4C Client.bin` aside before first run.
- If a server's terms of service forbid modified clients, abide by them. This tool's purpose is to remove privacy-invasive launcher behavior, not to provide gameplay advantage.

### License

MIT — see [`LICENSE`](LICENSE).

---

## Français

### Pourquoi ce launcher

Le `t4c.exe` officiel fait deux choses qu'il n'a aucune raison de faire :

1. **Il scanne votre PC.** Il inspecte le contenu d'autres processus et fichiers sous le prétexte d'« anti-triche », sans préciser ce qu'il collecte ni où ça part.
2. **Il tue votre client s'il disparaît.** `T4C Client.bin` contient un thread « watchdog » qui, toutes les 5 secondes, énumère les processus Windows et appelle `ExitProcess` sur lui-même si `t4c.exe` n'est pas dans la liste. Il n'y a aucune raison technique légitime pour que le launcher doive rester ouvert pendant que vous jouez.

Ce launcher fait l'essentiel — login, mises à jour, lancement du client — et rien d'autre.

### Fonctionnalités

- Aucun scan de processus ou fichiers tiers
- Patch local de 6 octets sur le watchdog de `T4C Client.bin` (sauvegarde `.bak` réversible)
- Même mécanisme de mise à jour officiel que le launcher d'origine (`t4c.hash` + `t4c.version` depuis `t4c-world.com`)
- Sélecteur par serveur — installez uniquement les packs des serveurs sur lesquels vous jouez
- Identifiants chiffrés avec **DPAPI Windows**, liés à votre compte Windows (jamais transmis, jamais en clair)
- GUI WPF, un seul fichier, entièrement auditable
- Le bouton **Launch Game** reste désactivé pendant la vérification ou la mise à jour — impossible de lancer le client en plein patch

### Installation

#### Option A — `.exe` pré-compilé

1. Téléchargez le dernier `T4CDirect.exe` depuis les [Releases](https://github.com/T4C-FanBoy/T4CDirect/releases).
2. Placez-le où vous voulez (Bureau, menu Démarrer, etc.).
3. Double-clic. Acceptez l'UAC (les droits admin sont nécessaires pour patcher le client dans `Program Files`).
4. Au premier lancement, indiquez votre `T4C Client.bin` s'il n'est pas dans le chemin par défaut.

#### Option B — Lancer le script directement

Nécessite PowerShell 5.1+ (présent par défaut sur Windows 10/11).

```powershell
git clone https://github.com/T4C-FanBoy/T4CDirect.git
cd T4CDirect
powershell -ExecutionPolicy Bypass -File .\t4c-direct.ps1
```

### Utilisation

1. Le launcher détecte (ou demande) le dossier d'installation de T4C.
2. Il vérifie les mises à jour contre le manifeste officiel, télécharge ce qui manque, applique le patch.
3. Choisissez un serveur, entrez compte/mot de passe, cliquez **Launch Game**.
4. Fermez le launcher quand vous voulez — le client continue de tourner.

Le bouton **Launch Game** ne devient actif que lorsque le pied de page affiche `up to date` ou `updated`. En cas d'échec, il reste verrouillé pour éviter de lancer un client à moitié mis à jour.

### Compiler le `.exe`

Via [PS2EXE](https://github.com/MScholtes/PS2EXE) — un wrapper .NET autour du script.

```powershell
Install-Module -Name ps2exe -Scope CurrentUser

Invoke-PS2EXE `
  -InputFile  '.\t4c-direct.ps1' `
  -OutputFile '.\T4CDirect.exe' `
  -IconFile   'C:\Program Files (x86)\The4ThComing\t4c.ico' `
  -NoConsole `
  -RequireAdmin `
  -Title       'T4C Direct Launcher' `
  -Version     '1.0.0.0'
```

`-RequireAdmin` embarque un manifeste UAC pour que le `.exe` se ré-élève au lancement. `-NoConsole` en fait une vraie appli GUI sans console noire.

### Comment ça marche (notes techniques)

| Sujet | Détails |
|---|---|
| Patch watchdog | Remplace un saut conditionnel de 6 octets à l'offset `0x147AF0` de `T4C Client.bin` par `NOP NOP NOP NOP NOP NOP`. Les octets d'origine (`0F 84 ED 01 00 00`) sont restaurés via `.bak` en cas de souci. |
| Mises à jour | Récupère `t4c.version` et `t4c.hash` depuis le serveur officiel. Vérification MD5 par fichier, téléchargements gzip-décompressés. |
| Binaires client | `T4C Client.bin` est mis à jour selon un flow rename → download → patch → cleanup-or-revert. Un patch raté ne laisse jamais un client cassé. |
| Sélection serveurs | Le manifeste est parsé pour toutes les entrées `Server Files\<nom>\...`. Vous choisissez quels serveurs installer/maintenir. |
| Identifiants | Stockés dans `%LOCALAPPDATA%\T4CDirectLauncher\config.json`, mot de passe chiffré via `ConvertTo-SecureString` (DPAPI, utilisateur courant uniquement). |
| Lancement client | Le client est lancé avec `CreateProcess`, watchdog patché. Le launcher se ferme proprement, le client continue tout seul. |

### Arborescence

```
%LOCALAPPDATA%\T4CDirectLauncher\
  config.json          # dossier d'install, serveur, host/port, identifiants, serveurs activés, dernière version manifeste

<dossier d'install>\
  T4C Client.bin       # patché sur place
  T4C Client.bin.bak   # original (uniquement pendant le flow de mise à jour)
  Server Files\<nom>\  # données par serveur
```

### Avertissement

Outil non officiel, maintenu par la communauté. **Aucun lien**, soutien ou affiliation avec les opérateurs de The 4th Coming.

- Utilisation à vos risques. Le patch modifie un fichier de votre dossier d'install.
- La sauvegarde `.bak` permet un retour arrière en une étape ; pour plus de sécurité, copiez `T4C Client.bin` à part avant la première utilisation.
- Si les CGU d'un serveur interdisent les clients modifiés, respectez-les. Le but de cet outil est de retirer les comportements intrusifs du launcher d'origine, pas de procurer un avantage en jeu.

### Licence

MIT — voir [`LICENSE`](LICENSE).
