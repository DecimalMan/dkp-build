dkp-build:
==========

dkp-build is used to build dkp for five different d2 variants, but should be easily extensible to build many other single-source, multiple-device kernels.

massbuild.sh is designed to build dkp as wastefully as possible (between source, .git, toolchain and intermediates, my build directory is up to 3GB).  All devices are built out-of-tree into their own directories, facilitating incremental rebuilds for multiple devices.  This also allows parallel building, avoiding stalling during the long single-threaded linking and compression steps.

Notable features:
-----------------

- Fast multi-device rebuilds, thanks to multiple out-of-tree build directories
- Automatic generation of install & uninstall zips, with automatic handling of xbin and initscripts
- Automatic flashing to an attached device
- Automatic versioning of builds
- Automatic uploading to Dev-Host
- Easy updates to the Linaro nightly toolchain

Configuration:
--------------

A number of options are available at the top of massbuild.sh.  It should be possible to reuse massbuild.sh for other kernels without changing anything beyond these settings.

When uploading to Dev-Host, massbuild.sh will ask for a username and password.  To avoid being prompted every time, create (and ```chmod 600```!) a file "devhostauth.sh" containing:
```sh
DHUSER=username
DHPASS=password
```

Usage:
------

Try ```./massbuild.sh --help```.  My typical usage is ```./massbuild.sh -f d2spr``` until everything works, then ```./massbuild.sh -lru``` to publish a new release with a fresh Linaro toolchain.

Limitations/TODO:
------------

Currently, only one initramfs and updater-script is generated, which is shared across all devices.  This works on d2, but other device families may need per-device ramdisks or installers.

Built packages and the ramdisk are generated outside of make, and are not run in parallel.

Included binaries:
------------------

- mkbootfs, mkbootimg: borrowed from CyanogenMod, source available at <https://github.com/cyanogenmod/android_system_core>
- initramfs.gz: built from CyanogenMod sources, available at <https://github.com/cyanogenmod/android>
