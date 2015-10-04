# solidfiles uploader.  plowshare configuration is done via plowshare.conf.
# Directories should be made in advance, since plowshare doesn't understand
# solidfiles' folder hierarchy.
# TODO: Add --private for experimental builds?

upload_solidfiles() {
	local param=()
	while [[ "$1" ]]
	do
		local f="$1"
		# solidfiles only supports leaf directory names
		local p="${2##*/}"
		local n="$3"
		param=("${param[@]}" "--folder=$p" "$f:$n")
		shift 3
	done
	parallel -n2 -j2 plowup -v1 solidfiles ::: "${param[@]}"
}
