#!/bin/bash

## This tool runs autopkg setup, runs the recipe list and reports on what it did
#
# "It's a party, an autopkg paaarty!"

# shellcheck disable=SC2154,SC2181,SC2164,SC1091,SC2001,SC2046

# Enable pipefail
set -o pipefail

### Vars #################################################################################

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

# Base vars
startDate=$(date '+%Y-%m-%d_%H%M')
logDir="$repoPath/logs"
logPath="$logDir/autopkg_$startDate.txt"
slacker="$repoPath/scripts/slacker.sh"
uglyJSON="$repoPath/scripts/ugly_json.py"
# read from global vars
repoList="$AP_REPO_LIST_PATH"
recipeListPath="$AP_RECIPE_LIST_PATH"
overrideFolderPath="$AP_OVERRRIDE_PATH"
logsToKeep="$LOG_FILES_TO_KEEP"
autopkgSlackPingURL="$SLACK_WEBHOOK_URL"
munkiRepoPath="$MUNKI_REPO_PATH"
# These paths are ephemeral
tmpFilesPath="$repoPath/tmp"
validRecipesListPath="$tmpFilesPath/valid_receipe_list.txt"
recipeIssueListPath="$tmpFilesPath/validation_issue_list.txt"
runErrorListPath="$tmpFilesPath/run_error_list.txt"
importsListPath="$tmpFilesPath/imports_list.txt"
# Set some counters
munkiUpdated=0
runErrors=0
recipeIssuesCount=0
cloneErrorCount=0
# run options
noSlack=false
consoleLogOnly=false
skipRepoClone=false


### Functions ############################################################################

# Function for general logging
logging () {
	local logMessage="$1"
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	if "$consoleLogOnly"; then
		echo "$timestamp :: $logMessage"
	else
		echo "$timestamp :: $logMessage" | tee -a "$logPath"
	fi
}

# Parse the receipt for what happened
runResultStatus () {
	local plist="$1"
	# Reset the name and version vars between calls
	name=''
	version=''

	# PlistBuddy help function
	pb () {
		local searchPath="$1"
		/usr/libexec/PlistBuddy -c \
		"$searchPath" \
		"$plist" 2>/dev/null
	}

	# Find the MunkiImporter dict in the base array, I don't trust it always to be the last there shouldn't be more than 30 processors
	i=1
	while [ $i -le 30 ]; do
		processorName=$(pb "print :$i:Processor")
		if [[ -z "$processorName" ]]; then
			return 2
		elif [[ "$processorName" == 'MunkiImporter' ]]; then
			index=$i
			break
		else
			((i++))
		fi
	done

	## Check for an import
	name=$(pb "print :$index:Input:pkginfo:display_name")
	munkiChangeCheck=$(pb "print :$index:Output:munki_repo_changed")
	if [[ "$munkiChangeCheck" != 'true' ]]; then
		# No import
		return 1
	else
		# We imported something...what?
		version=$(pb "print :$index:Output:munki_importer_summary_result:data:version")
		((munkiUpdated++))
		return 0
	fi
}

# Function to encapsulate sending slack pings and logging outcome
slackIt () {
	# Don't ping on console only output
	if "$noSlack" || "$consoleLogOnly"; then
		logging "SLACK: Slack ping skipped."
		return 0
	fi
	
	local message="$1"
	if ! "$slacker" "$autopkgSlackPingURL" "$message" > /dev/null; then
		logging "ERROR: Slack ping failed."
		return 1
	else
		logging "SLACK: Slack ping sent successfully."
		return 0
	fi
}

# Validate the munki repo
validateMunkiRepo () {
	logging "SETUP: Validating munki repo."
	if [[ ! -d "$munkiRepoPath" ]] || ! makecatalogs "$munkiRepoPath" > /dev/null; then
		logging "ERROR: Munki repo validation failed. Repo may not be present."
		# Slack the issue
		message="Autopkg run failed. Munki repo could not be validated."
		slackIt "$message"
		exit 2
	fi
}

# Setup autopkg config
setupAutopkg () {
	logging "SETUP: Writing autopkg config."
	defaults write com.github.autopkg CACHE_DIR "$repoPath"/Cache/
	defaults write com.github.autopkg RECIPE_OVERRIDE_DIRS "$repoPath"/Overrides/
	defaults write com.github.autopkg RECIPE_REPO_DIR "$repoPath"/repos/
	defaults write com.github.autopkg FAIL_RECIPES_WITHOUT_TRUST_INFO -bool YES
	defaults write com.github.autopkg MUNKI_REPO "$munkiRepoPath"
	return 0
}

# Add autopkg repos
cloneAndUpdateRepos () {
	if "$skipRepoClone"; then
		# Skip the clone/update of repos, usually done to speed up troubleshooting
		logging "SETUP: Recipe repo clone and update skipped per run flag."
		return 0
	fi

	# Clone the list
	logging "SETUP: Cloning receipe repos"
	while IFS= read -r thisRepo; do
		repoShortName=$(echo "$thisRepo" | sed -E 's_^https?://__')
		logging "CLONE: Cloning $repoShortName"  # Remove the https:// for the sake of readability
		if ! autopkg repo-add "$thisRepo" >/dev/null && autopkg repo-update "$thisRepo" >/dev/null; then
			((cloneErrorCount++))
			logging "ERROR: Problem cloning $repoShortName"
		fi
	done < "$repoList"

	# If we have failures, abort.
	if [ "$cloneErrorCount" -ne 0 ]; then
		# send a slack ping that there was a problem
		# Fill in the json payload
		read -r -d '' jsonPaylod <<- EOJ
		{
			"blocks": [
				{
					"type": "section",
					"text": {
						"type": "mrkdwn",
						"text": "😿 Issues cloing $cloneErrorCount recipe repo(s).\n\nAborting autopkg run."
					}
				},
				{
					"type": "divider"
				}
			]
		}
		EOJ

		# flatten the json payload into a single line
		message=$(echo "$jsonPaylod" | "$uglyJSON")
	
		# send ping
		slackIt "$message"
		logging "FAIL: Issues cloing $cloneErrorCount recipe repo(s), arborting setup and run."
		# fail out, we don't want the job to go on
		exit 11
	fi
}

# Verify override is saf to use
verifyOverride () {
	logging "VALID: Checking validaity for recipe list."
	while IFS= read -r thisRecipe; do
		logging "VALID: Validationg $thisRecipe..."
		if ! plutil "$overrideFolderPath/$thisRecipe.recipe" >/dev/null 2>&1; then
			# Recipe has a format problem, add to validation fail list
			logging "WARN: $thisRecipe has an format issue, skipping running it."
			echo "$thisRecipe" >> "$recipeIssueListPath"
			((recipeIssuesCount++))
		elif ! autopkg verify-trust-info "$thisRecipe" >/dev/null 2>&1; then
			# Recipe has a trust problem, add to validation fail list
			logging "WARN: $thisRecipe has a trust validation issue, skipping running it."
			echo "$thisRecipe" >> "$recipeIssueListPath"
			((recipeIssuesCount++))
		else
			# It's valid, add to valid recipes
			logging "VALID: $thisRecipe is valid, adding to run list."
			echo "$thisRecipe" >> "$validRecipesListPath"
		fi
	done <<< "$receipeList"
}

# Run the recipe list
runRecipeList () {
	# sanity check
	if [[ ! -f "$validRecipesListPath" ]]; then
		logging "FAIL: No valid recipes to run."
		exit 4
	fi
	# Run the loop
	while IFS= read -r thisValidRecipe; do
		# Run autopkg recipe and get results
		logging "RUN: Running recipe: $thisValidRecipe"
		runOutput=$(autopkg run -v "$thisValidRecipe" 2>&1 | tee -a "$logPath")
		runExit=$?

		if [ $runExit -ne 0 ]; then
			logging "FAIL: $thisValidRecipe run exited non-zero."
			echo "$thisValidRecipe: Non-zero" >> "$runErrorListPath"
			# increment error count
			((runErrors++))
			continue # Exit this run
		fi

		# Find out what happened with the run
		prefix='Receipt written to '
		runReceiptPath=$(echo "$runOutput" | grep ^'Receipt written' | sed -e "s/^$prefix//")
		if [[ -f "$runReceiptPath" ]]; then
			# We found the receipt, check it.
			runResultStatus "$runReceiptPath"
			runResultExit=$?
			if [ $runResultExit -eq 0 ]; then
				# run parsing found an import, name and version variables should be filled
				logging "ADDED: $name updated to $version."
				echo "$name updated to $version" >> "$importsListPath"
			elif [ $runResultExit -eq 1 ]; then
				# Run parse was good but nothing imported.
				logging "RUN: Nothing new for $name."
			else
				# Could find the index in the receipt
				logging "ERROR: Could find index for $thisValidRecipe."
				echo "$thisValidRecipe: Couldn't parse receipt format" >> "$runErrorListPath"
				# increment error count
				((runErrors++))
				continue # Exit this run
			fi
		else
			# Failed to find the receipt.
			logging "FAIL: Couldn't find autopkg run receipt for $thisValidRecipe."
			echo "$thisValidRecipe: Can't find receipt" >> "$runErrorListPath"
			# increment error count
			((runErrors++))
			continue # Exit this run
		fi
	done < "$validRecipesListPath"
}

# compiles and sends the post run ping
postRunPing () {
	logging "SLACK: Preparing to send slack message..."

	# Gather the data from the various run output files
	importsList=$(cat "$importsListPath" 2>/dev/null) # To column: | pr -2 -t -s
	validationList=$(cat "$recipeIssueListPath" 2>/dev/null)
	errorList=$(cat "$runErrorListPath" 2>/dev/null)

	# Format the run output data for the slack message body
	if [[ -n "$importsList" ]]; then
		read -r -d '' importBlock <<- EOI
		🫡 *Imported:*
		$importsList
		EOI
	fi

	if [[ -n "$validationList" ]]; then
		read -r -d '' validationBlock <<- EOT
		🥸 *Validation Issues:*
		$validationList
		EOT
	fi

	if [[ -n "$errorList" ]]; then
		read -r -d '' errorBlock <<- EOE
		😿 *Errors:*
		$errorList
		EOE
	fi

	# Form the summary line for the message
	runResultString="🤖 Run results: $munkiUpdated imports, $runErrors errors, $recipeIssuesCount recipe issues."

	# Concatenate the message body block
	read -r -d '' prettyMessage <<- EOF
	$importBlock

	$validationBlock

	$errorBlock
	EOF

	# If we have nothing in the body block, sub in a filler text
	if [[ -z "$prettyMessage" ]]; then
		prettyMessage="No changes to report."
	fi

	# Single line markdown encode the mody text. Remove instances of multiple blank lines, convert line breaks to \n\n\ per markdown spec.
	encodedBody=$(echo "$prettyMessage" | sed '/^$/N;/^\n$/D' | awk -v ORS='\\n\\n' '1')

	# Fill in the json payload
	read -r -d '' jsonPaylod <<- EOJ
	{
		"blocks": [
			{
				"type": "header",
				"text": {
					"type": "plain_text",
					"text": "$runResultString",
					"emoji": true
				}
			},
			{
				"type": "section",
				"text": {
					"type": "mrkdwn",
					"text": "$encodedBody"
				}
			},
			{
				"type": "divider"
			}
		]
	}
	EOJ

	# flatten the json payload into a single line
	message=$(echo "$jsonPaylod" | "$uglyJSON")

	# Send the actual ping
	slackIt "$message"
}

# function to run the sync up/down command
munkiRepoSync () {
	local direction="$1"
	local message=''
	case "$direction" in
		'up')
			if [[ -n "$SYNC_MUNKI_UP_COMMAND" ]]; then
				logging "SYNC: Syncing local munki repo up to cloud."
				# run the sync command
				if ! eval "$SYNC_MUNKI_UP_COMMAND" >/dev/null 2>&1; then
					message="Munki repo sync up failed."
					logging "FAIL: $message" # Slack only on a failure
					slackIt "$message"
					return 1
				else
					message="Munki repo sync up succeded."
					logging "SUCCESS: $message"
					return 0
				fi
			fi
			;;
		'down')
			if [[ -n "$SYNC_MUNKI_DOWN_COMMAND" ]]; then
				logging "SYNC: Syncing local munki repo down from cloud."
				# run the sync command
				if ! eval "$SYNC_MUNKI_DOWN_COMMAND" >/dev/null 2>&1; then
					message="Munki repo sync down failed."
					logging "FAIL: $message" # Slack only on a failure
					slackIt "$message"
					return 1
				else
					message="Munki repo sync down succeded."
					logging "SUCCESS: $message"
					return 0
				fi
			fi
			;;
	esac
}

# log pruning
logPrune () {
	local toDeleteList=''
	toDeleteList=$(find "$logDir" -name "autopkg_*" | sort -r | tail -n +$((++logsToKeep)))
	for thisOneToToss in $toDeleteList; do
		logging "CLEANUP: Deleting old log file $(basename "$thisOneToToss")."
		rm "$thisOneToToss"
	done
}

# Makecatalogs and sync the repo
makecatalogsAndSync () {
	if [ "$munkiUpdated" -gt 0 ]; then
		## Makecatalogs or it didn't happen...unless it didn't happen
		logging "RUN: Repo changed, rebuilding catalogs."
		if makecatalogs "$munkiRepoPath" > /dev/null 2>&1; then
			# Attempt to sync the repo back up to the cloud, if configured
			munkiRepoSync up
		else
			# The makecatalogs failed, don't sync a broken munki repo
			logging "ERROR: makecatalogs failed."
			# Slack the issue
			slackIt "Autopkg run failed. Post-run catalog rebuild failed."
		fi
	else
		# No change to the repo.
		logging "POST: No changes to the repo made."
	fi
}

# Prepare recipe list
prepRecipeList () {
	if [[ -n "$manualRecipe" ]]; then
		# manual list
		logging "RUN: Manual recipe list specified."
		receipeList="$manualRecipe"
	else
		# Check the recipe list file
		if [[ -r "$recipeListPath" ]]; then
			logging "RUN: Reading recipe list file."
			receipeList=$(grep -v ^'#' "$recipeListPath")
		else
			logging "ERROR: Could not find recipe list."
			exit 4
		fi
	fi
}

## Substantiate log
substantiateLog () {
	if "$consoleLogOnly"; then
		logging "START: Autopkg run start. Console logging only"
	else
		mkdir -p "$repoPath/logs" && touch "$logPath"
		logging "START: Autopkg run start."
	fi

	# Clean any tmp files from last run
	rm -rf "$tmpFilesPath" 2>/dev/null
	mkdir -p "$tmpFilesPath"
}

# Fetch and pull the autopkg git repo
gitFetchPull () {
	logging "GIT: Fetching and pulling our autopkg repo."
	git -C "$repoPath" fetch --all >/dev/null 2>&1 && \
	git -C "$repoPath" pull >/dev/null 2>&1
	return $?
}

# Find the git repo url for a given recipe and outputs it, exits
openRepoURLinBrowser () {
	local overrideName="$1"
	local parentRecipePath=''
	local gitRepoURL=''
	parentRecipePath=$(autopkg audit "$overrideName" | grep 'Parent recipe(s)' | awk -F ': ' '{print $NF}')
	gitRepoURL=$(git -C $(dirname "$parentRecipePath") remote show origin | grep 'Fetch URL:' | awk -F ': ' '{print $NF}')
	echo "Repo URL: $(dirname "$gitRepoURL")/$(basename "$gitRepoURL" .git)"
	exit 0
}

# Output usage text and exit
usage () {
	cat <<- EOU
	Usage: $(basename "$0") --flag --flag arg
	
	Main flags:
	 --all                       Full run using the recipe list, including slack pings.
	 --recipe recipe_name        Run a single recipe by name, eg. Firefox.munki. Slack pings skpped.
	 --manual-sync-down          If configured, syncs the munki repo down from the CDN and exits.
	 --manual-sync-up            If configured, syncs the munki repo up to the CDN and exits.
	 --help                      Print this message.
	
	Helpful troubleshooting flags:
	 --no-slack                  Skip sending Slack pings for this run.
	 --skip-repo-clone           Skip the step that clones the autopkg repos specfied in the repo_list file.
	 --clone-only                Clone the  autopkg repos specfied in the repo_list file and exit. Helpful when working with the autopkg command directly.
	 --setup-only                Setup the autopkg preferences and exit. Helpful when working with the autopkg command directly on a host that isn't normally used for autopkg.
	 --skip-sync-down            Skip the sync down from the CDN on this run.
	 --skip-sync-up              Skip the sync up up the CDN on this run.
	 --recipe-url recipe_name    Get the URL for the git repo of a given override's parent recipe. Helpful when checking for a change.
	
	Mulitple flags can be specified.
	
	EOU
	exit 101
}


### Main #################################################################################

## Parse passed options
if [[ -z "$1" ]]; then usage; fi
while [[ "$#" -gt 0 ]]; do
	case "$1" in
		'--all') echo 'scream' >/dev/null ;; # Kind of a placeholder, case requires a clause to do something
		'--no-slack') noSlack=true ;; # suppress all slack pings
		'--recipe') manualRecipe="$2"; shift; noSlack=true ;; # run a single recipe instead of the list
		'--skip-repo-clone') skipRepoClone=true ;; # saves a few seconds when troubleshooting
		'--clone-only') # Clone the repos and exit, handy ahead of troubleshooting with autopkg directly
			consoleLogOnly=true # implies no slack as well
			setupAutopkg
			cloneAndUpdateRepos
			logging "END: Ran setup and clone only, exiting."
			exit 0
			;;
		'--setup-only') # Only run the setup steps, for local troubleshooting 
			consoleLogOnly=true # implies no slack as well
			setupAutopkg
			logging "END: Ran setup only, exiting."
			exit 0
			;;
		'--skip-sync-down') SYNC_MUNKI_DOWN_COMMAND='' ;; # Nerfs the config, preventing sync
		'--skip-sync-up') SYNC_MUNKI_UP_COMMAND='' ;; # Nerfs the config, preventing sync
		'--manual-sync-down') consoleLogOnly=true; munkiRepoSync down; exit $? ;; # manual sync
		'--manual-sync-up') consoleLogOnly=true; munkiRepoSync up; exit $? ;; # manual sync
		'--recipe-url') openRepoURLinBrowser "$2" ;; # Get an override parents git repo URL
		'-h'|'--help') usage ;;
		*) echo "Unknown parameter passed: $1"; usage ;;
	esac
	shift
done

## Disable slack if we don't have the URL for it
if [[ -z "$autopkgSlackPingURL" ]]; then
	noSlack=true
fi

## Specify AWS creds file. 

## Substantiate log
substantiateLog

## Git pull our repo so we have the most current overrides and scripts. Don't bail on a fail.
if ! gitFetchPull; then
	logging "WARN: Couldn't pull our autopkg repo successfully."
	slackIt "Couldn't pull our autopkg repo successfully. Continuing run."
fi

## Sync down the munki repo from the cloud, if configured
if ! munkiRepoSync down; then
	# Down sync failed
	logging "FAIL: Repo sync down failed, aborting run."
	exit 6
fi

## Confirm the munki repo is mounted/present with a makecatalogs.
validateMunkiRepo

## configure autopkg
setupAutopkg

## repo cloning
cloneAndUpdateRepos

## Do we have a manual recipe list to run or should we read the file?
prepRecipeList

## Check override for format and trust issues and generate a valid recipe list
verifyOverride

## Loop the valid recipe list
runRecipeList

### Post autopkg Run

## Process Slack pinging for run
postRunPing

## If a change was made to the repo, makecatalogs and sync the repo up
makecatalogsAndSync

## Clean up old logs
logPrune

## End of job
logging "END: Run finished. $munkiUpdated imports, $runErrors errors, $recipeIssuesCount recipe issues."

exit 0
