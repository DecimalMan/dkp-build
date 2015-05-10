# each upload script is expected to provide a function "upload_<name>", which
# accepts the following usage:
# upload_<name> local_file remote_path remote_file

for up in "${UPLOAD[@]}"
do
	. "upload/upload_$up.sh"
	if declare -fp "upload_$up" &>/dev/null
	then
		"upload_$up" "${upparam[@]}" || echo "$up: uploads failed!" >&2
	else
		echo "$up didn't provide an upload function!" >&2
	fi
done
