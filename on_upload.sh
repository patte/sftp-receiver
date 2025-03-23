#!/bin/bash

WATCH_DIR="/home/scanner/upload"
DEST_DIR="/data/consume"
mkdir -p "$DEST_DIR"

# Move pre-existing files
echo "Checking for files in $WATCH_DIR..."
find "$WATCH_DIR" -type f -exec mv -v {} "$DEST_DIR/" \;

# Start inotify watcher
echo "Watching for new files in $WATCH_DIR..."
inotifywait -m -e close_write,moved_to --format '%w%f' "$WATCH_DIR" | while read file; do
    mv -v "$file" "$DEST_DIR/"
done
