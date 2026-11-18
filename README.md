# DSpace 9.x Automated Installer

A single Bash script (`install-dspace.sh`) that installs a complete, production-ready **DSpace 9.x** repository — backend, frontend, database, search and web server — on a fresh Ubuntu server.

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)
![DSpace](https://img.shields.io/badge/DSpace-9.x-0B3D91?style=flat)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?style=flat&logo=ubuntu&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

```bash
git clone https://github.com/varunvasudevan/dspace9-installer.git
cd dspace9-installer
chmod +x install-dspace.sh
sudo ./install-dspace.sh
```

---

## Contents

- [What gets installed](#what-gets-installed)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Installation steps](#installation-steps)
- [Re-running and upgrading](#re-running-and-upgrading)
- [After installation](#after-installation)
- [Directory layout](#directory-layout)
- [Managing services](#managing-services)
- [Scheduled tasks](#scheduled-tasks)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [License](#license)

---

## What gets installed

| Component        | Version (default)   | Purpose                                  |
|------------------|---------------------|------------------------------------------|
| OpenJDK          | 21                  | Runtime for backend, Solr, Tomcat        |
| Apache Maven     | distro package      | Builds the DSpace backend                |
| Apache Ant       | distro package      | Installs/updates the DSpace backend      |
| PostgreSQL       | distro package (14–16) + `pgcrypto` | Metadata database        |
| Apache Solr      | 9.10.1              | Search, browse, statistics, OAI indexes  |
| Apache Tomcat    | 10.1.55             | Serves the REST API at `/server`         |
| DSpace backend   | 9.2                 | REST API and core repository             |
| Node.js          | 22 LTS              | Runs the Angular frontend (SSR)          |
| PM2              | latest              | Process manager for the frontend         |
| DSpace frontend  | 9.2 (dspace-angular)| User interface                           |
| Nginx            | distro package      | Reverse proxy on ports 80/443 (optional) |
| Certbot          | distro package      | Free Let's Encrypt SSL (optional)        |

---

## Requirements

| Item        | Minimum                     | Recommended              |
|-------------|-----------------------------|--------------------------|
| OS          | Ubuntu 22.04 LTS            | Ubuntu 24.04 LTS         |
| CPU         | 2 cores                     | 4 cores                  |
| RAM         | 4 GB + 4 GB swap            | 8 GB or more             |
| Disk        | 15 GB free                  | 50 GB+ (grows with content) |
| Access      | root / sudo                 |                          |
| Network     | Outbound internet (apt, GitHub, apache.org, npm, Maven Central) |   |

For HTTPS you also need a **domain name whose DNS A record points to the server**, with ports **80 and 443** open.

> **Low RAM?** The Angular build is the most memory-hungry step. Add swap before running:
> ```bash
> sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
> sudo mkswap /swapfile && sudo swapon /swapfile
> echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
> ```

---

## Quick start

```bash
# 1. Copy the script to the server and make it executable
chmod +x install-dspace.sh

# 2a. Install with a domain and HTTPS
DOMAIN=repo.example.org \
ADMIN_EMAIL=admin@example.org \
ENABLE_SSL=yes SSL_EMAIL=admin@example.org \
sudo -E ./install-dspace.sh

# 2b. Or install on a plain IP address over HTTP (testing / intranet)
sudo ./install-dspace.sh
```

The full run takes roughly **30–60 minutes**, mostly the Maven and Angular builds.

When it finishes, open the **UI URL** printed in the summary and log in with the admin credentials from `/root/dspace-install-credentials.txt`.

---

## Configuration

Every setting has a default and can be overridden in either of two ways:

1. **Environment variables** — pass them on the command line with `sudo -E`.
2. **Config file** — create `dspace-install.conf` in the same folder as the script. It is loaded automatically.

Example `dspace-install.conf`:

```bash
DOMAIN="repo.example.org"
DSPACE_NAME="My Institutional Repository"
ADMIN_EMAIL="admin@example.org"
ADMIN_FIRST="Repository"
ADMIN_LAST="Admin"
ENABLE_NGINX="yes"
ENABLE_SSL="yes"
SSL_EMAIL="admin@example.org"
TOMCAT_XMX="3072m"
```

### All settings

**Versions**

| Variable          | Default                  | Notes |
|-------------------|--------------------------|-------|
| `DSPACE_VERSION`  | `9.2`                    | Must match a tag on GitHub (`dspace-X.Y`) for both backend and frontend |
| `SOLR_VERSION`    | `9.10.1`                 | Any Solr 9.x |
| `TOMCAT_VERSION`  | `10.1.55`                | Any Tomcat 10.1.x |
| `NODE_MAJOR`      | `22`                     | 20 or 22 |
| `JAVA_PKG`        | `openjdk-21-jdk-headless`| Use `openjdk-17-jdk-headless` for Java 17 |

**Paths and user**

| Variable        | Default           | Notes |
|-----------------|-------------------|-------|
| `DSPACE_USER`   | `dspace`          | System user that owns DSpace and runs Tomcat and PM2 |
| `DSPACE_DIR`    | `/dspace`         | DSpace installation directory (`[dspace]`) |
| `SRC_DIR`       | `/opt/dspace-src` | Downloaded source code and build output |
| `UI_DIR`        | `/opt/dspace-ui`  | Deployed frontend |
| `TOMCAT_DIR`    | `/opt/tomcat`     | Tomcat home |
| `SOLR_DATA_DIR` | `/var/solr`       | Solr data and cores |

**Site**

| Variable       | Default                | Notes |
|----------------|------------------------|-------|
| `DSPACE_NAME`  | `DSpace Repository`    | Shown in the UI and emails |
| `DOMAIN`       | server's first IP      | FQDN or IP address |
| `ENABLE_NGINX` | `yes`                  | `yes` = public on 80/443; `no` = UI on :4000, API on :8080 |
| `ENABLE_SSL`   | `no`                   | `yes` requests a Let's Encrypt certificate |
| `SSL_EMAIL`    | *(empty)*              | Required when `ENABLE_SSL=yes` |

**Database and admin**

| Variable      | Default            | Notes |
|---------------|--------------------|-------|
| `DB_NAME`     | `dspace`           | |
| `DB_USER`     | `dspace`           | |
| `DB_PASS`     | random (32 hex)    | Must be alphanumeric |
| `ADMIN_EMAIL` | `admin@example.org`| Login for the first administrator |
| `ADMIN_FIRST` / `ADMIN_LAST` | `Repository` / `Admin` | |
| `ADMIN_PASS`  | random (16 chars)  | |
| `ADMIN_LANG`  | `en`               | |

**Tuning**

| Variable           | Default | Notes |
|--------------------|---------|-------|
| `TOMCAT_XMX`       | `2048m` | Backend Java heap |
| `SOLR_HEAP`        | `1g`    | Solr Java heap |
| `PM2_INSTANCES`    | `2`     | Frontend worker processes |
| `UI_BUILD_HEAP_MB` | `4096`  | Node heap for the Angular build |

### Resulting URLs

| Mode                         | UI                        | REST API                          |
|------------------------------|---------------------------|-----------------------------------|
| Nginx + SSL                  | `https://DOMAIN`          | `https://DOMAIN/server/api`       |
| Nginx, no SSL                | `http://DOMAIN`           | `http://DOMAIN/server/api`        |
| No Nginx (`ENABLE_NGINX=no`) | `http://DOMAIN:4000`      | `http://DOMAIN:8080/server/api`   |

---

## Installation steps

The script runs these steps in order. Each one can also be run on its own.

| Step             | What it does |
|------------------|--------------|
| `preflight`      | Checks root, OS, RAM, disk space and settings; prints the URLs that will be used |
| `packages`       | Installs Java, Maven, Ant, PostgreSQL, Git and build tools; sets `JAVA_HOME` system-wide |
| `node`           | Installs Node.js from NodeSource and PM2 globally |
| `user`           | Creates the `dspace` user and the install directories |
| `database`       | Creates the PostgreSQL role and database (UTF-8) and enables `pgcrypto` |
| `solr`           | Installs Solr as a service, enables `solr.config.lib.enabled`, binds it to localhost, raises file limits |
| `tomcat`         | Installs Tomcat and a `tomcat` systemd service running as the `dspace` user |
| `backend`        | Downloads DSpace, writes `local.cfg`, builds with Maven, runs `ant fresh_install` (or `ant update`), migrates the database |
| `solr_cores`     | Copies the DSpace Solr cores (search, statistics, oai, authority, etc.) into Solr |
| `deploy_backend` | Points Tomcat's `/server` context at `[dspace]/webapps/server` and waits for the API |
| `admin`          | Creates the first administrator account |
| `frontend`       | Downloads dspace-angular, builds it, writes `config.prod.yml`, starts it under PM2, enables boot startup |
| `nginx`          | Writes the reverse-proxy site and, if enabled, obtains the SSL certificate |
| `firewall`       | Opens the required ports if UFW is active |
| `cron`           | Installs the DSpace maintenance crontab |
| `summary`        | Prints and saves URLs, paths and credentials |

List them at any time:

```bash
sudo ./install-dspace.sh --list
```

---

## Re-running and upgrading

**Re-run only what failed.** Pass step names as arguments. The `preflight` check always runs first.

```bash
sudo ./install-dspace.sh frontend nginx
```

**Passwords stay the same.** Generated passwords are stored in `/var/lib/dspace-install/secrets` on the first run and reused afterwards, so re-running never breaks the database login.

**Upgrading DSpace.** If `[dspace]/config/dspace.cfg` already exists, the `backend` step runs `ant update` instead of a fresh install. To move to a newer release:

```bash
# Back up first (see below), then:
DSPACE_VERSION=9.3 sudo -E ./install-dspace.sh backend solr_cores deploy_backend frontend
```

Always read the DSpace release notes before upgrading — some releases need extra manual steps.

---

## After installation

1. **Log in** at the UI URL with the admin email and password from `/root/dspace-install-credentials.txt`, then **change the password**.
2. **Configure email.** The script sets `mail.server = localhost`. Edit `[dspace]/config/local.cfg` to use your real SMTP server (`mail.server`, `mail.server.port`, `mail.server.username`, `mail.server.password`, `mail.extraproperties`), then restart Tomcat.
3. **Create your structure:** communities, collections and submission workflows.
4. **Customise the look.** Edit the theme in `/opt/dspace-src/dspace-angular-dspace-<version>/src/themes/`, then rebuild:
   ```bash
   sudo ./install-dspace.sh frontend
   ```
5. **Set up backups** (see below).

### Changing configuration later

| What                    | File                                   | Apply with |
|-------------------------|----------------------------------------|------------|
| Backend settings        | `/dspace/config/local.cfg`             | `sudo systemctl restart tomcat` |
| Frontend settings       | `/opt/dspace-ui/config/config.prod.yml`| `sudo -u dspace pm2 restart dspace-ui` |
| Nginx / upload size     | `/etc/nginx/sites-available/dspace`    | `sudo nginx -t && sudo systemctl reload nginx` |
| Solr memory             | `/etc/default/solr.in.sh`              | `sudo systemctl restart solr` |
| Tomcat memory           | `/etc/systemd/system/tomcat.service`   | `sudo systemctl daemon-reload && sudo systemctl restart tomcat` |

> Edits made directly in `/dspace/config/local.cfg` are overwritten if you re-run the `backend` step. For permanent changes, also update the copy in the source tree (`/opt/dspace-src/DSpace-dspace-<version>/dspace/config/local.cfg`) or the script settings.

### Backups

Back up these three things together:

```bash
# Database
sudo -u postgres pg_dump -Fc dspace > dspace-db-$(date +%F).dump
# Files (bitstreams) and configuration
sudo tar czf dspace-assets-$(date +%F).tar.gz /dspace/assetstore /dspace/config
```

Solr indexes can be rebuilt from the database, so they don't need backing up:

```bash
sudo -u dspace /dspace/bin/dspace index-discovery -b
```

---

## Directory layout

```
/dspace/                     DSpace installation ([dspace])
├── assetstore/              Uploaded files — BACK THIS UP
├── bin/dspace               Command-line tool
├── config/local.cfg         Main local configuration
├── log/                     DSpace logs
├── solr/                    Solr core templates
└── webapps/server/          REST API webapp served by Tomcat

/opt/dspace-src/             Downloaded source code and builds
/opt/dspace-ui/              Deployed frontend
├── dist/                    Compiled Angular app
├── config/config.prod.yml   Frontend configuration
└── dspace-ui.json           PM2 definition

/opt/tomcat/                 Tomcat
/opt/solr  → /opt/solr-9.x   Solr program files
/var/solr/data/              Solr cores and indexes

/root/dspace-install-credentials.txt   URLs and passwords (root only)
/var/log/dspace-install.log            Full installer log
/var/lib/dspace-install/               Installer state and saved secrets
```

---

## Managing services

| Service      | Status / control                               | Logs |
|--------------|------------------------------------------------|------|
| PostgreSQL   | `sudo systemctl status postgresql`             | `journalctl -u postgresql` |
| Solr         | `sudo systemctl status solr`                   | `/var/solr/logs/solr.log` |
| Tomcat (API) | `sudo systemctl restart tomcat`                | `/opt/tomcat/logs/catalina.out`, `/dspace/log/dspace.log` |
| Frontend     | `sudo -u dspace pm2 status` / `pm2 restart dspace-ui` | `sudo -u dspace pm2 logs dspace-ui` |
| Nginx        | `sudo systemctl reload nginx`                  | `/var/log/nginx/error.log` |

Startup order after a reboot is handled automatically: PostgreSQL → Solr → Tomcat → PM2 → Nginx.

Useful DSpace commands (run as the `dspace` user):

```bash
sudo -u dspace /dspace/bin/dspace database info          # DB status
sudo -u dspace /dspace/bin/dspace index-discovery -b     # Rebuild search index
sudo -u dspace /dspace/bin/dspace create-administrator   # Add another admin
sudo -u dspace /dspace/bin/dspace import ...             # Batch import (SAF)
```

---

## Scheduled tasks

Installed in the `dspace` user's crontab (`sudo crontab -u dspace -l`):

| Time            | Task |
|-----------------|------|
| Daily 01:00     | Daily subscription emails (weekly on Sunday, monthly on the 1st) |
| Daily 02:00     | `filter-media` — thumbnails and full-text extraction |
| Daily 02:30     | `oai import` — refresh the OAI-PMH index |
| Daily 03:00     | `solr-database-resync` — keep search in sync |
| Sunday 04:00    | `cleanup` — remove deleted bitstreams |
| Daily 05:00     | `generate-sitemaps` — for search engines |

---

## Troubleshooting

**Check the installer log first:** `sudo less /var/log/dspace-install.log`. The script stops at the first error and prints the line that failed.

| Symptom | Likely cause and fix |
|---------|----------------------|
| Angular build killed / `JavaScript heap out of memory` | Not enough RAM. Add swap (see Requirements) and run `sudo ./install-dspace.sh frontend` |
| Maven build fails downloading dependencies | Network or proxy issue. Re-run `sudo ./install-dspace.sh backend` |
| `/server/api` returns 404 or 503 | Tomcat still starting or failed. Check `/opt/tomcat/logs/catalina.out` and `/dspace/log/dspace.log` |
| Solr cores fail to load (`lib` errors) | Confirm `-Dsolr.config.lib.enabled=true` is in `/etc/default/solr.in.sh`, then `sudo systemctl restart solr` |
| UI shows "Service unavailable" or can't reach the REST API | `rest.host`/`port`/`ssl` in `config.prod.yml` don't match how the API is reached publicly. Fix and `pm2 restart dspace-ui` |
| CORS errors in the browser console | `dspace.ui.url` in `local.cfg` doesn't exactly match the URL in the browser (scheme, host, port). Fix and restart Tomcat |
| Login works but you're logged out immediately | Mixed HTTP/HTTPS. Make sure both `dspace.ui.url` and `dspace.server.url` use `https` when SSL is on |
| Certbot fails | DNS for `DOMAIN` doesn't point to this server yet, or port 80 is blocked. Fix, then `sudo certbot --nginx -d DOMAIN` |
| Upload fails with `413 Request Entity Too Large` | Increase `client_max_body_size` in the Nginx site file and reload Nginx |
| Search shows no items after import | `sudo -u dspace /dspace/bin/dspace index-discovery -b` |

**Switching from IP to domain or adding SSL later:** set the new `DOMAIN` / `ENABLE_SSL` and re-run the steps that bake in URLs:

```bash
DOMAIN=repo.example.org ENABLE_SSL=yes SSL_EMAIL=admin@example.org \
sudo -E ./install-dspace.sh backend deploy_backend frontend nginx
```

---

## Uninstall

> ⚠️ This permanently deletes the repository, including all uploaded files and the database. Back up first.

```bash
sudo -u dspace pm2 delete dspace-ui; sudo -u dspace pm2 save
sudo systemctl disable --now tomcat solr pm2-dspace
sudo rm -f /etc/systemd/system/tomcat.service /etc/nginx/sites-enabled/dspace /etc/nginx/sites-available/dspace
sudo -u postgres dropdb dspace; sudo -u postgres dropuser dspace
sudo rm -rf /dspace /opt/dspace-src /opt/dspace-ui /opt/tomcat /opt/solr* /var/solr /etc/default/solr.in.sh \
            /var/lib/dspace-install /root/dspace-install-credentials.txt
sudo crontab -u dspace -r
sudo systemctl daemon-reload && sudo systemctl reload nginx
```

---

## References

- DSpace 9 documentation: https://wiki.lyrasis.org/display/DSDOC9x
- DSpace backend releases: https://github.com/DSpace/DSpace/releases
- DSpace frontend releases: https://github.com/DSpace/dspace-angular/releases

---

## Contributing

Issues and pull requests are welcome, especially fixes for newer DSpace, Solr or Tomcat releases and support for other Linux distributions.

## Author

**Varun Kumar** — [GitHub](https://github.com/varunvasudevan) · [Portfolio](https://varunvasudevan.github.io)

Built from hands-on experience deploying DSpace for [Bhasha Sanchika](https://sanchika.ciil.org/), the digital language repository of CIIL.

## License

[MIT](LICENSE) © 2026 Varun Kumar. DSpace itself is distributed under the BSD 3-Clause license by LYRASIS and the DSpace community.
