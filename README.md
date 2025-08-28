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
Usage: zfs-restore [-h] <path>

Options:
  -h, --help    Display this help and exit.
  <path>
```

### Example

```sh
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
