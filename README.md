dkp-build:
==========

dkp-build is used to build dkp for as many as five different d2 variants, but should be easily extensible to build many other single-source, multiple-device kernels.  At present, it's composed of massbuild.sh, a number of dkp- or d2-specific files, and a few small utilities (see src/README).

massbuild.sh is designed to build dkp as wastefully as possible (between source, .git, toolchain, intermediates and output, my build directory is up to 35GB).  All devices are built out-of-tree into their own directories, facilitating incremental rebuilds for multiple devices.  This also allows parallel building, avoiding stalling during the long single-threaded linking and compression steps.

Notable features:
-----------------

- Fast multi-device rebuilds, thanks to multiple out-of-tree build directories
- Top-level make jobserver for efficient parallel building
- Automatic generation of install zips, with automatic handling of xbin and initscripts
- Install zip automatically builds boot.img using new zImage and existing ramdisk
- Automatic flashing to an attached device
- Automatic versioning of builds
- Automatic uploading to FTP host

Configuration:
--------------

A number of options are available at the top of massbuild.sh, though many of them will only be useful for me.  It should be possible to reuse massbuild.sh for other kernels without changing much beyond these settings.

If uploading to FTP, netrc(5) is probably the only workable way to authenticate curl.

Usage:
------

Try ```./massbuild.sh --help```.  My typical usage is ```./massbuild.sh -f d2spr``` until everything works, then ```./massbuild.sh -u``` to publish a new release.  ```./massbuild.sh -Cc``` is handy for fixing even the most broken build tree.
