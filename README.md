dkp-build:
==========

dkp-build contains the utilities used to build dkp.  At present, it's composed of massbuild.sh, a number of dkp- or d2-specific files, and a few small utilities (see src/README).

massbuild.sh is intended to simplify most tasks related to dkp development: configuration, compilation, installation, and public release.  Since dkp is built with multiple configurations, from multiple source branchs, across multiple repositories, massbuild.sh builds everything with external build trees and possibly external source trees.  This allows multiple builds to happen incrementally and in parallel, with no manual management of configurations or source branches required.  However, separate build trees consume dramatically more space, and may waste some CPU by building identical files repeatedly.

Notable massbuild.sh features:
-----------------

- Top-level make jobserver for efficient parallel building
- Automatic packaging into versioned install zips, flashing to attached devices, and uploading to MediaFire and/or FTP
- Parallel everything: source checkout (as needed), configuration (for defconfigs, anyway), compilation, and packaging

Configuration:
--------------

A few settings (paths and such) are available at the top of massbuild.sh.  Pay attention to the variable syntax, since they may be evaluated by bash, make, or bash eval.

massbuild.sh expects a few helpers stuffed into the source Makefile: DKP\_NAME provides a short name for the general build target (e.g. "aosp51"), and DKP\_LABEL provides a pretty label for uploaded builds (e.g. "dkp for AOSP 5.1.x").

If uploading to FTP, netrc(5) is probably the only workable way to authenticate curl.  If uploading to MediaFire, you'll need plowshare; its configuration lives in ~/.config/plowshare.

Usage:
------

Try ```./massbuild.sh --help```.  My typical usage is ```./massbuild.sh -f``` until everything works, then ```./massbuild.sh -r``` to publish a new release.

Devices may be specified as "device" (built from working directory) or "branch:device" (built from branch).  Branch and device names will be completed automatically if unambiguous.
