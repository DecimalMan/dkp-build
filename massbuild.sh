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
if [[ "$RNAME" == "dkp-aosp44" ]]
then
	ALLDEVS=(d2)
	DEFDEVS=(d2)
	UPFMT='dkp/$RPATH/$RNAME-$bdate.zip'
	export CROSS_COMPILE=../toolchain-trunk-20140210/bin/arm-eabi-
else
	ALLDEVS=(d2att-d2tmo d2spr-d2vmu d2usc-d2cri d2vzw)
	DEFDEVS=(d2att-d2tmo d2spr-d2vmu d2usc-d2cri d2vzw)
	UPFMT='dkp/$RPATH/${dev//-/, }/$RNAME-$bdate.zip'
	export CROSS_COMPILE=../toolchain-linaro-20140216/bin/arm-eabi-
fi

# defconfig format, will be expanded per-device
CFGFMT='cyanogen_$@_defconfig'

# Where to push flashable builds to (internal/external storage)
FLASH=external

# FTP server to upload to
# ftp's stdin is hijacked, so it can't prompt for a password; use .netrc instead
UPHOST=ftp.xstefen.net

###  END OF CONFIGURABLES  ###

devs=()
flashdev=

# Quick prompt
askyn() { while :; do echo
	read -n 1 -p "$* "; [[ "$REPLY" == [YyNn] ]] && break; done
	echo ${NONL:+-n}; [[ "$REPLY" == [Yy] ]]; }
# Set output vars
gbt() { dev="$1" eval izip="$ZIPFMT"; }
# Complete device name; fail on multiple matches
cdn() { local dn=($(grep -o "[-a-z0-9]*$1[-a-z0-9]*" <<<"${ALLDEVS[*]}"));
	[[ ${#dn[*]} == 1 ]] && dev="${dn[0]}"; }
# Fancy termination messages
die() { echo "$((exit "$1") && echo "Finished" || echo "Fatal"): $2"; exit "$1"; }
# ADB shell with return value
adbsh() { ((r="$(adb -d shell "$@; echo \$?" | sed 's/\r//' | tee >(sed '$d' >&3) | tail -n 1)" && exit $r) 3>&1) }

cd "$(dirname "$(readlink -f "$0")")"

CF=false
CL=false
BLD=true
PKG=true
FL=false
UP=false
KO=false
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
		{ cfg="$2"; s="$1"; shift 2; set -- "$s" "$@"; } && BLD=false && PKG=false;;
	(C|--clean) CL=true;;
	(f|--flash) FL=true;;
	(m|--modules) KO=true; PKG=false;;
	(n|--no-package) PKG=false;;
	(N|--no-build) BLD=false;;
	(u|--upload) UP=true;;
	(-[^-]*);;
	(*) 	if cdn "$v"
		then devs=("${devs[@]}" "$dev")
		else
			cat >&2 <<-EOF
			Usage: $0 [options] [devices]
			Devices: ${ALLDEVS[*]} (edit $0 to update list)
			Options:
			-c (--config) [<target>]: configure each device before building
			-C (--clean): make clean for each device before building
			-f (--flash): automagically flash
			-m (--modules): just build modules
			-n (--no-package): just build, don't package
			-N (--no-build): don't rebuild the kernel
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
if ! $UP
then
	bdate="$(date +%Y%m%d-%H%M%S)"
	rtype="experimental"
	ZIPFMT="${ZIPFMT[1]}"
else
	bdate="$(date +%Y%m%d)"
	rtype="release"
fi

# Use the make jobserver to sort out building everything
# oldconfig is a huge pain, since it won't run with multiple jobs, needs
# defconfig to run first and needs stdin.  Still, it's nice to have.
KB="\$(MAKE) -S -C \"$KSRC\" O=\"\$(tree)\" V=1" # CONFIG_DEBUG_SECTION_MISMATCH=y"
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
	if [[ "$MAKEJOBS" ]]
	then pc="$MAKEJOBS"
	else pc="$(grep '^processor\W*:' /proc/cpuinfo | wc -l)"
	fi
	if [[ "$LTOPART" ]]
	then mj="-j$pc CONFIG_LTO_PARTITIONS=$LTOPART"
	else
		mt="$(sed -n '/MemTotal/{s/[^0-9]//g;p}' /proc/meminfo)"
		#((lp=27962026*pc/mt, lp=lp>32?32:lp<pc?pc:lp))
		((lp=31457280*pc/mt, lp=lp>32?32:lp<pc?pc:lp))
		echo "Building with $lp LTO partitions..."
		mj="-j$pc CONFIG_LTO_PARTITIONS=$lp"
	fi
fi
#if sed 's/$/$/' <(cat <<EOF
if ! "$m" $mj "${devs[@]}" -k -f <(cat <<EOF
$(for dev in ${devs[@]}
do gbt "$dev"
echo $dev: tree = $PWD/kbuild-$RNAME-\$@
echo $dev: izip = $PWD/$izip
echo $dev: isrc = $PWD/installer-$RNAME
done)
${devs[@]}:
	@mkdir -p "\$(tree)"
	@touch ".build-failed-\$@"
	@rm -f "build-\$@.log"
	$($CL && \
	echo "@echo Cleaning \$@..." && \
	echo "	@$KB clean &>>\"build-\$@.log\"")
	$($CF && \
	if [[ "$cfg" ]]
	then
		echo "@echo Making $cfg for \$@..."
		echo "	@$KB -s $cfg 2>>\"build-\$@.log\""
		echo "	@rm -f \".build-failed-\$@\""
	else
		echo "@echo Making $CFGFMT..." && \
		echo "	@$KB $dc &>>\"build-\$@.log\""
	fi)
	$($BLD && \
	echo "@echo \"Making $($KO && echo modules || echo all) for \$@...\"" && \
	echo "	@rm -f \"\$(tree)/.version\"" && \
	echo "	@$KB $($KO && echo modules) &>>\"build-\$@.log\"")
	@echo "Stripping \$@ modules..."
	@find "\$(tree)" -name '*.ko' -exec "${CROSS_COMPILE#../}strip" --strip-unneeded \{\} \; &>>"build-\$@.log"
	$($UP && \
	echo "@echo Saving \$@ System.map..." && \
	echo "	@mkdir -p \"\$(dir \$(izip))\"" && \
	echo "	@xz -c \"\$(tree)/System.map\" >\"\$(izip:.zip=.map)\"")
	$($PKG && ! $KO && \
	echo "@echo \"Packaging \$@...\"" && \
	echo "	@rm -Rf \"\$(tree)/.package\"" && \
	echo "	@cp -lr \"\$(isrc)\" \"\$(tree)/.package\"" && \
	echo "	@mkdir -p \"\$(tree)/.package/system/lib/modules\"" && \
	echo "	@cp -l \"\$(tree)/arch/arm/boot/zImage\" \"\$(tree)/.package/dkp-zImage\"" && \
	echo "	@find \"\$(tree)\" -name '*.ko' -exec cp -l \{\} \"\$(tree)/.package/system/lib/modules\" \;" && \
	echo "	@cd \"\$(tree)/.package\" && zip -r \"\$(izip)\" * &>>\"build-\$@.log\"" && \
	echo "	@echo \"Created \$(notdir \$(izip)).\"")
	@echo "Finished building \$@."
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

askyn "Review build logs?" && \
		less $(sed 's/\(^\| \)\([^ ]*\)/build-\2.log /g' <<<"${devs[*]}")

! $PKG && echo && die 0 "packaging disabled by --$($KO && echo modules || echo no-package)."

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
			if [[ "$RNAME" == "dkp-aosp44" ]]
			then
				if [[ "$flashdev" == "d2"* ]]
				then flashdev=d2
				else
					NONL=y askyn "No suitable device connected.  Retry?" || \
					break
				fi
			else
				cdn "$flashdev" && [[ "${devs[*]}" == *"$dev"* ]] || \
					NONL=y askyn "No suitable device connected.  Retry?" || \
					break
				flashdev="$dev"
			fi
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

			if [[ "$FLASH" == "internal" ]]
			then recdir="/sdcard"
			else recdir="/storage/sdcard1"
			fi

			gbt "$flashdev"
			adbsh "mkdir -p '$flashdir/massbuild/'"
			echo "Pushing $izip..."
			adb -d push "$izip" "$flashdir/massbuild/$(basename "$izip")"
			adbsh "[ -f '$flashdir/massbuild/$(basename "$izip")' ]" >/dev/null
			echo "Generating OpenRecoveryScript..."
			inst="(echo mount $recdir; echo install $recdir/massbuild/$(basename "$izip"); echo unmount $recdir) >/cache/recovery/openrecoveryscript"
			(adbsh "su -c '$inst'" || adbsh "$inst") >/dev/null
			echo "Rebooting to recovery..."
			adb -d reboot recovery
		fi
	else	echo
	fi
fi

if $UP
then
	if askyn "Upload to $UPHOST?"
	then
		for dev in "${devs[@]}"
		do
			gbt "$dev"
			eval path=\"$UPFMT\"
			echo cd /
			while [[ "$path" == */* ]]
			do
				echo mkdir \"${path%%/*}\"
				echo cd \"${path%%/*}\"
				path="${path#*/}"
			done
			echo put \"$izip\" \"${path}\"
		done | ftp -p "$UPHOST"
	else	echo
	fi
fi
