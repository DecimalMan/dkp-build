#!/bin/bash -e
### CONFIGURABLE SETTINGS: ###

# Kernel version username
export KBUILD_BUILD_USER=decimalman

# Kernel source location, relative to massbuild.sh
if [[ "$TW" == "yup" ]]
then KSRC=../tw
else KSRC=../dkp
fi

# Kernel name used for paths/filenames
RPATH="$(sed -n '/^DKP_LABEL/{s/[^=]*=\W*//;p}' $KSRC/Makefile)"
RNAME="$(sed -n '/^DKP_NAME/{s/[^=]*=\W*//;p}' $KSRC/Makefile)"
ENAME="$(cd "$KSRC" && git symbolic-ref --short HEAD 2>&-)" || ENAME=no-branch

# Format used for filenames, relative to massbuild.sh
ZIPFMT=('out/$rtype-$bdate/$RNAME-$dev-$bdate.zip' \
	'out/$rtype/$RNAME-$dev-$bdate-$ENAME.zip')
# Devices available to build for
ALLDEVS=(d2att d2att-d2tmo d2cri d2spr d2usc d2vzw)
DEFDEVS=(d2att-d2tmo d2spr d2usc d2vzw)
# Devices that will be be marked 'release' rather than 'testing'
STABLE=(d2spr)
# defconfig format, will be expanded per-device
CFGFMT='cyanogen_$@_defconfig'

# Where to push flashable builds to (internal/external storage)
FLASH=external

# Dev-Host upload configs as ('release_val' 'experimental_val')
# DHUSER and DHPASS should be set in devhostauth.sh
DHPATH=('/dkp/$dev/$RPATH/Stable Builds/$RNAME $(date +%F) stable.zip' \
	'/dkp/$dev/$RPATH/Testing Builds/$RNAME $(date +%F) testing$([[ "$ENAME" == dkp* ]] || echo " ($ENAME branch)").zip')
# Upload description ('release' 'experimental')
DHDESC=('$RNAME $(date +%x) release for $dev' \
	'$RNAME test build for $dev (from branch $ENAME)')

###  END OF CONFIGURABLES  ###

devs=()
flashdev=
export CROSS_COMPILE=../hybrid-toolchain/bin/arm-eabi-
#export CROSS_COMPILE=../hybrid-toolchain-20130706/bin/arm-linux-gnueabi-
#export CROSS_COMPILE=../hybrid-4_7-toolchain/bin/arm-linux-gnueabi-

# Quick prompt
askyn() { while :; do echo
	read -n 1 -p "$* "; [[ "$REPLY" == [YyNn] ]] && break; done
	echo ${NONL:+-n}; [[ "$REPLY" == [Yy] ]]; }
# Set output vars
gbt() { dev="$1" eval izip="$ZIPFMT"; }
# Fancy termination messages
die() { echo "$((exit "$1") && echo "Finished" || echo "Fatal"): $2"; exit "$1"; }
# ADB shell with return value
adbsh() { ((r="$(adb -d shell "$@; echo \$?" | sed 's/\r//' | tee >(sed '$d' >&3) | tail -n 1)" && exit $r) 3>&1) }

cd "$(dirname "$(readlink -f "$0")")"

CF=false
CL=false
EXP=true
BLD=true
PKG=true
FL=false
DH=false
KO=false
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
	(m|--modules) KO=true; PKG=false;;
	(n|--no-package) PKG=false;;
	(N|--no-build) BLD=false;;
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
			-n (--no-package): just build, don't package
			-N (--no-build): don't rebuild the kernel
			-r (--release): package builds as release
			-u (--upload): upload builds to Dev-Host
			EOF
			exit 1
		fi
	esac
	# Can't use getopt since BSD's sucks.
	if [[ "$1" == --* ]] || ! getopts "cCflmnNru" v "$1"
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
fi

if $BLD
then
# Use the make jobserver to sort out building everything
# oldconfig is a huge pain, since it won't run with multiple jobs, needs
# defconfig to run first and needs stdin.  Still, it's nice to have.
KB="\$(MAKE) -S -C \"$KSRC\" O=\"$PWD/kbuild-$RNAME-\$@\" V=1" # CONFIG_DEBUG_SECTION_MISMATCH=y"
if [[ "$TW" == "yup" ]]
then dc="$CFGFMT"
else dc="VARIANT_DEFCONFIG=$CFGFMT SELINUX_DEFCONFIG=m2selinux_defconfig cyanogen_d2_defconfig"
fi
# Explicitly use GNU make when available.
m="$(which gmake make 2>&- | head -n 1)" || true
[[ "$m" ]] || die 1 "make not found; can't build."
"$m" -v 2>&- | grep -q GNU || echo "make isn't GNU make.  Expect problems."
if [[ "$cfg" ]]
then mj=
else
	pc="$(grep '^processor\W*:' /proc/cpuinfo | wc -l)"
	if which lmake >/dev/null 2>&1
	then
		mt="$(sed -n '/MemTotal/{s/[^0-9]//g;p}' /proc/meminfo)"
		((lp=27962026*pc/mt, lp=lp>32?32:lp<pc?pc:lp))
		echo "Building with $lp LTO partitions..."
		mj="-j$pc CONFIG_LTO_PARTITIONS=$lp"
	else
		mj="-j$pc"
	fi
fi
if ! "$m" $mj "${devs[@]}" -k -f <(cat <<EOF
${devs[@]}:
	@mkdir -p "kbuild-$RNAME-\$@"
	@touch ".build-failed-\$@"
	@rm -f "build-\$@.log"
	$($CL && \
	echo "@echo Cleaning \$@..." && \
	echo "	@$KB clean &>>\"build-\$@.log\""
	)$($CF && \
	echo && \
	if [[ "$cfg" ]]
	then
		echo "	@echo Making $cfg for \$@..." && \
		echo "	@$KB -s $cfg 2>>\"build-\$@.log\""
	else
		echo "	@echo Making $CFGFMT..." && \
		echo "	@$KB $dc &>>\"build-\$@.log\""
	fi
	)$(! [[ "$cfg" ]] && \
	echo && \
	echo "	@echo Making $($KO && echo modules || echo all) for \$@..." && \
	echo "	@rm -f \"kbuild-$RNAME-\$@/.version\"" && \
	(if $BOGUS_ERRORS
	then echo "	@until $KB $($KO && echo modules) &>>\"build-\$@.log\"; do :; done"
	else echo "	@$KB $($KO && echo modules) &>>\"build-\$@.log\""
	fi) && \
	echo "	@echo Stripping \$@ modules..." && \
	echo "	@find \"kbuild-$RNAME-\$@\" -name '*.ko' -exec \"${CROSS_COMPILE#../}\"strip --strip-unneeded \{\} \; &>>\"build-\$@.log\"" && \
	echo "	@echo \"Finished building \$@.\""
	)
	@rm -f ".build-failed-\$@"
.PHONY: ${devs[@]}
EOF
)
then
	askyn "Review build logs for failed builds?" && \
		less $(ls .build-failed-* | \
		sed 's/\.build-failed-\([^ ]*\)/build-\1.log/')
	rm -f .build-failed-*
	die 1 "building failed."
fi

[[ "$cfg" ]] && echo && die 0 "restart without --config to build."

$EXP && askyn "Review build logs?" && \
		less $(sed 's/\(^\| \)\([^ ]*\)/build-\2.log /g' <<<"${devs[*]}")

echo
$PKG || die 0 "packaging disabled by --$($KO && echo modules || echo no-package)."
fi

# Package everything.  Ramdisk is borrowed from the existing kernel so I don't
# have to keep CM sources around.  boot.img is generated first to avoid
# overwriting existing modules on failure.
echo "Generating install script..."
cat >installer/META-INF/com/google/android/updater-script <<-EOF
	ui_print("flashing kernel");
	run_program("/sbin/mkdir", "-p", "/cache/rd");
	package_extract_dir("rd", "/cache/rd");
	set_perm(0, 0, 0755, "/cache/rd/repack");
	run_program("/cache/rd/repack",
		"/dev/block/mmcblk0p7",
		"/cache/rd/zImage");
	delete_recursive("/cache/rd");
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
EOF
for dev in "${devs[@]}"
do
	echo "Packaging $dev..."
	cp "kbuild-$RNAME-$dev/arch/arm/boot/zImage" "installer/rd/zImage"
	rm -f installer/system/lib/modules/*
	find "kbuild-$RNAME-$dev" -name '*.ko' -exec cp '{}' installer/system/lib/modules ';'
	gbt "$dev"
	rm -f "$izip"
	mkdir -p "$(dirname "$izip")"
	(cd installer && zip -qr "../$izip" *)
	echo "Created $izip"
	if $DH
	then
		cp "kbuild-$RNAME-$dev/System.map" "${izip%zip}map"
		echo "Saved $dev System.map"
	fi
	sbi="$(stat -c %s installer/rd/zImage)"
	let sd="$(du -b -d0 installer | cut -f 1)-$sbi"
	sz="$(stat -c %s "$izip")"
	echo "zImage: $sbi; data: $sd; zip: $sz"
done

if $FL
then
	if NONL=y askyn "Flash to device?"
	then
		while ! [[ "$flashdev" ]]
		do
			if adb -d shell : &>/dev/null
			then
				# Note to Google: unices don't like CRLF.
				flashdev="$(adbsh 'getprop ro.product.device')" || \
				flashdev="$(adbsh 'sed -n "/^ro.product.device/{s/.*=//;p}" /default.prop')"
			fi
			[[ "$flashdev" && "${devs[*]}" == *"$flashdev"* ]] || \
				NONL=y askyn "No suitable device connected.  Retry?" || \
				break
		done
		echo
		if [[ "$flashdev" ]]
		then
			case "$FLASH" in
			(internal) flashdirs=(/storage/emulated/legacy /storage/sdcard0 /sdcard);;
			(external) flashdirs=(/storage/sdcard1 /storage/extSdCard /external_sd);;
			(*) die 1 "FLASH must be 'internal' or 'external'.";;
			esac
			flashdir="$(adb -d shell ls -d "${flashdirs[@]}" | \
				grep -v 'No such file or directory' | head -n 1 | \
				sed 's/\r//')"
			[[ "$flashdir" ]] || \
				die 1 "can't find device's $FLASH storage."

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
	else	echo
	fi
fi

if $DH && askyn "Upload to Dev-Host?"
then
	[[ -r devhostauth.sh ]] && . ./devhostauth.sh || true
	if ! [[ "$DHUSER" && "$DHPASS" ]]
	then
		read -p 'Dev-Host username: ' DHUSER
		read -s -p 'Dev-Host password: ' DHPASS
		echo
	fi
	if $EXP
	then dhidx=1
	else dhidx=0
	fi
	echo "Logging in as $DHUSER..."
	cookies="$(curl -s -F "action=login" -F "username=$DHUSER" -F "password=$DHPASS" -F "remember=false" -c - -o dh.html d-h.st)" || \
		die 1 "couldn't log in."
	for dev in "${devs[@]}"
	do
		gbt "$dev"
		html="$(curl -s -b <(echo "$cookies") d-h.st)" || \
			die 1 "couldn't fetch upload page."
		id=0
		IFS=/ read -a c < <(eval echo "${DHPATH[$dhidx]}")
		set -- "${c[@]}"
		[[ "$1" ]] || shift
		[[ "$2" ]] && {
		p="\\/$1"
		# This really needs to be optimized, but I'm lazy
		while new="$(sed -n '/<select name="uploadfolder"/ {
			: nl; n;
			s/.*<option value="\([0-9]\+\)">'"$p"'<\/option>.*/\1/; t pq;
			s/<\/select>//; T nl; q 1;
			: pq; p; q; }' <<<"$html")" \
			&& [[ "$2" ]]
		do shift; p="$p\\/$1"; id="$new"; done
		while [[ "$2" ]]
		do	id="$(curl -s -b <(echo "$cookies") \
				-F "action=createfolder" \
				-F "fld_parent_id=$id" \
				-F "fld_name=$1" \
				d-h.st)"
			shift
		done
		}
		action="$(sed -n '/<div class="file-upload"/ {
			: nl; n;
			s/.*<form.*action="\([^"]*\)".*/\1/; t pq;
			s/<\/form>//; T nl; q 1;
			: pq; p; q; }' <<<"$html")" || \
			die 1 "couldn't determine upload URL."
		userid="$(sed -n '/d-h.st.*user/ { s/.*%7E//; p }' <<<"$cookies")" || \
			die 1 "couldn't determine user id."
		echo "Beginning upload of ${izip}..."
		curl -s -b <(echo "$cookies") \
			-F "UPLOAD_IDENTIFIER=${action##*=}" \
			-F "action=upload" \
			-F "uploadfolder=$id" \
			-F "public=1" \
			-F "user_id=$userid" \
			-F "files[]=@$izip;filename=$1" \
			-F "file_description[]=$(eval echo "\"${DHDESC[$dhidx]}\"")" \
			"$action" -o /dev/null &
	done
	wait
	echo "All uploads completed!"
fi
