#!/bin/bash

#v.0.3          - adding --do-not-reboot
#v.0.2          - adding --skip_safety_checks
#v.0.1.12       - adding removing of downloaded packages
#v.0.1.11

KEEPALIVED_CONFIG_FILE=/etc/keepalived/keepalived.conf
HAPROXY_CONFIG_FILE=/etc/haproxy/haproxy.cfg
WAITING_AFTER_STOPPING_KEEPALIVED=4
DO_NOT_REBOOT=false
THINGS_TO_DO_TO_PATCH="apt-get -qq -y update;apt-get -qq -y upgrade; apt-get -qq -y autoremove; apt-get -qq -y dist-upgrade; apt-get -qq -y autoremove; apt-get -qq -y clean"
#if DO_NOT_REBOOT is not set later then ";shutdown -r now" will be appended to the above
THINGS_TO_DO_TO_REBOOT="shutdown -r now"

VERBOSE=true
FORCE_TO_DO_IT_TODAY=false
FORCE_TO_DO_IT_NOW=false
MAINTENANCE_DAY=3
MAINTENANCE_WINDOW_START=11:00
MAINTENANCE_WINDOW_END=16:00
SKIP_SAFETY_CHECKS=false


declare -a KEEPEALIVED_VIPS


while [ ! -z "${1}"  ]
do
        case ${1} in
                "--do-not-reboot")      DO_NOT_REBOOT=true;;
                "--skip_safety_checks") SKIP_SAFETY_CHECKS=true;;
                "--quiet")              VERBOSE=false;;
                "--verbose")            VERBOSE=true;;
                "--today")              FORCE_TO_DO_IT_TODAY=true;;
                "--now")                FORCE_TO_DO_IT_NOW=true;;
                "--start")              shift; MAINTENANCE_WINDOW_START=${1};;
                "--end")                shift; MAINTENANCE_WINDOW_END=${1};;
        esac
        shift
done

TMP_FILE_1=/tmp/`basename ${0}`.$$.1.tmp
TMP_FILE_2=/tmp/`basename ${0}`.$$.2.tmp
TMP_FILE_3=/tmp/`basename ${0}`.$$.3.tmp
TMP_FILE_4=/tmp/`basename ${0}`.$$.4.tmp
TMP_FILE_VRRP=/tmp/`basename ${0}`.$$.vrrp.tmp
TMP_FILE_VIP=/tmp/`basename ${0}`.$$.vip.tmp

if ! ${DO_NOT_REBOOT}
then
        THINGS_TO_DO_TO_PATCH="${THINGS_TO_DO_TO_PATCH}; shutdown -r now"
fi




clean_up () {
        rm -f ${TMP_FILE_1}
        rm -f ${TMP_FILE_2}
        rm -f ${TMP_FILE_3}
        rm -f ${TMP_FILE_4}
        rm -f ${TMP_FILE_VRRP}
        rm -f ${TMP_FILE_VIP}
}



is_this_valid_ip_address () {
        #4 non-empty '.' separated segments
        for SEGMENT_NO in `seq 1 4`
        do
                SEGMENT=`echo ${1} | cut -d'.' -f1`
                if [ -z "${SEGMENT}" ]
                then
                        return 1
                fi

                #of digits
        done

        return 0

}



deal_breaker () {
        local EXIT_CODE
        #not_maintenance_window
        #error
        #wrong_host

        case $1 in
                not_maintenance_window) EXIT_CODE=1;;
                error)  EXIT_CODE=2;;
                wrong_host)     EXIT_CODE=0;;
                *)      EXIT_CODE=3;;
        esac

        shift

        echo `date '+%Y-%m-%d %H:%M:%S'` ${*} >&2
        clean_up
        exit ${EXIT_CODE}
}



notify () {
        if ${VERBOSE}
        then
                shift
                echo `date '+%Y-%m-%d %H:%M:%S'` ${*}
        fi
}



process_virtual_ipaddress_section () {
        local VIP


        mv ${TMP_FILE_VIP} ${TMP_FILE_3}

        for VIP in `cat ${TMP_FILE_3} | cut -d' ' -f1`
        do
                if ! is_this_valid_ip_address ${VIP}
                then
                        deal_breaker error "the \"${VIP}\" does not look like valid IP address"
                else
                        notify VERBOSE check passed: the \"${VIP}\" looks like valid IP address
                fi

                KEEPEALIVED_VIPS[${#KEEPEALIVED_VIPS[*]}]=${VIP}

        done

}



process_vrrp_instance_section () {
        local START_LINE
        local END_LINE
        local VIPASA

        mv ${TMP_FILE_VRRP} ${TMP_FILE_2}

        VIPASA=`cat ${TMP_FILE_2} | grep -c -w virtual_ipaddress`
        if [ "${VIPASA}" != "1" ]
        then
                deal_breaker error "more than one virtual_ipaddress in vrrp_instance section"
        fi

        START_LINE=`cat ${TMP_FILE_2} | grep -n -w virtual_ipaddress | cut -d':' -f1`

        if [ -z "${START_LINE}" ]
        then
                deal_breaker error "not found the line with the virtual_ipaddress section beginning"
        fi

        END_LINE=`cat ${TMP_FILE_2} | sed -n "${START_LINE},$ p" | grep -n -w "}" | cut -d':' -f1 | head -n 1`

        if [ -z "${END_LINE}" ]
        then
                deal_breaker error "not found the line with the virtual_ipaddress section ending"
        fi
        END_LINE=$((END_LINE+START_LINE-2))
        START_LINE=$((START_LINE+1))

        cat ${TMP_FILE_2} | sed -n "${START_LINE},${END_LINE} p" > ${TMP_FILE_VIP}
        process_virtual_ipaddress_section

}




get_server_type () {
        local KEEPALIVED_ROLE
        local TYPE=unknown

        if [ -e ${KEEPALIVED_CONFIG_FILE} ]
        then

                case `cat ${KEEPALIVED_CONFIG_FILE} | tr '      ' ' ' | tr -s ' ' | sed 's/^ //g' | grep -v '^#' | grep '^state ' | cut -d' '  -f2 | sort -u` in
                        SLAVE)  TYPE=KEEPALIVED_SLAVE;;
                        MASTER)
                                if cat ${HAPROXY_CONFIG_FILE} | tr '    ' ' ' | tr -s ' ' | grep -v '^#' | grep -q ':5672'
                                then
                                        #unsupported till we have applications that handle VIP failover nicely
                                        TYPE=KEEPALIVED_MASTER_RABBITMQ
                                else
                                        TYPE=KEEPALIVED_MASTER
                                fi

                esac

        fi

        echo ${TYPE}

}



PENDING_UPDATES=`/usr/lib/update-notifier/apt-check 2>&1`
if [ "${PENDING_UPDATES}" == "0;0" ]
then
        THERE_ARE_PENDING_PATCHES=false
else
        THERE_ARE_PENDING_PATCHES=true
fi

if [ -e /var/run/reboot-required ]
then
        REBOOT_IS_NEEDED=true
else
        REBOOT_IS_NEEDED=false
fi


if ! ${THERE_ARE_PENDING_PATCHES} && ! ${REBOOT_IS_NEEDED}
then
        notify VERBOSE "Nothing to do here;doing nothing then."
        exit 0
fi



SERVER_TYPE=`get_server_type`

notify VERBOSE SERVER_TYPE=${SERVER_TYPE}
notify VERBOSE VERBOSE=${VERBOSE}
notify VERBOSE MAINTENANCE_DAY=${MAINTENANCE_DAY}
notify VERBOSE FORCE_TO_DO_IT_TODAY=${FORCE_TO_DO_IT_TODAY}
notify VERBOSE FORCE_TO_DO_IT_NOW=${FORCE_TO_DO_IT_NOW}
notify VERBOSE MAINTENANCE_WINDOW_START=${MAINTENANCE_WINDOW_START}
notify VERBOSE MAINTENANCE_WINDOW_END=${MAINTENANCE_WINDOW_END}
notify VERBOSE SKIP_SAFETY_CHECKS=${SKIP_SAFETY_CHECKS}


if ! ${SKIP_SAFETY_CHECKS}
then
        case ${SERVER_TYPE} in
                KEEPALIVED_SLAVE)               MAINTENANCE_DAY=3;;
                KEEPALIVED_MASTER)              MAINTENANCE_DAY=4;;
                #KEEPALIVED_MASTER_RABBITMQ)    #unsupported till we have applications that handle VIP failover nicely
                *)
                        deal_breaker unsupported_server_type "This type of server is unknown/unsupported for automatic patching"
        esac
fi





if ! ${FORCE_TO_DO_IT_TODAY}
then
        TODAY_DOW=`date +%u`
        if [ "${TODAY_DOW}" != "${MAINTENANCE_DAY}" ]
        then
                deal_breaker not_maintenance_window "Today (${TODAY_DOW}) is not when it should be done (${MAINTENANCE_DAY}) - and no overwrite set"
        fi
fi

if ! ${FORCE_TO_DO_IT_NOW}
then
        NOW_SSE=`date +%s`
        START_SSE=`date -d ${MAINTENANCE_WINDOW_START} +%s`

        if [ "${NOW_SSE}" -gt "${START_SSE}" ]
        then
                notify VERBOSE already pass restart window start
        else
                STWRS=$((START_SSE-NOW_SSE))
                notify VERBOSE window restart start starts in ${STWRS} seconds .... waiting
                notify VERBOSE sleep ${STWRS}
                NOW_SSE=`date +%s`
        fi

        END_SSE=`date -d ${MAINTENANCE_WINDOW_END} +%s`

        if [ "${NOW_SSE}" -ge "${END_SSE}" ]
        then
                deal_breaker not_maintenance_window "too little of maintenance window left now, sorry"
        fi
        MWL=$((END_SSE-NOW_SSE))

        SMWINS=$((RANDOM % MWL))
        notify VERBOSE "waiting ${SMWINS} seconds before starting (to regulate the service ;) )"
        sleep ${SMWINS}

fi

if ! ${SKIP_SAFETY_CHECKS}
then

if [ ! -e "${KEEPALIVED_CONFIG_FILE}" ]
then
        deal_breaker wrong_host "${KEEPALIVED_CONFIG_FILE} does not exist"
else
        notify VERBOSE check passed: ${KEEPALIVED_CONFIG_FILE} exist
fi

if [ ! -r "${KEEPALIVED_CONFIG_FILE}" ]
then
        deal_breaker error "I cannot read ${KEEPALIVED_CONFIG_FILE}"
else
        notify VERBOSE check passed: ${KEEPALIVED_CONFIG_FILE} is readable by me
fi

cat ${KEEPALIVED_CONFIG_FILE} | tr '    ' ' ' | tr -s ' ' | sed 's/^ //g' | grep -v '^#' > ${TMP_FILE_1}

AMOUNT_OF_vrrp_instance=`cat ${TMP_FILE_1} | grep -v '^#' | grep -c -w vrrp_instance`
if [ "${AMOUNT_OF_vrrp_instance}" -gt '0' ]
then
        notify VERBOSE check passed: found some amount of vrrp_instance sections
else
        deal_breaker error "expected one vrrp_instance section, got ${AMOUNT_OF_vrrp_instance}"
fi

LINES_NOS=`cat ${TMP_FILE_1} | grep -n -w vrrp_instance | cut -d':' -f1`
if [ -z "${LINES_NOS}" ]
then
        deal_breaker error "not found the line with the vrrp_instance section beginning"
fi

START_LINE=""
for LINE_NO in `echo ${LINES_NOS}`
do
        if [ ! -z "${START_LINE}" ]
        then
                END_LINE=$((LINE_NO-1))
                cat ${TMP_FILE_1} | sed -n "${START_LINE},${END_LINE} p" > ${TMP_FILE_VRRP}
                process_vrrp_instance_section
        fi

        START_LINE=${LINE_NO}

done

if [ -z "${START_LINE}" ]
then
        deal_breaker error "not found the line with the vrrp_instance section beginning"
else
        END_LINE='$'
        cat ${TMP_FILE_1} | sed -n "${START_LINE},${END_LINE} p" > ${TMP_FILE_VRRP}
        process_vrrp_instance_section
fi




for NO in `seq 0 $((${#KEEPEALIVED_VIPS[*]}-1))`
do
        VIP=${KEEPEALIVED_VIPS[${NO}]}


        if ip address list | grep -q "${VIP}/32"
        then
                if [ "${SERVER_TYPE}" == "KEEPALIVED_MASTER" ]
                then
                        notify VERBOSE "stopping keepalived so slave would take the IP over and waiting ${WAITING_AFTER_STOPPING_KEEPALIVED} seconds"
                        service keepalived stop 1>/dev/null
                        sleep ${WAITING_AFTER_STOPPING_KEEPALIVED}
                        if ip address list | grep -q "${VIP}/32"
                        then
                                #the VIP is still here - probaly client failed - starting keepalived back and failing
                                service keepalived start 1>/dev/null
                                deal_breaker error "virtual IP ${VIP} IS present on the box - despite stopping keepalived here - started keepalived back"
                        else
                                if ! ping -c 1 ${VIP} 1>/dev/null
                                then
                                        #ping failed, maybe slave did not start the IP, failing back and failing
                                        service keepalived start 1>/dev/null
                                        deal_breaker error "ping to virtual IP (${VIP}), on slave failed, - maybe slave failed - started keepalived back"
                                else
                                        notify VERBOSE "it looks slave took over the virtual IP (${VIP}) - continuing"
                                fi
                        fi

                else
                        deal_breaker error "virtual IP ${VIP} IS present on the box"
                fi
        else
                notify VERBOSE "check passed: virtual IP ${VIP} not present on the box"
        fi
done




clean_up
notify VERBOSE all safety checks passed

fi



if ${THERE_ARE_PENDING_PATCHES}
then
        notify VERBOSE "there are pending updates (${PENDING_UPDATES})"
        notify VERBOSE "running:${THINGS_TO_DO_TO_PATCH}"
        bash -c "${THINGS_TO_DO_TO_PATCH}"
fi


if ${REBOOT_IS_NEEDED}
then
        notify VERBOSE "Reboot is needed"
        if ${DO_NOT_REBOOT}
        then
                notify VERBOSE "No rebooting requested, so ... no rebooting then"
        else
                notify VERBOSE "running:${THINGS_TO_DO_TO_REBOOT}"
                bash -c "${THINGS_TO_DO_TO_REBOOT}"
        fi
fi


exit 0

