#!/bin/sh

. /lib/functions.sh
. /lib/functions/network.sh

# 【分析】 阅读这种multiwan代码，代码是很简单的，重在逻辑，而分析整套设计思路，两种模式，一种是netfilter实现，另外一种是iproute实现，
#   这算是一种纲，核心是对数据包做一系列处理，找不到这个，枉费时间。
#	微观来讲，从跟踪某一个数据包的收发轨迹转发流程上，以icmp 包为例，从内核生成到nic发出，从nic收到响应到内核，这个过程是要着重分析的。
#	分析，任何一个网络软件或者协议都是如此！
# * Load Balancing using 【netfilter】 is referred to as the “Fast Balancer (Best Distribution)”
# * Load Balancing using 【iproute2】 is referred to as “Load Balancer (Best Compatibility)”
# * wanrule for the “Fast Balancer” is now fastbalancer
# * wanrule for the “Load Balancer” is still just balancer

# multiwan 官方笔记
# Note: Multiwan will NOT work if the WAN connections are on the same subnet and share the same default gateway.
# Note2: Multiwan (at least on Barrier Breaker r39404) does not accept WAN interfaces with "_" or other special characters
silencer() {
    if [ -z "$debug" -o "$debug" == "0" ]; then
	$* > /dev/null 2>&1
    else
	$*
    fi
}

mwnote() {
    #logger ${debug:+-s} -p 5 -t multiwan "$1"
	echo "$1" > /var/multiwan
}

failover() {
    local failchk=$(query_config failchk $2)
    local recvrychk=$(query_config recvrychk $2)

    local wanid=$(query_config wanid $2)
    local failover_to=$(uci_get_state multiwan ${2} failover_to)
    local failover_to_wanid=$(query_config wanid $failover_to)

    local existing_failover=$(iptables -n -L FW${wanid}MARK -t mangle | echo $(($(wc -l) - 2)))

    add() {

	wan_fail_map=$(echo $wan_fail_map | sed -e "s/${1}\[${failchk}\]//g")
	wan_fail_map="$wan_fail_map${1}[x]"
	wan_recovery_map=$(echo $wan_recovery_map | sed -e "s/${1}\[${recvrychk}\]//g")
	update_cache

	if [ "$existing_failover" == "2" ]; then
	    if [ "$failover_to" != "balancer" -a "$failover_to" != "fastbalancer" -a "$failover_to" != "disable" -a "$failover_to_wanid" != "$wanid" ]; then
		iptables -I FW${wanid}MARK 2 -t mangle -j FW${failover_to_wanid}MARK
	    elif [ "$failover_to" == "balancer" ]; then
		iptables -I FW${wanid}MARK 2 -t mangle -j LoadBalancer
	    elif [ "$failover_to" == "fastbalancer" ]; then
		iptables -I FW${wanid}MARK 2 -t mangle -j FastBalancer
	    fi
	fi
	mwnote "$1 has failed and is currently offline."
    }

    del() {

	wan_recovery_map=$(echo $wan_recovery_map | sed -e "s/${1}\[${recvrychk}\]//g")
	wan_fail_map=$(echo $wan_fail_map | sed -e "s/${1}\[${failchk}\]//g")
	update_cache

	if [ "$existing_failover" == "3" ]; then
	    iptables -D FW${wanid}MARK 2 -t mangle
	fi
	mwnote "$1 has recovered and is back online!"
    }

    case $1 in 
	add) add $2;;
	del) del $2;;
    esac
}

fail_wan() {
    local new_fail_count

    local health_fail_retries=$(uci_get_state multiwan ${1} health_fail_retries)
    local weight=$(uci_get_state multiwan ${1} weight)

    local failchk=$(query_config failchk $1)
    local recvrychk=$(query_config recvrychk $1)
    wan_recovery_map=$(echo $wan_recovery_map | sed -e "s/${1}\[${recvrychk}\]//g")

    if [ -z "$failchk" ]; then
	failchk=1
	wan_fail_map="$wan_fail_map${1}[1]"
    fi

    if [ "$failchk" != "x" ]; then
	new_fail_count=$(($failchk + 1))
	if [ "$new_fail_count" -lt "$health_fail_retries" ]; then
	    wan_fail_map=$(echo $wan_fail_map | sed -e "s/${1}\[${failchk}\]/$1\[${new_fail_count}\]/g")
	else
	    failover add $1
	    refresh_dns
	    if [ "$weight" != "disable" ]; then
		refresh_loadbalancer
	    fi
	fi
    fi
    update_cache
}

recover_wan() {
    local new_fail_count

    local health_recovery_retries=$(uci_get_state multiwan ${1} health_recovery_retries)
    local weight=$(uci_get_state multiwan ${1} weight)

    local failchk=$(query_config failchk $1)
    local recvrychk=$(query_config recvrychk $1)
    local wanid=$(query_config wanid $1)

    if [ ! -z "$failchk" -a "$failchk" != "x" ]; then
	wan_fail_map=$(echo $wan_fail_map | sed -e "s/${1}\[${failchk}\]//g")
	update_cache
    fi

    if [ "$failchk" == "x" ]; then
	if [ -z "$recvrychk" ]; then
	    wan_recovery_map="$wan_recovery_map${1}[1]"
	    update_cache
	    if [ "$health_recovery_retries" == "1" ]; then
		recover_wan $1
	    fi
	else
	    new_recovery_count=$(($recvrychk + 1))
	    if [ "$new_recovery_count" -lt "$health_recovery_retries" ]; then
		wan_recovery_map=$(echo $wan_recovery_map | sed -e "s/${1}\[${recvrychk}\]/$1\[${new_recovery_count}\]/g")
		update_cache
	    else
		failover del $1
		refresh_dns
		if [ "$weight" != "disable" ]; then
		    refresh_loadbalancer
		fi
	    fi
	fi
    fi
}

acquire_wan_data() {
    local check_old_map
    local get_wanid
    local old_ifname
    local old_ipaddr
    local old_gateway

    local ifname ipaddr gateway
    network_get_device  ifname  ${1} || ifname=x
    network_get_ipaddr  ipaddr  ${1} || ipaddr=x
    network_get_gateway gateway ${1} || gateway=x

    check_old_map=$(echo $wan_id_map 2>&1 | grep -o "$1\[")

    if [ -z $check_old_map ]; then
	wancount=$(($wancount + 1))
	if [ $wancount -gt 20 ]; then
	    wancount=20
	    return
	fi
	wan_if_map="$wan_if_map${1}[${ifname}]"
	wan_id_map="$wan_id_map${1}[${wancount}]"
	wan_gw_map="$wan_gw_map${1}[${gateway}]"
	wan_ip_map="$wan_ip_map${1}[${ipaddr}]"
    else
	old_ipaddr=$(query_config ipaddr $1)
	old_gateway=$(query_config gateway $1)
	old_ifname=$(query_config ifname $1)
	get_wanid=$(query_config wanid $1)

	wan_if_map=$(echo $wan_if_map | sed -e "s/${1}\[${old_ifname}\]/$1\[${ifname}\]/g")
	wan_ip_map=$(echo $wan_ip_map | sed -e "s/${1}\[${old_ipaddr}\]/$1\[${ipaddr}\]/g")
	wan_gw_map=$(echo $wan_gw_map | sed -e "s/${1}\[${old_gateway}\]/$1\[${gateway}\]/g")

	if [ "$old_ifname" != "$ifname" ]; then
	    iptables -D MultiWanPreHandler -t mangle -i $old_$ifname -m state --state NEW -j FW${get_wanid}MARK
	 #   iptables -A MultiWanPreHandler -t mangle -i $ifname -m state --state NEW -j FW${get_wanid}MARK 
	    iptables -D MultiWanPostHandler -t mangle -o $old_$ifname -m mark --mark 0x1/0x0fff -j FW${get_wanid}MARK
	    iptables -A MultiWanPostHandler -t mangle -o $ifname -m mark --mark 0x1/0x0fff -j FW${get_wanid}MARK 
	fi 

	if [ "$ifname" != "x" -a "$ipaddr" != "x" -a "$gateway" != "x" ]; then
	    failover del $1
	    iprules_config $get_wanid
	else
	    failover add $1
	fi

	refresh_routes
	refresh_loadbalancer
	refresh_dns
	update_cache
    fi
}

update_cache() {
    if [ ! -d /tmp/.mwan ]; then
	mkdir /tmp/.mwan > /dev/null 2>&1
    fi

    rm /tmp/.mwan/cache > /dev/null 2>&1
    touch /tmp/.mwan/cache

    echo "# Automatically Generated by Multi-WAN Agent Script. Do not modify or remove. #" > /tmp/.mwan/cache
    echo "wan_id_map=\"$wan_id_map\"" >> /tmp/.mwan/cache
    echo "wan_if_map=\"$wan_if_map\"" >> /tmp/.mwan/cache
    echo "wan_ip_map=\"$wan_ip_map\"" >> /tmp/.mwan/cache
    echo "wan_gw_map=\"$wan_gw_map\"" >> /tmp/.mwan/cache
    echo "wan_fail_map=\"$wan_fail_map\"" >> /tmp/.mwan/cache
    echo "wan_recovery_map=\"$wan_recovery_map\"" >> /tmp/.mwan/cache
    echo "wan_monitor_map=\"$wan_monitor_map\"" >> /tmp/.mwan/cache
}

query_config() {
    case $1 in
	ifname) echo $wan_if_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';; 
	ipaddr) echo $wan_ip_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';;
	gateway) echo $wan_gw_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';;
	wanid) echo $wan_id_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';;
	failchk) echo $wan_fail_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';;
	recvrychk) echo $wan_recovery_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';;
	monitor) echo $wan_monitor_map | grep -o "$2\[\w*.*\]" | awk -F "[" '{print $2}' | awk -F "]" '{print $1}';;
	group) echo $wan_id_map | grep -o "\w*\[$2\]" | awk -F "[" '{print $1}';;
    esac
}

mwan_kill() {
    local otherpids=$(ps 2>&1 | grep 'multiwan agent' | grep -v $$ | awk '{print $1}')
    [ -n "$otherpids" ] && kill $otherpids > /dev/null 2>&1
    sleep 2
}

# For system shutdownl: stop
#   A plain stop will leave network in a limp state, without wan access
# stop single: restore to a single wan
# stop restart: restart multiple wan's
stop() {
    mwan_kill
    flush $1

    if [ "$1" == "single" ]; then
	# ifup is quite expensive--do it only when single wan is requested
	echo "## Refreshing Interfaces ##"
	local i=0
	while [ $((i++)) -lt $wancount ]; do 
	    local group=$(query_config group $i)
	    ifup $group >&- 2>&- && sleep 1
	done

	echo "## Unloaded, updating syslog and exiting. ##"
	mwnote "Succesfully Unloaded on $(exec date -R)."
	rm -fr /tmp/.mwan >&- 2>&-
    fi
    ip route flush cache

    if [ "$1" == "restart" ]; then
	echo "## Restarting Multi-WAN. ##"
	mwnote "Reinitializing Multi-WAN Configuration."
	rm -fr /tmp/.mwan >&- 2>&-
	/etc/init.d/multiwan start >&- 2>&-
    fi

    exit
}

clear_rules() {
    local restore_single=$1
    local group 

    iptables -t mangle -D PREROUTING -j MultiWan
    iptables -t mangle -D FORWARD -j MultiWan
    iptables -t mangle -D OUTPUT -j MultiWan
    iptables -t mangle -D POSTROUTING -j MultiWan

	# -A MultiWan -j CONNMARK --restore-mark --nfmask 0xfff --ctmask 0xfff
	# -A MultiWan -j MultiWanPreHandler
	# -A MultiWan -j MultiWanRules
	# -A MultiWan -j MultiWanLoadBalancer
	# -A MultiWan -j MultiWanDNS
	# -A MultiWan -j MultiWanPostHandler
    iptables -t mangle -F MultiWan
    iptables -t mangle -X MultiWan
    iptables -t mangle -F MultiWanRules
    iptables -t mangle -X MultiWanRules
    iptables -t mangle -F MultiWanDNS
    iptables -t mangle -X MultiWanDNS
    iptables -t mangle -F MultiWanPreHandler
    iptables -t mangle -X MultiWanPreHandler
    iptables -t mangle -F MultiWanPostHandler
    iptables -t mangle -X MultiWanPostHandler
    iptables -t mangle -F LoadBalancer
    iptables -t mangle -X LoadBalancer
    iptables -t mangle -F FastBalancer
    iptables -t mangle -X FastBalancer
    iptables -t mangle -F MultiWanLoadBalancer
    iptables -t mangle -X MultiWanLoadBalancer

    local i=0
    while [ $((i++)) -lt $wancount ]; do 
	iptables -t mangle -F FW${i}MARK
	iptables -t mangle -X FW${i}MARK
    done

    if [ ! -z "$CHKFORQOS" ]; then
	iptables -t mangle -F PREROUTING
	iptables -t mangle -F FORWARD
	iptables -t mangle -F OUTPUT
	iptables -t mangle -F POSTROUTING
	iptables -t mangle -F MultiWanQoS
	iptables -t mangle -X MultiWanQoS

	i=0
	while [ $((i++)) -lt $wancount ]; do

	    group=$(query_config group $i)
		echo "group=$group"
	    iptables -t mangle -F qos_${group}
	    iptables -t mangle -F qos_${group}_ct
	    iptables -t mangle -X qos_${group}
	    iptables -t mangle -X qos_${group}_ct
	done
    fi

    [ "$restore_single" == 'single' ] &&
	/etc/init.d/qos restart > /dev/null 2>&1
}

qos_init() {
    local ifname
    local queue_count
    local get_wan_tc
    local get_wan_iptables
    local add_qos_iptables
    local add_qos_tc
    local execute
    local iprule
    local qos_if_test

    ifname=$(query_config ifname $1)

    if [ "$ifname" == "x" ]; then
	return
    fi

    qos_if_test=$(echo $qos_if_done | grep $ifname.)

    if [ ! -z "$qos_if_test" ]; then
	return
    fi

    qos_if_done=$(echo ${qos_if_done}.${ifname})

    queue_count=$(tc filter list dev $ifname | tail -n 1 | awk -F " " '{print $10}' | sed "s/0x//g")

    if [ -z "$queue_count" ]; then
	return
    fi

    queue_count=$(($queue_count + 1))

    iptables -t mangle -N qos_${1}
    iptables -t mangle -N qos_${1}_ct

    get_wan_tc=$(tc filter list dev $ifname | grep "0x" | sed -e "s/filter /tc filter add dev $ifname /g" -e "s/pref/prio/g" -e "s/fw//g") 
    get_wan_iptables=$(iptables-save | egrep  '(-A Default )|(-A Default_ct )' | grep -v "MultiWanQoS" | sed -e "s/Default /qos_${1} /g" -e "s/Default_ct /qos_${1}_ct /g" -e "s/-A/iptables -t mangle -A/g")


    local i=0
    while [ $i -lt $queue_count ]; do 
	echo "s/\(0x$i \|0x$i\/0xffffffff\)/0x$(($2 * 10 + $i)) /g" >> /tmp/.mwan/qos.$1.sedfilter
	i=$(($i + 1))
    done

    add_qos_iptables=$(echo "$get_wan_iptables" | sed -f /tmp/.mwan/qos.$1.sedfilter)
    echo "$add_qos_iptables" | while read execute; do ${execute}; done

    rm /tmp/.mwan/qos.$1.sedfilter 
    i=1
    while [ $i -lt $queue_count ]; do 
	echo "s/0x$i /0x${2}${i} fw /g" >> /tmp/.mwan/qos.$1.sedfilter
	i=$(($i + 1))
    done

    add_qos_tc=$(echo "$get_wan_tc" | sed -f /tmp/.mwan/qos.$1.sedfilter)
    echo "$add_qos_tc" | while read execute; do ${execute}; done
    rm /tmp/.mwan/qos.$1.sedfilter

    i=0
    while [ $i -lt $queue_count ]; do
	if [ $i -lt $(($queue_count - 1)) ]; then
	    ip rule add fwmark 0x$(($2 * 10 + $i + 1))/0x0fff table $(($2 + 170)) prio $(( $2 * 10 + $i + 2))
	fi
	iptables -t mangle -A MultiWanQoS -m mark --mark 0x$(($2 * 10 + $i))/0x0fff -j qos_${1}
	i=$(($i + 1))
    done
}

mwanrule() {
    local src
    local dst
    local ports
    local proto
    local wanrule

    config_get src $1 src
    config_get dst $1 dst
    config_get port_type $1 port_type 'dports'
    config_get ports $1 ports
    config_get proto $1 proto
    config_get wanrule $1 wanrule

    if [ -z "$wanrule" ]; then
	return
    fi

    if [ "$wanrule" != "balancer" -a "$wanrule" != "fastbalancer" ]; then
	wanrule=$(query_config wanid ${wanrule})
	wanrule="FW${wanrule}MARK"
    elif [ "$wanrule" == "balancer" ]; then
	wanrule="LoadBalancer"
    elif [ "$wanrule" == "fastbalancer" ]; then
	wanrule="FastBalancer"
    fi
    if [ "$dst" == "all" ]; then
	dst=$NULL
    fi
    if [ "$proto" == "all" ]; then
	proto=$NULL
    fi
    if [ "$ports" == "all" ]; then
	ports=$NULL
    fi
    add_rule() {
	if [ "$proto" == "icmp" ]; then
	    ports=$NULL
	fi 
	if [ "$src" == "all" ]; then
	    src=$NULL
	fi
	iptables -t mangle -A MultiWanRules ${src:+-s $src} ${dst:+-d $dst} \
	    -m mark --mark 0x0/0x0fff ${proto:+-p $proto -m $proto} \
	    ${ports:+-m multiport --$port_type $ports} \
	    -j $wanrule
    }
    if  [ -z "$proto" -a ! -z "$ports" ]; then
	proto=tcp
	add_rule
	proto=udp
	add_rule
	return
    fi
    add_rule
}

refresh_dns() {
    local dns
    local group
    local ipaddr
    local gateway
    local ifname
    local failchk
    local compile_dns
    local dns_server
	return
    iptables -F MultiWanDNS -t mangle

    rm /tmp/resolv.conf.auto
    touch /tmp/resolv.conf.auto

    echo "## Refreshing DNS Resolution and Tables ##"

    local i=0
    while [ $((i++)) -lt $wancount ]; do
	group=$(query_config group $i)
	gateway=$(query_config gateway $group)
	ipaddr=$(query_config ipaddr $group)
	ifname=$(query_config ifname $group)
	failchk=$(query_config failchk $group)

	dns=$(uci_get_state multiwan ${group} dns 'auto')
	[ "$dns" == "auto" ] && network_get_dnsserver dns ${group}
	dns=$(echo $dns | sed -e "s/ /\n/g")

	if [ ! -z "$dns" -a "$failchk" != "x" -a "$ipaddr" != "x" -a "$gateway" != "x" -a "$ifname" != "x" ]; then
	    echo "$dns" | while read dns_server; do
		iptables -t mangle -A MultiWanDNS -d $dns_server -p tcp --dport 53 -j FW${i}MARK
		iptables -t mangle -A MultiWanDNS -d $dns_server -p udp --dport 53 -j FW${i}MARK

		compile_dns="nameserver $dns_server"
		echo "$compile_dns" >> /tmp/resolv.conf.auto
	    done
	fi
    done

    last_resolv_update=$(ls -l -e /tmp/resolv.conf.auto | awk -F " " '{print $5, $9}')
}

# IPTables Rule Initialization
iptables_init() {
    echo "## IPTables Rule Initialization ##"
    local iprule
    local group
    local ifname
    local execute
    local IMQ_NFO
    local default_route_id
    local i

    if [ ! -z "$CHKFORQOS" ]; then
	echo "## QoS Initialization ##"

	# 并没有qos, 待解决
	/etc/init.d/qos restart > /dev/null 2>&1  

	# IMQ 是中介队列设备的简称，是一个虚拟的网卡设备，与物理网卡不同的是，通过它可以进行全局的流量整形，不需要一个网卡一个网卡地限速。
	# 这对有多个ISP接入的情况特别方便。配合 Iptables，可以非常方便地进行上传和下载限速。
 	# IMQ(Intermediate queueing device,中介队列
	IMQ_NFO=$(iptables -n -L PREROUTING -t mangle -v | grep IMQ | awk -F " " '{print $6,$12}')

	iptables -t mangle -F PREROUTING 
	iptables -t mangle -F FORWARD
	iptables -t mangle -F POSTROUTING
	iptables -t mangle -F OUTPUT

	echo "$IMQ_NFO" | while read execute; do
	    iptables -t mangle -A PREROUTING -i $(echo $execute | awk -F " " '{print $1}') -j IMQ --todev $(echo $execute | awk -F " " '{print $2}')
	done

	iptables -t mangle -N MultiWanQoS

	i=0
	while [ $((i++)) -lt $wancount ]; do 
	    qos_init $(query_config group $i) $i
	done

    fi

    iptables -t mangle -N MultiWan
    iptables -t mangle -N LoadBalancer
    iptables -t mangle -N FastBalancer
    iptables -t mangle -N MultiWanRules
    iptables -t mangle -N MultiWanDNS
    iptables -t mangle -N MultiWanPreHandler
    iptables -t mangle -N MultiWanPostHandler
    iptables -t mangle -N MultiWanLoadBalancer

    echo "## Creating FW Rules ##"
    i=0
    while [ $((i++)) -lt $wancount ]; do 
	iprule=$(($i * 10))
	iptables -t mangle -N FW${i}MARK

	# -A FW1MARK -j MARK --set-xmark 0x10/0xfff  打标记为16  0x10
	# -A FW1MARK -j CONNMARK --save-mark --nfmask 0xfff --ctmask 0xfff
	# -A FW2MARK -j MARK --set-xmark 0x20/0xfff  打标记为32
	# -A FW2MARK -j CONNMARK --save-mark --nfmask 0xfff --ctmask 0xfff
	iptables -t mangle -A FW${i}MARK -j MARK --set-mark 0x${iprule}/0x0fff 
	iptables -t mangle -A FW${i}MARK -j CONNMARK --save-mark --mask 0x0fff
    done

	# -A LoadBalancer -j MARK --set-xmark 0x1/0xfff
	# -A LoadBalancer -j CONNMARK --save-mark --nfmask 0xfff --ctmask 0xfff   针对连接的MARK
    iptables -t mangle -A LoadBalancer -j MARK --set-mark 0x1/0x0fff
    iptables -t mangle -A LoadBalancer -j CONNMARK --save-mark --mask 0x0fff 

	# 检查模块 statistic 是否存在，为空
    if [ -z "$CHKFORMODULE" ]; then
	# -A FastBalancer -j MARK --set-xmark 0x2/0xfff
	# -A FastBalancer -j CONNMARK --save-mark --nfmask 0xfff --ctmask 0xfff
	iptables -t mangle -A FastBalancer -j MARK --set-mark 0x2/0x0fff 
	iptables -t mangle -A FastBalancer -j CONNMARK --save-mark --mask 0x0fff
    else
	mwnote "Performance load balancer(fastbalanacer) is unavailable due to current kernel limitations."
	iptables -t mangle -A FastBalancer -j MARK --set-mark 0x1/0x0fff 
	iptables -t mangle -A FastBalancer -j CONNMARK --save-mark --mask 0x0fff
    fi

    iptables -t mangle -A MultiWan -j CONNMARK --restore-mark --mask 0x0fff
    iptables -t mangle -A MultiWan -j MultiWanPreHandler   # 路由前处理
    iptables -t mangle -A MultiWan -j MultiWanRules        # MultiWanRules
    iptables -t mangle -A MultiWan -j MultiWanLoadBalancer # 负载均衡
    iptables -t mangle -A MultiWan -j MultiWanDNS		   # 未处理
    iptables -t mangle -A MultiWan -j MultiWanPostHandler  # 路由后处理

    iptables -t mangle -I PREROUTING -j MultiWan
    iptables -t mangle -I FORWARD -j MultiWan
    iptables -t mangle -I OUTPUT -j MultiWan
    iptables -t mangle -I POSTROUTING -j MultiWan


    refresh_dns

    config_load "multiwan"
    config_foreach mwanrule mwanfw

    if [ "$default_route" != "balancer" -a "$default_route" != "fastbalancer" ]; then 
	default_route_id=$(query_config wanid $default_route)
	iptables -t mangle -A MultiWanRules -m mark --mark 0x0/0x0fff -j FW${default_route_id}MARK
    elif [ "$default_route" == "fastbalancer" ]; then
	iptables -t mangle -A MultiWanRules -m mark --mark 0x0/0x0fff -j FastBalancer	
    else
	iptables -t mangle -A MultiWanRules -m mark --mark 0x0/0x0fff -j LoadBalancer
    fi

    i=0
    while [ $((i++)) -lt $wancount ]; do 
	group=$(query_config group $i)
	ifname=$(query_config ifname $group)
#	iptables -t mangle -A MultiWanPreHandler -i $ifname -m state --state NEW -j FW${i}MARK

	# -A MultiWanPostHandler -o eth4 -m mark --mark 0x1/0xfff -j FW1MARK
	# -A MultiWanPostHandler -o eth5 -m mark --mark 0x1/0xfff -j FW2MARK
	iptables -t mangle -A MultiWanPostHandler -o $ifname -m mark --mark 0x1/0x0fff -j FW${i}MARK
    done

    if [ ! -z "$CHKFORQOS" ]; then
	iptables -t mangle -A MultiWan -j MultiWanQoS
    fi
}

# 多径路由实现的负载均衡；
refresh_loadbalancer() {
    local group
    local gateway
    local ifname
    local failchk
    local weight
    local nexthop
    local pre_nexthop_chk
    local rand_probability

    echo "## Refreshing Load Balancer ##"

    ip rule del prio 9 > /dev/null 2>&1 
    ip route flush table 170 > /dev/null 2>&1

    for TABLE in 170; do
	ip route | grep -Ev ^default | while read ROUTE; do
	    ip route add table $TABLE to $ROUTE
	done
    done

    iptables -F MultiWanLoadBalancer -t mangle
	
    local total_weight=0

    local i=0
    while [ $((i++)) -lt $wancount ]; do 
	group=$(query_config group $i)
	failchk=$(query_config failchk $group)
	gateway=$(query_config gateway $group)
	ifname=$(query_config ifname $group)
	weight=$(uci_get_state multiwan ${group} weight)
	if [ "$gateway" != "x" -a "$ifname" != "x" -a "$failchk" != "x" -a "$weight" != "disable" ]; then
	    total_weight=$(($total_weight + $weight))
	fi
    done

    i=0
    while [ $((i++)) -lt $wancount ]; do 
	group=$(query_config group $i)
	failchk=$(query_config failchk $group)
	gateway=$(query_config gateway $group)
	ifname=$(query_config ifname $group)

	weight=$(uci_get_state multiwan ${group} weight)

	if [ "$gateway" != "x" -a "$ifname" != "x" -a "$failchk" != "x" -a "$weight" != "disable" -a "$weight" != "0" ]; then
	    nexthop="$nexthop nexthop via $gateway dev $ifname weight $weight"

	    rand_probability=$(($weight * 100 / $total_weight))
	    total_weight=$(($total_weight - $weight))

	    if [ $rand_probability -lt 10 ]; then
		rand_probability="0.0${rand_probability}"
	    elif [ $rand_probability -lt 100 ]; then
		rand_probability="0.${rand_probability}"
	    else
		rand_probability="1.0"
	    fi

	    if [ -z "$CHKFORMODULE" ]; then
		iptables -A MultiWanLoadBalancer -t mangle -m mark --mark 0x2/0x0fff -m statistic --mode random --probability $rand_probability -j FW${i}MARK
	    route add default gw $gateway > /dev/null 2>&1
		fi
	elif [ "$failchk" == "x" ]; then 
		route del default gw $gateway > /dev/null 2>&1
		
	fi

    done
####################################################################
	i=0
    while [ $((i++)) -lt $wancount ]; do 
	group=$(query_config group $i)
	failchk=$(query_config failchk $group)
	gateway=$(query_config gateway $group)
	ifname=$(query_config ifname $group)

	weight=$(uci_get_state multiwan ${group} weight)

	if [ "$gateway" != "x" -a "$ifname" != "x" -a "$failchk" != "x" -a "$weight" == "0" ]; then
		rand_probability="1.0"
	    if [ -z "$CHKFORMODULE" ]; then
		# -A MultiWanLoadBalancer -m mark --mark 0x2/0xfff -m statistic --mode random --probability 0.50000000000 -j FW1MARK
		# -A MultiWanLoadBalancer -m mark --mark 0x2/0xfff -m statistic --mode random --probability 1.00000000000 -j FW2MARK	
		iptables -A MultiWanLoadBalancer -t mangle -m mark --mark 0x2/0x0fff -m statistic --mode random --probability $rand_probability -j FW${i}MARK
		route add default gw $gateway metric 255 > /dev/null 2>&1	
	    fi
	elif [ "$failchk" == "x" ]; then 
		route del default gw $gateway > /dev/null 2>&1	
	fi

    done
######################################################################	
	

# Most of the capabilities of the kernel accessed by the ip and tc programs probably aren't included in your
# distribution's stock kernel configuration. If you can't get a feature to work, make sure that all of the required
# kernel configuration values are set properly. I've tried to note what kernel configuration options are required 
# or related in the Command Syntax section. I'm often guessing, so don't be suprised if I've missed something
# (please do tell me about it, though).

    pre_nexthop_chk=$(echo $nexthop | awk -F "nexthop" '{print NF-1}')
    if [ "$pre_nexthop_chk" == "1" ]; then
	echo "aaaaaaaaaaaaaaa"
	ip route add default via $(echo $nexthop | awk -F " " '{print $3}') dev $(echo $nexthop | awk -F " " '{print $5}') proto static table 170
    elif [ "$pre_nexthop_chk" -gt "1" ]; then

	# 需要内核模块的支持，等价多路径算法 IP: equal cost multipath 
	# ip route add proto static table 170 default scope global nexthop via 192.168.26.254 dev eth4 weight 1 nexthop via 192.168.10.1 dev eth5 weight 1
	ip route add proto static table 170 default scope global $nexthop
    fi
	#  9:	from all fwmark 0x1/0xfff lookup LoadBalancer
    ip rule add fwmark 0x1/0x0fff table 170 prio 9  
    ip route flush cache
	conntrack -F
}

refresh_routes() {
    local iprule
    local gateway
    local group
    local ifname
    local ipaddr

    echo "## Refreshing Routing Tables ##"
    local i=0
    while [ $((i++)) -lt $wancount ]; do 
	group=$(query_config group $i)
	gateway=$(query_config gateway $group)
	ifname=$(query_config ifname $group)
	ipaddr=$(query_config ipaddr $group)
	ip route flush table $(($i + 170)) > /dev/null 2>&1

# root@OpenWrt:/# ip route |grep -Ev ^default
# 192.168.0.0/20 dev br-ovs.1  proto kernel  scope link  src 192.168.0.1 
# 192.168.10.0/24 dev eth5  proto kernel  scope link  src 192.168.10.13 
# 192.168.26.0/24 dev eth4  proto kernel  scope link  src 192.168.26.60 
# 192.168.26.254 dev eth4  proto static  scope link  src 192.168.26.60 
	TABLE=$(($i + 170))
	ip route | grep -Ev ^default | while read ROUTE; do
	#	ip route add table 172 to 192.168.0.0/20 dev br-ovs.1 proto kernel scope link src 192.168.0.1
	#	ip route add table 172 to 192.168.10.0/24 dev eth5 proto kernel scope link src 192.168.10.13
	#	ip route add table 172 to 192.168.26.0/24 dev eth4 proto kernel scope link src 192.168.26.60
	#	ip route add table 172 to 192.168.26.254 dev eth4 proto static scope link src 192.168.26.60
	    ip route add table $TABLE to $ROUTE
	done

	if [ "$gateway" != "x" -a "$ipaddr" != "x" -a "$ifname" != "x" ]; then
		# ip route add default via 192.168.26.254 table 171 src 192.168.26.60 proto static
		# ip route add default via 192.168.10.1 table 172 src 192.168.10.13 proto static
	    ip route add default via $gateway table $(($i + 170)) src $ipaddr proto static
	    #route add default gw $gateway > /dev/null 2>&1
	fi
    done
	# 刷新路由缓存
    ip route flush cache
}

iprules_config() {
    local iprule
    local group
    local gateway
    local ipaddr

    group=$(query_config group $1)
    gateway=$(query_config gateway $group)
    ipaddr=$(query_config ipaddr $group)

	# 171 MWAN1
	# 172 MWAN2
    CHKIPROUTE=$(grep MWAN${1} /etc/iproute2/rt_tables)
    if [ -z "$CHKIPROUTE" ]; then
	echo "$(($1 + 170)) MWAN${1}" >> /etc/iproute2/rt_tables
    fi

	# 添加之前，先清空
    ip rule del prio $(($1 * 10)) > /dev/null 2>&1 
    ip rule del prio $(($1 * 10 + 1)) > /dev/null 2>&1

    if [ "$gateway" != "x" -a "$ipaddr" != "x" ]; then
	# 10:	from 192.168.26.60 lookup MWAN1 
	# 20:	from 192.168.10.8 lookup MWAN2
	ip rule add from $ipaddr table $(($1 + 170)) prio $(($1 * 10))

	# 11:	from all fwmark 0x10/0xfff lookup MWAN1
	# 21:	from all fwmark 0x20/0xfff lookup MWAN2
	ip rule add fwmark 0x$(($1 * 10))/0x0fff table $(($1 + 170)) prio $(($1 * 10 + 1))
    fi
}

# 1. 清除ip rules   
# 2. 清除ip routes   
# 3. 清除 fw rules
flush() {
    local restore_single=$1
    echo "## Flushing IP Rules & Routes ##"

	# 清空 ip rules
    ip rule flush > /dev/null 2>&1   
    ip rule add lookup local prio 1 > /dev/null 2>&1  # for Chaos Calmer by liujie
    ip rule add lookup main prio 32766 > /dev/null 2>&1
    ip rule add lookup default prio 32767 > /dev/null 2>&1
	
	# 清空 170 LoadBalancer 
    ip route flush table 170 > /dev/null

    local i=0
    while [ $((i++)) -lt $wancount ]; do 
	# ip route del default proto static
	ip route del default proto static > /dev/null 2>&1
	# ip route flush table 171， 172
	ip route flush table $(($i + 170)) > /dev/null 2>&1
    done

    echo "## Clearing Rules ##"
    clear_rules $restore_single > /dev/null 2>&1
	if [ -f $jobfile ]; then
    	rm $jobfile > /dev/null 2>&1
	fi
}

main_init() {
    local RP_PATH IFACE
    local group
    local health_interval

    echo "## Main Initialization ##"

    mkdir /tmp/.mwan > /dev/null 2>&1
    mwan_kill         # kill 所有multiwan进程
    flush			  # 清除ip规则和路由

    echo "## IP Rules Initialization ##"
	# 增加 170 LoadBalancer
    CHKIPROUTE=$(grep LoadBalancer /etc/iproute2/rt_tables)
    if [ -z "$CHKIPROUTE" ]; then
	echo "#" >> /etc/iproute2/rt_tables
	echo "170 LoadBalancer" >> /etc/iproute2/rt_tables
    fi

    local i=0
    while [ $((i++)) -lt $wancount ]; do 
	iprules_config $i
    done

	# Refreshing Routing Tables
    refresh_routes

    # IPTables Rule Initialization
    iptables_init

	# Refreshing Load Balancer
    refresh_loadbalancer

	# 即rp_filter参数有三个值，0、1、2，具体含义：   Linux内核文档documentation/networking/ip-sysctl.txt
	# 0：不开启源地址校验。
	# 1：开启严格的反向路径校验。对每个进来的数据包，校验其反向路径是否是最佳路径。如果反向路径不是最佳路径，则直接丢弃该数据包。
	# 2：开启松散的反向路径校验。对每个进来的数据包，校验其源地址是否可达，即反向路径是否能通（通过任意网口），如果反向路径不同，则直接丢弃该数据包
    # 当设置rp_filter参数==1时， 请求数据包进的网卡和响应数据包出的网卡不是同一个网卡，这时候系统会判断该反向路径不是最佳路径，而直接丢弃该请求数据包。
	RP_PATH=/proc/sys/net/ipv4/conf
    for IFACE in $(ls $RP_PATH); do
	echo 0 > $RP_PATH/$IFACE/rp_filter
    done
    mwnote "Succesfully Initialized on $(date -R)."

	
    fail_start_check


	# 循环检测 
    while :; do
	schedule_tasks
	do_tasks
    done
}

monitor_wan() {
    local ifname ipaddr gateway icmp_hosts_acquire icmp_test_host
    local check_test

    . /tmp/.mwan/cache

    local timeout=$(uci_get_state multiwan ${1} timeout)
    local icmp_hosts=$(uci_get_state multiwan ${1} icmp_hosts)
    local icmp_count=$(uci_get_state multiwan ${1} icmp_count '1')
    local health_interval=$(uci_get_state multiwan ${1} health_interval)
    local ifname_cur=$(query_config ifname $1)
    local ipaddr_cur=$(query_config ipaddr $1)
    local gateway_cur=$(query_config gateway $1)

    while :; do
	[ "${health_monitor%.*}" = 'parallel' ] && sleep $health_interval

	network_get_device  ifname  ${1} || ifname=x
	network_get_ipaddr  ipaddr  ${1} || ipaddr=x
	network_get_gateway gateway ${1} || gateway=x

	if [ "$ifname_cur" != "$ifname" -o "$ipaddr_cur" != "$ipaddr" -o "$gateway_cur" != "$gateway" ]; then
	    add_task "$1" acquire
	    if [ "${health_monitor%.*}" = 'parallel' ]; then
		exit
	    else
		return
	    fi
	else
	    [ "$gateway" != "x" ] && ! ip route | grep -o $gateway >&- 2>&- &&
		add_task route refresh
	fi

	if [ "$icmp_hosts" != "disable" -a "$ifname" != "x" -a "$ipaddr" != "x" -a "$gateway" != "x" ]; then

	    if [ "$icmp_hosts" == "gateway" -o -z "$icmp_hosts" ]; then
		icmp_hosts_acquire=$gateway
	    elif [ "$icmp_hosts" == "dns" ]; then
		icmp_hosts_acquire=$(uci_get_state multiwan $1 dns 'auto')
		[ "$icmp_hosts_acquire" == "auto" ] &&
			network_get_dnsserver icmp_hosts_acquire $1
	    else
		icmp_hosts_acquire=$icmp_hosts
	    fi

	    icmp_hosts=$(echo $icmp_hosts_acquire | sed -e "s/\,/ /g" | sed -e "s/ /\n/g")

	    ping_test() {
		echo "$icmp_hosts" | while read icmp_test_host; do
			# ping -c 1 -W 3 -I eth5 192.168.10.1
			# ping -c 1 -W 3 -I eth4 192.168.26.254
		    ping -c "$icmp_count" -W $timeout -I $ifname $icmp_hosts 2>&1 | grep   -o "ttl="
		done
	    }
		

	    check_test=$(ping_test)


	    if [ -z "$check_test" ]; then
		add_task "$1" fail
	    else
		add_task "$1" pass
	    fi       	        

	elif [ "$icmp_hosts" == "disable" ]; then 
	    add_task "$1" pass
	fi

	[ "$health_monitor" = 'serial' ] && {
	    wan_monitor_map=$(echo $wan_monitor_map | sed -e "s/$1\[\w*\]/$1\[$(date +%s)\]/g")
	    update_cache
	    break
	}
    done
}

# Add a task to the $jobfile while ensuring
# no duplicate tasks for the specified group
add_task() {
    local group=$1
    local task=$2
    grep -o "$group.$task" $jobfile >&- 2>&- || echo "$group.$task" >> $jobfile
}

# For health_monitor "parallel", start a background monitor for each group.
# For health_monitor "serial", queue monitor tasks for do_tasks.
schedule_tasks() {
    local group health_interval monitored_last_at current_time diff delay
    local i=0

	# uci 方式获取监控通断时间间隔
    get_health_interval() {
	group=$(query_config group $1)
	health_interval=$(uci_get_state multiwan ${group} health_interval 'disable')
	[ "$health_interval" = "disable" ] && health_interval=0
    }

	# 内存占用相关？？ 默认 parallel
    [ "$health_monitor" = 'parallel' ] && {
	while [ $((i++)) -lt $wancount ]; do
	    get_health_interval $i
	    if [ "$health_interval" -gt 0 ]; then
		monitor_wan $group &    # monitor wan 进程；
		sleep 1
	    fi
	done
	echo "## Started background monitor_wan ##"
	health_monitor="parallel.started"
    }

    [ "$health_monitor" = 'serial' ] && {
	local monitor_disabled=1

	until [ -f $jobfile ]; do
	    current_time=$(date +%s)
	    delay=$max_interval
	    i=0

	    while [ $((i++)) -lt $wancount ]; do
		get_health_interval $i
		if [ "$health_interval" -gt 0 ]; then
		    monitor_disabled=0

		    monitored_last=$(query_config monitor $group)
		    [ -z "$monitored_last" ] && {
			monitored_last=$current_time
			wan_monitor_map="${wan_monitor_map}${group}[$monitored_last]"
			update_cache
		    }

		    will_monitor_at=$(($monitored_last + $health_interval))
		    diff=$(($will_monitor_at - $current_time))
		    [ $diff -le 0 ] && add_task "$group" 'monitor'

		    delay=$(($delay > $diff ? $diff : $delay))
		fi
	    done

	    [ "$monitor_disabled" -eq 1 ] && {
		# Although health monitors are disabled, still
		# need to check up on iptables rules in do_tasks
		sleep "$iptables_interval"
		break
	    }
	    [ $delay -gt 0 ] && sleep $delay
	done
    }
}

rule_counter=0
# Process each task in the $jobfile in FIFO order
do_tasks() {
    local check_iptables
    local queued_task
    local current_resolv_file

    while :; do

	. /tmp/.mwan/cache

	if [ "$((++rule_counter))" -eq 5 -o "$health_monitor" = 'serial' ]; then

	    check_iptables=$(iptables -n -L MultiWan -t mangle | grep "references" | awk -F "(" '{print $2}' | cut -d " " -f 1)

	    if [ -z "$check_iptables" -o "$check_iptables" -lt 4 ]; then
		mwnote "Netfilter rules appear to of been altered."
		/etc/init.d/multiwan restart
		exit
	    fi

	    current_resolv_file=$(ls -l -e /tmp/resolv.conf.auto | awk -F " " '{print $5, $9}')

	    if [ "$last_resolv_update" != "$current_resolv_file" ]; then
		refresh_dns
	    fi

	    rule_counter=0
	fi

	if [ -f $jobfile ]; then

	    mv $jobfile $jobfile.work

	    while read LINE; do 

		execute_task() {
		    case $2 in 
			fail) fail_wan $1;;
			pass) recover_wan $1;;
			acquire)
			    acquire_wan_data $1
			    [ "${health_monitor%.*}" = 'parallel' ] && {
				monitor_wan $1 &
				echo "## Started background monitor_wan ##"
			    }
			    ;;
			monitor) monitor_wan $1;;
			refresh) refresh_routes;;
			*) echo "## Unknown task command: $2 ##";;
		    esac
		}

		queued_task=$(echo $LINE | awk -F "." '{print $1,$2}')
		execute_task $queued_task
	    done < $jobfile.work

	    rm $jobfile.work
	fi

	if [ "$health_monitor" = 'serial' ]; then
	    break
	else
	    sleep 1
	fi
    done
}

fail_start_check(){ 
    local ipaddr
    local gateway
    local ifname
    local group

    local i=0
    while [ $((i++)) -lt $wancount ]; do 
	group=$(query_config group $i)
	ifname=$(query_config ifname $group)
	ipaddr=$(query_config ipaddr $group)
	gateway=$(query_config gateway $group)

	if [ "$ifname" == "x" -o "$ipaddr" == "x" -o "$gateway" == "x" ]; then
	    failover add $group
	fi
    done
}

wancount=0
max_interval=$(((1<<31) - 1))

config_load "multiwan"
config_get_bool	enabled	config	enabled '1'
[ "$enabled" -gt 0 ] || stop exit
config_get default_route	config default_route
config_get health_monitor	config health_monitor
config_get iptables_interval	config iptables_interval '30'
config_get debug		config debug

[ "$health_monitor" = 'serial' ] || health_monitor='parallel'

config_foreach acquire_wan_data interface

update_cache

CHKFORQOS=$(iptables -n -L Default -t mangle 2>&1 | grep "Chain Default")
#CHKFORMODULE=$(iptables -m statistic 2>&1 | grep -o "File not found")
CHKFORMODULE=$(iptables -m statistic 2>&1 | grep -o "No such file")

jobfile="/tmp/.mwan/jobqueue"
case $1 in
    agent)  main_init;;
    stop)  stop;;
    restart)  stop restart;;
    single)  stop single;;
esac
