#!/usr/bin/perl
#
# Logger package	Interface for Syslog messages.
#
# This packages provides functions for logging at 5 different levels: debug, info, warn, error and fatal.
# The functions sends the log data to syslog at local1 channel.
#
# sjm@snex.dk, September 2012
#

package Logger;

use strict;
use warnings;
use Carp;
use Sys::Syslog qw(openlog syslog closelog);

my $Channel = 'local1';

my $idx = rindex($0, '/');
our $Program = ($idx >= 0 ? substr($0, $idx+1) : $0);

our (@ISA, @EXPORT);
BEGIN {
  require Exporter;
  @ISA = qw(Exporter);
  @EXPORT = qw(
	logdebug loginfo logwarn logerror logfatal errdie logfmt logconvlog
	setprogram $Program
  );
}

END {
  closelog();
}

sub _openlog() { openlog($Program, "nofatal", $Channel); }

sub setprogram($) {
  closelog();
  $Program = shift;
  _openlog();
}

sub logdebug(@) { _openlog(); syslog("debug|$Channel", "%s", @_);   closelog();  }
sub loginfo(@)  { _openlog(); syslog("info|$Channel", "%s", @_);    closelog();  }
sub logwarn(@)  { _openlog(); syslog("warning|$Channel", "%s", @_); closelog();  }
sub logerror(@) { _openlog(); syslog("err|$Channel", "%s", @_);     closelog();  }

sub logfatal(@) {
  _openlog();
  syslog("err|$Channel", "%s", @_);
  closelog();
  carp localtime().": ".join(' ', @_);
}

sub errdie(@) {
  _openlog();
  syslog("err|$Channel", "%s", @_);
  closelog();
  croak join(' ', @_);
}

sub logfmt(@) {
  my ($level, $fmt, @args) = @_;
  _openlog();
  syslog("$level|$Channel", $fmt, @args);
  closelog();
}

#
# Dump a TEQC conversion stderr log to syslog
#
sub logconvlog($$) {
  my ($tag, $fn) = @_;

  _openlog();
  if (open(my $fd, $fn)) {
    while (<$fd>) {
      s/\s+$//;
      if (/^! Notice ! (.*)/) {
        syslog("info|$Channel", "%s", $tag.": ".$1);
      } elsif (/^! Warning ! (.*)/) {
        syslog("warning|$Channel", "%s", $tag.": ".$1);
      } elsif (/^! Error ! (.*)/) {
        syslog("err|$Channel", "%s", $tag.": ".$1);
      }
    }
    undef $fd;
  }
  closelog();
}

1;