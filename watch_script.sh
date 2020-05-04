#!/usr/bin/env bash

# this script will watch examples/script.txt and send the message "reload" to
# localhost port 8888. if you start a zang example like this:
#
#   ZANG_LISTEN_PORT=8888 zang build script_runtime
#
# then it will listen for these messages, and reload the script (same effect
# as pressing F5).

# have to watch the directory. because vim doesn't modify the file directly,
# it overwrites it with a new copy, which makes inotifywait lose track after
# the first edit if you were watching the file directly.
inotifywait -m -e close_write,moved_to --format %e/%f examples |
while IFS=/ read -r events file; do
    if [ "$file" = "script.txt" ]; then
        echo -n reload > /dev/udp/localhost/8888
    fi
done
