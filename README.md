# autopkg-party

This repo contains tools used for managing autopkg recipes, running them on schedule and reporting activity to slack.

The main script, `autopkg_party.sh` has a number of functions:

1. Run a specified list of overrides
2. Run a specific override by name
3. Sync a munki repo up/down from an S3 bucket
4. Setup autopkg configuration
5. Clone a list of autopkg repos

It is self contained and does have a usage/help dialog:
```
	Usage: autopkg_party.sh --flag --flag arg
	
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
  ```
  
  Reference the wiki on this repo for setup steps and more details on the other tools here.
