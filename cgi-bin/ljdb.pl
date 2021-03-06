#!/usr/bin/perl
#

use strict;
use lib "$ENV{LJHOME}/cgi-bin";
use DBI::Role;
use DBI;

# need ljconfig to set up database connection
use LJ::Config;
LJ::Config->load;

$LJ::DBIRole = new DBI::Role {
    'timeout' => sub {
        my ($dsn, $user, $pass, $role) = @_;
        return $LJ::MASTER_DB_TIMEOUT || 0 if $role && $role eq "master";
        return $LJ::DB_TIMEOUT;
    },
    'sources' => \%LJ::DBINFO,
    'default_db' => "livejournal",
    'time_check' => 60,
    'time_report' => \&LJ::dbtime_callback,
};

package LJ::DB;

use Carp qw(croak);

# <LJFUNC>
# name: LJ::DB::time_range_to_ids
# des:  Performs a binary search on a table's primary id key looking
#       for time boundaries as specified.  Returns the boundary ids
#       that were found, effectively simulating a key on 'time' for
#       the specified table.
# info: This function shouldn't normally be used, but there are
#       rare instances where it's useful.
# args: opts
# des-opts: A hashref of keys. Keys are:
#           'table' - table name to query;
#           'roles' - arrayref of db roles to use, in order. Defaults to ['slow'];
#           'idcol' - name of 'id' primary key column.
#           'timecol' - name of unixtime column to use for constraint;
#           'starttime' - starting unixtime time of rows to match;
#           'endtime' - ending unixtime of rows to match.
# returns: startid, endid; id boundaries which should be used by
#          the caller.
# </LJFUNC>

sub time_range_to_ids {
    my %args = @_;

    my $table     = delete $args{table}     or croak("no table arg");
    my $idcol     = delete $args{idcol}     or croak("no idcol arg");
    my $timecol   = delete $args{timecol}   or croak("no timecol arg");
    my $starttime = delete $args{starttime} or croak("no starttime arg");
    my $endtime   = delete $args{endtime}   or croak("no endtime arg");
    my $roles     = delete $args{roles};
    unless (ref $roles eq 'ARRAY' && @$roles) {
        $roles = [ 'slow' ];
    }
    croak("bogus args: " . join(",", keys %args))
        if %args;

    my $db = LJ::get_dbh(@$roles)
        or die "unable to acquire db handle, roles=", join(",", @$roles);

    my ($db_min_id, $db_max_id) = $db->selectrow_array
        ("SELECT MIN($idcol), MAX($idcol) FROM $table");
    die $db->errstr if $db->err;
    die "error finding min/max ids: $db_max_id < $db_min_id"
        if $db_max_id < $db_min_id;

    # final output
    my ($startid, $endid);
    my $ct_max = 100;

    foreach my $curr_ref ([$starttime => \$startid], [$endtime => \$endid]) {
        my ($want_time, $dest_ref) = @$curr_ref;

        my ($min_id, $max_id) = ($db_min_id, $db_max_id);

        my $curr_time = 0;
        my $last_time = 0;

        my $ct = 0;
        while ($ct++ < $ct_max) {
            die "unable to find row after $ct tries" if $ct > 100;

            my $curr_id = $min_id + int(($max_id - $min_id) / 2)+0;

            my $sql =
                "SELECT $idcol, $timecol FROM $table " .
                "WHERE $idcol>=$curr_id ORDER BY 1 LIMIT 1";

            $last_time = $curr_time;
            ($curr_id, $curr_time) = $db->selectrow_array($sql);
            die $db->errstr if $db->err;

            # stop condition, two trigger cases:
            #  * we've found exactly the time we want
            #  * we're still narrowing but not finding rows in between, stop here with
            #    the current time being just short of what we were trying to find
            if ($curr_time == $want_time || $curr_time == $last_time) {

                # if we never modified the max id, then we
                # have searched to the end without finding
                # what we were looking for
                if ($max_id == $db_max_id && $curr_time <= $want_time) {
                    $$dest_ref = $max_id;

                # same for min id
                } elsif ($min_id == $db_min_id && $curr_time >= $want_time) {
                    $$dest_ref = $min_id;

                } else {
                    $$dest_ref = $curr_id;
                }
                last;
            }

            # need to traverse into the larger half
            if ($curr_time < $want_time) {
                $min_id = $curr_id;
                next;
            }

            # need to traverse into the smaller half
            if ($curr_time > $want_time) {
                $max_id = $curr_id;
                next;
            }
        }
    }

    return ($startid, $endid);
}

sub _connection_options {
    my $options = {
        'AutoCommit' => 1,
        'RaiseError' => 0,
        'PrintError' => 0,
    };

    if ( $LJ::IS_DEV_SERVER ) {
        $options->{'RaiseError'} = 1;
    }
    else {
        $options->{'PrintError'} = 1;
    }

    return { 'connection_opts' => $options };
}

sub dbh_by_role {
    return $LJ::DBIRole->get_dbh( _connection_options(), @_ );
}

sub dbh_by_name {
    my $name = shift;
    my $dbh = dbh_by_role("master")
        or die "Couldn't contact master to find name of '$name'\n";

    my $fdsn = $dbh->selectrow_array("SELECT fdsn FROM dbinfo WHERE name=?", undef, $name);
    die "No fdsn found for db name '$name'\n" unless $fdsn;

    return $LJ::DBIRole->get_dbh_conn( _connection_options(), $fdsn );

}

sub dbh_by_fdsn {
    my $fdsn = shift;
    return $LJ::DBIRole->get_dbh_conn( _connection_options(), $fdsn );
}

sub root_dbh_by_name {
    my $name = shift;
    my $dbh = dbh_by_role("master")
        or die "Couldn't contact master to find name of '$name'";

    my $fdsn = $dbh->selectrow_array("SELECT rootfdsn FROM dbinfo WHERE name=?", undef, $name);
    die "No rootfdsn found for db name '$name'\n" unless $fdsn;

    return $LJ::DBIRole->get_dbh_conn( _connection_options(), $fdsn );
}

sub user_cluster_details {
    my $name = shift;
    my $dbh = dbh_by_role("master") or die;

    my $role = $dbh->selectrow_array("SELECT role FROM dbweights w, dbinfo i WHERE i.name=? AND i.dbid=w.dbid",
                                     undef, $name);
    return () unless $role && $role =~ /^cluster(\d+)([ab])$/;
    return ($1, $2);
}

package LJ;

use Carp qw(croak);
use LJ::User qw//;

# when calling a supported function (currently: LJ::load_user() or LJ::load_userid*), LJ::SMS::load_mapping()
# ignores in-process request cache, memcache, and selects directly
# from the global master
#
# called as: require_master(sub { block })
sub require_master {
    my $callback = shift;
    croak "invalid code ref passed to require_master"
        unless ref $callback eq 'CODE';

    # run code in the block with local var set
    local $LJ::_PRAGMA_FORCE_MASTER = 1;
    return $callback->();
}

sub no_cache {
    my $sb = shift;
    local $LJ::MemCache::GET_DISABLED = 1;
    return $sb->();
}

sub cond_no_cache {
    my ($cond, $sb) = @_;
    return no_cache($sb) if $cond;
    return $sb->();
}

sub no_ml_cache {
    my $sb = shift;
    local $LJ::NO_ML_CACHE = 1;
    return $sb->();
}

# <LJFUNC>
# name: LJ::get_dbh
# class: db
# des: Given one or more roles, returns a database handle.
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub get_dbh {
    my $opts = ref $_[0] eq "HASH" ? shift : {};

    unless (exists $opts->{'max_repl_lag'}) {
        # for slave or cluster<n>slave roles, don't allow lag
        if ($_[0] =~ /slave$/) {
            $opts->{'max_repl_lag'} = $LJ::MAX_REPL_LAG || 100_000;
        }
    }

    if ($LJ::DEBUG{'get_dbh'} && $_[0] ne "logs") {
        my $errmsg = "get_dbh(@_) at \n";
        my $i = 0;
        while (my ($p, $f, $l) = caller($i++)) {
            next if $i > 3;
            $errmsg .= "  $p, $f, $l\n";
        }
        warn $errmsg;
    }

    my $nodb = sub {
        my $roles = shift;
        my $err = LJ::errobj("Database::Unavailable",
                             roles => $roles);
        return $err->cond_throw;
    };

    foreach my $role (@_) {
        # let site admin turn off global master write access during
        # maintenance
        return $nodb->([@_]) if $LJ::DISABLE_MASTER && $role eq "master";
        my $db = LJ::get_dbirole_dbh($opts, $role);
        return $db if $db;
    }
    return $nodb->([@_]);
}

sub get_db_reader {
    return LJ::get_dbh("master") if $LJ::_PRAGMA_FORCE_MASTER;
    return LJ::get_dbh("slave", "master");
}

sub get_db_writer {
    return LJ::get_dbh("master");
}

# Use the uniq DB if available, otherwise fall back to the main database
# Force the use of the uniq DB by setting $LJ::_PRAGMA_FORCE_UNIQ
sub get_uniq_db_reader {
    if ($LJ::_PRAGMA_FORCE_UNIQ) {
        return $LJ::_PRAGMA_FORCE_MASTER ?
            LJ::get_dbh("uniq_master") :
            LJ::get_dbh("uniq_slave", "uniq_master");
    }
    return LJ::get_dbh("uniq_master", "master") if $LJ::_PRAGMA_FORCE_MASTER;
    return LJ::get_dbh("uniq_slave", "uniq_master", "slave", "master");
}

sub get_uniq_db_writer {
    return LJ::get_dbh("uniq_master") if $LJ::_PRAGMA_FORCE_UNIQ;
    return LJ::get_dbh("uniq_master", "master");
}

# <LJFUNC>
# name: LJ::get_cluster_reader
# class: db
# des: Returns a cluster slave for a user, or cluster master if no slaves exist.
# args: uarg
# des-uarg: Either a userid scalar or a user object.
# returns: DB handle.  Or undef if all dbs are unavailable.
# </LJFUNC>
sub get_cluster_reader
{
    return LJ::get_cluster_master(@_);
}

# <LJFUNC>
# name: LJ::get_cluster_def_reader
# class: db
# des: Returns a definitive cluster reader for a given user, used
#      when the caller wants the master handle, but will only
#      use it to read.
# args: uarg
# des-uarg: Either a clusterid scalar or a user object.
# returns: DB handle.  Or undef if definitive reader is unavailable.
# </LJFUNC>
sub get_cluster_def_reader
{
    return LJ::get_cluster_master(@_);
}

# <LJFUNC>
# name: LJ::get_cluster_master
# class: db
# des: Returns a cluster master for a given user, used when the caller
#      might use it to do a write (insert/delete/update/etc...)
# args: uarg
# des-uarg: Either a clusterid scalar or a user object.
# returns: DB handle.  Or undef if master is unavailable.
# </LJFUNC>
sub get_cluster_master
{
    my @dbh_opts = scalar(@_) == 2 ? (shift @_) : ();
    my $arg = shift;
    my $id = LJ::isu($arg) ? $arg->{'clusterid'} : $arg;
    return undef unless ($id);
    return undef if $LJ::READONLY_CLUSTER{$id};
    return LJ::get_dbh(@dbh_opts, LJ::master_role($id));
}

## input: cluster id
## ouptut: hashiref like {active => 'a', dead => 'b' }
sub _cluster_config {
    my $cid = shift;
    
    my $block_id = 'cluster_config.rc';
    my $block = LJ::ExtBlock->load_by_id($block_id, {cache_valid => 15});
    return ($block && $block->data->{$cid}) ? $block->data->{$cid} : {};
}


# input: LJ::User object or cluster id
# output: the DBI::Role role name of a cluster master (like 'cluster10a')
sub master_role {
    my $arg = shift;
    
    my $cid = LJ::isu($arg) ? $arg->{'clusterid'} : $arg;
    if ($LJ::IS_DEV_SERVER) {
        return "cluster${cid}";
    } else {
        my $ab = _cluster_config($cid)->{'active'} || 'a';
        return "cluster${cid}${ab}";
    }
}

# input: LJ::User object or cluster id
# output: role name of inactive server, or undef if inactive server is dead
sub get_inactive_role {
    my $arg = shift;
    
    my $cid = LJ::isu($arg) ? $arg->{'clusterid'} : $arg;
    if ($LJ::IS_DEV_SERVER) {
        return "cluster${cid}";
    } else {
        my $c = _cluster_config($cid);
        my $ab = ($c && $c->{'active'} && $c->{'active'} eq 'b') ? 'a' : 'b';
        if ($c && $c->{'dead'} && $c->{'dead'} eq $ab) {
            ## oops, inactive is dead
            return;
        } else {
            return "cluster${cid}${ab}";
        }
    }
}

# <LJFUNC>
# name: LJ::get_dbirole_dbh
# class: db
# des: Internal function for get_dbh(). Uses the DBIRole to fetch a dbh, with
#      hooks into db stats-generation if that's turned on.
# info:
# args: opts, role
# des-opts: A hashref of options.
# des-role: The database role.
# returns: A dbh.
# </LJFUNC>
sub get_dbirole_dbh {
    my $dbh = $LJ::DBIRole->get_dbh( LJ::DB::_connection_options(), @_ )
        or return undef;

    if ( $LJ::DB_LOG_HOST && $LJ::HAVE_DBI_PROFILE ) {
        $LJ::DB_REPORT_HANDLES{ $dbh->{Name} } = $dbh;

        # :TODO: Explain magic number
        $dbh->{Profile} ||= "2/DBI::Profile";

        # And turn off useless (to us) on_destroy() reports, too.
        undef $DBI::Profile::ON_DESTROY_DUMP;
    }

    return $dbh;
}

# <LJFUNC>
# name: LJ::get_lock
# des: get a MySQL lock on a given key/dbrole combination.
# returns: undef if called improperly, true on success, die() on failure
# args: db, dbrole, lockname, wait_time?
# des-dbrole: the role this lock should be gotten on, either 'global' or 'user'.
# des-lockname: the name to be used for this lock.
# des-wait_time: an optional timeout argument, defaults to 10 seconds.
# </LJFUNC>
sub get_lock
{
    my ($db, $dbrole, $lockname, $wait_time) = @_;
    return undef unless $db && $lockname;
    return undef unless $dbrole eq 'global' || $dbrole eq 'user';

    my $curr_sub = join(", ", ((caller 1)[0..3])); # caller of current sub

    # die if somebody already has a lock
    use Carp qw/cluck confess/;
    confess "LOCK ERROR: can't get lock from\n$curr_sub\nbecause it's already taken from\n$LJ::LOCK_OUT{$dbrole}\n"
        if exists $LJ::LOCK_OUT{$dbrole};

    # get a lock from mysql
    $wait_time ||= 10;
    # NOTE: we have to get the result of GET_LOCK, so do NOT use $db->do()
    my ($got) = $db->selectrow_array( 'SELECT GET_LOCK(?,?)', undef, $lockname, $wait_time );
    return undef unless $got;

    # successfully got a lock
    $LJ::LOCK_OUT{$dbrole} = $curr_sub;
    return 1;
}

# <LJFUNC>
# name: LJ::may_lock
# des: see if we <strong>could</strong> get a MySQL lock on
#       a given key/dbrole combination, but don't actually get it.
# returns: undef if called improperly, true on success, die() on failure
# args: db, dbrole
# des-dbrole: the role this lock should be gotten on, either 'global' or 'user'.
# </LJFUNC>
sub may_lock
{
    my ($db, $dbrole) = @_;
    return undef unless $db && ($dbrole eq 'global' || $dbrole eq 'user');

    # die if somebody already has a lock
    if ($LJ::LOCK_OUT{$dbrole}) {
        my $curr_sub = (caller 1)[3]; # caller of current sub
        die "LOCK ERROR: $curr_sub; can't get lock from $LJ::LOCK_OUT{$dbrole}\n";
    }

    # see if a lock is already out
    return undef if exists $LJ::LOCK_OUT{$dbrole};

    return 1;
}

# <LJFUNC>
# name: LJ::release_lock
# des: release a MySQL lock on a given key/dbrole combination.
# returns: undef if called improperly, true on success, die() on failure
# args: db, dbrole, lockname
# des-dbrole: role on which to get this lock, either 'global' or 'user'.
# des-lockname: the name to be used for this lock
# </LJFUNC>
sub release_lock
{
    my ($db, $dbrole, $lockname) = @_;
    return undef unless $db && $lockname;
    return undef unless $dbrole eq 'global' || $dbrole eq 'user';

    # get a lock from mysql
    $db->do("SELECT RELEASE_LOCK(?)", undef, $lockname);
    delete $LJ::LOCK_OUT{$dbrole};

    return 1;
}

sub lock_taken {
    my ( $db, $dbrole, $lockname ) = @_;

    return unless $db && $lockname;
    return unless $dbrole eq 'global' || $dbrole eq 'user';

    my ($connid) = $db->selectrow_array( 'SELECT IS_USED_LOCK(?)',
        undef, $lockname );

    return $connid ? 1 : 0;
}

sub lock_free {
    my ( $db, $dbrole, $lockname ) = @_;

    return unless $db && $lockname;
    return unless $dbrole eq 'global' || $dbrole eq 'user';

    return ! lock_taken( $db, $dbrole, $lockname );
}

# <LJFUNC>
# name: LJ::disconnect_dbs
# des: Clear cached DB handles
# </LJFUNC>
sub disconnect_dbs {
    # clear cached handles
    $LJ::DBIRole->disconnect_all( { except => [qw(logs)] });
}

# <LJFUNC>
# name: LJ::use_diff_db
# class:
# des: given two DB roles, returns true only if it is certain the two roles are
#      served by different database servers.
# info: This is useful for, say, the moveusercluster script: You would not want
#       to select something from one DB, copy it into another, and then delete it from the
#       source if they were both the same machine.
# args:
# des-:
# returns:
# </LJFUNC>
sub use_diff_db {
    $LJ::DBIRole->use_diff_db(@_);
}

# to be called as &nodb; (so this function sees caller's @_)
sub nodb {
    shift @_ if
        ref $_[0] eq "LJ::DBSet" || ref $_[0] eq "DBI::db" ||
        ref $_[0] eq "Apache::DBI::db";
}

sub dbtime_callback {
    my ($dsn, $dbtime, $time) = @_;
    my $diff = abs($dbtime - $time);
    if ($diff > 2) {
        $dsn =~ /host=([^:\;\|]*)/;
        my $db = $1;
        print STDERR "Clock skew of $diff seconds between web($LJ::SERVER_NAME) and db($db)\n";
    }
}

sub foreach_cluster {
    my $coderef = shift;
    my $opts = shift || {};
    
    foreach my $cluster_id (@LJ::CLUSTERS) {
        if ($opts->{active}) {
            my $dbh = LJ::get_cluster_master($cluster_id);
            $coderef->($cluster_id, $dbh);
        } else {
            my $dbr = LJ::DBUtil->get_inactive_db($cluster_id, $opts->{verbose});
            $coderef->($cluster_id, $dbr);
        }
    }
}


sub isdb { return ref $_[0] && (ref $_[0] eq "DBI::db" ||
                                ref $_[0] eq "Apache::DBI::db"); }


sub bindstr { return join(', ', map { '?' } @_); }

package LJ::Error::Database::Unavailable;
sub fields { qw(roles) }  # arrayref of roles requested

sub as_string {
    my $self = shift;
    my $ct = @{$self->field('roles')};
    my $clist = join(", ", @{$self->field('roles')});
    return $ct == 1 ?
        "Database unavailable for role $clist" :
        "Database unavailable for roles $clist";
}


package LJ::Error::Database::Failure;
sub fields { qw(db) }

sub user_caused { 0 }

sub as_string {
    my $self = shift;
    my $code = $self->err;
    my $txt  = $self->errstr;
    return "Database error code $code: $txt";
}

sub err {
    my $self = shift;
    return $self->field('db')->err;
}

sub errstr {
    my $self = shift;
    return $self->field('db')->errstr;
}

1;
