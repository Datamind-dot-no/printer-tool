#!/bin/zsh

## printer_tool.zsh
# script to:
#  - remove legacy managed print queues,
#  - fetch printer settings for specified printer from AD using LDAP,
#  - delete old version of printer queue
#  - replace print queue with updated settings
#
# $1 parameter to specify unique printer designation, other (common) settings to be supplied in preferences for script domain
#
# prerequisites:
# - Logged in user must be a member of _lpadmin group, this is ensured by the postinstall script for this package
# - user must have kerberos ticket for ldapsearch

## Acknowledgements, these helped:
# https://blog.mobinergy.com/macos-deploying-printers/
# https://derflounder.wordpress.com/2017/07/18/generating-printer-configurations-using-payload-free_package_printer_generator-sh/
# https://www.macscripter.net/t/get-queue-name-from-printer-name/47466/8
# https://amsys.co.uk/mac-printing-scripts-mashup


DIR=$(dirname "${0:a}")
SCRIPT=$(basename "$0")

function log() {
    local timestamp=$(date +%Y-%m-%d\ %H:%M:%S%z)
    local message="$timestamp [$DIR/$SCRIPT] $1"
    echo "${message}"
    echo "${message}" >> /tmp/"${SCRIPT}"
}


# -----------------------------------------------------------------------------
# Open an AppleScript message window -
# thanks to Graham Pugh - https://github.com/grahampugh/erase-install/blob/legacy/erase-install.sh#L1155
# -----------------------------------------------------------------------------
open_osascript_dialog() {
    title="$1"
    message="$2"
    button1="$3"
    icon="$4"

    if [[ $message ]]; then
        /bin/launchctl asuser "$current_uid" /usr/bin/osascript <<-END
            display dialog "$message" ¬
            buttons {"$button1"} ¬
            default button 1 ¬
            with title "$title" ¬
            with icon $icon
END
    else
        /bin/launchctl asuser "$current_uid" /usr/bin/osascript <<-END
            display dialog "$title" ¬
            buttons {"$button1"} ¬
            default button 1 ¬
            with icon $icon
END
    fi
}


## settings - common ones are read from preference domain for this script
# (could be in a Configuration Profile)
PREF_DOMAIN="com.github.codeskipper.printer-tool"
COMPANY=$( defaults read ${PREF_DOMAIN} COMPANY )
PRINTER=$( defaults read ${PREF_DOMAIN} PRINTER )
LDAP_HOST=$( defaults read ${PREF_DOMAIN} LDAP_HOST )
LDAP_BASE=$( defaults read ${PREF_DOMAIN} LDAP_BASE )
PPD_DIR=$( defaults read ${PREF_DOMAIN} PPD_DIR )
PPD_NAME=$( defaults read ${PREF_DOMAIN} PPD_NAME )
DRIVER_DEFAULTS=$( defaults read ${PREF_DOMAIN} DRIVER_DEFAULTS )
PRINTER_PROTOCOL=$( defaults read ${PREF_DOMAIN} PRINTER_PROTOCOL )
REMOVE_LEGACY_MCX=$( defaults read ${PREF_DOMAIN} REMOVE_LEGACY_MCX )


# Remove any legacy Configuration Profile print queues that may linger
if [[ $REMOVE_LEGACY_MCX == "True" ]]; then
    for printer in $(lpstat -p | grep 'mcx_' | awk '{print $2}') ; do
        lpadmin -x "$printer"
        log "removed printer ${printer}"
    done
fi



# Check number of script arguments, need exactly one, the AD LDAP attribute printerName is searched for this
if [[ $# != 1 ]]; then
    log "This script needs exactly one parameter: the printer designation. \nFor instance to setup printer [${PRINTER} Houston] run:\n${DIR}/${SCRIPT} Houston\nBailing out."
    exit 1
fi
location=$1


# assert user is a member of _lpadmin group
# ToDo: implement check to assert user is a member of _lpadmin group
# Grab the currently logged in user to set the language for all dialogue messages
current_user=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}')
current_uid=$(/usr/bin/id -u "$current_user")


# assert contact with internal corporate network
# shellcheck disable=SC2046
if ! ping -c 1 "${LDAP_HOST}" &> /dev/null ; then
    message="No contact with host [${LDAP_HOST}] in corporate network detected.\n\nCannot get printer settings, please ensure you're connected before trying again."
    log "${message}"
    # /usr/local/bin/hubcli notify -t "${message}" # can only use hubcli if running as root
    # open_osascript_dialog syntax: title, message, button1, icon
    dialog_window_title="$SCRIPT"
    dialog_desc="$message"
    open_osascript_dialog "${dialog_window_title}" "${dialog_desc}" "OK" stop
    exit 1
fi


## use AD to retrieve list of print servers
# one fine day we'll fetch the closest printers for the office location from either Azure AD or on-prem AD using ldapsearch or something else clever.
#
# legacy search in on-prem AD for printer to get IP
# ldapsearch -H ldap://internal.example.com -b 'dc=internal,dc=example,dc=com' -Q -LLL '(&(objectClass=printQueue)(printShareName=" & InputString & "))' printerName location portName serverName printShareName|grep portName|sed 's/portName: IP_//g'
#
# 2023-04-30 working search for pullprint servers
# ldapsearch -v -H ldap://internal.example.com -b 'dc=internal,dc=example,dc=com' -Q -LLL '(&(objectClass=printQueue)(printShareName=pullprint*))' printerName description name keywords serverName printShareName
#
log "Looking up settings for printer [${PRINTER} ${location}] in AD using LDAP"
ldap_filter="(&(objectClass=printQueue)(printerName=${PRINTER} ${location}))"
#
# may need to make sure to run as console user so we can use their Kerberos SSO cache
# /bin/launchctl asuser "$current_uid"
# search LDAP, output to tmp file
ldapsearch -H "ldap://${LDAP_HOST}" -b "${LDAP_BASE}" -Q -LLL "${ldap_filter}"  printerName description name keywords serverName printShareName > /tmp/printer_tool.txt

# we need exactly one match in the search results
num_results=$( grep -c '^dn:' /tmp/printer_tool.txt )
if [ "${num_results}" != "1" ] ; then
    message="Found [${num_results}] LDAP match(es) for [${PRINTER} ${location}] but need exactly one - aborting"
    log "${message}"
    #/usr/local/bin/hubcli notify -t "${message}"
    exit 1
fi

# get the printer/printserver address
printer_address=$( awk -F ": " '$1 == "serverName" {print $2}' /tmp/printer_tool.txt )
log "Printer/printserver address: $printer_address"

# get the print share name, replace any spaces with %20
printer_queue=$( awk -F ": " '$1 == "printShareName" {print $2}' /tmp/printer_tool.txt | sed "s/ /%20/g" )
log "Printer/printserver queue: $printer_queue"

## initialize vars that will show up in the GUI
cups_queue="${PRINTER:l}_${location:l}"
cups_desc="${COMPANY} ${PRINTER} ${location}"
cups_location="${COMPANY} site ${location}"

# construct address to send to
printer_url="${PRINTER_PROTOCOL}${printer_address}/${printer_queue}"

# Find CUPS printer queue name of printer from its Description
#lpstat  -l -p | grep -i Description: |awk -F'Description: ' '{print $2}'

# Remove previous version of printer queue
if ( lpstat -v | grep -q "${cups_queue}" ) ; then
    log "Printer queue ${cups_queue} was configured before. Removing old version..."
    lpadmin -x "${cups_queue}"
    #sleep 3
else
    log "Printer queue ${cups_queue} does not exist yet."
fi


# Add Virtual Printer queue for print server
if ( lpstat -v | grep -q "${cups_queue}" ) ; then
    log "Printer [${cups_desc}] queue [${cups_queue}] already configured"
else
    log "Printer [${cups_desc}] queue [${cups_queue}] will be now configured"

    lpadmin -p "${cups_queue}" \
        -D "${cups_desc}" \
        -E -v "${printer_url}" \
        -P "${PPD_DIR}/${PPD_NAME}" \
        -L "${cups_location}" \
        -o "${DRIVER_DEFAULTS}"
fi


# Enable Kerberos Printing on SMB printers
if [[ "$PRINTER_PROTOCOL" == "smb://" ]]; then
    log "Enable SSO on printer queue : ${cups_queue}"
    lpadmin -p "${cups_queue}" -o auth-info-required=negotiate
fi

exit 0
