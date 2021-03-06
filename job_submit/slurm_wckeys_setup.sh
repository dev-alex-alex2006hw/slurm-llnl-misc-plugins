#!/bin/bash
# slurm_wckeys_setup.sh is part of Calibre
#
# Copyright (C) 2015 EDF SA
# Contact:
#       CCN - HPC <dsp-cspit-ccn-hpc@edf.fr>
#       1, Avenue du General de Gaulle
#       92140 Clamart
#
#Author: Antonio J. Russo <antonio-externe.russo@edf.fr>
#This program is free software; you can redistribute in and/or
#modify it under the terms of the GNU General Public License,
#version 2, as published by the Free Software Foundation.
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#On Calibre systems, the complete text of the GNU General
#Public License can be found in `/usr/share/common-licenses/GPL'.
###################################################################

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CMD=$(basename $0)
[ -f /etc/default/wckeysctl ] && source /etc/default/wckeysctl
[ -f /etc/slurm-llnl/slurmdbd.conf ] && source /etc/slurm-llnl/slurmdbd.conf

print_error () {
        echo -e "\e[00;31m$2\e[00m" 1>&2
        exit ${1}
}

print_msg () {
        echo -e "\e[00;34m$1\e[00m" 1>&2
}


### Block 0 ###
### Create temporaries files and directories ###
TMP_MNT_POINT=$(mktemp -d)
mount -t tmpfs -o size=20m tmpfs ${TMP_MNT_POINT}

WCKEYS_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
ACCOUNTS_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
TMP_FILE_MYSQL=$(tempfile -d ${TMP_MNT_POINT})
WCKEYS_INDB_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
WCKEYS_ADD_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})
WCKEYS_DEL_TMP_FILE=$(tempfile -d ${TMP_MNT_POINT})

### Block 1 ###
### Generate wckeys file ####

nb=0
for CODES_PROJETS_FILE_CURRENT in ${PAREO_FILE}
do
  if [ -f "${CODES_PROJETS_FILE_CURRENT}" ]
  then
    ((nb++))
    CODES_PROJETS_LIST=$(awk -F';' '{print tolower($1)}' ${CODES_PROJETS_FILE_CURRENT} | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u)
    CODES_METIERS_FILE_CURRENT=$(echo ${CODES_FILE} | cut -f${nb} -d" ")
      if [ -f "${CODES_METIERS_FILE_CURRENT}" ]
      then
        CODES_METIERS_LIST=$(iconv -f 437 -t ascii//TRANSLIT ${CODES_METIERS_FILE_CURRENT} | \
        awk -F';' '{gsub (/[ )]$/, "", $1 ); print tolower($1)}' | \
        tr '[:blank:]' '_' | sed -r -e 's/[_]+/_/g' -e 's/^[_]+//g' -e 's/[_]+$//g' | sort -u)

        for project in ${CODES_PROJETS_LIST}
        do
          for application in ${CODES_METIERS_LIST}
          do
            echo "${project}:${application}"
          done >> ${WCKEYS_TMP_FILE}
        done
      else
        print_error 1 "File not found: ${CODES_METIERS_FILE_CURRENT}"
      fi
  else
    print_error 1 "File not found: ${CODES_PROJETS_FILE_CURRENT}"
  fi
done
sort -u ${WCKEYS_TMP_FILE} -o ${WCKEYS_FILE}

if [ -f "${SLURMDB_FILE}" ]
then
  source ${SLURMDB_FILE}
else
  print_error 1 "File not found: ${CODES_FILE}"
fi

### Block 2 ###
### Generate add and delete files ###

${SACCTMGR} -np list wckeys | awk -F'|' '{ print $1 }' | sort -u > ${WCKEYS_INDB_TMP_FILE}
comm -23 ${WCKEYS_INDB_TMP_FILE} ${WCKEYS_FILE} > ${WCKEYS_DEL_TMP_FILE}
comm -13 ${WCKEYS_INDB_TMP_FILE} ${WCKEYS_FILE} > ${WCKEYS_ADD_TMP_FILE}

### Block 3 ###
### Insert wckeys into slurm database ###
for key in $(cat ${WCKEYS_ADD_TMP_FILE})
do
  DATE=$(date "+%s")

cat > ${TMP_FILE_MYSQL} << EOF
UPDATE ${DB_NAME}.${CLUSTERNAME}_wckey_table SET deleted = 0 WHERE wckey_name = '${key}';
INSERT INTO ${DB_NAME}.${CLUSTERNAME}_wckey_table
  (creation_time, mod_time, wckey_name, user)
SELECT
  '${DATE}','${DATE}','${key}','root'
FROM ${DB_NAME}.${CLUSTERNAME}_wckey_table
WHERE '${key}' NOT IN
(
  SELECT wckey_name
  FROM ${DB_NAME}.${CLUSTERNAME}_wckey_table
)
LIMIT 1
EOF
  mysql --host=${StorageHost} --user=${StorageUser} --password=${StoragePass} < ${TMP_FILE_MYSQL}
  print_msg "Add new wckey= ${key}"
done


### Block 4 ###
### Delete wckeys from slurm database ###
for key in $(cat ${WCKEYS_DEL_TMP_FILE})
do
cat > ${TMP_FILE_MYSQL} << EOF
UPDATE ${DB_NAME}.${CLUSTERNAME}_wckey_table SET deleted = 1 WHERE wckey_name = '${key}';
EOF
  mysql --host=${StorageHost} --user=${StorageUser} --password=${StoragePass} < ${TMP_FILE_MYSQL}
  print_msg "Del old wckey= ${key}"
done

### Block 5 ###
### Clean system ###
umount ${TMP_MNT_POINT}
rm -rf  ${TMP_MNT_POINT}

