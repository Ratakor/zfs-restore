# zfs-restore

Like [trash-restore](https://github.com/andreafrancia/trash-cli) but for zfs snapshots.

## Features
- File, directory & symlinks support
- Automatically hide duplicated entries
- Works independantely of the snapshot name pattern
- Fast (kinda)
- Pretty (but currently missing some colors)

## Usage

```sh
Usage: zfs-restore [-hvr] [-s <FIELD>] [--color <WHEN>] <PATH>

Options:
  -h, --help            Display this help and exit
  -v, --version         Display version information and exit
  -s, --sort <FIELD>    Which field to sort by (name, date, size)
  -r, --reverse         Reverse the sort order of the snapshots
      --color <WHEN>    When to use terminal colors (always, never, auto)
  <PATH>
```

### Example

```sh
$ zfs-restore flake.nix
╭───────┬───────────────────────────────────────┬───────────────┬─────────┬──────╮
│ Index │ Snapshot Name                         │ Date Modified │ Size    │ Kind │
├───────┼───────────────────────────────────────┼───────────────┼─────────┼──────┤
│    0  │ zfs-auto-snap_hourly-2025-08-29-20h00 │ 29 Aug 16:00  │ 1.94 kB │ file │
│    1  │ zfs-auto-snap_daily-2025-08-29-00h00  │ 28 Aug 22:49  │ 1.83 kB │ file │
│    2  │ zfs-auto-snap_weekly-2025-08-28-14h33 │ 28 Aug 13:28  │ 1.50 kB │ file │
│    3  │ zfs-auto-snap_daily-2025-08-28-00h00  │ 27 Aug 01:54  │ 1.51 kB │ file │
│    4  │ zfs-auto-snap_daily-2025-08-26-00h48  │ 25 Aug 19:52  │ 1.13 kB │ file │
╰───────┴───────────────────────────────────────┴───────────────┴─────────┴──────╯
Which version to restore [0..4]: 0
warning: '/home/ratakor/repos/zfs-restore/flake.nix' already exist
Overwrite? [y/N]: n
info: Aborting...

$ cd ~/Pictures
$ ls
screenshots  wallpapers  image.jpg
$ rm image.jpg
removed 'image.jpg'
$ zfs-restore image.jpg
╭───────┬──────────────────────────────────────┬───────────────┬──────────┬──────╮
│ Index │ Snapshot Name                        │ Date Modified │ Size     │ Kind │
├───────┼──────────────────────────────────────┼───────────────┼──────────┼──────┤
│    0  │ zfs-auto-snap_daily-2025-08-26-00h48 │ 15 Aug 17:15  │ 83.60 kB │ file │
╰───────┴──────────────────────────────────────┴───────────────┴──────────┴──────╯
Which version to restore [0..0]: 0
info: Restoring snapshot: zfs-auto-snap_daily-2025-08-26-00h48
```

## Installation

From source:
```sh
git clone https://github.com/ratakor/zfs-restore
cd zfs-restore
zig build --release=fast
```

# Alternatives

- [zfs-undelete](https://github.com/arctic-penguin/zfs-undelete)

<!--
# TODO
- interactive mode: preview entries before restoring
- better autocompletion
- btrfs support
- xfs support
-->
