#!/bin/bash -e
### CONFIGURABLE SETTINGS: ###

# Kernel version username
export KBUILD_BUILD_USER=decimalman

# Kernel source location, relative to massbuild.sh
if [[ "$TW" == "yup" ]]
then	KSRC=../tw
else	KSRC=../dkp
fi

# Kernel name used for paths/filenames
RPATH="$(sed -n '/^DKP_LABEL/{s/[^=]*=\W*//;p}' $KSRC/Makefile)"
RNAME="$(sed -n '/^DKP_NAME/{s/[^=]*=\W*//;p}' $KSRC/Makefile)"
ENAME="$(cd "$KSRC" && git symbolic-ref --short HEAD 2>&-)" || ENAME=no-branch

# Format used for filenames, relative to massbuild.sh
ZIPFMT='out/$zpath/$rname-$device-$bdate-$branch.zip'
UPFMT='$rname-$(maybe-branch)$device-$bdate.zip'
maybe-branch() { [[ "$branch" == dkp* ]] || echo "$branch"-; }

if [[ "$RNAME" == *aosp* ]]
then
	ALLDEVS=(5.1:d2 5.0:d2 4.4:d2 4.4:legacy)
	DEFDEVS=(d2)
	export CROSS_COMPILE=../toolchain/arm-eabi-gcc-4_9-20150228/bin/arm-eabi-
else
	ALLDEVS=(d2att-d2tmo d2spr-d2vmu d2usc-d2cri d2vzw)
	DEFDEVS=(d2spr-d2vmu)
	export CROSS_COMPILE=../toolchain/linaro-20140426/bin/arm-eabi-
fi

# defconfig format, will be expanded per-device
CFGFMT='cyanogen_$(device)_defconfig'

# Where to push flashable builds to (internal/external storage)
FLASH=external

# Upload configuration
UPDIR='dkp/$rpath$(maybe-legacy)'
maybe-legacy() { [[ "$device" != *legacy* ]] || echo " (old ROMs)"; }
UPLOAD=(mediafire) # ftp
#FTPHOST=(ftp.example.net ftp.host.com/username)

###  END OF CONFIGURABLES  ###

tmpdevs=()
flashdev=

# Quick prompt
askyn() { while :; do echo
	read -n 1 -p "$* "; [[ "$REPLY" == [YyNn] ]] && break; done
	echo ${NONL:+-n}; [[ "$REPLY" == [Yy] ]]; }
# Fancy termination messages
die() { echo "$((exit "$1") && echo "Finished" || echo "Fatal"): $2"; exit "$1"; }
# ADB shell with return value
adbsh() { ((r="$(adb -d shell "$@; echo \$?" | sed 's/\r//' | tee >(sed '$d' >&3) | tail -n 1)" && exit $r) 3>&1) }

# Recall device vars
gbt() {
	IFS=: read branch device <<<"$1"
	[[ "$device" ]] || { device="$1"; branch=; }

	if [[ "$branch" ]]
	then
		ksrc="ksrc-$branch"
		txt="$(cd "$KSRC" && git show "$branch:Makefile" | grep '^DKP_')"
		rpath="$(sed -n '/^DKP_LABEL/{s/[^=]*=\W*//;p}' <<<"$txt")"
		rname="$(sed -n '/^DKP_NAME/{s/[^=]*=\W*//;p}' <<<"$txt")"
		# make doesn't like colons in target names
		dev="${branch}_${device}"
	else
		branch="$ENAME"
		ksrc="$KSRC"
		rpath="$RPATH"
		rname="$RNAME"
	fi

	eval izip="$ZIPFMT"
}
# Match or complete [branch:]device name
cdn() {
	IFS=: read branch device <<<"$1"
	[[ "$device" ]] || { device="$1"; branch=; }

	if [[ "$branch" ]]
	then
		if ! [[ "$(cd "$KSRC" && git branch --list "$branch")" ]]
		then
			brs=($(cd "$KSRC" && git branch --list "*$branch*" | sed 's/^[ *]\{2\}//'))
			[[ "${#brs[@]}" -gt 1 ]] && die 1 "$branch matches multiple branches!"
			branch="${brs[0]}"
		fi
	fi

	# List defconfigs
	if [[ "$branch" ]]
	then	local dcs="$(cd "$KSRC" && git ls-tree --name-only "$branch:arch/arm/configs")"
	else	local dcs="$(ls "$KSRC/arch/arm/configs")"
	fi

	# Extract device names from matching defconfigs
	device() { echo "\\(.*${device}.*\\)"; }
	eval dcs=($(eval sed -n "/$CFGFMT/{s/$CFGFMT/\\\\1/\;p}" <<<"$dcs"))

	# Match or complete device name
	if [[ ${#dcs[@]} == 0 ]]
	then	return 1;
	elif [[ ${#dcs[@]} == 1 ]]
	then	device="${dcs[0]}"
	else
		local fail=y
		for d in "${dcs[@]}"; do [[ "$device" == "$d" ]] && fail= && break; done
		[[ "$fail" ]] && die 1 "$device matches multiple devices!"
	fi

	if [[ "$branch" ]]
	then	dev="$branch:$device"
	else	dev="$device"
	fi
}

cd "$(dirname "$(readlink -f "$0")")"

CF=false
CL=false
BLD=true
PKG=true
FL=false
FLASH_NOREBOOT=false
UP=false
KO=false
SP=false
cfg=
v="$1"
while [[ "$v" ]]
do
	case "$v" in
	(a|--all) tmpdevs=("${ALLDEVS[@]}");;
	(c|--config)
		CF=true
		# If next arg is a valid kconfig target, assume it requires
		# serial make and stdin/stdout.
		[[ "$2" != -* ]] && grep -q "^$2:" "$KSRC/scripts/kconfig/Makefile" 2>&- && \
		{ cfg="$2"; s="$1"; shift 2; set -- "$s" "$@"; } && BLD=false && PKG=false;;
	(C|--clean) CL=true;;
	(f|--flash) FL=true;;
	(F) FL=true; FLASH_NOREBOOT=true;;
	(m|--modules) KO=true; PKG=false;;
	(n|--no-package) PKG=false;;
	(N|--no-build) BLD=false;;
	(s|--sparse) SP=true;;
	(u|--upload) UP=true;;
	(-[^-]*);;
	(*) 	if cdn "$v"
		then	tmpdevs=("${tmpdevs[@]}" "$dev")
		else
			cat >&2 <<-EOF
			Usage: $0 [options] [devices]
			Options:
			 -a (--all): build all devices
			 -c (--config) [<target>]: configure each device before building
			 -C (--clean): make clean for each device before building
			 -f (--flash): automagically flash
			 -m (--modules): just build modules
			 -n (--no-package): don't package
			 -N (--no-build): don't build
			 -s (--sparse): build with C=1 to run sparse
			 -u (--upload): upload builds
			EOF
			exit 1
		fi
	esac
	# Can't use getopt since BSD's sucks.
	if [[ "$1" == --* ]] || ! getopts "acCfFmnNsu" v "$1"
	then
		shift
		v="$1"
		OPTIND=1
	fi
done

# Make sure we have devices to build
[[ "${tmpdevs[*]}" ]] || tmpdevs=("${DEFDEVS[@]}")

# Expand abbreviated devices
devs=()
for d in "${tmpdevs[@]}"
do
	cdn "$d"
	devs=("${devs[@]}" "$dev")
done

# Mangle devices for make
for n in `seq 0 $((${#devs[@]}-1))`; do
	mdevs=("${mdevs[@]}" "$(tr : _ <<<"${devs[$n]}")")
done

# Use a more informative naming scheme for experimental builds
if ! $UP
then
	bdate="$(date +%Y%m%d-%H%M%S)"
	zpath="experimental"
else
	bdate="$(date +%Y%m%d)"
	zpath="release-$bdate"
fi

# Use the make jobserver to sort out building everything
# oldconfig is a huge pain, since it won't run with multiple jobs, needs
# defconfig to run first and needs stdin.  Still, it's nice to have.
KB="\$(MAKE) -S -C \"\$(ksrc)\" O=\"\$(tree)\" V=1" # CONFIG_DEBUG_SECTION_MISMATCH=y"
if [[ "$RNAME" != "dkp-aosp"* ]]
then	dc="$CFGFMT"
else	dc="VARIANT_DEFCONFIG=$CFGFMT SELINUX_DEFCONFIG=m2selinux_defconfig cyanogen_d2_defconfig"
fi
# Explicitly use GNU make when available.
m="$(which gmake make 2>&- | head -n 1)" || true
[[ "$m" ]] || die 1 "make not found; can't build."
"$m" -v 2>&- | grep -q GNU || echo "make isn't GNU make.  Expect problems."
if [[ "$cfg" ]]
then	mj=
else
	if [[ "$MAKEJOBS" ]]
	then	pc="$MAKEJOBS"
	else	pc="$(grep '^processor\W*:' /proc/cpuinfo | wc -l)"
	fi
	if [[ "$LTOPART" ]]
	then	lp="$LTOPART"
	else	mt="$(sed -n '/MemTotal/{s/[^0-9]//g;p}' /proc/meminfo)"
		((lp=31457280*pc/mt, lp=lp>32?32:lp<pc?pc:lp, lp+=pc-lp%pc))
		echo "Building with $lp LTO partitions..."
	fi
	mj="-j$pc CONFIG_LTO_PARTITIONS=$lp"
fi

[[ "$DUMPMAKE" ]] && nice() { cat -n ${!#}; }
if ! nice "$m" $mj "${mdevs[@]}" -k -f <(cat <<EOF
$(for dev in ${devs[@]}
do gbt "$dev"
echo $dev: tree = $PWD/kbuild-${branch}-${device}
echo $dev: ksrc = $ksrc
echo $dev: izip = $PWD/$izip
echo $dev: isrc = $PWD/installer-$rname
echo $dev: dev = ${branch}_${device}
echo $dev: pretty = ${branch}:${device}
echo $dev: branch = $branch
echo $dev: device = $device
echo $dev: log = build-${dev}.log
echo $dev: fail = .failed-${dev}
echo $dev: \
	$($CF && echo config-${dev}) \
	$($BLD && echo build-${dev}) \
	$($UP && echo savemap-${dev}) \
	$($PKG && echo package-${dev})

if [[ "$branch" ]]
then	echo gen_ksrc-$dev: $ksrc
else	echo gen_ksrc-$dev:
fi
done)

_FORCE:

${mdevs[@]}:
	@echo "Finished building \$(dev)"
	@rm -f "\$(fail)"

cleanlog-%:
	@rm -f "\$(log)"

ksrc-%: cleanlog-% _FORCE
	@echo "Checking out branch \$(branch)..."
	@[[ -d "\$(ksrc)/.git" ]] || git clone -q --shared --no-checkout "$KSRC" "\$(ksrc)" &>>\$(log)
	@cd "\$(ksrc)" && git checkout -q "\$(branch)" &>>\$(log)

init-%: cleanlog-% gen_ksrc-%
	@touch "\$(fail)"
	@mkdir -p "\$(tree)"

build-%: init-% $($CL && echo clean-%) $($CF && echo config-%)
	@echo "Making $($KO && echo modules || echo all) for \$(pretty)..."
	@rm -f "\$(tree)/.version"
	@$KB $($KO && echo modules) $($SP && echo C=1 CF=-D__CHECK_ENDIAN__) \
		&>>\$(log); rv=\$\$?; \
	 echo "\$(pretty):" \
	 "\`grep 'warning:' \$(log) | wc -l\` warnings," \
	 "\`grep 'error:' \$(log) | wc -l\` errors"; \
	 exit \$\$rv

config-%: init-% $($CL && echo clean-%)
$(if [[ "$cfg" ]]
then
echo "	@echo Making $cfg for \$(pretty)..."
echo "	@$KB -s $cfg 2>>\"\$(log)\""
echo "	@rm -f \"\$(fail)\""
else
echo "	@echo Making ${CFGFMT} for \$(pretty)..."
echo "	@$KB $dc &>>\"\$(log)\""
fi)

clean-%: init-%
	@echo "Cleaning \$(pretty)..."
	@$KB clean &>>"\$(log)"

savemap-%: $($BLD && echo build-%)
	@echo "Saving System.map for \$(pretty)..."
	@mkdir -p "\$(dir \$(izip))"
	@xz -c "\$(tree)/System.map" >"\$(izip:.zip=.map)"

strip-%: $($BLD && echo build-%)
	@if grep -q "^CONFIG_MODULES=y" "\$(tree)/.config"; \
	then \
		echo "Stripping modules for \$(pretty)..."; \
		find "\$(tree)"/*/ -name '*.ko' -a -printf 'Stripping %p...\n' -exec \
		"${CROSS_COMPILE#../}strip" --strip-unneeded \{\} \; &>>"\$(log)"; \
	fi

package-%: strip-% $($BLD && echo build-%)
	@echo "Packaging \$(pretty)..."
	@rm -rf "\$(tree)/.package"
	@cp -r "\$(isrc)" "\$(tree)/.package"
	@mkdir -p "\$(tree)/.package/system/lib/modules"
	@cp "\$(tree)/arch/arm/boot/zImage" "\$(tree)/.package/dkp-zImage"
	@find "\$(tree)"/* -name '*.ko' -exec cp \{\} "\$(tree)/.package/system/lib/modules" \;
	@mkdir -p "\$(dir \$(izip))"
	@cd "\$(tree)/.package" && zip -r "\$(izip)" * &>>"\$(log)"
	@let sbi=\$\$(stat -c %s "\$(tree)/.package/dkp-zImage"); \
	 let sd=\$\$(du -b -d0 "\$(tree)/.package" | cut -f 1)-\$\$sbi; \
	 let sz=\$\$(stat -c %s "\$(izip)"); \
	 echo "\$(notdir \$(izip)): zImage: \$\$sbi; data: \$\$sd; zip: \$\$sz"

.PHONY: init-% build-% savemap-% package-% clean-% config-% gen_ksrc-% ksrc-% cleanlog-% ${mdevs[@]}
EOF
)
then
	askyn "Review build logs for failed builds?" && \
		less $(ls ".failed-"* | \
		sed 's/\.failed-\([^ ]*\)/build-\1.log/')
	rm -f ".failed-"*
	die 1 "building failed."
fi

[[ "$cfg" ]] && echo && die 0 "restart without --config to build."

$BLD && askyn "Review build logs?" && \
		less $(sed 's/\(^\| \)\([^ ]*\)/build-\2.log /g' <<<"${devs[*]}")

! $PKG && echo && die 0 "packaging disabled by --$($KO && echo modules || echo no-package)."

# TODO: make flashing work with branched builds somehow?
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
			if [[ "$RNAME" == "dkp-aosp"* ]]
			then
				if [[ "$flashdev" == "d2"* ]]
				then	flashdev=d2
				else
					NONL=y askyn "No suitable device connected.  Retry?" || \
					break
				fi
			else
				cdn "$flashdev" && [[ "${devs[*]}" == *"$device"* ]] || \
					NONL=y askyn "No suitable device connected.  Retry?" || \
					break
				flashdev="$device"
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
			then	recdir="/sdcard"
			else	recdir="/storage/sdcard1"
			fi

			gbt "$flashdev"
			adbsh "mkdir -p '$flashdir/massbuild/'"
			echo "Pushing $izip..."
			adb -d push "$izip" "$flashdir/massbuild/$(basename "$izip")"
			adbsh "[ -f '$flashdir/massbuild/$(basename "$izip")' ]" >/dev/null
			if ! $FLASH_NOREBOOT
			then
				echo "Generating OpenRecoveryScript..."
				inst="(echo mount $recdir; echo install $recdir/massbuild/$(basename "$izip"); echo unmount $recdir) >/cache/recovery/openrecoveryscript"
				(adbsh "su -c '$inst'" || adbsh "$inst") >/dev/null
				echo "Rebooting to recovery..."
				adb -d reboot recovery
			fi
		fi
	else	echo
	fi
fi

if $UP
then
	if askyn "Upload builds?"
	then
		upparam=()
		for dev in "${devs[@]}"
		do
			gbt "$dev"
			eval rfn=\""$UPFMT"\"
			eval rp=\""$UPDIR"\"
			upparam=("${upparam[@]}" "$izip" "$rp" "$rfn")
		done
		. upload/upload.sh
	fi
fi
