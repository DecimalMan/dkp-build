#!/bin/bash -e

### CONFIGURABLE SETTINGS: ###

# Devices available to build for
ALLDEVS=(d2att d2cri d2spr d2usc d2vzw)
# Devices that will be be marked 'release'
STABLE=(d2spr)
# Kernel source location, relative to massbuild.sh
KSRC=../android_kernel_samsung_d2
# Ramdisk source, relative to massbuild.sh
RDSRC=../../cm101/out/target/product/d2spr/root
# defconfig format, will be expanded per-device
CFGFMT='cyanogen_${dev}_defconfig'
# Where to push flashable builds to (internal/external "SD" card)
FLASH=external

###  END OF CONFIGURABLES  ###

DEVS=()
let MAKEJ="$(grep '^processor\W*:' /proc/cpuinfo | wc -l)" MAKEL=MAKEJ*3/2
export CROSS_COMPILE=../android-toolchain-eabi/bin/arm-eabi-
BD="$(date +%Y%m%d)"
BDIR="out/release-$BD"

# Run a build in its own device-specific dir
kb() {
	[[ "$1" ]]
	D="$1"
	shift
	echo "Making ${@:-all} for $D..."
	mkdir -p "kbuild-$D"
	make -j $MAKEJ -l $MAKEL -C "$KSRC" O="$(pwd)/kbuild-$D" "$@" >"massbuild-$dev.log" 2>&1 || \
		{ touch build-failed-"$D"; false; }
}

# Build for all devices in parallel
kba() {
	rm -f build-failed-*
	for dev in "${DEVS[@]}"
	do eval kb "$dev" "$@" &
	done
	wait
	if ls build-failed-* &>/dev/null
	then
		echo
		echo "The following builds failed:"
		ls build-failed-* | sed -e 's/build-failed-//'
		echo
		read -n 1 -p 'Read build logs? '
		[[ "$REPLY" == [Yy] ]] && \
			less $(ls build-failed-* | \
			sed -n 's/build-failed-\(d2[a-z]\{3\}\)/massbuild-\1.log/; T; p')
		echo
		rm -f build-failed-*
		false
	fi
}

cd "$(dirname "$(readlink -f "$0")")"

GL=false
RD=false
CF=false
CL=false
EXP=false
PKG=true
FL=false
while [[ "$1" ]]
do
	case "$1" in
	(-l|--linaro) GL=true;;
	(-r|--ramdisk) RD=true;;
	(-c|--config) CF=true;;
	(-C|--clean) CL=true;;
	(-e|--experimental) EXP=true; BD="$(date +%s)"; BDIR="out/experimental";;
	(-n|--no-package) PKG=false;;
	(-f|--flash) FL=true; EXP=true; BD="$(date +%s)"; BDIR="out/experimental";;
	(*) 	if [[ "${ALLDEVS[*]}" == *$1* ]]
		then DEVS=("${DEVS[@]}" "$1")
		else
			cat >&2 <<-EOF
			Usage: $0 [options] [devices]
			Devices: ${ALLDEVS[*]} (edit $0 to update list)
			Options:
			-c (--config): make each device's defconfig before building
			-C (--clean): make clean for each device before building
			-e (--experimental): package builds as "experimental"
			-f (--flash): automagically flash; implies -e
			-l (--linaro): upgrade Linaro toolchain ($(dirname "$0")/android-toolchain-eabi), implies -C
			-n (--no-package): just build, don't package
			-r (--ramdisk): regenerate ramdisk from built Android sources
			EOF
			exit 1
		fi
	esac
	shift
done

# Make sure we have devices to build
[[ "${DEVS[*]}" ]] || DEVS=("${ALLDEVS[@]}")

if $FL
then
	flashdev="$(adb shell getprop ro.product.device | sed 's/[^[:print:]]//g')"
	if [[ "${DEVS[*]}" != *$flashdev* ]]
	then
		echo "Not building for device to be flashed ($flashdev)!"
		echo "Refusing to continue."
		exit 1
	fi
	case "$FLASH" in
	(internal) flashdir="/storage/sdcard0";;
	(external) flashdir="/storage/sdcard1";;
	(*) echo "FLASH must be 'internal' or 'external'"; exit 1;;
	esac
fi

# Update Linaro?
if $GL
then
	echo "Fetching latest Linaro toolchain..."
	mv android-toolchain-eabi{,.old}
	curl "http://snapshots.linaro.org/android/~linaro-android/toolchain-4.7-bzr/lastSuccessful/android-toolchain-eabi-4.7-daily-linux-x86.tar.bz2" | tar xj
	rm -Rf android-toolchain-eabi.old
fi

# Rebuild ramdisk?
if $RD || ! [[ -f initramfs.gz ]]
then
	echo "Rebuilding initramfs..."
	./mkbootfs "$RDSRC" | gzip -9 >initramfs.gz.tmp
	mv initramfs.gz.tmp initramfs.gz
fi

echo "Building..."
if ! $EXP
then for dev in "${DEVS[@]}"; do rm -f "$dev/.version"; done
fi
if $CL || $GL
then kba clean
fi
if $CF
then kba $CFGFMT
fi
kba

$PKG || exit 0
echo
echo "Packaging..."
mkdir -p "$BDIR"
echo "Generating install script..."
cat >installer/META-INF/com/google/android/updater-script <<-EOF
	ui_print("mounting system");
	run_program("/sbin/busybox", "mount", "/system");
	ui_print("copying modules & initscripts");
	package_extract_dir("system", "/system");
	ui_print("setting permissions");
	$(for f in installer/system/etc/init.d/*
	do echo "set_perm(0, 0, 0755, \"${f#installer}\");"
	done
	)$([[ -f installer/system/etc/init.qcom.post_boot.sh ]] && echo && \
	echo 'set_perm(0, 0, 0755, "/system/etc/init.qcom.post_boot.sh");'
	)$([[ -d installer/system/xbin ]] && echo && \
	for f in installer/system/xbin/*
	do echo "set_perm(0, 0, 0755, \"/system/xbin/$f\");"
	done
	)
	ui_print("unmounting system");
	unmount("/system");
	ui_print("flashing kernel");
	package_extract_file("boot.img", "/dev/block/mmcblk0p7");
EOF
for dev in "${DEVS[@]}"
do
	echo "Packaging $dev..."
	# CM uses rdo 0x0130000, but we need a few extra MB thanks to linaro -O3
	./mkbootimg \
		--kernel "kbuild-$dev/arch/arm/boot/zImage" \
		--ramdisk "initramfs.gz" \
		--cmdline 'console = null androidboot.hardware=qcom user_debug=31 zcache' \
		--base 0x80200000 --pagesize 2048 --ramdisk_offset 0x01900000 \
		--output "installer/boot.img"
	rm -f installer/system/lib/modules/*
	find "kbuild-$dev" -name '*.ko' -exec cp '{}' installer/system/lib/modules ';'
	if $EXP
	then btype=experimental
	elif [[ "${STABLE[@]}" == *$dev* ]]
	then btype=release
	else btype=testing
	fi
	rm -f "$BDIR/dkp-$btype-$dev-$BD.zip"
	(cd installer && zip -qr "../$BDIR/dkp-$btype-$dev-$BD.zip" *)
	echo "Created $BDIR/dkp-$btype-$dev-$BD.zip"
done

if $EXP
then
	echo
	read -n 1 -p 'Review build logs? '
	[[ "$REPLY" == [Yy] ]] && \
		less $(sed 's/\(^\| \)\([^ ]*\)/massbuild-\2.log /g' <<<"${DEVS[*]}")
	echo
	if $FL
	then
		read -n 1 -p 'Flash to device? '
		if [[ "$REPLY" == [Yy] ]]
		then
			echo
			# adb always returns 0, which sucks.
			adb shell "mkdir -p \"$flashdir/massbuild/\""
			echo "Pushing dkp-$btype-$flashdev-$BD.zip..."
			adb push "$BDIR/dkp-$btype-$flashdev-$BD.zip" \
				"$flashdir/massbuild/dkp-$btype-$flashdev-$BD.zip"
			echo "Generating OpenRecoveryScript..."
			adb shell "su -c 'echo \"install massbuild/dkp-$btype-$flashdev-$BD.zip\" >/cache/recovery/openrecoveryscript'"
			echo "Rebooting to recovery..."
			adb reboot recovery
		fi
	fi
	exit 0
fi

echo
echo "Building uninstaller..."
echo "Generating uninstall script..."
cat >uninstaller/META-INF/com/google/android/updater-script <<-EOF
	ui_print("mounting system");
	run_program("/sbin/busybox", "mount", "/system");
	ui_print("cleaning modules");
	$(for f in installer/system/lib/modules/*
	do echo "delete(\"${f#installer}\");"
	done)
	ui_print("cleaning initscripts");
	$(for f in installer/system/etc/init.d/*
	do echo "delete(\"${f#installer}\");"
	done
	)$([[ -f uninstaller/init.qcom.post_boot.sh ]] && echo && \
	echo 'package_extract_file("init.qcom.post_boot.sh", "/system/etc/init.qcom.post_boot.sh");'
	)$([[ -d installer/system/xbin ]] && echo && \
	echo "ui_print(\"cleaning xbin\");" && \
	for f in installer/system/xbin
	do echo "delete(\"${f#installer}\");"
	done
	)
	set_perm(0, 0, 0755, "/system/etc/init.qcom.post_boot.sh");
	ui_print("unmounting system");
	run_program("/sbin/busybox", "umount", "/system");
EOF
echo "Packaging uninstaller..."
rm -f "$BDIR/uninstall-dkp-$BD.zip"
(cd uninstaller && zip -qr "../$BDIR/uninstall-dkp-$BD.zip" *)
echo "Created $BDIR/uninstall-dkp-$BD.zip"
