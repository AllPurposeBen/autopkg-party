#!/bin/bash

### This script processes slack pings

slackWebhookURL="$1"
message="$2"

usage () {
	# only output the usage text outside of CI so we don't muddy up logs
	cat <<- EOU
	This script sends a slack message via a webhook app.

	Usage: $(basename "$0") <webhookURL> <message>
	webhookURL    The url to send the webhook payload to, not including https://.
	message       The message to send. This can either be a single line of plain
				   text or a single line json string. No URL escaping is done in
				   this script.
	EOU
	exit 1
}

# Sanity checks

# Make sure we have all required arguments
if [[ -z "$message" ]]; then
	echo "ERROR: Missing Required Args."
	usage
fi

# make sure the message is a single line
if [[ $(echo "$message" | wc -l | xargs) != '1' ]]; then
	echo "ERROR: Message string needs to be a single line, either of plain text or a json string."
	usage
fi

# determine if we have a plain text or json string message
if [[ "$message" == '{'*'}' ]]; then
	# json string message
	dataString="$message"
else
	#plain txt string message, wrap in json object
	dataString="{\"text\":\"$message\"}"
fi


## Run the curl to send the message
curlResponseCode=$(curl \
-X POST \
-Ss \
-o /dev/null \
-w "%{http_code}" \
-H 'Content-type: application/json' \
--data "$dataString" \
https://"$slackWebhookURL")

# Handle success check and exits
if [[ "$curlResponseCode" == '200' ]]; then
	echo "SUCCESS: Slack ping successful."
	exit 0
else
	echo "FAIL: Slack ping failed, returned $curlResponseCode."
	exit 1
fi
