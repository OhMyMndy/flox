# -*- mode: sh; sh-shell: bash; -*-
## General commands

_general_commands+=("channels")
_usage["channels"]="list channel subscriptions"
_usage_options["channels"]="[--json]"
function floxChannels() {
	trace "$@"
	local -i displayJSON=0
	while [[ "$#" -gt 0 ]]; do
		# 'flox list' args.
		case "$1" in
		--json) # takes zero args
			displayJSON=1
			shift
			;;
		-*)
			usage | error "unknown option '$1'"
			;;
		*)
			usage | error "extra argument '$1'"
			;;
		esac
	done
	if [[ "$displayJSON" -gt 0 ]]; then
		getChannelsJSON
	else
		local -a rows;
		mapfile -t rows < <( getChannelsJSON | $_jq -r '
		  to_entries | sort_by(.key) | map(
			"|\(.key)|\(.value.type)|\(.value.url)|"
		  )[]'
		)
		${invoke_gum?} format --type="markdown"                              \
		               -- "|Channel|Type|URL|" "|---|---|---|" "${rows[@]}"
	fi
}

_general_commands+=("subscribe")
_usage["subscribe"]="subscribe to channel URL"
_usage_options["subscribe"]="[<name> [<url>]]"
function floxSubscribe() {
	trace "$@"
	local flakeName
	local flakeUrl
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		-*)
			usage | error "unknown option '$1'"
			;;
		*)
			if [ -n "$flakeName" ]; then
				if [ -n "$flakeUrl" ]; then
					usage | error "extra argument '$1'"
				else
					flakeUrl="$1"; shift
				fi
			else
				flakeName="$1"; shift
			fi
			;;
		esac
	done
	if [[ -z "$flakeName" ]]; then
		read -er -p "Enter channel name to be added: " flakeName
	fi
	if [[ ${validChannels["$flakeName"]+_} ]]; then
		error "subscription already exists for channel '$flakeName'" < /dev/null
	fi
	if ! [[ "$flakeName" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
		error "invalid channel name '$flakeName', valid regexp: ^[a-zA-Z][a-zA-Z0-9_-]*$" < /dev/null
	fi
	if [[ -z "$flakeUrl" ]]; then
		local prompt="Enter URL for '$flakeName' channel: "
		local value
		value="$(
			git_base_urlToFlakeURL "${git_base_url?}" "$flakeName/floxpkgs"  \
			                       master
		)"
		read -er -p "$prompt" -i "$value" flakeUrl
	fi
	if ! validateFlakeURL "$flakeUrl"; then
		error "could not verify channel URL: \"$flakeUrl\"" < /dev/null
	fi
	floxUserMetaRegistry set channels "$flakeName" "$flakeUrl"
	warn "subscribed channel '$flakeName'"
}

_general_commands+=("unsubscribe")
_usage["unsubscribe"]="unsubscribe from channel"
_usage_options["unsubscribe"]="[<name>]"
function floxUnsubscribe() {
	trace "$@"
	local flakeName
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		-*)
			usage | error "unknown option '$1'"
			;;
		*)
			if [[ -n "$flakeName" ]]; then
				usage | error "extra argument '$1'"
			else
				flakeName="$1"; shift
			fi
			;;
		esac
	done
	if [[ -n "$flakeName" ]]; then
		if ! [[ ${validChannels["$flakeName"]+_} ]]; then
			error "invalid channel '$flakeName'" < /dev/null
		fi
		if [[ "${validChannels["$flakeName"]}" == "flox" ]]; then
			error "cannot unsubscribe from flox channel '$flakeName'" < /dev/null
		fi
	else
		local -A userChannels
		for i in "${!validChannels[@]}"; do
			if [[ ${validChannels["$i"]} = "user" ]]; then
				userChannels["$i"]=1
			fi
		done
		local -a sortedUserChannels;
		read -ra sortedUserChannels < <(
			echo "${!userChannels[@]}" | $_xargs -n 1 | $_sort | $_xargs
		)
		if [[ "${#sortedUserChannels[@]}" -gt 0 ]]; then
			warn "Select channel to unsubscribe: "
			flakeName="$($_gum choose "${sortedUserChannels[@]}")"
		else
			error "no channel to unsubscribe" < /dev/null
		fi
	fi
	if floxUserMetaRegistry delete channels "$flakeName"; then
		warn "unsubscribed from channel '$flakeName'"
	else
		error "unsubscribe channel failed '$flakeName'" < /dev/null
	fi
}

_general_commands+=("search")
_usage["search"]="search packages in subscribed channels"
_usage_options["search"]="[(-c,--channel) <channel>]... [(-l|--long)|--json] "
_usage_options["search"]+="[--refresh] [<regex>[@<semver-range>]]"
function floxSearch() {
	trace "$@"
	packageregexp=
	declare -i jsonOutput=0
	declare showDetail="false"
	declare refreshArg
	declare -a channels=()
	semver=
	semverRange='*'
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		-c | --channel)
			shift
			channels+=("$1")
			shift
			;;
		# TODO: Will implement when catalog has `has{Bin,Man}'.
		#show-libs)
		#	shift
		#	;;
		--refresh)
			refreshArg="--refresh"
			shift
			;;
		--json)
			jsonOutput=1
			shift
			;;
		# TODO: Deprecate `-v,--verbose'
		-v|--verbose)
			_msg="the flag 'flox search -v,--verbose' is deprecated."
			_msg="$_msg Please use 'flox search -l,--long' instead."
			warn "WARNING: $_msg"
			showDetail="true"
			shift
			;;
		-l|--long)
			showDetail="true"
			shift
			;;
		*@*)  # Semver
			semver=:
			semverRange="${1##*@}"
			_pkg="${1%@*}"
			shift
			set -- "$_pkg" "$@"
			unset _pkg
		    ;;
		*)
			if [[ "${subcommand:-}" = "packages" ]]; then
				# Expecting a channel name (and optionally a jobset).
				packageregexp="^$1\."
			elif [[ -z "${packageregexp:-}" ]]; then
				# Expecting a package name (or part of a package name)
				packageregexp="$1"
				# In the event that someone has passed a space or "|"-separated
				# search term (thank you Eelco :-\), turn that into an equivalent
				# regexp.
				if [[ "${packageregexp:-}" =~ [:space:] ]]; then
					packageregexp="(${packageregexp// /|})"
				fi
			else
				usage | error "multiple search terms provided"
			fi
			shift
			;;
		esac
	done

	: "${packageregexp:=.}"
	if [[ "$#" -gt 0 ]]; then
		usage | error "extra arguments \"$*\""
	fi
	: "${GREP_COLORS:=mt=1;32}"
	export GREP_COLORS

	# TODO: handle lines which contain `|' in their descriptions
	if [[ "$showDetail" = true ]]; then
		_m_col="cat -"
	else
		_m_col="$_column -s '|' -t"
	fi

	runSearch() {
	  if [[ "$jsonOutput" -gt 0 ]]; then
		  searchChannels "$packageregexp" "${channels[@]}" $refreshArg | \
			$_jq -L "${_lib?}" -r 'include "catalog-search";
			  to_entries|map( select( .key|endswith( ".latest" )|not )|.value )
			';
	  else
	  	# Use grep to highlight text matches, but also include all the lines
	  	# around the matches by using the `-C` context flag with a big number.
	  	# It's also unfortunate that the Linux version of `column` which
	  	# supports the `--keep-empty-lines` option is not available on Darwin,
	  	# so we instead embed a line with "---" between groupings and then use
	  	# `sed` below to replace it with a blank line.
		#shellcheck disable=SC2016
	  	searchChannels "$packageregexp" "${channels[@]}" $refreshArg |   \
	  		$_jq -L "${_lib?}" -r --argjson showDetail "$showDetail" '
			  include "catalog-search";
              to_entries|map( catalogPkgToSearchEntry )|
              searchEntriesToPretty( $showDetail )
			'|$_m_col|$_sed 's/^---[[:space:]]*$//'|     \
	  		$_grep -C 1000000 --ignore-case --color -E "$packageregexp"
	  fi
	}

	if [[ -z "${semver:-}" ]]; then
		# You're done!
		runSearch
	elif [[ "$semverRange" = '*' ]]; then
		# '*' matches all versions, so there's no reason to perform filtering
		showDetail='true'
		runSearch
	else
		# Semver Search requires additional processing.
		local matchesJSON versionsList keepVersionsJSON keepsJSON;
		matchesJSON="$(mkTempFile)"
		versionsList="$(mkTempFile)"
		keepVersionsJSON="$(mkTempFile)"
		keepsJSON="$(mkTempFile)"
		# Run search and stash results for post-processing.
		searchChannels "$packageregexp" "${channels[@]}" $refreshArg | \
		  $_jq -L "${_lib?}" -r 'include "catalog-search";
		    to_entries|map( catalogPkgToSearchEntry )' > "$matchesJSON";

		# Extract the version numbers
		$_jq -r 'map( .version )[]' "$matchesJSON"|$_sort -u > "$versionsList"

		# Get a list of satisfactory versions, and stash them to a file.
		#shellcheck disable=SC2046
		$_semver --coerce --loose --range "$semverRange" $(< "$versionsList")  \
			|$_jq -Rsc 'split( "\n" )|map( select( . != "" ) )'                \
			> "$keepVersionsJSON"

		# Filter original results to those with satisfactory versions.
		#shellcheck disable=SC2016
		$_jq -c --slurpfile keeps "$keepVersionsJSON" '
		  map( .version as $v|select( $keeps[]|any(
		    ( . == $v ) or ( . == ( $v + ".0" ) ) or ( . == ( $v + ".0.0" ) )
		  ) ) )' "$matchesJSON" > "$keepsJSON"

		# Post-process results to match `flox search -v'
		if [[ "$jsonOutput" -le 0 ]]; then
			#shellcheck disable=SC2016
			$_jq -L "${_lib?}" -r 'include "catalog-search";
			  searchEntriesToPretty( true )
			' "$keepsJSON"|$_m_col|$_sed 's/^---[[:space:]]*$//'            \
	  		  |$_grep -C 1000000 --ignore-case --color -E "$packageregexp"
		else
			$_jq . "$keepsJSON"
		fi
	fi
}

_general_commands+=("config")
_usage["config"]="configure user parameters"
_usage_options["config"]="[--list] [--reset [--confirm]] \\
                [--set <arg> <value>] [--setNumber <arg> <value>] \\
                [--delete <arg>]"
function floxConfig() {
	trace "$@"
	local -i configListMode=0
	local -i configResetMode=0
	local -i configRegistryMode=0
	local configRegistryCmd
	local -a configRegistryArgs
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--list|-l)
			configListMode=1; shift
			;;
		--set|-s)
			configRegistryMode=1; shift
			configRegistryCmd='set'
			configRegistryArgs+=("$1"); shift
			configRegistryArgs+=("$1"); shift
			;;
		--setNumber)
			configRegistryMode=1; shift
			configRegistryCmd=setNumber
			configRegistryArgs+=("$1"); shift
			configRegistryArgs+=("$1"); shift
			;;
		--delete)
			configRegistryMode=1; shift
			configRegistryCmd=delete
			configRegistryArgs+=("$1"); shift
			;;
		--reset|-r)
			configResetMode=1; shift
			;;
		--confirm|-c)
			getPromptSetConfirm=1; shift
			export getPromptSetConfirm
			;;
		*)
			usage | error "extra argument '$1'"
			;;
		esac
	done
	if [[ "$configListMode" -eq 0 ]]; then
		if [[ "$configResetMode" -eq 1 ]]; then
			# Forcibly wipe out contents of floxUserMeta.json and start over.
			$_jq -n -r -S '{channels:{},version:1}' | \
				initFloxUserMetaJSON                                     \
				  "${userFloxMetaCloneDir?}" "reset: floxUserMeta.json"
			bootstrap
		elif [[ "$configRegistryMode" -eq 1 ]]; then
			floxUserMetaRegistry $configRegistryCmd "${configRegistryArgs[@]}"
		fi
	fi
	# Finish by listing values.
	floxUserMetaRegistry dump | $_jq -r '
	  del(.version) | to_entries | map("\(.key) = \"\(.value)\"") | .[]'
}

_general_commands+=("gh")
_usage["gh"]="access to the gh CLI"

_general_commands+=("(envs|environments)")
_usage["(envs|environments)"]="list all available environments"
function floxEnvironments() {
	trace "$@"
	local system="$1"; shift
	if [[ "$#" -ne 0 ]]; then
		usage | error "the 'flox environments' command takes no arguments"
	fi
	# For each environmentMetaDir, list environment
	for i in "$FLOX_META/"*; do
		if [[ -d "$i" ]] && { ! [[ -L "$i" ]]; }; then
			listEnvironments "$system" "$i"
		fi
	done
}

_general_commands+=("auth")
_usage["auth"]="floxHub authentication commands"
_usage_options["auth"]="(login|logout|status)"
function floxAuth() {
	trace "$@"
	$invoke_flox_gh auth "$@"
}

# vim:ts=4:noet:syntax=bash
