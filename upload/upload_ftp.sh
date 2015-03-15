# FTP uploader.  Authentication uses netrc, servers are configured with
# FTPHOST=(ftp.example.net [...]).

upload_ftp() {
	local param=()
	while [[ "$1" ]]
	do
		for server in "${FTPHOST[@]}"
		do
			param=("${param[@]}" -T "$1" "ftp://$server/$2/$3")
		done
		shift 3
	done
	curl -n --ftp-create-dirs "${param[@]}"
}
