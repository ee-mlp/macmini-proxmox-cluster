#!/bin/bash
LOGFILE="/tmp/udev-debug.log"
IF="en05"
echo "$(date): pve-$IF.sh triggered by udev" >> "$LOGFILE"
for i in {1..10}; do
    echo "$(date): Attempt $i to bring up $IF" >> "$LOGFILE"
    /usr/sbin/ifup $IF >> "$LOGFILE" 2>&1 && {
        echo "$(date): Successfully brought up $IF on attempt $i" >> "$LOGFILE"
        break
    }
    echo "$(date): Attempt $i failed, retrying in 3 seconds..." >> "$LOGFILE"
    sleep 3
done
