dkp-build:
==========

dkp-build is used to build dkp for 5 different d2 variants, but should be easily extensible to build many other single-source, multiple-device kernels.

massbuild.sh is designed to build dkp as wastefully as possible.  All builds are done in separate kbuild trees and executed in parallel, so incremental rebuilds (which otherwise spend 75% of their time running a single-threaded linker or compressor) generally complete very quickly.  GNU make's questionable --load-average hampers this process slightly.

Notable features:
-----------------

- Automatic versioning of builds
- Automatic generation of install & uninstall zips
- Fast multi-device rebuilds, thanks to multiple out-of-tree build directories
- Easy updates to the Linaro nightly toolchain
- Automatic flashing to an attached device
- Automatic uploading to Dev-Host

Configuration:
--------------

A number of options are available at the top of massbuild.sh.  It should be possible to reuse massbuild.sh for other kernels without changing anything beyond these settings.

In order to upload to Dev-Host, massbuild.sh expects devhostauth.sh to be created, containing:
```sh
DHUSER=(username)
DHPASS=(password)
```

Usage:
------

Try ./massbuild.sh --help.  My typical usage is "./massbuild.sh -f d2spr" until everything works, then "./massbuild.sh -l -r -u" to publish a new release with a fresh Linaro toolchain.

Note that massbuild.sh is sort of stupid, and doesn't understand combined short parameters (eg. -lru).

Included binaries:
------------------

- mkbootfs, mkbootimg: borrowed from CyanogenMod, source available at <https://github.com/cyanogenmod/android_system_core>
- initramfs.gz: built from CyanogenMod sources, available at <https://github.com/cyanogenmod/android>
