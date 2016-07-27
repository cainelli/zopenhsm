# zopenhsm

Zimbra HSM is a great feature on Zimbra Network Edition which helps administratros reduce significantly storage costs and still offer large mailboxes to its users.
This tool brings the HSM feature only available in Zimbra Network Edition to Zimbra Open Source Edition.

## Dependencies
You should install the following Perl Modules:
- DBI;
- XML::Simple;
- Log::Log4perl

For ubuntu 14.04LTS:
```
apt-get update
apt-get install libxml-simple-perl liblog-log4perl-perl libdbd-mysql-perl
```

For CentOS 7
```
yum install perl-XML-Simple.noarch perl-Log-Log4perl
```

## Setup
Download and save money :P.
```
wget -c https://raw.githubusercontent.com/cainelli/zopenhsm/master/bin/zopenhsm.pl 
mv zopenhsm.pl /usr/local/bin/
chmod +x /usr/local/bin/zopenhsm.pl
```
## Usage
You can set the age policy for HSM using the same key of Zimbra Network Edition.
```sh
zmprov modifyserver $(zmhostname) zimbraHsmAge 10d
```

The destination volume(/opt/zimbra/hsm01 on this case) must be either a Zimbra Primary or Secondary Message Store. To create a new Zimbra volume:

```sh
mkdir /opt/zimbra/hsm01
chown zimbra: /opt/zimbra/hsm01
zmvolume --add --name hsm01 --path /opt/zimbra/hsm01 --type primaryMessage --compress true
```

Run as following:
```sh
zopenhsm.pl --source /opt/zimbra/store --destination /opt/zimbra/hsm01
```
