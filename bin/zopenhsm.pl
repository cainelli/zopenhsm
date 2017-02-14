#!/usr/bin/perl
use warnings;
use strict;
use DBI;
use XML::Simple;
use Data::Dumper;
use Getopt::Long;
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($ERROR);


# LOAD CONFIG
my $logconf = q(
  log4perl.logger.zopenhsm=DEBUG, LOGFILE, SCREEN

    log4perl.appender.LOGFILE.filename=/var/log/zopenhsm.log
    log4perl.appender.LOGFILE=Log::Log4perl::Appender::File
    log4perl.appender.LOGFILE.mode=append
    log4perl.appender.LOGFILE.layout=PatternLayout
    log4perl.appender.LOGFILE.layout.ConversionPattern=%d %p - %m%n

    log4perl.appender.SCREEN  = Log::Log4perl::Appender::Screen
    log4perl.appender.SCREEN.layout=PatternLayout
    log4perl.appender.SCREEN.layout.ConversionPattern=%d %p - %m%n

);

Log::Log4perl::init(\$logconf);
my $logger = Log::Log4perl->get_logger('zopenhsm.topdrwr');

my ($src_vol, $dst_vol, $interative);
GetOptions( 
    "source=s"  => \$src_vol,
    "destination=s" => \$dst_vol,
    "interative" => \$interative
    );

if ( ! ($src_vol && $dst_vol))
{
    $logger->error("you need to specify source and destination volumes.");
    &help;
}

$logger->info("Getting zimbraHsmAge...");
my $hsmage = `/opt/zimbra/bin/zmprov getserver \`/opt/zimbra/bin/zmhostname\` | grep zimbraHsmAge | cut -d\\  -f2`;

# default hsm age is 7d.
if ( ! $hsmage )
{
    $hsmage = '7d';
}


$logger->info("zimbraHsmAge=$hsmage");

my $localconfig = '/opt/zimbra/conf/localconfig.xml';
my $xml = new XML::Simple;
my $localconfig_xml = $xml->XMLin($localconfig);
my %zconf = (
    mysql_host => $localconfig_xml->{key}->{mysql_bind_address}->{value},
    mysql_port => '7306',
    mysql_user => 'zimbra',
    mysql_pass => $localconfig_xml->{key}->{zimbra_mysql_password}->{value},
    volumes    => {},
    );

$hsmage = &convertHsmAge($hsmage);
my %mailboxes = &loadMailboxes;

# check if defined volumes exists on Zimbra.
my ($src_vol_id, $dst_vol_id);
for my $id (keys($zconf{'volumes'}))
{
    
    if ( $zconf{'volumes'}{$id} =~ m/^$dst_vol$/ )
    {
        $dst_vol_id = $id;
    }
    elsif ( $zconf{'volumes'}{$id} =~ m/^$src_vol$/ )
    {
        $src_vol_id = $id;
    }
}

if ( ! $src_vol_id ) 
{
    $logger->error("Volume '$src_vol' doesn't exists in Zimbra. Run 'zmvolumes -l' and see if the volume that you specified is a Primary or Secondary Zimbra volume.");
    exit 1;
}
elsif ( ! $dst_vol_id )
{
    $logger->error("Volume '$dst_vol' doesn't exists in Zimbra. Run 'zmvolumes -l' and see if the volume that you specified is a Primary or Secondary Zimbra volume.");
    exit 1;
}


####
# Manual overwrite for testing
####
#$src_vol_id = 3;
#$dst_vol_id = 1;
####


for my $group ( keys(%mailboxes) )
{
    my $dsn = "DBI:mysql:database=mboxgroup$group;host=$zconf{mysql_host};port=$zconf{mysql_port}";
    my $dbh = DBI->connect($dsn, $zconf{mysql_user}, $zconf{mysql_pass});

    #my $current_time = time;
    for my $mailbox (keys(\%{$mailboxes{$group}}))
    {
    my $query_time = time - $hsmage;
    my $str_query="SELECT id,
        CONCAT('locator:',locator,':/', (mailbox_id >> 12), '/', mailbox_id, '/msg/', (id % (1024*1024) >> 12), '/') AS path,
        CONCAT( id, '-', mod_content, '.msg' ) AS file 
        FROM mail_item 
        WHERE mailbox_id='$mailbox' AND 
            type = 5 AND 
            locator = $src_vol_id AND
            date < $query_time";        
    my $query = $dbh->prepare($str_query);
    $query->execute;


    my $res_count = $query->rows;
    $logger->debug("query:[$str_query] results:[$res_count]");
    while ( my $row = $query->fetchrow_hashref() )
    {

        my %msgs;
        my $volume_id;
        if ( $row->{path} =~ m/^locator\:(.+?)\:.+?/ )
        {
            $volume_id = $1;
        }

        $row->{path} =~ s|locator:$volume_id:|$zconf{volumes}{$volume_id}|g;

        # skip message if exists in database but not in the filesystem.
        if ( ! -e "$row->{path}$row->{file}" )
        {
            $logger->warn("file not found $row->{path}$row->{file}.");
            next;
        }
        
        my $newpath = $row->{path};
        $newpath =~ s|$zconf{volumes}{$volume_id}|$zconf{volumes}{$dst_vol_id}|g;

        
        $msgs{$row->{path}.$row->{file}}{mysqlcmd} = "UPDATE mail_item SET locator = $dst_vol_id WHERE id = $row->{id} AND mailbox_id = $mailbox";
        $msgs{$row->{path}.$row->{file}}{destination} = $newpath.$row->{file};
        $msgs{$row->{path}.$row->{file}}{database} = "mboxgroup$group";
        $msgs{$row->{path}.$row->{file}}{mailbox} = $mailboxes{$group}{$mailbox}{comment};
        $msgs{$row->{path}.$row->{file}}{newpath} = $newpath;

        $logger->debug(Dumper(%msgs));
        my $res;
        if ( $interative )
        {
            do
            {
                if ( $res && $res =~ m/^n$|^no$/ )
                {
                    exit;
                }
                print "Do you want to move forward?[y/n]";
                $res = <STDIN>;
            } while ( $res !~ m/^y$|^yes$/ );

        }

        system("mkdir -p $newpath");
        system("chown zimbra: $newpath");
        system("mv -v $row->{path}$row->{file} $newpath$row->{file}");
        if ( $? == 0 )
        {
            my $queryupdate = $dbh->prepare("UPDATE mail_item SET locator = $dst_vol_id WHERE id = $row->{id} AND mailbox_id = $mailbox");
            $queryupdate->execute;
        }
        else
        {
            die $logger->error("Could not move message $row->{path}$row->{file} to $newpath$row->{file}:$? $0");
        }

    }
    }
    $dbh->disconnect;
}



# SUBS
sub loadMailboxes
{
    my $dsn = "DBI:mysql:database=zimbra;host=$zconf{mysql_host};port=$zconf{mysql_port}";
    my $dbh = DBI->connect($dsn, $zconf{mysql_user}, $zconf{mysql_pass});

    my $query = $dbh->prepare("SELECT * FROM mailbox");
    $query->execute;

    my %mailboxes;
    while ( my $row = $query->fetchrow_hashref() )
    {
        for my $field ( keys(%{$row}) )
        {
            $mailboxes{$row->{group_id}}{$row->{id}}{$field}=$row->{$field};
        }
    }

    $query = $dbh->prepare("SELECT * FROM volume WHERE type IN (1,2)");
    $query->execute;


    while ( my $row = $query->fetchrow_hashref() )
    {
        $zconf{volumes}{$row->{id}}=$row->{path};
    }

    $dbh->disconnect;

    return %mailboxes;
}

sub convertHsmAge
{
    my $hsmage = shift;

    if ( $hsmage =~ m/d$/ )
    {

        $hsmage =~ s|d$||g;
        $hsmage = $hsmage * 24 * 60 * 60; # hours/day * minutes * seconds

        return $hsmage;

    }
    else
    {
        die $logger->error("Hsm age $hsmage not supported. Try something like '7d'.");
    }
}

sub help
{
    print q(
    zopenhsm - HSM for Zimbra Open Source Edition. ( NOT FULLY TESTED!)

    usage: zopenhsm [options]
    --sorce [-s]                -   (required) Source volume witch you want to move messages from.
    --destination [-d]          -   (required) Destination volume witch you want to move messages to.
    --interative [-i]           -   Iterative mode on. Before move a message will be prompt if you want to.
);

    exit 1;   
}
