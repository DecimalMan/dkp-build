dkp-build:
==========

dkp-build contains the utilities used to build dkp.  At present, it's composed of massbuild.sh, a number of dkp- or d2-specific files, and a few small utilities (see src/README).

massbuild.sh is intended to simplify most tasks related to dkp development: configuration, compilation, installation, and public release.  Since dkp is built with multiple configurations, from multiple source trees, massbuild.sh builds everything with external build trees and possibly external source trees.  This allows multiple builds to happen incrementally and in parallel, with no management of configurations or source branches required.  However, separate build trees require substantially more disk space (my build directory currently takes up 35 GB).

Notable features:
-----------------

- Fast multi-device, multi-branch rebuilds, thanks to multiple out-of-tree build directories
- Top-level make jobserver for efficient parallel building
- Automatic generation of install zips, with automatic handling of xbin and initscripts
- Install zip automatically builds boot.img using new zImage and existing ramdisk
- Automatic flashing to an attached device
- Automatic versioning of builds
- Automatic uploading to MediaFire and/or FTP hosts

Configuration:
--------------

A number of options are available at the top of massbuild.sh, though many of them will only be useful for me.  It should be possible to reuse massbuild.sh for other kernels without changing much beyond these settings.

If uploading to FTP, netrc(5) is probably the only workable way to authenticate curl.

Usage:
------

Try ```./massbuild.sh --help```.  My typical usage is ```./massbuild.sh -f``` until everything works, then ```./massbuild.sh -cau``` to publish a new release.

Devices may be specified as "device" (built from working directory) or "branch:device" (built from branch).  Branch and device names will be completed automatically if unambiguous.
