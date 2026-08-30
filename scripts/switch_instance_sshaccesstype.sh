#!/bin/bash
#
# Switch an already-deployed instance between the 3 SSH access types (0=SystemDefault/no jail,
# 1=CommonUserJail, 2=PrivateUserJail), tearing down whichever jail it currently has (detected
# from its actual passwd entry, not trusted from the caller) and setting up the target one -
# mirroring exactly what scripts/action_deploy_undeploy.sh does at first deploy (mode deployall)
# and at full removal (mode undeployall), just triggered later, on a live instance.
#
# Used by action_customurl_instance.sh (mode changesshaccesstype, from a contract's SSH access
# type field being changed after the instance is already deployed - see the trigger).
#
# Usage: switch_instance_sshaccesstype.sh <fqn> <osusername> <instancedir> <newsshaccesstype> <enablejailkit>
#
# <enablejailkit> is the master's current SELLYOURSAAS_SSH_JAILKIT_ENABLED value (1/0), passed in
# by the caller rather than queried here - this script has no other need for a master-DB
# connection, so a fresh read of a single admin toggle is not worth adding one for.
#
# Safe to re-run: does nothing if the account is already jailed (or not) as requested.

set -e

fqn=$1
osusername=$2
instancedir=$3
newsshaccesstype=$4
enablejailkit=$5

if [[ "x$fqn" == "x" || "x$osusername" == "x" || "x$instancedir" == "x" || "x$newsshaccesstype" == "x" ]]; then
	echo "Usage: $0 <fqn> <osusername> <instancedir> <newsshaccesstype> <enablejailkit>" 1>&2
	exit 1
fi
case "$newsshaccesstype" in
	0|1|2) ;;
	*)
		echo "Error: newsshaccesstype must be 0, 1 or 2 (got '$newsshaccesstype')" 1>&2
		exit 2
		;;
esac
if [[ "x$enablejailkit" != "x1" ]]; then
	echo "Error: SELLYOURSAAS_SSH_JAILKIT_ENABLED is not enabled on the master server (Home - Setup - Other). Enable it before switching any instance's SSH access type." 1>&2
	exit 1
fi

homedir=$(dirname "$instancedir")
targetdir=$(dirname "$homedir")

if ! getent passwd "$osusername" >/dev/null 2>&1; then
	echo "Error: unix account $osusername does not exist - is $fqn actually deployed?" 1>&2
	exit 3
fi

chrootdir=$(grep '^chrootdir=' /etc/sellyoursaas.conf | cut -d '=' -f 2)
if [[ "$newsshaccesstype" != "0" ]]; then
	if ! command -v jk_init >/dev/null 2>&1; then
		echo "Error: jailkit is not installed on this server, cannot set sshaccesstype=$newsshaccesstype" 1>&2
		exit 4
	fi
	if [[ "x$chrootdir" == "x" ]]; then
		echo "Error: chrootdir= is not set in /etc/sellyoursaas.conf, this server is not set up for jailkit" 1>&2
		exit 5
	fi
fi

privatejailtemplatename=$(grep '^privatejailtemplatename=' /etc/sellyoursaas.conf | cut -d '=' -f 2)
commonjailtemplatename=$(grep '^commonjailtemplatename=' /etc/sellyoursaas.conf | cut -d '=' -f 2)
templatesdir=$(grep '^templatesdir=' /etc/sellyoursaas.conf | cut -d '=' -f 2)
if [[ "x$templatesdir" == "x" ]]; then
	templatesdir=$(dirname "$(realpath "$0")")/templates
fi

# Detect the CURRENT type from the account's actual passwd home field, not from what the caller
# thinks it is - jailkit rewrites this field at deploy time (see the undeployall fix in
# action_deploy_undeploy.sh for why trusting a stale caller-provided value here is exactly what
# breaks things elsewhere).
currentpasswdhome=$(getent passwd "$osusername" | cut -d: -f6)
currentsshaccesstype=0
if [[ "x$commonjailtemplatename" != "x" && "$currentpasswdhome" == "$chrootdir/$commonjailtemplatename"*"$homedir" ]]; then
	currentsshaccesstype=1
elif [[ "$currentpasswdhome" == "$chrootdir/$osusername"*"$homedir" ]]; then
	currentsshaccesstype=2
fi

echo "$(date +'%Y-%m-%d %H:%M:%S') ***** Switching SSH access type of $fqn ($osusername) from '$currentsshaccesstype' (detected) to '$newsshaccesstype'"

if [[ "$currentsshaccesstype" == "$newsshaccesstype" ]]; then
	echo "Instance $fqn is already sshaccesstype $newsshaccesstype, nothing to do"
	exit 0
fi

# Stop this instance's php-fpm pool first: it runs as $osusername with Restart=always, so a
# plain killall would just have systemd relaunch it a few seconds later, still holding the
# account "in use" and making the usermod below fail silently every time.
phpfpmservicefile=$(ls /etc/systemd/system/sellyoursaas-php*-fpm-"$fqn".service 2>/dev/null | head -1)
if [[ "x$phpfpmservicefile" != "x" ]]; then
	phpfpmservicename=$(basename "$phpfpmservicefile")
	echo "systemctl stop $phpfpmservicename"
	systemctl stop "$phpfpmservicename" 2>/dev/null || true
fi

# Kill any other process still running as this user before touching its jail/passwd entry -
# killall only sends SIGTERM by default and a lingering process makes the usermod below fail
# silently (see the hardened version of the same pattern in action_deploy_undeploy.sh).
echo "killall -9 -u $osusername"
killall -9 -u "$osusername" 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10; do
	pgrep -u "$osusername" >/dev/null 2>&1 || break
	sleep 1
done

# Tear down whichever jail the account currently has (mirrors action_deploy_undeploy.sh mode
# undeploy/undeployall).
if [[ "$currentsshaccesstype" == "1" ]]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') Removing from the common jail"
	if [[ -d "$chrootdir/$commonjailtemplatename" ]]; then
		echo "umount $chrootdir/$commonjailtemplatename$homedir"
		umount "$chrootdir/$commonjailtemplatename$homedir" 2>/dev/null || true
		echo "rm -Rf $chrootdir/$commonjailtemplatename$homedir"
		rm -Rf "$chrootdir/$commonjailtemplatename$homedir"
		sed -i "/$osusername/d" "$chrootdir/$commonjailtemplatename/etc/passwd"
		sed -i "/$osusername/d" "$chrootdir/$commonjailtemplatename/etc/group"
	fi
elif [[ "$currentsshaccesstype" == "2" ]]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') Removing the private jail"
	if [[ -d "$chrootdir/$osusername" ]]; then
		echo "umount $chrootdir/$osusername$homedir"
		umount "$chrootdir/$osusername$homedir" 2>/dev/null || true
		echo "rm -Rf $chrootdir/$osusername"
		rm -Rf "$chrootdir/$osusername"
	fi
fi
sed -i "/$osusername/d" /etc/fstab

# Reset to a clean, non-jailed baseline before applying the new type below - matters most for
# newsshaccesstype=0, and is a harmless intermediate step otherwise since the jk_jailuser call
# below rewrites both fields again anyway. Retry once after another kill if something else was
# still holding the account busy - see the identical pattern (and why it is needed) in
# action_deploy_undeploy.sh.
echo "usermod -d $homedir --shell /bin/secureBash $osusername"
if ! usermod -d "$homedir" --shell /bin/secureBash "$osusername"; then
	echo "usermod failed for $osusername (still in use?), killing again and retrying once"
	killall -9 -u "$osusername" 2>/dev/null || true
	sleep 2
	if ! usermod -d "$homedir" --shell /bin/secureBash "$osusername"; then
		echo "Error: usermod still failed for $osusername after retry" 1>&2
		exit 8
	fi
fi

# Set up the new jail type (mirrors action_deploy_undeploy.sh mode deployall).
if [[ "$newsshaccesstype" == "1" ]]; then
	if [[ "x$commonjailtemplatename" == "x" ]]; then
		echo "Error: commonjailtemplatename= is not set in /etc/sellyoursaas.conf" 1>&2
		exit 6
	fi
	if [[ ! -d "$chrootdir/$commonjailtemplatename" ]]; then
		echo "Common jail directory $chrootdir/$commonjailtemplatename does not exist, creating it"
		if [[ -f "$templatesdir/$commonjailtemplatename.tar.zst" ]]; then
			tar -I zstd -xf "$templatesdir/$commonjailtemplatename.tar.zst" --directory "$chrootdir/"
		elif [[ -f "$templatesdir/$commonjailtemplatename.tgz" ]]; then
			tar -xzf "$templatesdir/$commonjailtemplatename.tgz" --directory "$chrootdir/"
		else
			echo "Error: failed to get jailkit common template $templatesdir/$commonjailtemplatename.[tgz|tar.zst]" 1>&2
			exit 7
		fi
	fi
	mkdir -p "$chrootdir/$commonjailtemplatename$homedir"
	echo "jk_jailuser -s /bin/bash -n -j $chrootdir/$commonjailtemplatename/ $osusername"
	jk_jailuser -s /bin/bash -n -j "$chrootdir/$commonjailtemplatename/" "$osusername"
	if ! mountpoint -q "$chrootdir/$commonjailtemplatename$homedir"; then
		mount "$homedir" "$chrootdir/$commonjailtemplatename$homedir" -o bind
	fi
	if ! grep -q "$chrootdir/$commonjailtemplatename$homedir" /etc/fstab; then
		echo "$homedir $chrootdir/$commonjailtemplatename$homedir bind defaults,bind 0" >> /etc/fstab
	fi
elif [[ "$newsshaccesstype" == "2" ]]; then
	if [[ ! -d "$chrootdir/$osusername" ]]; then
		# Both the private and common jail archives are built by setup_server_phpfpm.sh from the
		# same /home/jail/chroot/template directory (tar c ... template), so the top-level entry
		# inside either archive is always literally "template", never $privatejailtemplatename
		# itself - that variable only names the .tar.zst/.tgz *file*.
		if [[ "x$privatejailtemplatename" != "x" && -f "$templatesdir/$privatejailtemplatename.tar.zst" ]]; then
			tar -I zstd -xf "$templatesdir/$privatejailtemplatename.tar.zst" --directory "$chrootdir/"
			mv "$chrootdir/template" "$chrootdir/$osusername"
		elif [[ "x$privatejailtemplatename" != "x" && -f "$templatesdir/$privatejailtemplatename.tgz" ]]; then
			tar -xzf "$templatesdir/$privatejailtemplatename.tgz" --directory "$chrootdir/"
			mv "$chrootdir/template" "$chrootdir/$osusername"
		else
			jk_init -c /etc/jailkit/jk_init.ini "$chrootdir/$osusername" extendedshell limitedshell groups sftp rsync editors git php mysqlclient >/dev/null 2>&1
		fi
		mkdir -p "$chrootdir/$osusername$homedir"
	fi
	echo "jk_jailuser -s /bin/bash -n -j $chrootdir/$osusername/ $osusername"
	jk_jailuser -s /bin/bash -n -j "$chrootdir/$osusername/" "$osusername"
	if ! mountpoint -q "$chrootdir/$osusername$homedir"; then
		mount "$homedir" "$chrootdir/$osusername$homedir" -o bind
	fi
	if ! grep -q "$chrootdir/$osusername$homedir" /etc/fstab; then
		echo "$homedir $chrootdir/$osusername$homedir bind defaults,bind 0" >> /etc/fstab
	fi
fi

if [[ "x$phpfpmservicefile" != "x" ]]; then
	echo "systemctl start $phpfpmservicename"
	systemctl start "$phpfpmservicename"
	phpfpmversion=$(echo "$phpfpmservicename" | sed -nE 's/^sellyoursaas-php([0-9.]+)-fpm-.*/\1/p')
	newsocket="/run/php/php${phpfpmversion}-fpm-${fqn}.sock"
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -S "$newsocket" ] && break
		sleep 0.5
	done
	[ -S "$newsocket" ] || echo "Warning: $newsocket did not appear after restarting $phpfpmservicename" 1>&2
fi

echo "$(date +'%Y-%m-%d %H:%M:%S') SSH access type switch for $fqn to $newsshaccesstype done"
