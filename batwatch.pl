#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use File::Path qw(make_path);
use File::Slurp;
use Sys::Syslog qw(:standard :macros);
use Config::Tiny;

# ---- Command-line options
my $debug = 0;
my $sim_unplugged = 0;
my $sim_lowcap    = 0;
my $config_file   = '/etc/batwatch.conf';

GetOptions(
    'debug'         => \$debug,
    'sim-unplugged' => \$sim_unplugged,
    'sim-lowcap'    => \$sim_lowcap,
    'config=s'      => \$config_file
);

# ---- Load configuration
my $Config = Config::Tiny->read($config_file)
    or die "Could not read config file: $config_file";

my $state_dir       = $Config->{general}->{state_dir};
my $state_file      = "$state_dir/progstate";
my $threshold       = $Config->{general}->{bat_threshold_pct};
my $psonline_path   = $Config->{general}->{psonline_path};
my $batcap_path     = $Config->{general}->{batcap_path};

make_path($state_dir, { mode => 0700 }) unless -d $state_dir;

# Syslog init
openlog('batwatch', 'pid', LOG_USER);

# Notification Messages
my $unplugged_msg = Email::MIME->create(
    header_str => [
        From    => $Config->{email}->{from},
        To      => $Config->{email}->{to},
        Subject => '[NOTIFY] Node Unplugged'
    ],
    attributes => {
        encoding => 'quoted-printable',
        charset  => 'ISO-8859-1'                                                                                                                                                                                     },
    body_str => "Node had been unplugged. I will continue to monitor the system battery level, once it goes under the threshold, I will notify you again and perform an automated shutdown to prevent data loss.\n"
);

my $under_threshold_msg = Email::MIME->create(
    header_str => [
        From    => $Config->{email}->{from},
        To      => $Config->{email}->{to},
        Subject => '[ALERT] Node Going Offline'
    ],
    attributes => {
        encoding => 'quoted-printable',
        charset  => 'ISO-8859-1'
    },
    body_str => "Node's battery level is under the threshold. To prevent data loss, I will perform a shutdown sequence on this node, see you soon!\n"
);

# SMTP Transport
my $transport = Email::Sender::Transport::SMTP->new({
    host          => $Config->{email}->{smtp_host},
    port          => $Config->{email}->{smtp_port},
    sasl_username => $Config->{email}->{smtp_user},
    sasl_password => $Config->{email}->{smtp_pass},
    ssl           => $Config->{email}->{use_ssl},
    debug         => $Config->{email}->{debug}
});

# ---- Initialize state file if needed
unless (-e $state_file) {
    write_file($state_file, "INIT");
}

# Read current power supply state
my $ac_status = read_file($psonline_path);
chomp($ac_status);
my $battery_capacity = read_file($batcap_path);
chomp($battery_capacity);
my $state = read_file($state_file);
chomp($state);

# Simulation overrides
$ac_status = '0' if $sim_unplugged;
$battery_capacity = $threshold - 1 if $sim_lowcap;

# Debug output
if ($debug) {
    syslog(LOG_DEBUG, "DEBUG: AC status: %s", $ac_status);
    syslog(LOG_DEBUG, "DEBUG: Battery capacity: %s%%", $battery_capacity);
    syslog(LOG_DEBUG, "DEBUG: Current program state: %s", $state);
}

if ($ac_status eq '0') {
    if ($state ne "AC_UNPLUGGED" && $state ne "BELOW_THRESHOLD") {
        write_file($state_file, "AC_UNPLUGGED");
        syslog(LOG_INFO, "AC adapter is offline (on battery)");
        sendmail($unplugged_msg, { transport => $transport });
    }

    if (int($battery_capacity) <= $threshold) {
        write_file($state_file, "BELOW_THRESHOLD");
        syslog(LOG_WARNING, "Battery capacity below threshold (%d%%), initiating shutdown...", $battery_capacity);
        sendmail($under_threshold_msg, { transport => $transport });
        closelog();
        system('shutdown', 'now');
    }

} elsif ($ac_status ne '1') {
    syslog(LOG_ERR, "Unexpected value in $psonline_path: '%s'", $ac_status);
}

closelog();
