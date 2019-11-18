#!/usr/bin/perl

package Job;

use strict;
use warnings;
use Data::Dumper;
use JSON;
use Fcntl qw(:DEFAULT :flock);
use lib '/home/gpsuser';
use BaseConfig;
use Utils;
use Logger;
use RinexSet;
use GPSDB;

sub new {
  my $class = shift;
  my %args = @_;
  my $self = { source => 'unknown' };

  if (exists $args{'jobfile'}) {
    my $href = loadJSON($args{'jobfile'});
    $self->{$_} = $$href{$_} foreach keys %$href;
  } else {
    $self->{$_} = $args{$_} foreach keys %args;
  }
  bless($self, $class);
  return $self;
}

sub getIdent() {
  my $self = shift;
  return $self->{'site'}.'-'.$self->{'year'}.'-'.$self->{'doy'}.'-'.$self->{'hour'};
}

sub jobfile() {
  my $self = shift;
  return "$JOBQUEUE/".$self->{'site'}.$self->{'year'}.$self->{'doy'}.$self->{'hour'};
}

sub getWorkdir() {
  my $self = shift;
  return sprintf("%s/%s/%d/%03d", $WORKDIR, $self->{'site'}, $self->{'year'}, $self->{'doy'});
}

sub mkWorkdir() {
  my $self = shift;
  my $dir = $self->getWorkdir();
  system("/bin/mkdir -p -m 777 $dir") unless -d $dir;
  return $dir;
}

# Write this job in $JOBQUEUE
sub submitjob($) {
  my $self = shift;
  my $source = shift;
  my %h = map { $_ => $self->{$_} } keys %$self;
  $h{'source'} = $source;
  storeJSON($self->jobfile(), \%h);
}

# Delete this job from $JOBQUEUE
sub deletejob() {
  my $self = shift;
  unlink($self->jobfile());
}

##########################################################################################
# Fetch station info from database for the RINEX header
#
sub getStationInfo($$) {
  my ($self, $startdate) = @_;
  my $dbh = $self->{'DB'}->{'DBH'};

  my $sql = qq{
	select	rectype, serialno, firmware
	from	receivers
	where	site = ?
	  and	startdate < str_to_date(?, '%Y-%m-%d %T')
	order	by startdate desc
	limit	1
  };
  my $rcvrow = $dbh->selectrow_hashref($sql, undef, uc($self->{'site'}), $startdate);

  $sql = qq{
	select	anttype, serialno
	from	antennas
	where	site = ?
	  and	startdate < str_to_date(?, '%Y-%m-%d %T')
	order	by startdate desc
	limit	1
  };
  my $antrow = $dbh->selectrow_hashref($sql, undef, uc($self->{'site'}), $startdate);
  if ($antrow->{anttype} =~ /,/) {
    my @a = split(/,/, $antrow->{anttype});
    $antrow->{anttype} = sprintf("%-16s%s", $a[0], $a[1]);
  }

  return ($rcvrow, $antrow);
}

##########################################################################################
# Decimate observation from $src_interval to $dst_interval
#
sub _decimate($$$$$) {
  my ($obsinfile, $obsoutfile, $src_interval, $dst_interval, $logfile) = @_;

  if ($src_interval < $dst_interval) {
    loginfo("decimate $obsinfile to $obsoutfile");
    my $cmd =
	"$BNC -nw -conf /dev/null --key reqcAction Edit/Concatenate ".
	"--key reqcRunBy SDFE ".
	"--key reqcObsFile $obsinfile ".
	"--key reqcOutObsFile $obsoutfile ".
	"--key reqcOutLogFile $logfile ".
	"--key reqcRnxVersion 3 ".
	"--key reqcSampling $dst_interval";
    sysrun($cmd);
  }
}

##########################################################################################
# Splice hourly observation file for the given interval
#
sub _splice($$$) {
  my ($rsday, $rslist, $interval) = @_;

  my $outfile = $rsday->getRinexFilename('MO.'.$interval);
  loginfo("Creating $outfile");
  my @infiles = ();
  push(@infiles, $_->{'MO.'.$interval}) foreach @$rslist;
  my $cmd =
	"$BNC -nw --conf /dev/null --key reqcAction Edit/Concatenate ".
	"--key reqcRunBy SDFE ".
	"--key reqcRnxVersion 3 ".
	"--key reqcObsFile \"".join(',',@infiles)."\" ".
	"--key reqcOutObsFile $outfile";
  sysrun($cmd);
  $rsday->{'MO.'.$interval} = $outfile;
}

##########################################################################################
# Check if a hourly site day is complete.
# If so, splice hourly files into a day file and submit a new job
#
sub gendayfiles() {
  my $self = shift;
  my $dbh = $self->{DB}->{DBH};
  my ($site, $year, $doy) = ($self->{'site'}, $self->{'year'}, $self->{'doy'});
  my @rslist = ();
  my $rsday = new RinexSet(site => $site, year => $year, doy => $doy, hour => '0');

  loginfo("Generating daily files for $site-$year-$doy");
  foreach my $h ('a'..'x') {
    my $rs = new RinexSet(site => $site, year => $year, doy => $doy, hour => $h);
    if (-f $rs->getRsFile()) {
      $rs->load();
      next unless exists $rs->{'processed'};
      $rs->checkfiles();
      push(@rslist, $rs);
    }
  }
  if (scalar(@rslist) != 24 && ! -f 'force-complete') {
    unlink("daily.lock");
    return;
  }

  # all hourfiles processed or forced.
  print "$site $year-$doy complete\n";

  # Splice navigation files
  my %navbytyp;
  foreach my $rs (@rslist) {
    my $navlist = $rs->getNavlist;
    foreach (@$navlist) {
      if (/_([A-Z]N)\./) {
        my $navtyp = $1;
        $navbytyp{$navtyp} = [] unless exists $navbytyp{$navtyp};
        push(@{$navbytyp{$navtyp}}, $_);
      }
    }
  }
  foreach my $navtyp (keys %navbytyp) {
    my $navoutfile = $rsday->getRinexFilename($navtyp);
    my $aref = $navbytyp{$navtyp};
    my $cmd = "$GFZRNX -f -kv -q -finp ".join(' ',@$aref)." -fout $navoutfile";
    sysrun($cmd);
    $rsday->{$navtyp} = $navoutfile;
  }


  # Do we need 1s dayfile?
  my $interval = 30;
  my $aref = $dbh->selectrow_arrayref(q{
	select count(*) from rinexdist
	where  site = ? and freq = 'D' and filetype = 'Obs' and obsint = 1
  }, undef, $site);
  if ($aref->[0] ne '0') {
    $interval = 1;
    _splice($rsday, \@rslist, 1);
  }
  $rsday->{'interval'} = $interval;

  # create 30s dayfile as we know we need it for QC
  _splice($rsday, \@rslist, 30);

  $rsday->store();
  return $rsday;
  # my $dayjob = new Job(site => $site, year => $year, doy => $doy, hour => '0',
  #                      interval => $interval, rsfile => $rsday->getRsFile);
  # $dayjob->submitjob('daily');
}

###################################################
# decimate obs into intervals we need to distribute
#
sub createWantedIntervals($) {
  my ($self, $rs) = @_;
  my $dbh = $self->{'DB'}->{'DBH'};
  my ($site, $srcinterval) = ($self->{'site'}, $self->{'interval'});

  my $aref = $self->{'DB'}->{'DBH'}->selectall_arrayref(q{
	select distinct obsint from rinexdist where site = ?
  }, { Slice => {} }, $self->{'site'});
  my %intervals = map { $_->{'obsint'} => 1 } @$aref;
  $intervals{'30'} = 1;  # always need 30s files

  foreach my $interval (keys %intervals) {
    next if $interval == $srcinterval || exists $rs->{'MO.'.$interval};
    if ($interval < $srcinterval) {
      logerror("Cannot create ${interval}s RINEX based in ${srcinterval}s RINEX files");
      next;
    }
    # decimate this into requested interval
    my $obs = $rs->getRinexFilename('MO.'.$interval);
    _decimate($rs->{'MO.'.$srcinterval}, $obs, $srcinterval, $interval, "dec.$rs->{hour}.$interval.log");
    $rs->{'MO.'.$interval} = $obs;
  }
}

sub is_complete() {
  my $self = shift;
  return 1 if -f "force-complete";
  foreach my $h ('a'..'x') {
    return 0 unless -f "rs.$h.json";
    my $rs = new RinexSet(rsfile => "rs.$h.json");
    return 0 unless defined $rs->{processed};
  }
  return 1;
}

###################################################################################
# Main processor. This is where the actual processing of RINEX files happen.
#
sub process() {
  my $self = shift;

  return unless sysopen(LOCK, $self->{'hour'}.'.lock', O_CREAT|O_EXCL);
  close(LOCK);

  $self->{DB} = new GPSDB;
  my $dbh = $self->{DB}->{DBH};

  my $rs;
  if ($self->{'source'} eq 'hour2daily') {
    $rs = $self->gendayfiles();
  } else {
    $rs = new RinexSet(rsfile => $self->{rsfile});
  }

  my ($site, $year, $doy, $hour) = ($self->{'site'}, $self->{'year'}, $self->{'doy'}, $self->{'hour'});
  my $hh24 = ($hour eq '0') ? 0 : letter2hour($hour);
  my $freq = $hour eq '0' ? 'D':'H';
  my @tmpfiles = ();

  #################
  # Patch RINEX header
  #
  if ($self->{'source'} eq 'ftp') {
    my $obs = $rs->{'MO.'.$self->{'interval'}};
    my @ymd = Doy_to_Date($year, $doy);
    my ($rcv,$ant) = $self->getStationInfo(sprintf("%4d-%02d-%02d %02d:00:00", @ymd, $hh24));
    my $cmd =
	"$BNC --nw --conf /dev/null --key reqcAction Edit/Concatenate ".
	"--key reqcRunBy SDFE ".
	"--key reqcRnxVersion 3 ".
	"--key reqcOutLogFile patch.$hour.log ".
	"--key reqcObsFile $obs ".
	"--key reqcOutObsFile $obs.tmp ".
	"--key reqcNewMarkerName $site ".
	"--key reqNewReceiverName \"$rcv->{rectype}\" ".
	"--key reqcNewReceiverNumber $rcv->{serialno} ".
	"--key reqcNewAntennaName \"$ant->{anttype}\" ".
	"--key reqcNewAntennaNumber $ant->{serialno}"
    ;
    sysrun($cmd);
    system("mv $obs.tmp $obs");
    push(@tmpfiles, "patch.$hour.log");
  }

  #################################
  # Produce wanted intervals.
  #
  $self->createWantedIntervals($rs);

  #################
  # QC on 30s file
  #
  my $sumfile = $rs->getFilenamePrefix().'.sum';
  my $navfiles = $rs->getNavlist();
  my $cmd =
	"$BNC --nw --conf /dev/null --key reqcAction Analyze ".
	"--key reqcObsFile ".$rs->{'MO.30'}." ".
	"--key reqcNavFile \"".join(',',@$navfiles)."\" ".
	"--key reqcLogSummaryOnly 2 ".
	"--key reqcOutLogFile $sumfile"
  ;
  sysrun($cmd);
  # parse sumfile
  open(my $fd, '<', $sumfile);
  my ($obshave, $obspossible, $qc, $ngaps) = (0, 0, 0, 0);
  while (<$fd>) {
    if (/^\s+G:\s+1C: Observations\s+:\s*(\d+)\s+\(\s*(\d+)\)\s+([\d\.]+)/) {
      ($obshave, $obspossible, $qc) = ($1, $2, $3);
    }
    elsif (/^\s+G:\s+1C: Gaps\s+:\s*(\d+)/) {
      $ngaps = $1;
    }
  }
  close($fd);
  loginfo("$site-$year-$doy-$hour: QC: $obshave/$obspossible ($qc)");
  sysrun("gzip -f $sumfile");
  $sumfile .= ".gz";

  $dbh->do(qq{
	delete from gpssums
	where	site = ?
	  and	year = ?
	  and	doy = ?
	  and	hour = ?
  }, undef, $site, $year, $doy, $hour);
  $dbh->do(qq{
	insert into gpssums
	(site, year, doy, hour, jday, expt, have, quality, ngaps)
	values (?, ?, ?, ?, ?, ?, ?, ?, ?)
  }, undef, $site, $year, $doy, $hour, Doy_to_Days($year,$doy), $obspossible, $obshave, $qc, $ngaps);

  push(@tmpfiles, $sumfile);

  #################
  # Distribute
  #
  my $sql = $dbh->prepare(q{
        select  r.obsint, r.filetype, ld.path, s.navlist, ld.name
        from    rinexdist r, localdirs ld, siteconfig s
        where   r.site = ?
          and   r.freq = ?
          and   r.active = 1
          and   r.localdir = ld.name
          and   r.site = s.site
  });
  $sql->execute($site, $freq);
  my $aref = $sql->fetchall_arrayref({});

  foreach my $r (@$aref) {
    next if (-f "do-not-upload" && $r->{'name'} =~ /^ftp-/);

    my $destpath = $r->{'path'};
    $destpath =~ s/%year/$year/g;
    $destpath =~ s/%doy/$doy/g;

    ######
    # Obs
    if ($r->{'filetype'} eq 'Obs') {
      my $filetosend = $rs->{'MO.'.$r->{'obsint'}};
      if (!-f $filetosend) {
        logerror("Cannot distribute $filetosend. Does not exist?!");
        print("Cannot distribute $filetosend. Does not exist?!");
        next;
      }
      # Compress and upload
      my $crxfile = $filetosend;
      $crxfile =~ s/\.rnx$/.crx.gz/;
      if (! -f $crxfile || fileage($filetosend) > fileage($crxfile)) {
        sysrun("$RNX2CRX - < $filetosend | gzip > $crxfile");
        push(@tmpfiles, $crxfile);
      }
      syscp($crxfile, $destpath, { mkdir => 1, log => 1 } );
    }

    ######
    # Nav
    elsif ($r->{'filetype'} eq 'Nav') {
      my @copylist = ();
      foreach my $navfile (@$navfiles) {
        my $gzfile = "$navfile.gz";
        if (! -f $gzfile || fileage($navfile) > fileage($gzfile)) {
          system("gzip < $navfile > $gzfile");
          push(@tmpfiles, $gzfile);
        }
        push(@copylist, $gzfile);
      }
      syscp(\@copylist, $destpath, { mkdir => 1, log => 1 });
    }

    ######
    # Sum
    elsif ($r->{'filetype'} eq 'Sum') {
      syscp($sumfile, $destpath, { mkdir => 1, log => 1 });
    }

    ######
    # Arc
    elsif ($r->{'filetype'} eq 'Arc') {
      syscp($rs->{'zipfile'}, $destpath, { mkdir => 1, log => 1 });
    }

  }

  $rs->{'processed'} = 1;
  $rs->store($self->{rsfile});

  if ($hour eq '0') {
    # This is a dayfile and is now processed. We are done and delete the workdir.
    chdir("..");
    system("echo rm -rf ".$self->getWorkdir);
  }
  unlink("$hour.lock");
  return 0;
}

1;