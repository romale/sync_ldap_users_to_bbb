#!/bin/bash
#
############################################################################################
#Script Name	: sync_ldap_users_to_bbb.sh
#Description	: This script sync LDAP users to BigBlueButton (sqlite3 DB).
#               : One-way. If sync was been before, script start
#               : sync from new user created in LDAP (comparing "createtimestamp" attribute)
#               : For resync all LDAP users from scratch: echo "" > "$SYNC_STATUS_FILE"
#Args           : No                                                                                          
#Author       	: Alexander
#Email         	: aleromex.tr@gmail.com                                           
############################################################################################

LDAP_SERVER="ipa01.example.ru"
LDAP_BASE_DN="cn=users,cn=accounts,dc=example,dc=ru"
#LDAP_FILTER : see "get_ldap_users" function below and change the filter what you need
LDAP_USER="uid=BBB_LDAP_USER,cn=sysaccounts,cn=etc,dc=example,dc=ru"
LDAP_PASSW="MYLDAPPASSWORD"

SQLITE3_BIN="/usr/bin/sqlite3"
# DB of BBB
DB_FILE="/root/greenlight/db/production/production.sqlite3"
# Keep newest value of 'createtimestamp' user LDAP attribute
SYNC_STATUS_FILE="/root/sync_status_file"
DEFAULT_ROOM_NAME="Домашнаяя комната"

get_ldap_users(){
    local last_sync="$1"
    # Change it for your needs
    LDAP_FILTER="(&(objectClass=posixaccount)(memberOf=cn=mail,cn=groups,cn=accounts,dc=example,dc=ru)(memberOf=cn=example,cn=groups,cn=accounts,dc=example,dc=ru)(createtimestamp>="${last_sync}")(!(createtimestamp="${last_sync}")))"
    local all_users=$(ldapsearch -LLL -x -D "${LDAP_USER}" -w "${LDAP_PASSW}" -h "${LDAP_SERVER}" -b "${LDAP_BASE_DN}" "${LDAP_FILTER}" uid | grep '^uid' | sed 's/uid\:\s//g')
    echo "$all_users"
}

get_gecos(){
    local user_data=$1
    local gecos=$(echo "${user_data[*]}" | grep '^displayName' | sed -e 's/^displayName\:[ \t]*//')
    echo "$gecos"
}

get_email(){
    local user_data=$1
    local email=$(echo "${user_data[*]}" | grep '^mail' | sed -e 's/^mail\:[ \t]*//')
    echo "$email"
}

get_dn(){
    local user_data=$1
    local dn=$(echo "${user_data[*]}" | grep '^dn\:' | sed -e 's/^dn\:[ \t]*//')
    echo "$dn"
}

get_user_uid(){
    local uid=gl-$(tr -cd '[:alpha:]' < /dev/urandom | fold -w12 | head -n1 | tr '[:upper:]' '[:lower:]')
    echo "$uid"
}

get_room_uid(){
        gecos=$1
        local room_uid=$(echo "$gecos" | sed 's/[[:space:]]//g' | cut -c1-3 | tr '[:upper:]' '[:lower:]')-$(tr -cd '[:alpha:]' < /dev/urandom | fold -w3 | head -n1 | tr '[:upper:]' '[:lower:]')-$(tr -cd '[:alpha:]' < /dev/urandom | fold -w3 | head -n1 | tr '[:upper:]' '[:lower:]')
        echo "$room_uid"
}
        
get_bbb_id(){
        local bbb_id=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w40 | head -n1 | tr '[:upper:]' '[:lower:]')
        echo "$bbb_id"
}

get_pw(){
        local pw=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w12 | head -n1 | tr '[:upper:]' '[:lower:]')
        echo "$pw"
}

put_sync_time(){
        local last_sync=$1
        echo "# If you need force sync all users, delete next line like 20200324135612Z" > "$SYNC_STATUS_FILE"
        echo "$last_sync" >> "$SYNC_STATUS_FILE"
}

get_user_create_time(){
        local user=$1
        local createtimestamp=$(ldapsearch -LLL -x -D "${LDAP_USER}" -w "${LDAP_PASSW}" -h "${LDAP_SERVER}" -b "${LDAP_BASE_DN}" uid="${user}" createtimestamp | grep '^createtimestamp' | sed 's/createtimestamp\:\s//g')
        echo "$createtimestamp"
}

if [ ! -f "$SYNC_STATUS_FILE" ]; then
    touch "$SYNC_STATUS_FILE" || echo "Can't create file $SYNC_STATUS_FILE, pls check directory path exist"
fi

# Check if there was synchronization
last_sync=$(cat "$SYNC_STATUS_FILE"|grep -v '^#')
if [ -z $last_sync ]; then
    # Get users list
    all_users=$(get_ldap_users "${last_sync}")
else
    if [[ $last_sync =~ ^[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[1-2][0-9]|3[0-1]).*Z$ ]]; then
        # Get users list after last sync
        all_users=$(get_ldap_users "${last_sync}")
    fi
fi

# Get last room id
room_id=$($SQLITE3_BIN $DB_FILE "select id from rooms order by id desc limit 1;")
((room_id++))

# Get last user id
user_id=$($SQLITE3_BIN $DB_FILE "select id from users order by id desc limit 1;")
((user_id++))

for user in ${all_users}
do
    # Get data for user info filling
    user_data=$(ldapsearch -LLL -x -D "${LDAP_USER}" -w "${LDAP_PASSW}" -h "${LDAP_SERVER}" -b "${LDAP_BASE_DN}" uid="${user}")

    gecos=$(get_gecos "${user_data}")
    email=$(get_email "${user_data}")
    dn=$(get_dn "${user_data}")
    create_date=`date "+%Y-%m-%d %H:%M:%S.%6N"`
    update_date="$create_date"
    uid=$(get_user_uid)
    createtimestamp=$(get_user_create_time "${user}")
    
    if [ -z $gecos | -z $email | -z $dn | -z $createtimestamp ]; then
        echo "User does not have all LDAP attribute filled: displayName or dn or mail or createtimestamp"
        break
    fi
    
    # Create user
    "$SQLITE3_BIN" "$DB_FILE" "INSERT INTO users (id,room_id,provider,uid,name,username,email,social_uid,created_at,updated_at,email_verified) VALUES(\"$user_id\",\"$room_id\",\"ldap\",\"$uid\",\"$gecos\",\"$user\",\"$email\",\"$dn\",\"$create_date\",\"$update_date\",\"1\");"

    # Assign user role
    "$SQLITE3_BIN" "$DB_FILE" "INSERT INTO users_roles (user_id, role_id) VALUES(\"$user_id\",\"1\");"
    
    bbb_id=$(get_bbb_id)
    room_uid=$(get_room_uid "$gecos")
    moderator_pw=$(get_pw)
    attendee_pw=$(get_pw)
        
    # Create user room
    "$SQLITE3_BIN" "$DB_FILE" "INSERT INTO rooms (id,user_id,name,uid,bbb_id,created_at,updated_at,moderator_pw,attendee_pw) VALUES(\"$room_id\",\"$user_id\",\"$DEFAULT_ROOM_NAME\",\"$room_uid\",\"$bbb_id\",\"$create_date\",\"$update_date\",\"$moderator_pw\",\"$attendee_pw\");"
    
    if [[ $last_sync < $createtimestamp ]]; then
        put_sync_time "$createtimestamp"
    fi

    ((user_id++))
    ((room_id++))

done
