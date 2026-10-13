<p align="center">
  <img src="https://github.com/evgeniy-harchenko/muon/blob/master/assets/logo.png" width=150 />
  <h1 align="center">Muon Qt6</h1>
  <p align="center">Manage applications and libraries installed on your system at the package level. Search, install and remove packages, and inspect their versions and dependencies.</p>
</p>

<p align="center">
  <img src="https://github.com/evgeniy-harchenko/muon/blob/master/assets/image.png"/>
</p>

## Install

Download the package for your system from the [latest release](https://github.com/obook/muon/releases/latest):

| System | Package |
|---|---|
| KDE neon | `muon_<version>_neon_amd64.deb` |
| Ubuntu 26.04 | `muon_<version>_ubuntu26.04_amd64.deb` |

```bash
sudo apt install ./muon_*_amd64.deb
```

Each package installs only on the system named in its file, because KDE neon and Ubuntu name their Qt and KDE Frameworks packages differently. Ubuntu 24.04 has no KDE Frameworks 6, so Muon cannot run there.

The package contains [QApt 4](https://github.com/evgeniy-harchenko/qapt), which Muon needs and no distribution ships. QApt 4 installs next to the `libqapt3` of the distribution.

## Build the packages

You need Docker. `build.sh` builds each package in a container of its distribution:

```bash
git clone https://github.com/obook/muon.git
cd muon
./build.sh
```

The packages are in `build/`. `./build.sh neon` builds that one only.

On another distribution, install QApt 4 first, then build Muon with CMake.
