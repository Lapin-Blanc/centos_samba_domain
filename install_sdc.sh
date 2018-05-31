#!/bin/bash

HOSTNAME='hole2'
DOMAIN='wonderland.infra'

WAN_NIC='enp0s3'
WAN_IP='192.168.1.51'
WAN_PREFIX='24'
GATEWAY='192.168.1.1'

PDC='172.19.3.1'
LAN_NIC='enp0s8'
LAN_IP='172.19.3.2'
LAN_PREFIX='24'
POOL_START='172.19.3.200'
POOL_END='172.19.3.249'

ADMIN_PWD='Pa$$word'

#########################################################

ip2int()
{
    local a b c d
    { IFS=. read a b c d; } <<< ${1}
    echo $(((((((a << 8) | b) << 8) | c) << 8) | d))
}

int2ip()
{
    local ui32=$1; shift
    local ip n
    for n in 1 2 3 4; do
        ip=$((ui32 & 0xff))${ip:+.}$ip
        ui32=$((ui32 >> 8))
    done
    echo $ip
}

netmask()
{
    local mask=$((0xffffffff << (32 - ${1}))); shift
    int2ip $mask
}


broadcast()
{
    local addr=$(ip2int $1); shift
    local mask=$((0xffffffff << (32 -${1}))); shift
    int2ip $((addr | ~mask))
}

network()
{
    local addr=$(ip2int $1); shift
    local mask=$((0xffffffff << (32 -${1}))); shift
    int2ip $((addr & mask))
}

FQDN=${HOSTNAME}.${DOMAIN}
REALM=${DOMAIN^^}
NETBIOS=$(echo $REALM | cut -d '.' -f 1)
NETBIOS=${NETBIOS^^}

LAN_MASK=$(netmask ${LAN_PREFIX})

sed -i "s/enforcing$/disabled/" /etc/sysconfig/selinux
setenforce 0

nmcli g h $FQDN

yum install -y attr bind-utils docbook-style-xsl gcc gdb krb5-workstation \
       libsemanage-python libxslt perl perl-ExtUtils-MakeMaker \
       perl-Parse-Yapp perl-Test-Base pkgconfig policycoreutils-python \
       python-crypto gnutls-devel libattr-devel keyutils-libs-devel \
       libacl-devel libaio-devel libblkid-devel libxml2-devel openldap-devel \
       pam-devel popt-devel python-devel readline-devel zlib-devel systemd-devel \
       cups-devel vim wget net-tools tree dhcp mlocate ntp cyrus-sasl-plain mutt

cat >/etc/sysctl.d/disable_ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system

cat >/etc/hosts <<EOF
127.0.0.1 localhost localhost.localdomain
$LAN_IP $FQDN $HOSTNAME
EOF

cat >/etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet $(network $LAN_IP $LAN_PREFIX) netmask ${LAN_MASK} {
  range ${POOL_START} ${POOL_END};
  option domain-name-servers ${LAN_IP}, ${PDC};
  option domain-name "$DOMAIN";
  option routers ${LAN_IP}, ${PDC};
  option broadcast-address $(broadcast $LAN_IP $LAN_PREFIX);
  default-lease-time 3600;
  max-lease-time 7200;
}
EOF
########################################################################################

mkdir src
pushd src
        wget https://download.samba.org/pub/samba/samba-latest.tar.gz
        wget https://download.samba.org/pub/samba/samba-latest.tar.asc
        wget https://download.samba.org/pub/samba/samba-pubkey.asc
        gunzip samba-*.tar.gz
        gpg --import samba-pubkey.asc
        gpg --verify samba-latest.tar.asc
        tar xvf samba-latest.tar
        rm -f samba-latest.tar*
        cd samba-*
        ./configure && make && make install
popd

echo "export PATH=/usr/local/samba/bin/:/usr/local/samba/sbin/:$PATH" >> /root/.bashrc
echo "export MANPATH=\":/usr/local/samba/share/man\"" >> /root/.bashrc
ln -s /usr/local/samba/lib/libnss_winbind.so.2 /lib64/
ln -s /lib64/libnss_winbind.so.2 /lib64/libnss_winbind.so
ln -s /usr/local/samba/lib/security/pam_winbind.so /lib64/security/
ldconfig
mv /etc/{krb5.conf,.old}

# SDC
nmcli c modify ${WAN_NIC} ipv4.ignore-auto-dns yes ipv4.dns-search "" ipv6.method ignore
nmcli c modify ${LAN_NIC} ipv4.method manual ipv4.dns $PDC ipv4.address $LAN_IP/$LAN_PREFIX ipv6.method ignore connection.autoconnect yes
nmcli con up ${LAN_NIC}
nmcli con up ${WAN_NIC}

cat >/etc/krb5.conf <<EOF
[libdefaults]
    dns_lookup_realm = false
    dns_lookup_kdc = true
    default_realm = ${REALM}
EOF

/usr/local/samba/bin/samba-tool domain join ${DOMAIN} DC -Uadministrator%${ADMIN_PWD} --dns-backend=SAMBA_INTERNAL --option="interfaces=lo $LAN_NIC" --option="bind interfaces only=yes" --option="idmap_ldb:use rfc2307 = yes"
/usr/local/samba/bin/samba-tool domain exportkeytab /etc/krb5.keytab --principal host/${FQDN}
authconfig --enablemkhomedir --enablewinbindauth --update
sed -i "s/^\(passwd:.*\)/\1 winbind/" /etc/nsswitch.conf
sed -i "s/^\(group:.*\)/\1 winbind/" /etc/nsswitch.conf
sed -i "/\[global\]/apassword hash userPassword schemes = CryptSHA512" /usr/local/samba/etc/smb.conf

cat >/etc/firewalld/services/samba-ad-dc.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Samba</short>
  <description>Samba is an important component to seamlessly integrate Linux/Unix Servers and Desktops into Active Directory environments. It can function both as a domain controller or as a regular domain member.</description>

  <port protocol="tcp" port="53"/>
  <port protocol="udp" port="53"/>
  <port protocol="tcp" port="88"/>
  <port protocol="udp" port="88"/>
  <port protocol="tcp" port="135"/>
  <port protocol="udp" port="137"/>
  <port protocol="udp" port="138"/>
  <port protocol="tcp" port="139"/>
  <port protocol="tcp" port="389"/>
  <port protocol="udp" port="389"/>
  <port protocol="tcp" port="445"/>
  <port protocol="tcp" port="464"/>
  <port protocol="udp" port="464"/>
  <port protocol="tcp" port="636"/>
  <port protocol="tcp" port="49152-65535"/>
  <port protocol="tcp" port="3268"/>
  <port protocol="tcp" port="3269"/>

  <module name="nf_conntrack_netbios_ns"/>
</service>
EOF

cat >/etc/systemd/system/samba-ad-dc.service <<EOF
[Unit]
Description=Samba Active Directory Domain Controller
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
ExecStart=/usr/local/samba/sbin/samba -D
PIDFile=/usr/local/samba/var/run/samba.pid
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
chmod +x /etc/systemd/system/samba-ad-dc.service

firewall-cmd --reload
firewall-cmd --permanent --zone=internal --add-service=samba-ad-dc
firewall-cmd --permanent --zone=external --add-interface=$WAN_NIC
firewall-cmd --permanent --zone=internal --add-interface=$LAN_NIC
firewall-cmd --reload

systemctl start dhcpd
systemctl enable dhcpd

# systemctl start samba-ad-dc
# systemctl enable samba-ad-dc
# see below

systemctl start ntpd
systemctl enable ntpd

########################################################
nmcli c modify ${WAN_NIC} ipv4.method manual ipv4.dns '' ipv4.ignore-auto-dns yes ipv4.address $WAN_IP/$WAN_PREFIX ipv4.gateway $GATEWAY ipv6.method ignore connection.autoconnect yes
nmcli c up ${WAN_NIC}

# 1 - Join domain
# 2 - From pdc : tdbbackup -s .bak /usr/local/samba/private/idmap.ldb
# 3 - From pdc : scp -r /usr/local/samba/private/idmap.ldb.bak root@hole2:/usr/local/samba/private/idmap.ldb
# 4 - On sdc : systemctl start samba-ad-dc
# 5 - On sdc : systemctl enable samba-ad-dc
# 6 - On both : samba-tool drs showrepl
# 7 - On pdc : git clone -b "stable" https://github.com/deajan/osync.git
# 8 - On pdc : cd osyync/
# 9 - On pdc : ./install.sh
# 10 - On pdc : ssh-keygen -t rsa -f ~/.ssh/osync_rsa
# 11 - On pdc : ssh-copy-id -i ~/.ssh/osync_rsa.pub root@hole2
# 12 - On pdc : cp sysvol_sync.conf /etc/osync/
# 13 - On pdc : /usr/local/bin/osync.sh /etc/osync/sysvol_sync.conf --dry --verbose
# 14 - On pdc : /usr/local/bin/osync.sh /etc/osync/sysvol_sync.conf --verbose
# 15 - On pdc : crontab -e
# 16 - On pdc : */5 * * * * /usr/local/bin/osync.sh /etc/osync/sysvol_sync.conf --silent
# 17 - On pdc : cp users_sync.conf /etc/osync/
# 18 - On pdc : /usr/local/bin/osync.sh /etc/osync/users_sync.conf --dry --verbose
# 19 - On pdc : /usr/local/bin/osync.sh /etc/osync/users_sync.conf --verbose
# 20 - On pdc : crontab -e
# 21 - On pdc : 2-59/5 * * * * /usr/local/bin/osync.sh /etc/osync/users_sync.conf --silent
