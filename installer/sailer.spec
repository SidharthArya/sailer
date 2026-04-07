Name:           sailer
Version:        0.0.1
Release:        1%{?dist}
Summary:        A Wayland compositor written in Zig, built on wlroots

License:        MIT
URL:            https://github.com/SidharthArya/sailer
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  zig >= 0.15.2
BuildRequires:  wlroots-devel >= 0.19
BuildRequires:  wayland-devel
BuildRequires:  wayland-protocols-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  pixman-devel
BuildRequires:  freetype-devel
BuildRequires:  dbus-devel
BuildRequires:  scdoc

Requires:       python3-pyyaml
Requires:       wlroots >= 0.19

%description
A Wayland compositor written in Zig, built on wlroots. Sailing across in Linux.

%prep
%autosetup

%build
zig build -Doptimize=ReleaseSafe

%install
mkdir -p %{buildroot}%{_bindir}
install -p -m 755 zig-out/bin/sailer %{buildroot}%{_bindir}/sailer
install -p -m 755 zig-out/bin/sailer-mcp %{buildroot}%{_bindir}/sailer-mcp

%files
%license LICENSE
%{_bindir}/sailer
%{_bindir}/sailer-mcp

%changelog
* Wed Apr 08 2026 Sidharth Arya <sid@example.com> - 0.0.1-1
- Initial release
