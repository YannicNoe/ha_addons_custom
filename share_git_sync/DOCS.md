# Share Git Sync

Syncs folders of a (private) Git repository into `/share`. Runs once and
stops (like a script), start it from an automation to sync regularly.

## Rules

| File is ...                                     | Action                     |
| ----------------------------------------------- | -------------------------- |
| in the current commit                           | written / overwritten      |
| synced last time, but no longer in the repo     | deleted                    |
| never part of the repository                    | **never touched**          |

- Existing folders are merged, other files in them stay as they are.
- Folders that become empty after deleting a file are removed.
- The repository always wins. A warning is logged if a file was changed
  locally or already existed before it was synced the first time.
- The first sync of a mapping never deletes anything.
- If the repository cannot be fetched (deleted, no access, wrong branch, no
  network ...), a source folder is missing in the repository or an add-on to
  restart does not exist, the add-on stops **without changing anything**.
- Symlinks and submodules in the repository are skipped.

The add-on remembers which files it synced per mapping (with checksums) in
its `/data` folder. If you change the `source` or `target` of a mapping, it
counts as a new mapping: files at the old target are not deleted.

## Setup

1. Install and start the add-on once. It generates an SSH key and prints
   the public key in the log.
2. Add that key to your private repository as deploy key **without** write
   access (GitHub: *Settings → Deploy keys → Add deploy key*).
3. Set `repository` to the SSH URL and configure the mappings.
4. Start once with `dry_run: true` and check the log, then set it to `false`.

The private key only lives in the add-on's `/data` folder (it is included in
backups of this add-on). The host key of the Git server is trusted on first
use.

## Options

```yaml
repository: git@github.com:user/ha-share.git
branch: main
dry_run: false
mappings:
  - source: nginx_proxy          # folder in the repository ("" = root)
    target: nginx_proxy          # folder below /share ("" = /share)
    restart_addon: nginx_proxy_custom
  - source: other_stuff
    target: somewhere/else
```

`restart_addon` is optional. The add-on is restarted only if files of that
mapping changed. The repository prefix of the slug (e.g. `1a2b3c4d_`) can be
omitted.

## Sync regularly

```yaml
automation:
  - alias: Sync /share from Git
    triggers:
      - trigger: time
        at: "04:30:00"
    actions:
      - action: hassio.addon_start
        data:
          addon: 1a2b3c4d_share_git_sync # full slug, see add-on URL
```
