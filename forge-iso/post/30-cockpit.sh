#!/bin/bash
# Cockpit firewall + defaults. The socket itself is enabled via the `services`
# directive in the kickstart so we don't double-enable here.
set -euo pipefail

# `cockpit` service is already allowed in the kickstart `firewall` line; this
# adds the migration port range used by cockpit-machines live-migrate.
firewall-offline-cmd --add-port=49152-49215/tcp || true

# Cockpit: turn on `allowed-origins=*` relaxation only if the operator sets
# FORGE_COCKPIT_RELAX=1 at build time. By default Cockpit's same-origin rules
# stay in place.
if [ "${FORGE_COCKPIT_RELAX:-0}" = "1" ]; then
    mkdir -p /etc/cockpit
    cat > /etc/cockpit/cockpit.conf <<'EOF'
[WebService]
AllowUnencrypted = false
EOF
fi

# Drop the default "sample" Cockpit landing page tweaks that Red Hat adds in
# some builds — keep the UI bare.
rm -f /etc/issue.d/cockpit.issue 2>/dev/null || true
