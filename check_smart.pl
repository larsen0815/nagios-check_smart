#!/usr/bin/perl -w
# Check SMART status of ATA/SCSI disks, returning any usable metrics as perfdata.
# Can be used with disks in a RAID as well. Use something like /dev/sg0 (depends on your own setup).
# Check for ATA/SCSI(SAS) with:
#     smartctl -i /dev/sg0 | egrep "Transport protocol|ATA Version"
# For usage information, run ./check_smart -h
#
# This script was created under contract for the US Government and is therefore Public Domain
#
# Changes and Modifications
# =========================
# Feb 3, 2009: Kurt Yoder - initial version of script 1.0
# Jan 27, 2010: Philippe Genonceaux - modifications for compatibility with megaraid, use smartmontool version >= 5.39
# Add this line to /etc/sudoers: "nagios        ALL=(root) NOPASSWD: /usr/sbin/smartctl"
# 2015-01-23: larsen0815 - fixed some bugs
# - Using "-d ata" brings "A mandatory SMART command failed: exiting." therefore not using it anymore. Works anyway.
# - Separated megaraid from ata/scsi as either one can be found behind a megaraid controller
# 2015-07-15: larsen0815 - added "HP Smart Array" (cciss) as RAID controller


use strict;
use Getopt::Long;

use File::Basename qw(basename);
my $basename = basename($0);

my $revision = '$Revision: 1.0.2 $';

use lib '/usr/lib/nagios/plugins/';
use utils qw(%ERRORS &print_revision &support &usage);

$ENV{'PATH'}='/bin:/usr/bin:/sbin:/usr/sbin';
$ENV{'BASH_ENV'}='';
$ENV{'ENV'}='';

my $smartctl = '/usr/sbin/smartctl';
unless (-f $smartctl) {
	print "'".$smartctl."' not found! Please install smartmontools or fix the path to it.\n";
	exit $ERRORS{'UNKNOWN'};
}

use vars qw($opt_d $opt_debug $opt_h $opt_i $opt_r $opt_n $opt_v);
Getopt::Long::Configure('bundling');
GetOptions(
						"debug"			=> \$opt_debug,
	"d=s"	=> \$opt_d,	"device=s"		=> \$opt_d,
	"h"		=> \$opt_h,	"help"			=> \$opt_h,
	"i=s"	=> \$opt_i,	"interface=s"	=> \$opt_i,
	"r=s"	=> \$opt_r,	"raid=s"		=> \$opt_r,
	"n=i"	=> \$opt_n,	"number=i"		=> \$opt_n,
	"v"		=> \$opt_v,	"version"		=> \$opt_v,
);

if ($opt_v) {
	print_revision($basename,$revision);
	exit $ERRORS{'OK'};
}

if ($opt_h) {
	print_help();
	exit $ERRORS{'OK'};
}

# Check command line options
my ($device, $interface, $raid, $number) = qw//;
if ($opt_d) {
	unless($opt_i){
		print "Must specify an interface for $opt_d using -i/--interface!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}

# don´t check anymore as this interferes with RAID
#	if (-b $opt_d){
		$device = $opt_d;
#	}
#	else{
#		print "$opt_d is not a valid block device!\n\n";
#		print_help();
#		exit $ERRORS{'UNKNOWN'};
#	}

	if(grep {$opt_i eq $_} ('ata', 'scsi')){
		$interface = $opt_i;
	}
	else{
		print "Invalid interface $opt_i for $opt_d!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}
}
else{
	print "Must specify a device!\n\n";
	print_help();
	exit $ERRORS{'UNKNOWN'};
}

# RAID options
if ($opt_r) {
	if(grep {$opt_r eq $_} ('megaraid', 'cciss')){
		$raid = $opt_r;
	}
	else{
		print "Invalid RAID $opt_r!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}

	unless(defined($opt_n)){
		print "Must specify a disk number for $opt_r using -n/--number!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}
	else{
		# ID of disk behind RAID controller
		$number = $opt_n;
	}
}

# Prepare SMART command and params
my $smart_command = '/usr/bin/sudo '.$smartctl;
my @error_messages = qw//;
my $exit_status = 'OK';

my $smart_params = ' '.$device;

if(defined($raid) && defined($number)){
	$smart_params = $smart_params.' -d '.$raid.','.$number;
}

warn "###########################################################\n" if $opt_debug;
warn "(debug) CHECK 1: getting overall SMART health status\n" if $opt_debug;
warn "###########################################################\n" if $opt_debug;

my $full_command = "$smart_command -H".$smart_params;
warn "(debug) executing:\n$full_command\n" if $opt_debug;

my @output = `$full_command`;
warn "(debug) output:\n@output\n" if $opt_debug;

# parse ata output
my $found_status = 0;

# ATA
my $line_str = 'SMART overall-health self-assessment test result: ';
my $ok_str = 'PASSED';

if ($interface eq 'scsi'){
	$line_str = 'SMART Health Status: ';
	$ok_str = 'OK';
}

warn "(debug) looking for line:\n$line_str\n" if $opt_debug;
foreach my $line (@output){
	if($line =~ /$line_str(.+)/){
		$found_status = 1;
		warn "(debug) parsing line:\n$line\n" if $opt_debug;
		if ($1 eq $ok_str) {
			warn "(debug) found string '$ok_str'; status OK\n" if $opt_debug;
		}
		else {
			warn "(debug) no '$ok_str' status; failing\n" if $opt_debug;
			push(@error_messages, "Health status: $1");
			escalate_status('CRITICAL');
		}
	}
}

unless ($found_status) {
	push(@error_messages, 'No health status line found');
	escalate_status('UNKNOWN');
}


warn "###########################################################\n" if $opt_debug;
warn "(debug) CHECK 2: getting silent SMART health check\n" if $opt_debug;
warn "###########################################################\n" if $opt_debug;

$full_command = "$smart_command -q silent -A".$smart_params;
warn "(debug) executing:\n$full_command\n" if $opt_debug;

system($full_command);
my $return_code = $?;
warn "(debug) return code: $return_code\n" if $opt_debug;

if ($return_code) {
	warn "(debug) non-zero exit code, generating error condition\n" if $opt_debug;
} else {
	warn "(debug) zero exit code, status OK\n" if $opt_debug;
}

if ($return_code & 0x01) {
	push(@error_messages, 'Commandline parse failure');
	escalate_status('UNKNOWN');
} elsif ($return_code & 0x02) {
	push(@error_messages, 'Device could not be opened');
	escalate_status('UNKNOWN');
} elsif ($return_code & 0x04) {
	push(@error_messages, 'Checksum failure');
	escalate_status('WARNING');
} elsif ($return_code & 0x08) {
	push(@error_messages, 'Disk is failing');
	escalate_status('CRITICAL');
} elsif ($return_code & 0x10) {
	push(@error_messages, 'Disk is in prefail');
	escalate_status('WARNING');
} elsif ($return_code & 0x20) {
	push(@error_messages, 'Disk may be close to failure');
	escalate_status('WARNING');
} elsif ($return_code & 0x40) {
	push(@error_messages, 'Error log contains errors');
	escalate_status('WARNING');
} elsif ($return_code & 0x80) {
	push(@error_messages, 'Self-test log contains errors');
	escalate_status('WARNING');
} elsif ($return_code != 0) {
	push(@error_messages, 'Unknown return code: '.$return_code);
	escalate_status('UNKNOWN');
}


warn "###########################################################\n" if $opt_debug;
warn "(debug) CHECK 3: getting detailed statistics\n" if $opt_debug;
warn "(debug) information contains a few more potential trouble spots\n" if $opt_debug;
warn "(debug) plus, we can also use the information for perfdata/graphing\n" if $opt_debug;
warn "###########################################################\n" if $opt_debug;

$full_command = "$smart_command -A".$smart_params;
warn "(debug) executing:\n$full_command\n" if $opt_debug;
@output = `$full_command`;
warn "(debug) output:\n@output\n" if $opt_debug;
my @perfdata = qw//;

# separate metric-gathering and output analysis for ATA vs SCSI SMART output
if ($interface eq 'ata'){
	foreach my $line(@output){
		# get lines that look like this:
		#    9 Power_On_Minutes        0x0032   241   241   000    Old_age   Always       -       113h+12m
		next unless $line =~ /^\s*\d+\s(\S+)\s+(?:\S+\s+){6}(\S+)\s+(\d+)/;
		my ($attribute_name, $when_failed, $raw_value) = ($1, $2, $3);
		if ($when_failed ne '-'){
			push(@error_messages, "Attribute $attribute_name failed at $when_failed");
			escalate_status('WARNING');
			warn "(debug) parsed SMART attribute $attribute_name with error condition:\n$when_failed\n" if $opt_debug;
		}
		# some attributes produce questionable data; no need to graph them
		if (grep {$_ eq $attribute_name} ('Unknown_Attribute', 'Power_On_Minutes') ){
			next;
		}
		push (@perfdata, "$attribute_name=$raw_value");

		# do some manual checks
		if ( ($attribute_name eq 'Current_Pending_Sector') && $raw_value ) {
			push(@error_messages, "Sectors pending re-allocation");
			escalate_status('WARNING');
			warn "(debug) Current_Pending_Sector is non-zero ($raw_value)\n" if $opt_debug;
		}
	}
}
else{
	my ($current_temperature, $max_temperature, $current_start_stop, $max_start_stop) = qw//;
	foreach my $line(@output){
		if ($line =~ /Current Drive Temperature:\s+(\d+)/){
			$current_temperature = $1;
		}
		elsif ($line =~ /Drive Trip Temperature:\s+(\d+)/){
			$max_temperature = $1;
		}
		elsif ($line =~ /Current start stop count:\s+(\d+)/){
			$current_start_stop = $1;
		}
		elsif ($line =~ /Recommended maximum start stop count:\s+(\d+)/){
			$max_start_stop = $1;
		}
		elsif ($line =~ /Elements in grown defect list:\s+(\d+)/){
			push (@perfdata, "defect_list=$1");
		}
		elsif ($line =~ /Blocks sent to initiator =\s+(\d+)/){
			push (@perfdata, "sent_blocks=$1");
		}
	}
	if($current_temperature){
		if($max_temperature){
			push (@perfdata, "temperature=$current_temperature;;$max_temperature");
			if($current_temperature > $max_temperature){
				warn "(debug) Disk temperature is greater than max ($current_temperature > $max_temperature)\n" if $opt_debug;
				push(@error_messages, 'Disk temperature is higher than maximum');
				escalate_status('CRITICAL');
			}
		}
		else{
			push (@perfdata, "temperature=$current_temperature");
		}
	}
	if($current_start_stop){
		if($max_start_stop){
			push (@perfdata, "start_stop=$current_start_stop;$max_start_stop");
			if($current_start_stop > $max_start_stop){
				warn "(debug) Disk start_stop is greater than max ($current_start_stop > $max_start_stop)\n" if $opt_debug;
				push(@error_messages, 'Disk start_stop is higher than maximum');
				escalate_status('WARNING');
			}
		}
		else{
			push (@perfdata, "start_stop=$current_start_stop");
		}
	}
}
warn "(debug) gathered perfdata:\n@perfdata\n" if $opt_debug;
my $perf_string = join(' ', @perfdata);

warn "###########################################################\n" if $opt_debug;
warn "(debug) FINAL STATUS: $exit_status\n" if $opt_debug;
warn "###########################################################\n" if $opt_debug;

warn "(debug) final status/output:\n" if $opt_debug;

my $status_string = '';

if($exit_status ne 'OK'){
	$status_string = "$exit_status: ".join(', ', @error_messages);
}
else {
	$status_string = "OK: no SMART errors detected";
}

print "$status_string|$perf_string\n";
exit $ERRORS{$exit_status};

sub print_help {
	print_revision($basename,$revision);
	print "Usage: $basename (--device=<SMART device> --interface=(ata|scsi)|-h|-v) [--raid=(megaraid|cciss) --number=<disk ID>] [--debug]\n";
	print "  --debug: show debugging information\n";
	print "  -d/--device: a device to be SMART monitored, eg /dev/sda\n";
	print "  -i/--interface: ata/scsi depending upon the device's interface type\n";
	print "  -r/--raid: megaraid|cciss if using a RAID\n";
	print "  -n/--number: physical disk number within a RAID controller\n";
	print "  -h/--help: this help\n";
	print "  -v/--version: Version number\n";
	support();
}

# escalate an exit status if it's more severe than the previous exit status
sub escalate_status {
	my $requested_status = shift;
	# no test for 'CRITICAL'; automatically escalates upwards
	if ($requested_status eq 'WARNING') {
		return if $exit_status eq 'CRITICAL';
	}
	if ($requested_status eq 'UNKNOWN') {
		return if $exit_status eq 'WARNING';
		return if $exit_status eq 'CRITICAL';
	}
	$exit_status = $requested_status;
}
