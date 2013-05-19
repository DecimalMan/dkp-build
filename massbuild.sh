#!/bin/bash -e

### CONFIGURABLE SETTINGS: ###

# Kernel source location, relative to massbuild.sh
KSRC=../dkp
KVER="$(sed -n '1{s/.*= //;h;n;s/.*= /./;H;x;s/\n//;p;q}' "$KSRC/Makefile")"
# Kernel version username
export KBUILD_BUILD_USER=decimalman
# Kernel name used for filenames
RNAME=dkp-$KVER
ENAME="$(cd "$KSRC" && git symbolic-ref --short HEAD 2>&-)" || ENAME=no-branch
# Format used for filenames, relative to massbuild.sh
ZIPFMT=('out/$rtype-$bdate/$RNAME-$dev-$bdate.zip' \
	'out/$rtype/$RNAME-$dev-$bdate-$ENAME.zip' \
	'out/$rtype-$bdate/uninstall-$RNAME-$bdate.zip')
# Devices available to build for
ALLDEVS=(d2att d2att-d2tmo d2cri d2spr d2usc d2vzw)
DEFDEVS=(d2att-d2tmo d2spr d2usc d2vzw)
# Devices that will be be marked 'release' rather than 'testing'
STABLE=(d2spr)
# defconfig format, will be expanded per-device
CFGFMT='cyanogen_$@_defconfig'

# boot.img kernel command line.  Without STRICT_RWX, RDO can be reduced (CM
# uses 0x0130000).
BOOTCLI='console = null androidboot.hardware=qcom user_debug=31 zcache'
BOOTRDO='0x1500000'

# Where to push flashable builds to (internal/external storage)
FLASH=external

# Dev-Host upload configs as ('release_val' 'experimental_val')
# DHUSER and DHPASS should be set in devhostauth.sh
# Upload directory, must already exist
DHDIRS=("/dkp-$KVER" "/dkp-$KVER-wip")
# Make public (1 = public, 0 = private)
DHPUB=(1 1)
# Upload description ('release' 'experimental' 'uninstaller')
DHDESC=('$RNAME $(date +%x) release for $dev' \
	'$RNAME $ENAME branch test build for $dev' \
	'$RNAME $(date +%x) uninstaller')

###  END OF CONFIGURABLES  ###

devs=()
#export CROSS_COMPILE=../hybrid-toolchain/bin/arm-linux-gnueabi-
export CROSS_COMPILE=../hybrid-4_7-toolchain/bin/arm-linux-gnueabi-

# Quick prompt
askyn() { echo; read -n 1 -p "$* "; echo; [[ "$REPLY" == [Yy] ]]; }
# Set output vars
gbt() { { $EXP && btype="experimental"; } || { [[ "${STABLE[*]}" == *"$1"* ]] && btype="release"; } || btype="testing"; eval izip="$ZIPFMT"; }
# Fancy termination messages
die() { echo "$((exit "$1") && echo "Finished" || echo "Fatal"): $2"; exit "$1"; }
# ADB shell with return value
adbsh() { ((r="$(adb -d shell "$@; echo \$?" | sed 's/\r//' | tee >(sed '$d' >&3) | tail -n 1)" && exit $r) 3>&1) }

cd "$(dirname "$(readlink -f "$0")")"

GL=false
CF=false
CL=false
EXP=true
PKG=true
FL=false
DH=false
BOGUS_ERRORS=false
cfg=
v="$1"
while [[ "$v" ]]
do
	case "$v" in
	(c|--config)
		CF=true
		# If next arg is a valid kconfig target, assume it requires
		# serial make and stdin/stdout.
		[[ "$2" != -* ]] && grep -q "^$2:" "$KSRC/scripts/kconfig/Makefile" 2>&- && \
		{ cfg="$2"; s="$1"; shift 2; set -- "$s" "$@"; };;
	(C|--clean) CL=true;;
	(f|--flash) FL=true;;
	(l|--linaro) GL=true;;
	(n|--no-package) PKG=false;;
	(--no-really) BOGUS_ERRORS=true;;
	(r|--release) EXP=false;;
	(u|--upload) DH=true;;
	(-[^-]*);;
	(*) 	if [[ " ${ALLDEVS[*]} " == *" $v "* ]]
		then devs=("${devs[@]}" "$v")
		else
			cat >&2 <<-EOF
			Usage: $0 [options] [devices]
			Devices: ${ALLDEVS[*]} (edit $0 to update list)
			Options:
			-c (--config) [<target>]: configure each device before building
			-C (--clean): make clean for each device before building
			-f (--flash): automagically flash
			-l (--linaro): upgrade Linaro toolchain ($(dirname "$0")/android-toolchain-eabi), implies -C
			-n (--no-package): just build, don't package
			-r (--release): package builds for release; generate uninstaller
			-u (--upload): upload builds to Dev-Host
			EOF
			exit 1
		fi
	esac
	# Can't use getopt since BSD's sucks.
	if [[ "$1" == --* ]] || ! getopts "cCflnru" v "$1"
	then
		shift
		v="$1"
		OPTIND=1
	fi
done

# Make sure we have devices to build
[[ "${devs[*]}" ]] || devs=("${DEFDEVS[@]}")

# Use a more informative naming scheme for experimental builds
if $EXP
then
	bdate="$(date +%Y%m%d-%H%M%S)"
	rtype="experimental"
	ZIPFMT="${ZIPFMT[1]}"
else
	bdate="$(date +%Y%m%d)"
	rtype="release"
	eval uzip="${ZIPFMT[2]}"
fi

# Sanity-check the device to be flashed
if $FL
then
	echo "Checking device to be flashed..."
	adb start-server &>/dev/null
	adb -d shell : >&-
	# Note to Google: unices don't like CRLF.
	flashdev="$(adbsh 'getprop ro.product.device')" || \
	flashdev="$(adbsh 'sed -n "/^ro.product.device/{s/.*=//;p}" /default.prop')"
	[[ "${devs[*]}" == *"$flashdev"* ]] || \
		die 1 "not building for device to be flashed ($flashdev)."
	case "$FLASH" in
	(internal) flashdirs=(/storage/emulated/legacy /sdcard);;
	(external) flashdirs=(/storage/sdcard1 /external_sd);;
	(*) die 1 "FLASH must be 'internal' or 'external'.";;
	esac
	flashdir="$(adb -d shell ls -d "${flashdirs[@]}" | \
		grep -v 'No such file or directory' | head -n 1 | \
		sed 's/\r//')"
	[[ "$flashdir" ]] || \
		die 1 "can't find device's $FLASH storage."
	echo
fi

# Update Linaro?
if $GL
then
	echo "Fetching latest Linaro nightly toolchain..."
	mv android-toolchain-eabi{,.old}
	if curl "http://snapshots.linaro.org/android/~linaro-android/toolchain-4.7-bzr/lastSuccessful/android-toolchain-eabi-4.7-daily-linux-x86.tar.bz2" | tar xj
	then rm -Rf android-toolchain-eabi.old
	else
		rm -Rf android-toolchain-eabi
		mv android-toolchain-eabi{.old,}
		die 1 "fetch failed.  Old toolchain restored."
	fi
	echo
fi

# Use the make jobserver to sort out building everything
# oldconfig is a huge pain, since it won't run with multiple jobs, needs
# defconfig to run first and needs stdin.  Still, it's nice to have.
KB="	@\$(MAKE) -C \"$KSRC\" O=\"$PWD/kbuild-\$@\"" # CONFIG_DEBUG_SECTION_MISMATCH=y"
# Explicitly use lto-fixed GNU make when available.
m="$(which lmake gmake make 2>&- | head -n 1)" || true
[[ "$m" ]] || die 1 "make not found; can't build."
"$m" -v 2>&- | grep -q GNU || echo "make isn't GNU make.  Expect problems."
if [[ "$cfg" ]]
then mj=
else mj="-j $(grep '^processor\W*:' /proc/cpuinfo | wc -l)"
fi
if ! "$m" $mj "${devs[@]}" -k -f <(cat <<EOF
${devs[@]}:
	@mkdir -p "kbuild-\$@"
	@touch "build-failed-\$@"
	@rm -f "build-\$@.log"
	$({ $CL || $GL; } && \
	echo "@echo Cleaning \$@..." && \
	echo "$KB clean &>>\"build-\$@.log\""
	)$($CF && \
	echo && \
	if [[ "$cfg" ]]
	then
		echo "	@echo Making $cfg for \$@..." && \
		echo "$KB -s $cfg 2>>\"build-\$@.log\""
	else
		echo "	@echo Making $CFGFMT..." && \
		echo "$KB $CFGFMT &>>\"build-\$@.log\""
	fi
	)$(! [[ "$cfg" ]] && \
	echo && \
	echo "	@echo Making all for \$@..." && \
	echo "	@rm -f \"kbuild-\$@/.version\"" && \
	(if $BOGUS_ERRORS
	then echo "	until $KB &>>\"build-\$@.log\"; do :; done"
	else echo "$KB &>>\"build-\$@.log\""
	fi) && \
	echo "	@echo Stripping \$@ modules..." && \
	echo "	@find \"kbuild-\$@\" -name '*.ko' -exec \"${CROSS_COMPILE#../}\"strip --strip-unneeded \{\} \; &>>\"build-\$@.log\"" && \
	echo "	@echo \"Finished building \$@.\""
	)
	@rm -f "build-failed-\$@"
.PHONY: ${devs[@]}
EOF
)
then
	askyn "Review build logs for failed builds?" && \
		less $(ls build-failed-* | \
		sed 's/build-failed-\([^ ]*\)/build-\1.log/')
	rm -f build-failed-*
	die 1 "building failed."
fi

[[ "$cfg" ]] && echo && die 0 "restart without --config to build."

$EXP && askyn "Review build logs?" && \
		less $(sed 's/\(^\| \)\([^ ]*\)/build-\2.log /g' <<<"${devs[*]}")

echo
$PKG || die 0 "packaging disabled by --no-package."

# Package everything.  Ramdisk is borrowed from the existing kernel so I don't
# have to keep CM sources around.  boot.img is generated first to avoid
# overwriting existing modules on failure.
echo "Generating install script..."
cat >installer/META-INF/com/google/android/updater-script <<-EOF
	ui_print("generating boot.img");
	run_program("/sbin/mkdir", "-p", "/cache/rd");
	package_extract_dir("rd", "/cache/rd");
	set_perm(0, 0, 0755, "/cache/rd/repack");
	run_program("/cache/rd/repack",
		"/dev/block/mmcblk0p7",
		"/cache/rd/zImage",
		"/cache/rd/boot.img",
		"$BOOTRDO",
		"$BOOTCLI");
	ui_print("mounting system");
	run_program("/sbin/busybox", "mount", "/system");
	ui_print("copying modules & initscripts");
	package_extract_dir("system", "/system");
	ui_print("setting permissions");
	$(for f in installer/system/etc/init.d/*
	do echo "set_perm(0, 0, 0755, \"${f#installer}\");"
	done
	)$(ls installer/system/xbin/* &>/dev/null && echo && \
	for f in installer/system/xbin/*
	do echo "set_perm(0, 0, 0755, \"${f#installer}\");"
	done)
	ui_print("unmounting system");
	unmount("/system");
	ui_print("flashing kernel");
	write_raw_image("/cache/rd/boot.img", "/dev/block/mmcblk0p7");
	delete_recursive("/cache/rd");
EOF
for dev in "${devs[@]}"
do
	echo "Packaging $dev..."
	cp "kbuild-$dev/arch/arm/boot/zImage" "installer/rd/zImage"
	rm -f installer/system/lib/modules/*
	find "kbuild-$dev" -name '*.ko' -exec cp '{}' installer/system/lib/modules ';'
	gbt "$dev"
	rm -f "$izip"
	mkdir -p "$(dirname "$izip")"
	(cd installer && zip -qr "../$izip" *)
	echo "Created $izip"
	cp "kbuild-$dev/System.map" "${izip%zip}map"
	echo "Saved $dev System.map"
	sbi="$(stat -c %s installer/rd/zImage)"
	let sd="$(du -b -d0 installer | cut -f 1)-$sbi"
	sz="$(stat -c %s "$izip")"
	echo "zImage: $sbi; data: $sd; zip: $sz"
done

if ! $EXP
then
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
		)$(ls installer/system/xbin/* &>/dev/null && echo && \
		echo "ui_print(\"cleaning binaries\");" && \
		for f in installer/system/xbin/*
		do echo "delete(\"${f#installer}\");"
		done
		)$(ls installer/system/etc/init.qcom.post_boot.sh &>/dev/null && echo && \
		echo 'set_perm(0, 0, 0755, "/system/etc/init.qcom.post_boot.sh");'
		)
		ui_print("unmounting system");
		run_program("/sbin/busybox", "umount", "/system");
	EOF
	echo "Packaging uninstaller..."
	rm -f "$uzip"
	(cd uninstaller && zip -qr "../$uzip" *)
	echo "Created $uzip"
fi

if $FL
then
	if askyn "Flash to device?"
	then
		gbt "$flashdev"
		# adb always returns 0, which sucks.
		adbsh "mkdir -p '$flashdir/massbuild/'"
		echo "Pushing $izip..."
		adb -d push "$izip" "$flashdir/massbuild/$(basename "$izip")"
		adbsh "[ -f '$flashdir/massbuild/$(basename "$izip")' ]" >/dev/null
		echo "Generating OpenRecoveryScript..."
		inst="echo install massbuild/$(basename "$izip") >/cache/recovery/openrecoveryscript"
		(adbsh "su -c '$inst'" || adbsh "$inst") >/dev/null
		echo "Rebooting to recovery..."
		adb -d reboot recovery
	fi
fi

if $DH
then
	askyn "Upload to Dev-Host?" || exit 0
	if $EXP
	then
		dha=()
		dhidx=1
	else
		dha=(-F "files[]=@$uzip" -F "file_description[]=$(eval echo "${DHDESC[2]}")")
		dhidx=0
	fi
	for dev in "${devs[@]}"
	do
		gbt "$dev"
		dha=("${dha[@]}" -F "files[]=@$izip" \
			-F "file_description[]=$(eval echo "${DHDESC[$dhidx]}")")
	done
	[[ -r devhostauth.sh ]] && . ./devhostauth.sh || true
	if ! [[ "$DHUSER" && "$DHPASS" ]]
	then
		read -p 'Dev-Host username: ' DHUSER
		read -s -p 'Dev-Host password: ' DHPASS
		echo
	fi
	echo "Logging in as $DHUSER..."
	cookies="$(curl -s -F "action=login" -F "username=$DHUSER" -F "password=$DHPASS" -F "remember=false" -c - -o /dev/null d-h.st)" || \
		die 1 "couldn't log in."
	html="$(curl -s -b <(echo "$cookies") d-h.st)" || \
		die 1 "couldn't fetch upload page."
	dirid="$(sed -n '/<select name="uploadfolder"/ { : nl; n; s/.*<option value="\([0-9]\+\)">'"${DHDIRS[$dhidx]//\//\\/}"'<\/option>.*/\1/; t pq; s/<\/select>//; T nl; q 1; : pq; p; q; }' <<<"$html")" || \
		die 1 "couldn't find folder ${DHDIRS[$dhidx]}."
	action="$(sed -n '/<div class="file-upload"/ { : nl; n; s/.*<form.*action="\([^"]*\)".*/\1/; t pq; s/<\/form>//; T nl; q 1; : pq; p; q; }' <<<"$html")" || \
		die 1 "couldn't determine upload URL."
	userid="$(sed -n '/d-h.st.*user/ { s/.*%7E//; p }' <<<"$cookies")" || \
		die 1 "couldn't determine user id."
	curl -F "UPLOAD_IDENTIFIER=${action##*=}" -F "action=upload" -F "uploadfolder=$dirid" -F "public=${DHPUB[$dhidx]}" -F "user_id=$userid" "${dha[@]}" -b <(echo "$cookies") "$action" -o /dev/null || \
		die 1 "upload unsuccessful."
fi
