# MediaFire uploader.  plowshare configuration is done via plowshare.conf.
# Directories must be made in advance.
# TODO: Add --private for experimental builds?

upload_mediafire() {
	local param=()
	while [[ "$1" ]]
	do
		local f="$1"
		# MediaFire only supports leaf directory names
		local p="${2##*/}"
		local n="$3"
		param=("${param[@]}" "--folder=$p" "$f:$n")
		shift 3
	done
	parallel -n2 -j2 plowup -v1 mediafire ::: "${param[@]}"
}
