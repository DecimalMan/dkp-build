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
# boot.img command line and arguments.
BOOTCLI='console = null androidboot.hardware=qcom user_debug=31 zcache'
BOOTARGS='--base 0x80200000 --pagesize 2048 --ramdisk_offset 0x01900000'
# defconfig format, will be expanded per-device
CFGFMT='cyanogen_$@_defconfig'
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
export CROSS_COMPILE=../android-toolchain-eabi/bin/arm-eabi-

# Upload to Dev-Host.  This could be done better, but I <3 sed.
dhup() {
	(( $# > 2 && $# % 2 == 0 ))
	[[ -r devhostauth.sh ]] && . ./devhostauth.sh || true
	if ! [[ "$DHUSER" && "$DHPASS" ]]
	then
		read -p 'Dev-Host username: ' DHUSER
		read -s -p 'Dev-Host password: ' DHPASS
		echo
	fi
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
v="$1"
while [[ "$v" ]]
do
	case "$v" in
	(c|--config) CF=true;;
	(C|--clean) CL=true;;
	(f|--flash) FL=true; EXP=true;;
	(l|--linaro) GL=true;;
	(n|--no-package) PKG=false;;
	(o|--oldconfig) OC=true;;
	(r|--release) EXP=false;;
	(R|--ramdisk) RD=true;;
	(u|--upload) DH=true;;
	(-*);;
	(*) 	if [[ "${ALLDEVS[*]}" == *"$v"* ]]
		then DEVS=("${DEVS[@]}" "$v")
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
	if ! getopts "cCflnorRu" v "$1"
	then
		shift
		v="$1"
		OPTIND=1
	fi
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
	echo "Checking device to be flashed..."
	adb start-server >/dev/null 2>&1
	adb -d shell : >/dev/null
	flashdev="$(adb -d shell getprop ro.product.device | sed 's/[^[:print:]]//g')"
	[[ "$flashdev" == *"getprop: not found" ]] && \
	flashdev="$(adb -d shell sed -n '/^ro.product.device/ { s/.*=//; p; }' /default.prop | \
	sed 's/[^[:print:]]//g')"
	if [[ "${DEVS[*]}" != *"$flashdev"* ]]
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
	flashdir="$(adb -d shell ls -d "${flashdirs[@]}" | sed 's/[^[:print:]]//g' | \
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

# Use the make jobserver to sort out building everything
# oldconfig is a huge pain, since it won't run with multiple jobs, needs
# defconfig to run first and needs stdin.  Still, it's nice to have.
KB="	@\$(MAKE) -C \"$KSRC\" O=\"$PWD/kbuild-\$@\""
if $OC
then mj=
else mj="-j $(grep '^processor\W*:' /proc/cpuinfo | wc -l)"
fi
if ! make $mj "${DEVS[@]}" -k -f <(cat <<EOF
${DEVS[@]}:
	@mkdir -p "kbuild-\$@"
	@touch "build-failed-\$@"
	@rm -f "massbuild-\$@.log"
	$($CL && \
	echo "@echo Cleaning \$@..." && \
	echo "$KB clean >>\"massbuild-\$@.log\" 2>&1"
	)$($CF && \
	echo && \
	echo "	@echo Making ${CFGFMT}..." && \
	echo "$KB $CFGFMT >>\"massbuild-\$@.log\" 2>&1"
	)$($OC && \
	echo && \
	echo "	@echo Making oldconfig for \$@..." && \
	echo "$KB -s oldconfig 2>\"massbuild-\$@.log\""
	)$(! $OC && \
	echo && \
	echo "	@echo Making all for \$@..." && \
	echo "$KB $* >>\"massbuild-\$@.log\" 2>&1"
	)
	@rm -f "build-failed-\$@"
	@echo "Finished building \$@."
.PHONY: ${DEVS[@]}
EOF
)
then
	echo
	read -n 1 -p 'Some builds failed.  Read build logs? '
	echo
	[[ "$REPLY" == [Yy] ]] && \
		less $(ls build-failed-* | \
		sed -n 's/build-failed-\(d2[a-z]\{3\}\)/massbuild-\1.log/; T; p')
	rm -f build-failed-*
	false
fi

(n=
$OC && n="Finished configuration.  Please restart without --oldconfig to build." || true
$PKG || n="Finished building.  Packaging disabled by --no-package."
[[ "$n" ]] || exit 0
echo
echo "$n"
false) || exit 0

echo
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
	done)
	ui_print("unmounting system");
	unmount("/system");
	ui_print("flashing kernel");
	package_extract_file("boot.img", "/dev/block/mmcblk0p7");
EOF
for dev in "${DEVS[@]}"
do
	echo "Packaging $dev..."
	./mkbootimg \
		--kernel "kbuild-$dev/arch/arm/boot/zImage" \
		--ramdisk "initramfs.gz" \
		--cmdline "$BOOTCLI" \
		$BOOTARGS \
		--output "installer/boot.img"
	rm -f installer/system/lib/modules/*
	find "kbuild-$dev" -name '*.ko' -exec cp '{}' installer/system/lib/modules ';'
	if $EXP
	then btype=experimental
	elif [[ "${STABLE[@]}" == *"$dev"* ]]
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
			adb -d shell "mkdir -p \"$flashdir/massbuild/\""
			echo "Pushing $NAME-$btype-$flashdev-$BD.zip..."
			adb -d push "$BDIR/$NAME-$btype-$flashdev-$BD.zip" \
				"$flashdir/massbuild/$NAME-$btype-$flashdev-$BD.zip"
			echo "Generating OpenRecoveryScript..."
			adb -d shell "e='echo \"install massbuild/$NAME-$btype-$flashdev-$BD.zip\" >/cache/recovery/openrecoveryscript'; su -c \"\$e\" || eval \"\$e\"" >/dev/null 2>&1
			echo "Rebooting to recovery..."
			adb -d reboot recovery
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
	)$(ls installer/system/xbin/* &>/dev/null && echo && \
	echo "ui_print(\"cleaning binaries\");" && \
	for f in installer/system/xbin/*
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
		if [[ "${STABLE[@]}" == *"$dev"* ]]
		then btype=release
		else btype=testing
		fi
		dhupargs=("${dhupargs[@]}" "$BDIR/$NAME-$btype-$dev-$BD.zip" "$(eval echo "${DHDESC[0]}")")
	done
	dhup "${DHDIRS[0]}" "${DHPUB[0]}" "${dhupargs[@]}"
fi
