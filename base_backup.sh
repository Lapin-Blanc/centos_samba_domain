#!/bin/sh

# make sure to backup the partition table in case of big crash
dd if=/dev/sda of=/root/bootsectors bs=512 count=248

BORGUSER="borguser"
BORGHOST="srv.example.com"
BORGPATH="wonderland/hole"

REPOSITORY=$BORGUSER@$BORGHOST:/home/${BORGUSER}/$BORGPATH

####################################################
#### Install borgbackup if first time
# wget https://github.com/borgbackup/borg/releases/download/1.1.5/borg-linux64 -O /usr/local/bin/borg
# chmod +x /usr/local/bin/borg
#### initialy, the repository has to be initialized with these commands :
# ssh-keygen -t ed25519
# ssh-copy-id $BORGUSER@$BORGHOST
# ssh $BORGUSER@$BORGHOST

#### On remote server
# ssh $BORGUSER@$BORGHOST "mkdir ~/${BORGPATH} -p; chmod 0750 ${BORGPATH}"

# borg init --encryption=keyfile $REPOSITORY
#### then export and move the key to a *safe* place
# borg key export $REPOSITORY ./borg_key
#####################################################

#Bail if borg is already running, maybe previous run didn't finish
if pidof -x borg >/dev/null; then
    echo "Backup already running"
    exit
fi

# Setting this, so you won't be asked for your repository passphrase:
export BORG_PASSPHRASE='superpassphrase'
# or this to ask an external program to supply the passphrase:
# export BORG_PASSCOMMAND='pass show backup'

# Backup all except a few excluded directories
/usr/local/bin/borg create -v --stats --progress \
    $REPOSITORY::'{hostname}-{now:%Y-%m-%d}'    \
    /                                           \
    --exclude '/dev'                            \
    --exclude '/proc'                           \
    --exclude '/sys'                            \
    --exclude '/run'                            \
    --exclude '/var/run'                        \
    --exclude '/mnt'                            \
    --exclude '/tmp'                            \
        
# Use the `prune` subcommand to maintain 7 daily, 4 weekly and 6 monthly
# archives of THIS machine. The '{hostname}-' prefix is very important to
# limit prune's operation to this machine's archives and not apply to
# other machine's archives also.
borg prune -v --list $REPOSITORY --prefix '{hostname}-' \
    --keep-daily=7 --keep-weekly=4 --keep-monthly=6
# for individual file restore
# export BORG_PASSPHRASE='superpassphrase'; borg mount $REPOSITORY /mnt
# /root/backup.sh 2>&1 | mutt -s "Borgbackup : " -- admin@domain.com
