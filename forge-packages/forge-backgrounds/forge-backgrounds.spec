%global fedora_base %{fedora}

Name:           forge-backgrounds
Version:        0.1.0
Release:        1%{?dist}
Summary:        forge Linux default backgrounds

License:        MIT
URL:            https://github.com/aflawrence/infra/tree/main/forge-packages/forge-backgrounds

Source0:        forge-default.svg

BuildArch:      noarch

BuildRequires:  librsvg2-tools

Provides:       system-backgrounds = %{version}-%{release}
Provides:       fedora-backgrounds = %{version}-%{release}
Obsoletes:      fedora-backgrounds < %{fedora_base}
Obsoletes:      fedora-backgrounds-gnome < %{fedora_base}

%description
Default desktop and login backgrounds for forge Linux. Server installs
rarely see these — they exist so fedora-backgrounds can be swapped out
cleanly without breaking packages that Require it.

%prep
cp -a %{SOURCE0} forge-default.svg

%build
# Standard desktop resolutions. SVG source makes 4K+ essentially free.
for res in 1280x720 1920x1080 2560x1440 3840x2160; do
    w=${res%x*}; h=${res#*x}
    rsvg-convert -w "$w" -h "$h" forge-default.svg -o "forge-default-${res}.png"
done

%install
install -d %{buildroot}%{_datadir}/backgrounds/forge/default

install -m 0644 forge-default.svg \
    %{buildroot}%{_datadir}/backgrounds/forge/default/forge.svg

for res in 1280x720 1920x1080 2560x1440 3840x2160; do
    install -m 0644 "forge-default-${res}.png" \
        "%{buildroot}%{_datadir}/backgrounds/forge/default/forge-${res}.png"
done

%files
%{_datadir}/backgrounds/forge/

%changelog
* Mon Apr 21 2026 forge maintainers <forge@example.invalid> - 0.1.0-1
- Initial backgrounds set.
