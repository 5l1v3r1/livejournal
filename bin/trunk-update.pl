#!/usr/bin/perl

use strict;
use IO::Socket::INET;

unless ($ENV{LJHOME}) {
    die "\$LJHOME not set.";
}
chdir "$ENV{LJHOME}" or die "Failed to chdir to \$LJHOME";




update_svn();
my @files = get_updated_files();
sync();
new_phrases() if  grep { /en.+\.dat/ } @files;
update_db() if  grep { /\.sql/ } @files;
bap() if  grep { /cgi-bin.+\.[pl|pm]/ } @files;



sub update_svn {
    system("cvsreport.pl", "-u")
	and die "Failed to run cvsreport.pl with update.";
}

sub get_updated_files {
    my @files = ();
    open(my $cr, "cvsreport.pl -c -1|") or die "Could not run cvsreport.pl";
    while (my $line = <$cr>) {
	$line =~ s/\s+$//;
	push @files, $line;
    }
    close($cr);

    return @files;
}

sub sync {
    system("cvsreport.pl", "-c", "-s")
	and die "Failed to run cvsreport.pl sync second time.";
}

sub update_db {
    system("bin/upgrading/update-db.pl", "-r", "-p")
	and die "Failed to run update-db.pl with -r/-p";

    system("bin/upgrading/update-db.pl", "-r", "--cluster=all")
	and die "Failed to run update-db.pl on all clusters";
}

sub new_phrases {
    my @langs = @_;

    system("bin/upgrading/texttool.pl", "load", @langs)
	and die "Failed to run texttool.pl load @langs";
}

sub bap {
    print "Restarting apache...\n";

    my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:7600")
        or die "Couldn't connect to webnoded (port 7600)\n";

    print $sock "apr\r\n";
    while (my $ln = <$sock>) {
	print "$ln";
	last if $ln =~ /^OK/;
    }
}
