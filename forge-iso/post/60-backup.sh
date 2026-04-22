#!/bin/bash
# Stage sanoid with a sensible default config. No datasets referenced yet
# (pools don't exist), so sanoid.timer can be enabled but will log empty
# runs until the operator defines datasets via cockpit-scheduler.
set -euo pipefail

install -d -m 0755 /etc/sanoid

cat > /etc/sanoid/sanoid.conf <<'EOF'
# Managed by forge — default snapshot policies. Add per-dataset blocks below
# once you've created ZFS pools (e.g. [tank/vm] use_template = production).

[template_production]
hourly = 36
daily = 30
weekly = 8
monthly = 12
yearly = 2
autosnap = yes
autoprune = yes

[template_backup_target]
autosnap = no
autoprune = yes
hourly = 0
daily = 30
weekly = 8
monthly = 12
EOF

systemctl enable sanoid.timer
