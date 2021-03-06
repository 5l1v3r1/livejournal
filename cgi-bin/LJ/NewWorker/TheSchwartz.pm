package LJ::NewWorker::TheSchwartz;
use strict;

use lib "$ENV{LJHOME}/cgi-bin";
use base "LJ::NewWorker", "Exporter";
use POSIX ();
use LJ;

my $interval        = 10;
my $verbose         = 0;
my $prioritize      = 0;
my $schwartz_role   = $LJ::THESCHWARTZ_ROLE_WORKER;
my $priority_limit;

sub options {
    my $self = shift;
    return (
        'interval|i=i'          => \$interval,
        'schwartz-role|r=s'     => \$schwartz_role,
        'priority-level|l=i'    => \$priority_limit,
        'prioritize|p'          => \$prioritize,
        $self->SUPER::options(),
    );
}

sub help {
    my $self = shift;
    return
        $self->SUPER::help() .
        "-i | --interval=n          set sleep interval to n secounds\n" .
        "-l | --priority-level=n    work only with this priority level\n" .
        "-p | --prioritize          use prioritization\n".
        "-r | --schwartz-role=role  connect to db with specified role (defualt is '$schwartz_role')\n";
}

sub find_job_limit  { }
sub capabilities    { }
sub on_idle         { }
sub on_afterwork    { }
sub on_prework      { 1 }  # return 1 to proceed and do work
sub schwartz_verbose_handler { } ## may return coderef for TheSchartz->set_verbose method

my $sclient;

sub _init {
    my $class = shift;
    
    if ($sclient) {
        warn "Schwartz client has been initialized already" if $verbose;
        return;
    }
    
    warn "The Schwartz _init(): init with role '$schwartz_role'.\n" if $verbose;

    $sclient = LJ::theschwartz({ role => $schwartz_role }) or die "Could not get schwartz client";
    $sclient->set_prioritize($prioritize);
    $sclient->set_priority_limit($priority_limit) if defined $priority_limit;

    $sclient->set_verbose( $class->schwartz_verbose_handler || $class->verbose );
    $sclient->set_find_job_limit( $class->find_job_limit );
    foreach my $classname ($class->capabilities) {
        warn "The Schwartz run(): can_do('$classname').\n" if $verbose;
        $sclient->can_do($classname);
    }
    
}

sub run {
    my $class = shift;
    my $opts = shift;

    my $sleep = 0;

    $verbose = $class->verbose;
    
    $class->_init;
    warn "The Schwartz run(): init complete.\n" if $verbose;
    
    my $last_death_check = time();
    while ( ! $class->should_quit()) {
        LJ::start_request();
        $class->check_limits();

        my $did_work = 0;
        warn "looking for work...\n" if $verbose;

        my $work_result = eval {
            if ($class->on_prework()) {
                $did_work = $sclient->work_once();
                $class->on_afterwork($did_work);
            }
            
            1;
        };
        warn $@ unless $work_result;

        warn "did work = " . ($did_work || '') . "\n" if $verbose;

        last if $class->should_quit || $opts->{'run_once'};

        if ($work_result) {
            if ($did_work) {
                $sleep-- if $sleep > 0;
            } else {
                $class->on_idle();
                $sleep = 10 if ++$sleep > 10;
                sleep $sleep;
            }
        }

        # do request cleanup before we process another job
        LJ::end_request();
    }
    POSIX::_exit(0);
}

# Copy-pasted from 'old' Schwartz.

sub work_safely {
    my ($class, $job) = @_;
    my $client = $job->handle->client;
    my $res;

    $job->debug("Working on $class ...");
    $job->set_as_current;
    $client->start_scoreboard;

    eval {
        $res = $class->work($job);
    };

    my $cjob = $client->current_job;
    if ($@) {
        $job->debug("Eval failure: $@");
        $cjob->failed($@);
    }
    unless ($cjob->did_something) {
        $cjob->failed('Job did not explicitly complete, fail, or get replaced');
    }

    $client->end_scoreboard;

    # FIXME: this return value is kinda useless/undefined.  should we even return anything?  any callers? -brad
    return $res;
}
1;
