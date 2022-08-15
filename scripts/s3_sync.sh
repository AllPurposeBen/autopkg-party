#!/bin/bash

## Sync the Repo to or from S3

# shellcheck disable=SC2154,SC2013,SC2164,SC1091

# Find our repo root
scriptPath="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )" # Path to this script
repoPath=${scriptPath%/*} # The root of this autopkg config repo

# Read global vars
if [[ -r "$repoPath/global_vars.txt" ]]; then
	# Source the global vars file
	. "$repoPath/global_vars.txt"
else
	echo "FATAL: Can not read global vars file. Exiting."
	exit 100
fi

## Vars
syncDirection="$1"
s3URL="$S3_REPO_URL"
munkiRepoPath="$MUNKI_REPO_PATH"
e=0 # default exit

# usage text
usage () {
	cat <<- EOU
	Usage: $(basename "$0") up|down (--dryrun)
	
	Main argument is the direction of sync, up to or down from S3.
	  Optional: --dryrun runs the sync in dryrun mode, no files are moved.
	
	EOU
	exit 101
}

# parse args and do stuff
case "$syncDirection" in
	'up')
		if [[ "$2" == '--dryrun' ]]; then
			echo "Dry run syncing up to S3."
			aws s3 sync "$munkiRepoPath" "$s3URL" \
			--no-progress \
			--delete \
			--size-only \
			--dryrun
		else
			echo "Syncing up to S3."
			aws s3 sync "$munkiRepoPath" "$s3URL" \
			--no-progress \
			--delete \
			--size-only
			e=$?
		fi
		;;
	'down')
		if [[ "$2" == '--dryrun' ]]; then
			echo "Dry run syncing down from S3."
			aws s3 sync "$s3URL" "$munkiRepoPath" \
			--no-progress \
			--delete \
			--size-only \
			--dryrun
		else
			echo "Syncing down from S3."
			aws s3 sync "$s3URL" "$munkiRepoPath" \
			--no-progress \
			--delete \
			--size-only
			e=$?
		fi
		;;
	*)
		usage
		;;
esac

# exit correctly for what happened
exit "$e"
