# qb-installer

A standalone, **interactive** installer for **qBittorrent only**.

Unlike the full [Dedicated-Seedbox](https://github.com/SAGIRIxr/Dedicated-Seedbox)
installer, this script:

- installs **only** `qbittorrent-nox` + its WebUI;
- does **not** modify `sysctl` / kernel settings;
- does **not** install BBR;
- does **not** install any other component (autobrr, vertex, filebrowser, …).

The precompiled `qbittorrent-nox` binary comes from the same source the full
installer uses: [`SAGIRIxr/Seedbox-Components-P`](https://github.com/SAGIRIxr/Seedbox-Components-P).

## Usage

Run as **root** on a Debian/Ubuntu box:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main/install.sh)
```

The script will:

1. detect your CPU architecture (x86_64 / ARM64);
2. list the qBittorrent builds that actually exist for your architecture and let
   you pick one (this includes the libtorrent pairing and any CPU-optimised
   variant such as `x64_v3`);
3. interactively ask for **username**, **password**, **disk cache (MiB)**,
   **download path**, **WebUI port** and **incoming/BT port**;
4. create the user, download the binary, write `qBittorrent.conf`, install a
   `qbittorrent-nox@<user>.service` systemd unit and start it.

When it finishes it prints the WebUI URL and the service-management commands.

## Managing the service

```bash
systemctl status  qbittorrent-nox@<user>
systemctl restart qbittorrent-nox@<user>
systemctl stop    qbittorrent-nox@<user>
journalctl -u qbittorrent-nox@<user> --no-pager -n 50
```

## Notes

- The script only writes qBittorrent's own configuration (cache, IO buffers,
  save path, WebUI credentials). It does not change anything system-wide.
- Supported config formats are detected automatically from the chosen
  qBittorrent version (4.1.x uses an MD5 WebUI hash; 4.2+ uses PBKDF2).
- The build menu is fetched live from the GitHub API. If that call is
  rate-limited (the unauthenticated API allows 60 requests/hour per IP), the
  script falls back to the bundled `builds-x86_64.txt` / `builds-ARM64.txt`
  manifests. Regenerate them when new builds are added to `Seedbox-Components-P`:

  ```bash
  for a in x86_64 ARM64; do
    gh api "repos/SAGIRIxr/Seedbox-Components-P/contents/Torrent%20Clients/qBittorrent/$a" \
      --jq '.[] | select(.type=="dir") | .name' | grep '^qBittorrent-' | sort -V > "builds-$a.txt"
  done
  ```
