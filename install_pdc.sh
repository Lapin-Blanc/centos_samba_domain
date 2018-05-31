#!/bin/bash

HOSTNAME='hole1'
DOMAIN='wonderland.infra'

WAN_NIC='enp0s3'
WAN_IP='192.168.1.50'
WAN_PREFIX='24'
GATEWAY='192.168.1.1'

LAN_NIC='enp0s8'
LAN_IP='172.19.3.1'
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

sed -i "s/enforcing$/permissive/" /etc/sysconfig/selinux
setenforce Permissive

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
${LAN_IP} ${FQDN} ${HOSTNAME}
EOF

cat >/etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet $(network $LAN_IP $LAN_PREFIX) netmask ${LAN_MASK} {
  range ${POOL_START} ${POOL_END};
  option domain-name-servers ${LAN_IP};
  option domain-name "$DOMAIN";
  option routers ${LAN_IP};
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
/usr/local/samba/bin/samba-tool domain provision --server-role=dc --use-rfc2307 --dns-backend=SAMBA_INTERNAL --realm=$REALM --domain=$NETBIOS --adminpass=$ADMIN_PWD --option="interfaces=lo $LAN_NIC" --option="bind interfaces only=yes"
cp /usr/local/samba/private/krb5.conf /etc/
/usr/local/samba/bin/samba-tool domain exportkeytab /etc/krb5.keytab --principal ${FQDN}
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


nmcli c modify ${WAN_NIC} ipv4.dns ''
nmcli c up ${WAN_NIC}

nmcli c modify ${LAN_NIC} ipv4.method manual ipv4.dns $LAN_IP ipv4.address $LAN_IP/$LAN_PREFIX ipv6.method ignore connection.autoconnect yes
nmcli con up ${LAN_NIC}

firewall-cmd --reload
firewall-cmd --permanent --zone=internal --add-service=samba-ad-dc
firewall-cmd --permanent --zone=external --add-interface=$WAN_NIC
firewall-cmd --permanent --zone=internal --add-interface=$LAN_NIC
firewall-cmd --reload

systemctl start dhcpd
systemctl enable dhcpd

systemctl start samba-ad-dc
systemctl enable samba-ad-dc

systemctl start ntpd
systemctl enable ntpd

/usr/local/samba/bin/samba-tool domain passwordsettings set --complexity=off
/usr/local/samba/bin/samba-tool domain passwordsettings set --history-length=0
/usr/local/samba/bin/samba-tool domain passwordsettings set --min-pwd-age=0
/usr/local/samba/bin/samba-tool domain passwordsettings set --max-pwd-age=0

########################################################
nmcli c modify ${WAN_NIC} ipv4.method manual ipv4.dns '' ipv4.ignore-auto-dns yes ipv4.address $WAN_IP/$WAN_PREFIX ipv4.gateway $GATEWAY ipv6.method ignore connection.autoconnect yes
nmcli c up ${WAN_NIC}

