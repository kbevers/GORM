#!/usr/bin/perl
#
# Common subroutines for the GPS monitor scripts. This module cannot be instantiated.
#
# Soren Juul Moller, August 2012.
# Soren Juul Moller, Nov 2019

package Utils;

use strict;
use warnings;

use POSIX qw(strftime);
use IO::File;
use File::stat;
use File::Path qw(make_path);
use Net::SMTP;
use Date::Manip::Base;
use JSON;
use BaseConfig;
use Logger;

our $CRX2RNX = '/usr/local/bin/crx2rnx';
our $RNX2CRX = '/usr/local/bin/rnx2crx';
our $TEQC = '/usr/local/bin/teqc';
our $CONVERT = '/usr/local/bin/convert';
our $RUNPKR = '/usr/bin/runpkr00';

our $DMB;

# Export subs and symbols to other modules.
our (@ISA, @EXPORT);
BEGIN {
  require Exporter;
  @ISA = qw(Exporter);
  @EXPORT = qw(
	sysrun syscp sysmv
	Day_of_Year Doy_to_Date Doy_to_Days Days_to_Date Date_to_Days
	sy2year year2sy letter2hour hour2letter gm2str
	basename dirname fileage dirlist
	loadJSON storeJSON parseFilename
	$CRX2RNX $RNX2CRX $TEQC $CONVERT $RUNPKR
  );
  $DMB = new Date::Manip::Base;
}


##########################################################################
# Perform shell command and log.
#
sub sysrun($;$) {
  my ($cmd, $opts) = @_;
  $opts = {} unless defined $opts;
  loginfo($cmd) if $$opts{'log'};
  system($cmd);
  if ($? == -1) {
    logerror("failed to execute: $!");
    return -1;
  }
  if ($? & 127) {
    logfmt("err", "child died with signal %d, %s coredump",
			   ($? & 127), ($? & 128 ? "with":"without"));
    return -1;
  }
  return $? >> 8;
}


##########################################################################
# Copy/Move file(s).
# Do NOT use File::Copy as it does not close handles. Inotify2 depend on it.
# Do NOT use rename/link/unlink. Inotify2 will not detect it properly.
#
sub _eval_cp_args($$$$) {
  my ($cmd, $srclist, $dst, $opts) = @_;

  $srclist = join(' ', @$srclist) if ref($srclist) eq "ARRAY";
  loginfo("$cmd $srclist $dst") if $$opts{'log'};
  make_path($dst) if $$opts{'mkdir'} && ! -d $dst;
  return system("/bin/$cmd $srclist $dst");
}

sub syscp($$;$) {
  my ($srclist, $dst, $opts) = @_;
  $opts = {} unless defined $opts;
  return _eval_cp_args('cp', $srclist, $dst, $opts);
}

sub sysmv($$;$) {
  my ($srclist, $dst, $opts) = @_;
  $opts = {} unless defined $opts;
  return _eval_cp_args('mv', $srclist, $dst, $opts);
}


##########################################################################
# Convert (year, mon, day) to DOY
#
sub Day_of_Year($$$) {
  my @ymd = @_;
  return $DMB->day_of_year(\@ymd);
}


##########################################################################
# Convert (year, day) to (year, mon, day)
#
sub Doy_to_Date($$) {
  my ($year, $doy) = @_;
  my $ymd = $DMB->day_of_year($year, $doy);
  return @$ymd;
}


##########################################################################
# Convert (year, day) to jday
#
sub Doy_to_Days($$) {
  my ($year, $doy) = @_;
  my $ymd = $DMB->day_of_year($year, $doy);
  return $DMB->days_since_1BC($ymd);
}


##########################################################################
# Convert jday to (year, mon, day, doy) 
# jday is number of days since 31 dec 1BC
#
sub Days_to_Date($) {
  my $jday = shift;

  my $ymd = $DMB->days_since_1BC($jday);
  my $doy = $DMB->day_of_year($ymd);
  return (@$ymd, $doy);
}


##########################################################################
# Convert (year, mon, day) to jday
#
sub Date_to_Days(@) {
  my @ymd = @_;
  return $DMB->days_since_1BC(\@ymd);
}


##########################################################################
# Returns YYYY version of YY
#
sub sy2year($) {
  my $sy = shift;
  return $sy + ($sy < 80 ? 2000 : 1900);
}


##########################################################################
# Returns YY version of YYYY
#
sub year2sy($) {
  my $year = shift;
  return $year % 100;
}


##########################################################################
# Returns the letter representation of an integer hour
#
sub hour2letter($) {
  my $hh = shift;
  return chr(ord('a')+$hh);
}


##########################################################################
# Returns the integer representation of a letter hour
#
sub letter2hour($) {
  my $letter = shift;
  return 0 if $letter eq '0';
  return ord(lc($letter))-97;
}


##########################################################################
# Format GM time
#
sub gm2str($) {
  my $gm = shift;
  return strftime("%Y-%m-%d %H:%M:%S", gmtime($gm));
}

##########################################################################
# Returns basename of filename
#
sub basename($) {
  my $fn = shift;
  my $i = rindex($fn, '/');
  return ($i >= 0 ? substr($fn, $i+1) : $fn);
}


##########################################################################
# Returns dirname of filename
#
sub dirname($) {
  my $fn = shift;
  my $i = rindex($fn, '/');
  return "/" if $i == 0;
  return ($i >= 0 ? substr($fn, 0, $i) : ".");
}

##########################################################################
# Returns age of file in seconds.
# Returns 0 if file does not exists.
#
sub fileage($) {
  my $fn = shift;
  my $st = stat($fn);
  return (defined $st ? time() - $st->mtime : 0);
}


##########################################################################
# Returns array of plain files in list context or number of plain files in
# scalar context. Files are relative to specified directory.
#
sub dirlist($) {
  my $dir = shift;
  my @files = ();
  if (opendir(my $dh, $dir)) {
    @files = grep { -f $dir.'/'.$_ } readdir($dh);
    closedir($dh);
  }
  return (wantarray ? @files : scalar(@files));
}


##########################################################################################
# Load a JSON file into a hash reference
#
sub loadJSON($) {
  my $file = shift;
  local $/;  # enable slurp
  open(my $fh, '<', $file) || return undef;
  my $json = <$fh>;
  close($fh);
  return undef if !defined $json || length($json) == 0;
  return from_json($json);
}


##########################################################################################
# Store a hash reference in the named file
#
sub storeJSON($$) {
  my ($file, $ref) = @_;
  open(my $fh, '>', $file) || die("cannot create $file: $!");
  print $fh to_json($ref, { utf8 => 1, pretty => 1, canonical => 0 });
  close($fh);
}


##########################################################################################
# Extract date and time from a filename
# Returns a hash reference with info or undef if not recognized.
#
sub parseFilename($) {
  my $fn = shift;
  my ($site, $site4, $year, $yy, $doy, $mm, $dd, $hour, $hh, $mi);
  study($fn);
  # Trinzic: ssssyyyymmddhhmiB.zip
  # Leica:   ssssdddh*.yyo.zip
  # Septentrio: sssssssss_R_yyyydddhhmi_##H_##S_MO.rnx
  #             sssssssss_R_yyyydddhhmi_##H_xN.rnx
  if ($fn =~ /^([a-z0-9]{4})([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})B\.zip$/i) {
    ($site4, $year, $yy, $mm, $dd, $hh, $hour, $mi) =
		(uc($1), int($2), year2sy($2), int($3), int($4), int($5), hour2letter($5), int($6));
    $yy = year2sy($year);
    $doy = Day_of_Year($year, $mm, $dd);
  }
  elsif ($fn =~ /^([a-zA-Z0-9]{4})([0-9]{3})([a-xA-X0]).*\.([0-9]{2})[a-z]\.zip$/i) {
    ($site4, $doy, $hour, $hh, $yy, $year, $mi) = (uc($1), int($2), $3, letter2hour($3), int($4), sy2year($4), 0);
    ($year, $mm, $dd) = Doy_to_Date($year, $doy);
  }
  elsif ($fn =~ /^([A-Z0-9]{9})_R_([0-9]{4})([0-9]{3})([0-9]{2})([0-9]{2})/i) {
    ($site, $year, $yy, $doy, $hh, $hour, $mi) = (uc($1), int($2), year2sy($2), int($3), int($4), hour2letter($4), int($5));
    ($year, $mm, $dd) = Doy_to_Date($year, $doy);
  }
  return undef if !defined $site && !defined $site4;
  if (!defined $site) {
    $site = $site4."00DNK";
    $site = $site4."00FRO" if $site4 eq 'ARGI';
  }
  $site4 = substr($site, 0, 4) if !defined $site4;

  return { site => $site, site4 => $site4, year => $year, doy => $doy, yy => $yy, mm => $mm, dd => $dd,
           hour => $hour, hh => $hh, mi => $mi };
}

1;
