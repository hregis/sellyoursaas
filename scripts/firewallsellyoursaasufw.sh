#!/bin/bash

IPTABLES=iptables

masterserver=`grep '^masterserver=' /etc/sellyoursaas.conf | cut -d '=' -f 2`
if [[ "x$masterserver" == "x" ]]; then
	echo Failed to get masterserver parameter.
	exit 1
fi

dnsserver=`grep '^dnsserver=' /etc/sellyoursaas.conf | cut -d '=' -f 2`
if [[ "x$dnsserver" == "x" ]]; then
	echo Failed to get dnsserver parameter.
	exit 2
fi

instanceserver=`grep '^instanceserver=' /etc/sellyoursaas.conf | cut -d '=' -f 2`
if [[ "x$instanceserver" == "x" ]]; then
	echo Failed to get instanceserver parameter.
	exit 3
fi

allowed_hosts=`grep '^allowed_hosts=' /etc/sellyoursaas.conf | cut -d '=' -f 2`
if [[ "x$allowed_hosts" == "x" && "x$instanceserver" != "x" && "x$instanceserver" != "x0" ]]; then
	echo Parameter allowed_host not found or empty. This is not possible when the server is an instanceserver.
	exit 4
fi


case $1 in
  start)

ufw enable

# From local to external target - Out
#------------------------------------

# SSH
ufw allow out 22/tcp
# HTTP
ufw allow out 80/tcp
ufw allow out 8080/tcp
ufw allow out 443/tcp
# Mysql/Mariadb
ufw allow out 3306/tcp
# Mail
ufw allow out 25/tcp
ufw allow out 2525/tcp
ufw allow out 465/tcp
ufw allow out 587/tcp
ufw allow out 110/tcp
# LDAP LDAPS
ufw allow out 389/tcp
ufw allow out 636/tcp
# IMAP
ufw allow out 143/tcp
ufw allow out 993/tcp
# DCC (anti spam public services)
#ufw allow out 6277/tcp
#ufw allow out 6277/udp
# Rdate
ufw allow out 37/tcp
ufw allow out 123/udp
# Whois
ufw allow out 43/tcp
# DNS
ufw allow out 53/tcp
ufw allow out 53/udp
# NFS
ufw allow out 2049/tcp
ufw allow out 2049/udp


# From external source to local - In
#-----------------------------------

export atleastoneipfound=0

if [[ "x$masterserver" == "x2" || "x$instanceserver" == "x2" ]]; then
	# SSH and MySQL
	for fic in `ls /etc/sellyoursaas-allowed-ip.d/*.conf`
	do
		echo Process file $fic
		for line in `grep -v '^#' "$fic" | sed 's/\s*Require ip\s*//i' | grep '.*\..*\..*\..*'`
		do
			# Allow SSH and Mysql to the restricted ip $line
			echo Allow SSH and Mysql to the restricted ip $line
			# SSH
			ufw allow from $line to any port 22 proto tcp
			# Mysql/Mariadb
			ufw allow from $line to any port 3306 proto tcp
	
			export atleastoneipfound=1
		done
	done
fi

if [[ "x$atleastoneipfound" == "x1" ]]; then
	echo Disallow In access for SSH and Mysql to everybody
	# SSH
	ufw delete allow in 22/tcp
	# Mysql/Mariadb
	ufw delete allow in 3306/tcp
else 
	echo Allow In access with SSH and Mysql to everybody
	# SSH
	ufw allow in 22/tcp
	# Mysql/Mariadb
	ufw allow in 3306/tcp
fi


# HTTP
ufw allow in 80/tcp
ufw allow in 443/tcp
# DNS
ufw allow in 53/tcp
ufw allow in 53/udp

# To see master NFS server
if [[ "x$masterserver" != "x0" ]]; then
	echo Enable NFS entry from instance servers
	ufw allow in 111/udp
	ufw allow in 111/tcp
	ufw allow in 2049/udp
	ufw allow in 2049/tcp
else
	ufw delete allow in 111/udp
	ufw delete allow in 111/tcp
	ufw delete allow in 2049/tcp
	ufw delete allow in 2049/udp
fi

# To accept remote action on port 8080
if [[ "x$allowed_hosts" != "x" ]]; then
	echo Process allowed_host=$allowed_hosts to accept remote call on 8080
	ufw delete allow in 8080/tcp
	for ipsrc in `echo $allowed_hosts | tr "," "\n"`
	do
		echo Process ip $ipsrc - Allow remote actions requests on port 8080 from this ip
		ufw allow from $ipsrc to any port 8080 proto tcp
	done
else
	echo No entry allowed_host found in /etc/sellyoursaas.conf, so no remote action can be requested to this server.
	ufw delete allow in 8080/tcp
fi

ufw default deny incoming
ufw default deny outgoing

ufw reload

$0 status
	;;

  stop)
    
    echo "Stopping firewall rules"

ufw disable 	

    exit 0
    ;;
  restart)
    $0 stop
    $0 start
    ;;
  status)
    ${IPTABLES} -L | grep anywhere | grep ESTABLISHED 1>/dev/null 2>&1
    if [ "$?" == 0 ];
    then
        echo "Firewall is running : OK"
    else
        echo "Firewall is NOT running."
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 4
esac
