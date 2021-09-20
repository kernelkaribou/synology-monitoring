#!/bin/bash

#This script pulls various information from the Synology NAS
#Edit /etc/crontab then restart, synoservice -restart crond

#Metrics to capture, set to false if you want to skip that specific set
capture_system="true" #model information, temperature, update status, 
capture_memory="true" #information about memory stats
capture_cpu="true" #CPU usage
capture_volume="true" #Volume statistics, this is similar to raid but is not a Synology MIB
capture_raid="true" #Synology volume/raid statistics.  Preferred stats as they are syno specific.
capture_disk="true" #disk specific stats such as model, type, reads, writes, load and temperature
capture_ups="false" #get UPS status such as runtime, status and charge level. Default false as it will fail if no UPS is configured.
capture_network="true" #Get network stats, Rx and Tx

#Set capture intervals in seconds. Tor instance 10 which will be 6 times in a minute.  Do not recommend more frequent than 10 seconds with between 15-20 being ideal. Set it higher than 60 and you are an idiot
capture_interval=20

#NAS DETAILS
nas_url="localhost" #url/IP to the NAS itself. Since it is likely running on the NAS just leave it to localhost
nas_name=""  #Leave empty if you want to get the name from the NAS itself, otherwise provide a custom name
ups_group="NAS" #For filtering metrics if more than one UPS, only necessary if capturing ups stats is enabled

#INFLUXDB SETTINGS
influxdb_host="127.0.0.1" #URL/IP for influxdb
influxdb_port="8086" #Port influxdb is running on
influxdb_name="telegraf" #influxdb database name, default telegraf
influxdb_user="" #influxdb user, leave blank if you do not have an influxdb user, shame on you.
influxdb_pass="" #influxdb password

#HTTP METHOD SETTINGS
http_method="http" #Setting for https or http URL, default for influx is http and thus 'http'. Set to 'https' if using a secure port such as through a Reverse Proxy

# Getting NAS hostname from NAS if it was not manually set
if [[ -z $nas_name ]]; then
	nas_name=`snmpwalk -c public -v 2c $nas_url SNMPv2-MIB::sysName.0 -Ovqt`
fi

#loop the script 
total_executions=$(( 60 / $capture_interval))
echo "Capturing $total_executions times"
i=0
while [ $i -lt $total_executions ]; do
	
	#Create empty URL
	post_url=

	#GETTING VARIOUS SYSTEM INFORMATION
	if (${capture_system,,} = "true"); then
		
		measurement="synology_system"
		
		#System uptime
		system_uptime=`snmpwalk -c public -v 2c $nas_url HOST-RESOURCES-MIB::hrSystemUptime.0 -Ovt`
		
		#System Status,  1 is online, 0 is failed/offline
		system_status=`snmpwalk -v 2c -c public $nas_url SYNOLOGY-SYSTEM-MIB::systemStatus.0 -Oqv`
		
		#Fan status1 is online, 0 is failed/offline
		system_fan_status=`snmpwalk -c public -v 2c $nas_url SYNOLOGY-SYSTEM-MIB::systemFanStatus.0 -Oqv`
		
		#Various SYNOLOGY-SYSTEM stats for common OID
		while IFS= read -r line; do
		
		    if [[ $line == SYNOLOGY-SYSTEM-MIB::modelName.0* ]]; then 
		    	model=${line/"SYNOLOGY-SYSTEM-MIB::modelName.0 = STRING: "/}
		    	#model=${line#*'"'}; model=${model%'"'*}
			
			elif [[ $line == SYNOLOGY-SYSTEM-MIB::serialNumber.0* ]]; then
		    	serial=${line/"SYNOLOGY-SYSTEM-MIB::serialNumber.0 = STRING: "/}
			
			elif [[ $line == SYNOLOGY-SYSTEM-MIB::upgradeAvailable.0* ]]; then
			   	upgrade=${line/SYNOLOGY-SYSTEM-MIB::upgradeAvailable.0 = INTEGER: /}
			
			elif [[ $line == SYNOLOGY-SYSTEM-MIB::version.0* ]]; then
		    	version=${line/"SYNOLOGY-SYSTEM-MIB::version.0 = STRING: "/}
		    
		    fi
		done < <(snmpwalk -c public -v 2c $nas_url 1.3.6.1.4.1.6574.1.5) #Parent OID for SYNOLOGY-SYSTEM-MIB
		
		# synology NAS Temperature
		system_temp=`snmpwalk -v 2c -c public $nas_url 1.3.6.1.4.1.6574.1.2 -Oqv`
		
		#System details to post
		post_url=$post_url"$measurement,nas_name=$nas_name uptime=$system_uptime,system_status=$system_status,fan_status=$system_fan_status,model=$model,serial_number=$serial,upgrade_status=$upgrade,dsm_version=$version,system_temp=$system_temp
"
	else
		echo "Skipping system capture"
	fi
	
	
	# GETTING MEMORY STATS
	if (${capture_memory,,} = "true"); then
		
		measurement="synology_memory"
		
		#Various Memory stats for common Memory OID 
		while IFS= read -r line; do
		
			# Calculation for used percent
			# ($mem_total - $mem_avail_real - $mem_buffer - $mem_cached)/$mem_total) * 100")
		
		    if [[ $line == UCD-SNMP-MIB::memTotalReal.0* ]]; then
		    	mem_total=${line/"UCD-SNMP-MIB::memTotalReal.0 = INTEGER: "/}
		    	mem_total=${mem_total/" kB"/}
		
		    elif [[ $line == UCD-SNMP-MIB::memAvailReal.0* ]]; then
		    	mem_avail_real=${line/"UCD-SNMP-MIB::memAvailReal.0 = INTEGER: "/}
		    	mem_avail_real=${mem_avail_real/" kB"/}
		
		    elif [[ $line == UCD-SNMP-MIB::memBuffer.0* ]]; then
		    	mem_buffer=${line/"UCD-SNMP-MIB::memBuffer.0 = INTEGER: "/}
		    	mem_buffer=${mem_buffer/" kB"/}
		
		    elif [[ $line == UCD-SNMP-MIB::memCached.0* ]]; then
		    	mem_cached=${line/"UCD-SNMP-MIB::memCached.0 = INTEGER: "/}
		    	mem_cached=${mem_cached/" kB"/}
			
			elif [[ $line == UCD-SNMP-MIB::memTotalFree.0* ]]; then
		    	mem_free=${line/"UCD-SNMP-MIB::memTotalFree.0 = INTEGER: "/}
		    	mem_free=${mem_free/" kB"/}
		
			fi
			
		done < <(snmpwalk -c public -v 2c $nas_url 1.3.6.1.4.1.2021.4) #Parent OID for UCD-SNMP-MIB Memory stats
	
		post_url=$post_url"$measurement,nas_name=$nas_name mem_total=$mem_total,mem_avail_real=$mem_avail_real,mem_buffer=$mem_buffer,mem_cached=$mem_cached,mem_free=$mem_free
"
	else
		echo "Skipping memory capture"
	fi
	
	
	# GETTING CPU USAGE
	if (${capture_cpu,,} = "true"); then
		
		# UCD-SNMP-MIB::ssCpuIdle.0 = INTEGER: 93
		measurement="synology_cpu"
		usage_idle=`snmpwalk -c public -v 2c $nas_url UCD-SNMP-MIB::ssCpuIdle.0 -Oqv`
		post_url=$post_url"$measurement,nas_name=$nas_name usage_idle=$usage_idle
"
	else
		echo "Skipping CPU capture"
	fi
	
	
	# GETTING VOLUME information based upon the SYNOLOGY-RAID-MIB it is basically the summarized version of what information we want.
	if (${capture_volume,,} = "true"); then
		measurement="synology_volume"
		
		while IFS= read -r line; do
			
			if [[ $line =~ "/volume"+([0-9]$) ]]; then
				id=${line/"HOST-RESOURCES-MIB::hrStorageDescr."/}; id=${id%" = STRING:"*}
				vol_name=${line#*STRING: }
				
				# Allocation units for volume in bytes (typically 4096)
				vol_blocksize=`snmpwalk -v 2c -c public $nas_url HOST-RESOURCES-MIB::hrStorageAllocationUnits.$id -Ovq | awk {'print $1'}`
				
				# Total Volume Size is size before being multipled by allocation units
				vol_totalsize=`snmpwalk -v 2c -c public $nas_url HOST-RESOURCES-MIB::hrStorageSize.$id -Oqv`
				
				# Volume Usage
				vol_used=`snmpwalk -v 2c -c public $nas_url HOST-RESOURCES-MIB::hrStorageUsed.$id -Oqv`
				
				# Need to actually convert the sizes provided by their allocation unit, leaving in bytes format
				# Calculation to TB is =(vol_totalsize*vol_blocksize)/1024/1024/1024/1024
				vol_totalsize=$(($vol_totalsize * $vol_blocksize))
				vol_used=$(($vol_used * $vol_blocksize))
				post_url=$post_url"$measurement,nas_name=$nas_name,volume=$vol_name vol_totalsize=$vol_totalsize,vol_used=$vol_used
"
		
			fi
		done < <(snmpwalk -c public -v 2c $nas_url 1.3.6.1.2.1.25.2.3.1.3)
	
	else
		echo "Skipping volume capture"
	fi
	
	
	#GETTING RAID INFO
	if (${capture_raid,,} = "true"); then
		measurement="synology_raid"
		
		raid_info=()
		
		while IFS= read -r line; do
			
			id=${line/"SYNOLOGY-RAID-MIB::raidName."/}; id=${id%" = STRING:"*}
			raid_name=${line#*STRING: };raid_name=${raid_name// /};raid_name=${raid_name//\"}
			raid_info+=([$id]=$raid_name)
		
		done< <(snmpwalk -v 2c -c public localhost SYNOLOGY-RAID-MIB::raidName)
		
		for id in "${!raid_info[@]}"
		do
		
			while IFS= read -r line; do
			
			raid_name=${raid_info[$id]}
			
			if [[ $line == SYNOLOGY-RAID-MIB::raidStatus.$id* ]]; then
				raid_status=${line/"SYNOLOGY-RAID-MIB::raidStatus."$id" = INTEGER: "/}
			fi
			
			if [[ $line == SYNOLOGY-RAID-MIB::raidFreeSize.$id* ]]; then
				raid_free_size=${line/"SYNOLOGY-RAID-MIB::raidFreeSize."$id" = Counter64: "/}
			fi
			
			if [[ $line == SYNOLOGY-RAID-MIB::raidTotalSize.$id* ]]; then
				raid_total_size=${line/"SYNOLOGY-RAID-MIB::raidTotalSize."$id" = Counter64: "/}
			fi
		
			done < <(snmpwalk -c public -v 2c $nas_url 1.3.6.1.4.1.6574.3.1.1)
		
			post_url=$post_url"$measurement,nas_name=$nas_name,raid_name=$raid_name raid_status=$raid_status,raid_free_size=$raid_free_size,raid_total_size=$raid_total_size
"
		done
		
	else
		echo "Skipping RAID capture"
	fi
	
	
	#GETTING DISK INFO
	if (${capture_disk,,} = "true"); then
		measurement="synology_disk"
		
		disk_info=()
		
		while IFS= read -r line; do
			
			id=${line/"SYNOLOGY-DISK-MIB::diskID."/}; id=${id%" = STRING:"*}
			disk_name=${line#*STRING: }; disk_name=${disk_name// /};disk_name=${disk_name//\"}
			disk_info+=([$id]=$disk_name)
		
		done< <(snmpwalk -v 2c -c public localhost SYNOLOGY-DISK-MIB::diskID)
		
		for id in "${!disk_info[@]}"
		do
		
			while IFS= read -r line; do
			
			disk_name=${disk_info[$id]}
			
			if [[ $line == SYNOLOGY-DISK-MIB::diskModel.$id* ]]; then
				disk_model=${line/"SYNOLOGY-DISK-MIB::diskModel."$id" = STRING: "/}; disk_model=${disk_model// /}
			fi
			
			if [[ $line == SYNOLOGY-DISK-MIB::diskType.$id* ]]; then
				disk_type=${line/"SYNOLOGY-DISK-MIB::diskType."$id" = STRING: "/}
			fi
			
			if [[ $line == SYNOLOGY-DISK-MIB::diskStatus.$id* ]]; then
				disk_status=${line/"SYNOLOGY-DISK-MIB::diskStatus."$id" = INTEGER: "/}
			fi
		
			if [[ $line == SYNOLOGY-DISK-MIB::diskTemperature.$id* ]]; then
				disk_temp=${line/"SYNOLOGY-DISK-MIB::diskTemperature."$id" = INTEGER: "/}
			fi
			
			done < <(snmpwalk -c public -v 2c $nas_url 1.3.6.1.4.1.6574.2.1.1)
		
			post_url=$post_url"$measurement,nas_name=$nas_name,disk_name=$disk_name disk_model=$disk_model,disk_type=$disk_type,disk_temp=$disk_temp,disk_status=$disk_status
"
		
		done
		
		#GETTING Disk IO STATS
		disk_info=()
		
		while IFS= read -r line; do
		
				id=${line/"SYNOLOGY-STORAGEIO-MIB::storageIODevice."/}; id=${id%" = STRING:"*}
				disk_path=${line#*STRING: };
				disk_info+=([$id]=$disk_path)
		
		done< <(snmpwalk -v 2c -c public localhost SYNOLOGY-STORAGEIO-MIB::storageIODevice)
		
		for id in "${!disk_info[@]}"
		do
			disk_path="/dev/"${disk_info[$id]}
			
			while IFS= read -r line; do
				if [[ $line == "SYNOLOGY-STORAGEIO-MIB::storageIONReadX.$id "* ]]; then
					disk_reads=${line/"SYNOLOGY-STORAGEIO-MIB::storageIONReadX."$id" = Counter64: "/};
				fi
		
				if [[ $line == "SYNOLOGY-STORAGEIO-MIB::storageIONWrittenX.$id "* ]]; then
					disk_writes=${line/"SYNOLOGY-STORAGEIO-MIB::storageIONWrittenX."$id" = Counter64: "/}
				fi
		
				if [[ $line == "SYNOLOGY-STORAGEIO-MIB::storageIOLA.$id "* ]]; then
					disk_load=${line/"SYNOLOGY-STORAGEIO-MIB::storageIOLA."$id" = INTEGER: "/}
				fi
			done< <(snmpwalk -v 2c -c public localhost 1.3.6.1.4.1.6574.101)
			
			post_url=$post_url"$measurement,nas_name=$nas_name,disk_path=$disk_path disk_reads=$disk_reads,disk_writes=$disk_writes,disk_load=$disk_load
"
		
		done
	else
		echo "Skipping Disk capture"
	fi
	
	
	#GETTING UPS STATUS
	if (${capture_ups,,} = "true"); then
		measurement="synology_ups"
		
		#UPS Battery charge level
		ups_battery_charge=`snmpwalk -v 2c -c public $nas_url SYNOLOGY-UPS-MIB::upsBatteryChargeValue.0 -Oqv`; ups_battery_charge=${ups_battery_charge%\.*}
		
		#UPS Load
		ups_load=`snmpwalk -v 2c -c public $nas_url SYNOLOGY-UPS-MIB::upsInfoLoadValue.0 -Oqv`;ups_load=${ups_load%\.*}
		
		#UPS State (OL is online, OL CHRG is plugged in but charging, OL DISCHRG is on battery")
		ups_status=`snmpwalk -v 2c -c public $nas_url SYNOLOGY-UPS-MIB::upsInfoStatus.0 -Oqv`; ups_status=${ups_status//\"}
		
		if [[ $ups_status == "OL" ]];
		    then
		        ups_status=1
		elif [[ $ups_status == "OL CHRG" ]];
		    then
		        ups_status=2
		elif [[ $ups_status == "OL DISCHRG" ]];
		    then
		        ups_status=3
		elif [[ $ups_status == "FSD OL" ]];
		    then
		        ups_status=4
		elif [[ $ups_status == "FSD OB LB" ]];
		    then
		        ups_status=5
		elif [[ $ups_status == "OB" ]];
		    then
		        ups_status=6
		fi
		
		#Battery Runtime
		ups_battery_runtime=`snmpwalk -c public -v 2c $nas_url SYNOLOGY-UPS-MIB::upsBatteryRuntimeValue.0 -Oqv | awk {'print $1'}`
		
		post_url=$post_url"$measurement,nas_name=$nas_name,ups_group=$ups_group ups_status=$ups_status,ups_load=$ups_load,ups_battery_runtime=$ups_battery_runtime,ups_battery_charge=$ups_battery_charge
"
	else
		echo "Skipping UPS capture"
	fi
	
	
	#GETTING NETWORK STATS
	if (${capture_network,,} = "true"); then
		measurement="synology_network"
		
		network_info=()
		
		while IFS= read -r line; do
		
				id=${line/"IF-MIB::ifName."/}; id=${id%" = STRING:"*}
				interface_name=${line#*STRING: };
				network_info+=([$id]=$interface_name)
		
		done< <(snmpwalk -v 2c -c public localhost IF-MIB::ifName | grep -E 'eth*|bond*')
		
		for id in "${!network_info[@]}"
		do
			interface_name=${network_info[$id]}
			
			while IFS= read -r line; do
				if [[ $line =~ "IF-MIB::ifHCInOctets.$id =" ]]; then
					bytes_recv=${line/"IF-MIB::ifHCInOctets."$id" = Counter64: "/};
				fi
		
				if [[ $line =~ "IF-MIB::ifHCOutOctets.$id =" ]]; then
					bytes_sent=${line/"IF-MIB::ifHCOutOctets."$id" = Counter64: "/};
				fi
		
			done< <(snmpwalk -v 2c -c public localhost 1.3.6.1.2.1.31.1.1.1)
			
			post_url=$post_url"$measurement,nas_name=$nas_name,interface_name=$interface_name bytes_recv=$bytes_recv,bytes_sent=$bytes_sent
"	
		done
		
	else
		echo "Skipping Network capture"
	fi
	
	#Post to influxdb
	if [[ -z $influxdb_user ]]; then
		curl -i -XPOST "$http_method://$influxdb_host:$influxdb_port/write?db=$influxdb_name" --data-binary "$post_url"
	else
		curl -i -XPOST "$http_method://$influxdb_host:$influxdb_port/write?db=$influxdb_name&u=$influxdb_user&p=$influxdb_pass" --data-binary "$post_url"
	fi
	echo "$post_url"
	
	let i=i+1
	
	echo "Capture #$i complete"
	
	#Sleeping for capture interval unless its last capture then we dont sleep
	if (( $i < $total_executions)); then
		sleep $capture_interval
	fi
	
done
