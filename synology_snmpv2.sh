#!/bin/bash

# https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_MIB_Guide.pdf
#This script pulls various information from the Synology NAS

# Set capture intervals in seconds. For instance interval of 10  will be 6 times in a minute.  
# Do not recommend more frequent than 10 seconds with between 15 or 20 being ideal. Set it higher than 60 then not sure what to tell you.
capture_interval=20

#############
# NAS Details
#############
nas_url="localhost" # url/IP to the NAS itself. Leave as localhost if running the script locally
nas_name=""  # nas_name Tag sent to influx. Leave empty to pull from the NAS (SNMP configuration>Device Name). Otherwise provide a custom name if desired

###############
# SNMP Settings
###############
snmp_version="3" # Version 3 is default but can be provided as 2c. 3 is recommended and required more details below
# IF USING VERSION 3, FILL IN CREDENTIALS AND CONFIGURATION BELOW FROM SYNOLOGY NAS
snmp_user=""
snmp_password=""
snmp_protocol="" #Can be MD5 or SHA, recommend SHA
snmp_privacy_protocol="" #Can be DES or AES, recommend AES
snmp_privacy_password=""

#################
# Influx Settings
#################
influxdb_method="" #Setting for https or http URL, default for influx is http and thus 'http'. Set to 'https' if using a secure port such as through a Reverse Proxy
influxdb_host="" #URL/IP for influxdb
influxdb_port="" #Port influxdb is running on
influxdb_org=""
influxdb_bucket="" #influxdb database name, default telegraf
influxdb_token=""

function Help()
{
	# Display Help
	echo
	echo "Script for capturing SNMP data from Synology NAS to Influxdb"
	echo
	echo "Syntax: scriptName.sh [-h|a|s|c|m|n|v|d|e|u|t|q]"
	echo
	echo "General options:"
	echo "-h    Display this help information"
	echo
	echo "Measurements Capture Options:"
	echo "-a    Full stats capture"
	echo "-s    System stats like model information, temperature, update status"
	echo "-c    CPU Usage stats"
	echo "-m    Memory stats like total, used free and cached"
	echo "-n    Network interface(s) Rx/Tx stats"
	echo "-v    Volume statistics, this is similar to raid but is not a Synology MIB but HOST-RESOURCES-MIB"
	echo "-d    Disk specific stats such as model, type, reads, writes, load and temperature"
	echo "-e    Service stats such as the service and connection count"
	echo "-u    UPS status such as runtime, status and charge level. If no UPS configured will silently continue"
   	echo 
	echo "Execution Options:"
	echo "-t	Test the capture but do not output to influx"
	echo "-o	Gather metrics only once, can be paired with"
	echo "-f	Full output of measurements and request results to influx"
	echo "-q	Supress all outputs, defaults to basic summary of request results to influx"
	echo
	echo "Examples:"
	echo "script.sh -aq (Capturere all SNMP measurements to influx and hide all output)"
	echo "script.sh -scmt (Gather System, CPU and Memory measurements and output measurements but not submit to influx)"
	echo
}

function singleObjects()
{
	
	#function for where there is a single object entry for the given MIB e.g. uptime or ModelName
	fields=""
	
	measurement=$1
	mib=$2
    [[ $3 ]] && filter=$3 || filter='' # Grep filter that is blank if no filter

	while IFS= read -r line; do
	  oid_name=$(echo $line | cut -d. -f1)
	  oid_value=$(cut -d ' ' -f2- <<<"$line")
	  fields+=",$oid_name=$oid_value"
    done < <($snmp_url $mib -OqsU | grep "$filter")

    measurements+="$measurement,nas_name=$nas_name ${fields#,}\n"

}

function multipleObjects()
{
    measurement=$1
    mib=$2
    [[ $3 ]] && filter=$3 || filter='' # Grep filter that is blank if no filter
    tag_name=$4
    mib_tables=("${!5}")  #array of MIB tables.

    declare -a object_info
    while IFS= read -r line; do

        id=$(cut -d. -f2 <<<"$line" | cut -d ' ' -f1)
        object_name=$(cut -d ' ' -f2- <<<"$line" | sed -e 's/ /\\ /g' -e 's/"//g')
        if [[ "$mib" == "SYNOLOGY-STORAGEIO-MIB::storageIODevice" ]]
        then # Special consideration to change name of storage to match disk name, grr synology
            object_name=$(sed -e 's/sata/\Disk\\ /g' -e 's/nvme0n/Cache\\ device\\ /' <<< $object_name)
        fi
        object_info+=([$id]=$object_name)

    done < <($snmp_url $mib -Oqs | grep "$filter")

    #Got the primary MIB withouth table array
    parent_mib=$(cut -d: -f1 <<<"$mib")

    for id in "${!object_info[@]}"
    do
        object_name=${object_info[$id]}
        fields=""

        for table in "${mib_tables[@]}"
        do
            result=$($snmp_url $parent_mib::$table.$id -OqvU)
            fields+=",$table=$result"
        done

        measurements+="$measurement,nas_name=$nas_name,$tag_name=${object_info[$id]} ${fields#,}\n"

    done
}

function getMeasurement()
{
	for measurement in "$@"; do
        
		if [[ $measurement == "sys" ]]; then #System Measurement
			singleObjects system_synology "HOST-RESOURCES-MIB::hrSystemUptime" #Uptime
			singleObjects system_synology "SYNOLOGY-SYSTEM-MIB::synoSystem" #System stats

		elif [[ $measurement == "cpu" ]]; then #CPU measurement
			singleObjects cpu_synology "UCD-SNMP-MIB::systemStats" "CpuRaw\|CpuNum"

		elif [[ $measurement == "mem" ]]; then #Memory measurement
			singleObjects memory_synology "UCD-SNMP-MIB::memory" "Real\.\|Free\.\|Buffer\.\|Cached\."

		elif [[ $measurement == "net" ]]; then #Network measurement
			mib_tables=(ifHCInOctets ifHCOutOctets)
			multipleObjects network_synology "IF-MIB::ifName" "eth\|bond" "interface_name" mib_tables[@]

		elif [[ $measurement == "vol" ]]; then #Volume measurement
			mib_tables=(raidStatus raidFreeSize raidTotalSize)
			multipleObjects volume_synology "SYNOLOGY-RAID-MIB::raidName" "Volume" "volume_name" mib_tables[@]

		elif [[ $measurement == "dsk" ]]; then # Disk measurement
			mib_tables=(diskModel diskType diskTemperature diskHealthStatus diskRole)
			multipleObjects disk_synology "SYNOLOGY-DISK-MIB::diskID" "" "disk_name" mib_tables[@] #Disk base info
			mib_tables=(storageIONReadX storageIONWrittenX storageIOLA)
			multipleObjects disk_synology "SYNOLOGY-STORAGEIO-MIB::storageIODevice" "" "disk_name" mib_tables[@] #Disk performance stats

		elif [[ $measurement == "ser" ]]; then #Service measurement
			mib_tables=(serviceUsers)
			multipleObjects services_synology "SYNOLOGY-SERVICES-MIB::serviceName" "" "service_name" mib_tables[@]

		elif [[ $measurement == "ups" ]]; then #UPS measurement
			#Check for connected UPS, if one gather metrics
			ups_check=$($snmp_url SYNOLOGY-UPS-MIB::upsInfoStatus.0 -Oqv) 
			if ! grep -q "No Such Instance currently exists at this OID" <<< "$ups_check"
			then
				#The Synology UPS mib does not quote strings like their other MIB that have string values.
    			singleObjects ups_synology "SYNOLOGY-UPS-MIB::synoUPS" "DeviceModel\|ChargeValue\|LoadValue\|InfoStatus\|PowerNominal\|RuntimeValue"
			fi
		fi

	done

}

#Check for Args being passed and exit if none passed, validation is done later
[[ ${#@} == 0 ]] && { echo "No arguments provided, use -h to view options"; exit 1; } 

#Set any excecution variables to be used throughout execution, saves constant evaluation later
if grep -q 't' <<< ${@}; then is_test=true; fi #Run the script without submitting to influx
if grep -q 'o' <<< ${@}; then is_once=true; fi #Run the captures once, regardless of configured capture interval
if grep -q 'f' <<< ${@}; then is_verbose=true; fi #Output all information, i.e. verbose
if grep -q 'a' <<< ${@}; then is_all=true; fi #Capture all measurements


#Build the SNMP url before any commands
if [[ $snmp_version == "3" ]]; then
	snmp_url="snmpwalk -Ot -c public \
            -v 3 \
			-l authPriv \
			-u $snmp_user \
			-a $snmp_protocol \
            -A $snmp_password \
			-x $snmp_privacy_protocol \
			-X $snmp_privacy_password \
			$nas_url"
else
    snmp_url="snmpwalk -c public \
	        -v 2c \
			$nas_url"
fi


# Getting NAS hostname from NAS if it was not manually set
if [[ -z $nas_name ]]; then
    nas_name=$($snmp_url SNMPv2-MIB::sysName.0 -Ovqt) #MIB for Hostname detailss
fi


#loop the script based upon capture interval or -o flag
if [[ $is_once ]]; then
	total_executions=1
else
	total_executions=$(( 60 / $capture_interval))
fi

if [[ -z $is_verbose ]]; then
	echo "Capturing $total_executions time(s)"
fi

i=0
while [ $i -lt $total_executions ]; do

    #Set measurements to empty value
    measurements=""

    if [[ $is_all ]]; then
        getMeasurement "sys" "cpu" "mem" "net" "vol" "dsk" "ser" "ups"
    else
        while getopts ":hascmnvdeutfqo" option; do
            case $option in
                h)  Help # display Help
                    exit;;
                s) getMeasurement "sys";; #System measurements
                c) getMeasurement "cpu";; #CPU measurements
                m) getMeasurement "mem";; #Memory measurements
                n) getMeasurement "net";; #Network measurements
                v) getMeasurement "vol";; #Volume measurements
                d) getMeasurement "dsk";; #Disk measurements
                e) getMeasurement "ser";; #Service measurements
                u) getMeasurement "ups";; #UPS measurements
                \?) echo "Error: Invalid option -${OPTARG}, -h for help" # Invalid option
                    exit;;
            esac
        done
        OPTIND=1 #Reset the getopts index for next loop
    fi

	# Testing or verbose flag to output measurements
	if [[ $is_test ]] || [[ $is_verbose ]]; then
		echo -e $measurements
	fi

    if [[ ! $is_test ]]; then
        post_url="$influxdb_method://$influxdb_host/api/v2/write?org=$influxdb_org&bucket=$influxdb_bucket&precision=ms"
        curl --request POST $post_url \
             --header "Content-Type: text/plain; charset=utf-8" \
             --header "Authorization: Token $influxdb_token" \
             --header "Accept: application/json" \
             --data-binary "$(echo -e $measurements)"
    fi

	# Incrementing counter for executions
	let i=i+1

	#Sleeping for capture interval unless its last capture then we dont sleep
	if (( $i < $total_executions)); then
		sleep $capture_interval
	fi
	
done
