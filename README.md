dkp-build:
==========

dkp-build is used to build dkp for as many as five different d2 variants, but should be easily extensible to build many other single-source, multiple-device kernels.

massbuild.sh is designed to build dkp as wastefully as possible (between source, .git, toolchain and intermediates, my build directory is up to 3GB).  All devices are built out-of-tree into their own directories, facilitating incremental rebuilds for multiple devices.  This also allows parallel building, avoiding stalling during the long single-threaded linking and compression steps.

Notable features:
-----------------

- Fast multi-device rebuilds, thanks to multiple out-of-tree build directories
- Automatic generation of install & uninstall zips, with automatic handling of xbin and initscripts
- Install zip automatically builds boot.img using new zImage and existing ramdisk
- Automatic flashing to an attached device
- Automatic versioning of builds
- Automatic uploading to Dev-Host
- Easy updates to the Linaro nightly toolchain

Configuration:
--------------

A number of options are available at the top of massbuild.sh.  It should be possible to reuse massbuild.sh for other kernels without changing much beyond these settings.

When uploading to Dev-Host, massbuild.sh will ask for a username and password.  To avoid being prompted every time, create (and ```chmod 600```!) a file "devhostauth.sh" containing:
```sh
DHUSER=username
DHPASS=password
```

Usage:
------

Try ```./massbuild.sh --help```.  My typical usage is ```./massbuild.sh -f d2spr``` until everything works, then ```./massbuild.sh -lru``` to publish a new release with a fresh Linaro toolchain.  ```./massbuild.sh -Cc``` is handy when switching between Linux versions.
