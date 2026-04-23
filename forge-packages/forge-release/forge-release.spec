%global fedora_base %{fedora}
%global forge_pretty_name forge Linux
%global forge_url https://github.com/aflawrence/infra/tree/main/forge-iso

Name:           forge-release
Version:        0.1.0
Release:        1%{?dist}
Summary:        forge Linux release files

# This package ships distribution identity files (os-release, issue, etc.)
# that are written locally by the forge project — no upstream to track.
License:        MIT
URL:            %{forge_url}

Source0:        os-release
Source1:        issue
Source2:        issue.net
Source3:        forge.repo
Source4:        ATTRIBUTION

BuildArch:      noarch

# Drop-in replacement for fedora-release. DNF's obsolete-processing swaps it
# cleanly at install time. We still Provide the fedora-release capability so
# any package with a hard Requires: fedora-release keeps resolving.
Provides:       system-release = %{version}-%{release}
Provides:       system-release(%{fedora_base})
Provides:       base-module(platform:f%{fedora_base})
Provides:       fedora-release = %{fedora_base}
Provides:       generic-release = %{version}-%{release}
Obsoletes:      fedora-release < %{fedora_base}
Obsoletes:      fedora-release-common < %{fedora_base}
Obsoletes:      fedora-release-server < %{fedora_base}
Obsoletes:      fedora-release-identity-basic < %{fedora_base}
Obsoletes:      fedora-release-identity-server < %{fedora_base}
Obsoletes:      generic-release < %{fedora_base}

Requires:       system-release-common = %{version}-%{release}

%description
forge Linux release files: /etc/os-release, /etc/system-release, /etc/issue.

forge Linux is an independent project based on Fedora Linux. Fedora is a
trademark of Red Hat, Inc., which is neither affiliated with nor endorses
this project.

# -----------------------------------------------------------------------------
# Common subpackage — provides system-release-common capability so fedora's
# dependency graph stays satisfied.
# -----------------------------------------------------------------------------
%package common
Summary:        Common files for %{forge_pretty_name} release packages
Provides:       system-release-common = %{version}-%{release}
Obsoletes:      fedora-release-common < %{fedora_base}

%description common
Shared files for the forge-release package family.

# -----------------------------------------------------------------------------
%prep
# Nothing to unpack — we ship flat files from SOURCES.

%build
# Nothing to compile.

%install
install -d %{buildroot}%{_sysconfdir}
install -d %{buildroot}%{_prefix}/lib
install -d %{buildroot}%{_sysconfdir}/yum.repos.d
install -d %{buildroot}%{_datadir}/licenses/%{name}

# /etc/os-release is a symlink to /usr/lib/os-release per systemd convention.
install -m 0644 %{SOURCE0} %{buildroot}%{_prefix}/lib/os-release
ln -sf  ../usr/lib/os-release %{buildroot}%{_sysconfdir}/os-release

# /etc/system-release — classic one-line id string.
echo "%{forge_pretty_name} %{version} (based on Fedora %{fedora_base})" \
    > %{buildroot}%{_sysconfdir}/system-release

# issue / issue.net — pre-login banners on tty and telnet/ssh respectively.
install -m 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/issue
install -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/issue.net

# Ship the attribution notice alongside the license so it's discoverable.
install -m 0644 %{SOURCE4} %{buildroot}%{_datadir}/licenses/%{name}/ATTRIBUTION

# Optional: an empty forge.repo, disabled by default. Operators can flip
# enabled=1 to pull forge-specific updates once a public repo exists.
install -m 0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/yum.repos.d/forge.repo

%files
%license %{_datadir}/licenses/%{name}/ATTRIBUTION
%{_prefix}/lib/os-release
%{_sysconfdir}/os-release
%{_sysconfdir}/system-release
%{_sysconfdir}/issue
%{_sysconfdir}/issue.net
%config(noreplace) %{_sysconfdir}/yum.repos.d/forge.repo

%files common
# Marker-only subpackage. Owning no files is legal for capability providers.

%changelog
* Mon Apr 21 2026 forge maintainers <forge@example.invalid> - 0.1.0-1
- Initial release.
