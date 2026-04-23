%global fedora_base %{fedora}

Name:           forge-logos
Version:        0.1.0
Release:        1%{?dist}
Summary:        forge Linux branding assets (logos, Plymouth theme, pixmaps)

License:        MIT
URL:            https://github.com/aflawrence/infra/tree/main/forge-packages/forge-logos

Source0:        forge-logo.svg
Source1:        forge-wordmark.svg
Source2:        plymouth/forge.plymouth
Source3:        plymouth/forge.script

BuildArch:      noarch

# rsvg-convert + ImageMagick rasterize the SVGs at build time.
BuildRequires:  librsvg2-tools
BuildRequires:  ImageMagick

# Same drop-in pattern as forge-release — swap out fedora-logos cleanly.
Provides:       system-logos = %{version}-%{release}
Provides:       fedora-logos = %{version}-%{release}
Provides:       generic-logos = %{version}-%{release}
Obsoletes:      fedora-logos < %{fedora_base}
Obsoletes:      generic-logos < %{fedora_base}

# Plymouth theme file format is interpreted by the plymouth binary.
Requires:       plymouth
Requires(post): plymouth

%description
Branding assets for forge Linux: logos, Plymouth boot splash theme, and
installer pixmaps. Replaces fedora-logos; no Fedora trademarks are
reproduced here.

# -----------------------------------------------------------------------------
%prep
cp -a %{SOURCE0} forge-logo.svg
cp -a %{SOURCE1} forge-wordmark.svg
cp -a %{SOURCE2} forge.plymouth
cp -a %{SOURCE3} forge.script

%build
# Rasterize the vector sources into every size Plymouth + anaconda expect.
# rsvg-convert handles the SVGs; ImageMagick makes the solid-color bars we
# need for the progress widget.

# Plymouth assets
rsvg-convert -w 256 -h 256 forge-logo.svg -o plymouth-logo.png

# A 400x4 orange progress bar — Plymouth clips to animate progress.
convert -size 400x4 xc:'#f97316' plymouth-progress-bar.png

# Anaconda sidebar + top header pixmaps (sizes per Fedora's anaconda UI spec).
rsvg-convert -w 150 -h 150 forge-logo.svg     -o anaconda-logo.png
rsvg-convert -w 640 -h 160 forge-wordmark.svg -o anaconda-sidebar.png

# Generic pixmaps used by GDM / login shell / /usr/share/pixmaps consumers.
for px in 16 22 24 32 48 64 96 128 256; do
    rsvg-convert -w $px -h $px forge-logo.svg -o forge-logo-${px}.png
done

%install
# ---- Plymouth theme ---------------------------------------------------------
install -d %{buildroot}%{_datadir}/plymouth/themes/forge
install -m 0644 forge.plymouth               %{buildroot}%{_datadir}/plymouth/themes/forge/
install -m 0644 forge.script                 %{buildroot}%{_datadir}/plymouth/themes/forge/
install -m 0644 plymouth-logo.png            %{buildroot}%{_datadir}/plymouth/themes/forge/logo.png
install -m 0644 plymouth-progress-bar.png    %{buildroot}%{_datadir}/plymouth/themes/forge/progress-bar.png

# ---- Anaconda pixmaps (consumed by the product.img we ship in the ISO) -----
install -d %{buildroot}%{_datadir}/anaconda/pixmaps
install -m 0644 anaconda-logo.png     %{buildroot}%{_datadir}/anaconda/pixmaps/forge-logo.png
install -m 0644 anaconda-sidebar.png  %{buildroot}%{_datadir}/anaconda/pixmaps/forge-sidebar.png

# ---- Generic icons + pixmaps -----------------------------------------------
install -d %{buildroot}%{_datadir}/pixmaps
install -m 0644 forge-logo.svg        %{buildroot}%{_datadir}/pixmaps/forge-logo.svg

for px in 16 22 24 32 48 64 96 128 256; do
    install -d %{buildroot}%{_datadir}/icons/hicolor/${px}x${px}/apps
    install -m 0644 forge-logo-${px}.png \
        %{buildroot}%{_datadir}/icons/hicolor/${px}x${px}/apps/forge-logo.png
done

install -d %{buildroot}%{_datadir}/icons/hicolor/scalable/apps
install -m 0644 forge-logo.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/forge-logo.svg

%post
# Make forge the active Plymouth theme + rebuild initramfs so the splash is
# available from the very first frame after the bootloader. Failure here is
# non-fatal (a headless server doesn't need Plymouth anyway).
if [ -x %{_sbindir}/plymouth-set-default-theme ]; then
    %{_sbindir}/plymouth-set-default-theme forge -R 2>/dev/null || \
    %{_sbindir}/plymouth-set-default-theme forge     2>/dev/null || :
fi

%postun
# On uninstall, revert to Fedora's default theme so the system still boots.
if [ $1 -eq 0 ] && [ -x %{_sbindir}/plymouth-set-default-theme ]; then
    %{_sbindir}/plymouth-set-default-theme charge -R 2>/dev/null || :
fi

%files
%{_datadir}/plymouth/themes/forge/
%{_datadir}/anaconda/pixmaps/forge-logo.png
%{_datadir}/anaconda/pixmaps/forge-sidebar.png
%{_datadir}/pixmaps/forge-logo.svg
%{_datadir}/icons/hicolor/scalable/apps/forge-logo.svg
%{_datadir}/icons/hicolor/*/apps/forge-logo.png

%changelog
* Mon Apr 21 2026 forge maintainers <forge@example.invalid> - 0.1.0-1
- Initial branding set.
