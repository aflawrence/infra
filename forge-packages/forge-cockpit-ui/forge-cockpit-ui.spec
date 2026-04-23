%global cockpit_datadir %{_datadir}/cockpit

Name:           forge-cockpit-ui
Version:        0.1.0
Release:        1%{?dist}
Summary:        forge branding and overview module for Cockpit

License:        MIT
URL:            https://github.com/aflawrence/infra/tree/main/forge-packages/forge-cockpit-ui

# Source tree is laid out at the final install paths already — keeps the
# spec trivial and the asset filenames matching what Cockpit looks for.
Source0:        overview/manifest.json
Source1:        overview/index.html
Source2:        overview/overview.js
Source3:        overview/overview.css

Source10:       branding/branding.css
Source11:       branding/style.css

# Logo artwork is rasterized from forge-logos' SVGs at build time. The
# RPM has a hard BuildRequires on forge-logos being locally available if
# we want those assets baked in; otherwise we render from the raw SVG.
Source20:       %{_sourcedir}/forge-logo.svg

BuildArch:      noarch
BuildRequires:  librsvg2-tools

Requires:       cockpit >= 266
Requires:       forge-release
# The cards' deep-link footers reference these modules. Not hard-required
# (Cockpit won't break if they're missing) but a consistent UI depends on
# them being installed.
Recommends:     cockpit-machines
Recommends:     cockpit-zfs-manager
Recommends:     cockpit-scheduler

%description
forge's Cockpit presentation layer: a unified dark theme applied via
PatternFly token overrides, plus a new "Overview" landing page module
that surfaces cluster, ZFS, backup, and VM state on a single screen.

The Overview module is self-contained vanilla JS — it calls into
virsh, zpool, pcs, and systemctl via Cockpit's spawn API with no
backend daemon to install.

%prep
# No sources to unpack; the spec places files directly.

%build
# Pull forge-logos' SVG out of the SOURCES tree (populated by build-rpms.sh)
# and rasterize to the sizes Cockpit's login page expects.
if [ -f "%{SOURCE20}" ]; then
    rsvg-convert -w 96  -h 96  "%{SOURCE20}" -o logo.png
    rsvg-convert -w 152 -h 152 "%{SOURCE20}" -o apple-touch-icon.png
    rsvg-convert -w 64  -h 64  "%{SOURCE20}" -o favicon.png
fi

%install
# ---- Overview module --------------------------------------------------------
install -d %{buildroot}%{cockpit_datadir}/forge-overview
install -m 0644 %{SOURCE0} %{buildroot}%{cockpit_datadir}/forge-overview/manifest.json
install -m 0644 %{SOURCE1} %{buildroot}%{cockpit_datadir}/forge-overview/index.html
install -m 0644 %{SOURCE2} %{buildroot}%{cockpit_datadir}/forge-overview/overview.js
install -m 0644 %{SOURCE3} %{buildroot}%{cockpit_datadir}/forge-overview/overview.css

# ---- Branding (auto-loaded because /etc/os-release carries ID=forge) -------
# Cockpit searches /usr/share/cockpit/branding/<os-id>/ for logo/style/branding
# assets, falling back to the default subdirectory. Matching os-release ID
# means no cockpit.conf changes are needed.
install -d %{buildroot}%{cockpit_datadir}/branding/forge
install -m 0644 %{SOURCE10} %{buildroot}%{cockpit_datadir}/branding/forge/branding.css
install -m 0644 %{SOURCE11} %{buildroot}%{cockpit_datadir}/branding/forge/style.css

if [ -f logo.png ]; then
    install -m 0644 logo.png               %{buildroot}%{cockpit_datadir}/branding/forge/logo.png
    install -m 0644 apple-touch-icon.png   %{buildroot}%{cockpit_datadir}/branding/forge/apple-touch-icon.png
    install -m 0644 favicon.png            %{buildroot}%{cockpit_datadir}/branding/forge/favicon.png
fi

%files
%{cockpit_datadir}/forge-overview/
%{cockpit_datadir}/branding/forge/

%changelog
* Mon Apr 21 2026 forge maintainers <forge@example.invalid> - 0.1.0-1
- Initial Cockpit branding + forge-overview module.
