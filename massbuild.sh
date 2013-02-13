#!/bin/bash -e

### CONFIGURABLE SETTINGS: ###

# Kernel source location, relative to massbuild.sh
KSRC=../android_kernel_samsung_d2
# Kernel name used for filenames
#NAME=dkp
NAME="$(cd "$KSRC" && git symbolic-ref --short HEAD)"
# Devices available to build for
ALLDEVS=(d2att d2cri d2spr d2usc d2vzw)
# Devices that will be be marked 'release'
STABLE=(d2spr)
# Ramdisk source, relative to massbuild.sh
RDSRC=../../cm101/out/target/product/d2spr/root
# defconfig format, will be expanded per-device
CFGFMT='cyanogen_${dev}_defconfig'
# Where to push flashable builds to (internal/external "SD" card)
FLASH=external

# Dev-Host upload configs as (release_val experimental_val)
# DHUSER and DHPASS should be set in devhostauth.sh
# Upload directory, must already exist
DHDIRS=(/DKP /DKP-WIP)
# Make public (1 = public, 0 = private)
DHPUB=(1 1)
# Upload description (release experimental uninstaller)
DHDESC=('$NAME $(date +%x) release for $dev' '$NAME test build for $dev' '$NAME $(date +%x) uninstaller')

###  END OF CONFIGURABLES  ###

DEVS=()
let MAKEJ="$(grep '^processor\W*:' /proc/cpuinfo | wc -l)" MAKEL=MAKEJ+1
export CROSS_COMPILE=../android-toolchain-eabi/bin/arm-eabi-

# Run a build in its own device-specific dir
kb() {
	[[ "$1" ]]
	D="$1"
	shift
	echo "Making ${@:-all} for $D..."
	mkdir -p "kbuild-$D"
	make -j $MAKEJ -l $MAKEL -C "$KSRC" O="$(pwd)/kbuild-$D" "$@" >"massbuild-$D.log" 2>&1 || \
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
		echo
		[[ "$REPLY" == [Yy] ]] && \
			less $(ls build-failed-* | \
			sed -n 's/build-failed-\(d2[a-z]\{3\}\)/massbuild-\1.log/; T; p')
		rm -f build-failed-*
		false
	fi
}

# Upload to Dev-Host.  This could be done better, but I <3 sed.
dhup() {
	(( $# > 2 && $# % 2 == 0 ))
	. ./devhostauth.sh
	[[ "$DHUSER" && "$DHPASS" ]]
	# Sign in.  Resulting page isn't useful.
	echo "Logging in as $DHUSER..."
	cookies="$(curl -s -F "action=login" -F "username=$DHUSER" -F "password=$DHPASS" -F "remember=false" -c - -o /dev/null d-h.st)"
	# Fetch signed-in upload page.
	html="$(curl -s -b <(echo "$cookies") d-h.st)"
	# Look up directory id
	dirid="$(sed -n '/<select name="uploadfolder"/ { : nl; n; s/.*<option value="\([0-9]\+\)">'"${1//\//\\/}"'<\/option>.*/\1/; t pq; s/<\/select>//; T nl; q 1; : pq; p; q; }' <<<"$html")"
	# Look up form action (i.e. URL)
	action="$(sed -n '/<div class="file-upload"/ { : nl; n; s/.*<form.*action="\([^"]*\)".*/\1/; t pq; s/<\/form>//; T nl; q 1; : pq; p; q; }' <<<"$html")"
	# Guess userid from cookie instead of looking it up
	userid="$(sed -n '/d-h.st.*user/ { s/.*%7E//; p }' <<<"$cookies")"
	dhpub="$2"
	shift 2
	dhargs=()
	while [[ "$1" ]]; do dhargs=("${dhargs[@]}" -F "files[]=@$1" -F "file_description[]=$2"); shift 2; done
	# pull upload_id from action instead of looking it up
	echo "Uploading..."
	curl -F "UPLOAD_IDENTIFIER=${action##*=}" -F "action=upload" -F "uploadfolder=$dirid" -F "public=$dhpub" -F "user_id=$userid" "${dhargs[@]}" -b <(echo "$cookies") "$action" -o /dev/null
}

cd "$(dirname "$(readlink -f "$0")")"

GL=false
RD=false
CF=false
CL=false
EXP=true
PKG=true
FL=false
DH=false
OC=false
while [[ "$1" ]]
do
	case "$1" in
	(-l|--linaro) GL=true;;
	(-R|--ramdisk) RD=true;;
	(-c|--config) CF=true;;
	(-C|--clean) CL=true;;
	(-r|--release) EXP=false;;
	(-n|--no-package) PKG=false;;
	(-f|--flash) FL=true; EXP=true;;
	(-u|--upload) DH=true;;
	(-o|--oldconfig) OC=true;;
	(*) 	if [[ "${ALLDEVS[*]}" == *$1* ]]
		then DEVS=("${DEVS[@]}" "$1")
		else
			cat >&2 <<-EOF
			Usage: $0 [options] [devices]
			Devices: ${ALLDEVS[*]} (edit $0 to update list)
			Options:
			-c (--config): make each device's defconfig before building
			-C (--clean): make clean for each device before building
			-f (--flash): automagically flash
			-l (--linaro): upgrade Linaro toolchain ($(dirname "$0")/android-toolchain-eabi), implies -C
			-n (--no-package): just build, don't package
			-o (--oldconfig): make oldconfig for each device before building
			-r (--release): package builds for release; generate uninstaller
			-R (--ramdisk): regenerate ramdisk from built Android sources
			-u (--upload): upload builds to Dev-Host
			EOF
			exit 1
		fi
	esac
	shift
done

# Make sure we have devices to build
[[ "${DEVS[*]}" ]] || DEVS=("${ALLDEVS[@]}")

if $EXP
then
	BD="$(date +%s)"
	BDIR="out/experimental"
else
	BD="$(date +%Y%m%d)"
	BDIR="out/release-$BD"
fi

if $FL
then
	adb start-server >/dev/null 2>&1
	flashdev="$(adb shell getprop ro.product.device | sed 's/[^[:print:]]//g')"
	[[ "$flashdev" == *"getprop: not found" ]] && \
	flashdev="$(adb shell sed -n '/^ro.product.device/ { s/.*=//; p; }' /default.prop | \
	sed 's/[^[:print:]]//g')"
	if [[ "${DEVS[*]}" != *$flashdev* ]]
	then
		echo "Not building for device to be flashed ($flashdev)!"
		echo "Refusing to continue."
		exit 1
	fi
	case "$FLASH" in
	(internal) flashdirs=(/storage/sdcard0 /sdcard/0);;
	(external) flashdirs=(/storage/sdcard1 /external_sd);;
	(*) echo "FLASH must be 'internal' or 'external'"; exit 1;;
	esac
	flashdir="$(adb shell ls -d "${flashdirs[@]}" | sed 's/[^[:print:]]//g' | \
		grep -v 'No such file or directory')"
fi

# Update Linaro?
if $GL
then
	echo "Fetching latest Linaro nightly toolchain..."
	mv android-toolchain-eabi{,.old}
	curl "http://snapshots.linaro.org/android/~linaro-android/toolchain-4.7-bzr/lastSuccessful/android-toolchain-eabi-4.7-daily-linux-x86.tar.bz2" | tar xj
	rm -Rf android-toolchain-eabi.old
	echo
fi

# Rebuild ramdisk?
if $RD || ! [[ -f initramfs.gz ]]
then
	echo "Rebuilding initramfs..."
	rdtmp="$(mktemp -d 'initramfs.XXXXXX')"
	cp -r "${RDSRC}"/* "$rdtmp"
	ls ramdisk-overlay/* &>/dev/null &&
		cp -r ramdisk-overlay/* "$rdtmp"
	./mkbootfs "$rdtmp" | gzip -9 >initramfs.gz.tmp
	rm -rf "$rdtmp"
	mv initramfs.gz.tmp initramfs.gz
	echo
fi

echo "Building $NAME..."
if ! $EXP
then for dev in "${DEVS[@]}"; do rm -f "kbuild-$dev/.version"; done
fi
if $OC
then for dev in "${DEVS[@]}"; do make -C "$KSRC" O="$(pwd)/kbuild-$dev" oldconfig; done
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
echo "Packaging $NAME..."
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
	)$(ls installer/system/xbin/* &>/dev/null && echo && \
	for f in installer/system/xbin/*
	do echo "set_perm(0, 0, 0755, \"${f#installer}\");"
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
	rm -f "$BDIR/$NAME-$btype-$dev-$BD.zip"
	(cd installer && zip -qr "../$BDIR/$NAME-$btype-$dev-$BD.zip" *)
	echo "Created $BDIR/$NAME-$btype-$dev-$BD.zip"
done

if $EXP
then
	echo
	read -n 1 -p 'Review build logs? '
	echo
	[[ "$REPLY" == [Yy] ]] && \
		less $(sed 's/\(^\| \)\([^ ]*\)/massbuild-\2.log /g' <<<"${DEVS[*]}")
	if $FL
	then
		read -n 1 -p 'Flash to device? '
		echo
		if [[ "$REPLY" == [Yy] ]]
		then
			# adb always returns 0, which sucks.
			adb shell "mkdir -p \"$flashdir/massbuild/\""
			echo "Pushing $NAME-$btype-$flashdev-$BD.zip..."
			adb push "$BDIR/$NAME-$btype-$flashdev-$BD.zip" \
				"$flashdir/massbuild/$NAME-$btype-$flashdev-$BD.zip"
			echo "Generating OpenRecoveryScript..."
			adb shell "e='echo \"install massbuild/$NAME-$btype-$flashdev-$BD.zip\" >/cache/recovery/openrecoveryscript'; su -c \"\$e\" || eval \"\$e\"" >/dev/null 2>&1
			echo "Rebooting to recovery..."
			adb reboot recovery
		fi
	fi
	if $DH
	then
		read -n 1 -p 'Upload to Dev-Host? '
		echo
		if [[ "$REPLY" == [Yy] ]]
		then
			dhupargs=()
			for dev in "${DEVS[@]}"
			do
				dhupargs=("${dhupargs[@]}" "$BDIR/$NAME-$btype-$dev-$BD.zip" "$(eval echo "${DHDESC[1]}")")
			done
			dhup "${DHDIRS[1]}" "${DHPUB[1]}" "${dhupargs[@]}"
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
rm -f "$BDIR/uninstall-$NAME-$BD.zip"
(cd uninstaller && zip -qr "../$BDIR/uninstall-$NAME-$BD.zip" *)
echo "Created $BDIR/uninstall-$NAME-$BD.zip"

if $DH
then
	echo
	dhupargs=("${dhupargs[@]}" "$BDIR/uninstall-$NAME-$BD.zip" "$(eval echo "${DHDESC[2]}")")
	for dev in "${DEVS[@]}"
	do
		if [[ "${STABLE[@]}" == *$dev* ]]
		then btype=release
		else btype=testing
		fi
		dhupargs=("${dhupargs[@]}" "$BDIR/$NAME-$btype-$dev-$BD.zip" "$(eval echo "${DHDESC[0]}")")
	done
	dhup "${DHDIRS[0]}" "${DHPUB[0]}" "${dhupargs[@]}"
fi
