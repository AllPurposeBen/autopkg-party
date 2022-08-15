#!/bin/bash

# shellcheck disable=SC2162,SC2001

pb='/usr/libexec/PlistBuddy'
checkTheseKeysListPath="$(dirname "$0")/checkTheseKeys.txt"
defaultKeysToCheck=\
"pkginfo:unattended_uninstall
MUNKI_REPO_SUBDIR
pkginfo:developer
pkginfo:description
pkginfo:category
pkginfo:notes
"

# usage text
usage () {
	cat <<- EOU
	Usage: $(basename "$0") <flag> (arg)
	
	Available flags:
	--overrride <path to override>      Will check the specified override for the configured important keys interactively.
	--make-override <name of recipe>    Will first create a new override for the specified recipe, then check for the configured important keys.
	
	EOU
	exit 101
}

## Parse passed options
if [[ -z "$1" ]]; then usage; fi
while [[ "$#" -gt 0 ]]; do
	case "$1" in
		'--override') overridePath="$2"; shift ;;
		'--make-override') makeThisOverrideName="$2" ;shift ;;
		*) echo "Unknown parameter passed: $1"; usage ;;
	esac
	shift
done

# Make an override if specified
if [[ -n "$makeThisOverrideName" ]]; then
	# call autopkg to make the override for the named recipe
	makeOverrideOutput=$(autopkg make-override "$makeThisOverrideName")
	prefix='Override file saved to '
	overridePath=$(echo "$makeOverrideOutput" | sed -e "s/^$prefix//")
fi

# Sanity check
if [[ ! -f "$overridePath" ]]; then
	echo "Override not found at path: $overridePath"
	exit 2
fi

## Functions

# Add or set a key
setaddKey () {
	local keyPath="$1"
	local value="$2"
	
	# Sanity check
	if [[ -z "$keyPath" ]] || [[ -z "$value" ]]; then
		echo "ERROR: Need function args"
		return 2
	fi
	
	# Form the correct strings for an add vs set. We don't care about ints, treat them as strings.
	case "$value" in
		'true'|'True'|'TRUE')
			setValue="bool true" ;;
		'false'|'False'|'FALSE')
			setValue="bool false" ;;
		*) # Anything else, assume string
			setValue="string '$value'" ;; #Confirm quoting
	esac
	
	# Try to set value
	if "$pb" -c "set :Input:$keyPath $value" "$overridePath" 2>/dev/null; then
		# we could set
		echo "Key set successfully."
	elif "$pb" -c "add :Input:$keyPath $setValue" "$overridePath" 2>/dev/null; then
		# could add 
		echo "Key added successfully."
	else
		# Could set
		echo "ERROR: Key couldn't be written"
		return 1
	fi
}

# print a key
checkKey () {
	local keyPath="$1"
	
	# Sanity check
	if [[ -z "$keyPath" ]]; then
		echo "ERROR: Need function args"
		return 2
	fi
	
	checkedValue=$("$pb" -c "print :Input:$keyPath" "$overridePath" 2>/dev/null)
	
	if [[ -n "$checkedValue" ]]; then
		echo "$checkedValue"
		return 0
	else
		return 1
	fi
}

keyMaster () {
	local keyPath="$1"
	local keyName=''
	keyName=$(echo "$keyPath" | awk -F':' '{print $NF}')
	local value=''
	
	# Check for they key's value
	beforeCheck=$(checkKey "$keyPath")
	if [[ -z "$beforeCheck" ]]; then
		echo "Key $keyName is unset."
		# Ask to set
		echo "Enter value for $keyName. Return to leave unset."
		read -p 'Enter new value: ' returnedValue
	else
		echo "Key $keyName currently: $beforeCheck"
		# Ask to change
		echo "Enter new value for $keyName. Return to keep current value"
		read -p 'Enter new value: ' returnedValue
	fi
	
	# Set the value if we got one
	if [[ -n "$returnedValue" ]]; then
		# write the value to the key
		setaddKey "$keyPath" "$returnedValue"
	fi
	# add a space for readability
	echo ''
}

## Main

# check for a list of keys to check
if [[ -f "$checkTheseKeysListPath" ]]; then
	# read the list
	keyCheckList=$(grep "^[^#;]" "$checkTheseKeysListPath" | grep .)
	echo "Using external key list."
else
	# read the defaults
	keyCheckList=$(echo "$defaultKeysToCheck" | grep .)
fi

# Loop the list
for thisKey in $keyCheckList; do
	keyMaster "$thisKey"
done

# exit clean
exit 0

