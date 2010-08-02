#!/usr/bin/perl
#
# <LJDEP>
# link: htdocs/userinfo.bml, htdocs/go.bml, htdocs/tools/memadd.bml, htdocs/editjournal.bml
# link: htdocs/tools/tellafriend.bml
# img: htdocs/img/btn_prev.gif, htdocs/img/memadd.gif, htdocs/img/btn_edit.gif
# img: htdocs/img/btn_next.gif, htdocs/img/btn_tellafriend.gif
# </LJDEP>

use strict;
package LJ::Talk;

use LJ::Constants;
use LJ::RateLimit qw//;
use Class::Autouse qw(
                      LJ::Event::JournalNewComment
                      LJ::Event::UserNewComment
                      LJ::Comment
                      LJ::EventLogRecord::NewComment
                      Captcha::reCAPTCHA
                      LJ::OpenID
                      );
use MIME::Words;
use Carp qw(croak);
use LJ::TimeUtil;

use constant PACK_FORMAT => "NNNNC"; ## $talkid, $parenttalkid, $poster, $time, $state 

# dataversion for rate limit logging
our $RATE_DATAVER = "1";

sub get_subjecticons
{
    my %subjecticon;
    $subjecticon{'types'} = [ 'sm', 'md' ];
    $subjecticon{'lists'}->{'md'} = [
            { img => "md01_alien.gif",          w => 32,        h => 32 },
            { img => "md02_skull.gif",          w => 32,        h => 32 },
            { img => "md05_sick.gif",           w => 25,        h => 25 },
            { img => "md06_radioactive.gif",    w => 20,        h => 20 },
            { img => "md07_cool.gif",           w => 20,        h => 20 },
            { img => "md08_bulb.gif",           w => 17,        h => 23 },
            { img => "md09_thumbdown.gif",      w => 25,        h => 19 },
            { img => "md10_thumbup.gif",        w => 25,        h => 19 }
    ];
    $subjecticon{'lists'}->{'sm'} = [
            { img => "sm01_smiley.gif",         w => 15,        h => 15 },
            { img => "sm02_wink.gif",           w => 15,        h => 15 },
            { img => "sm03_blush.gif",          w => 15,        h => 15 },
            { img => "sm04_shock.gif",          w => 15,        h => 15 },
            { img => "sm05_sad.gif",            w => 15,        h => 15 },
            { img => "sm06_angry.gif",          w => 15,        h => 15 },
            { img => "sm07_check.gif",          w => 15,        h => 15 },
            { img => "sm08_star.gif",           w => 20,        h => 18 },
            { img => "sm09_mail.gif",           w => 14,        h => 10 },
            { img => "sm10_eyes.gif",           w => 24,        h => 12 }
    ];

    # assemble ->{'id'} portion of hash.  the part of the imagename before the _
    foreach (keys %{$subjecticon{'lists'}}) {
            foreach my $pic (@{$subjecticon{'lists'}->{$_}}) {
            next unless ($pic->{'img'} =~ /^(\D{2}\d{2})\_.+$/);
            $subjecticon{'pic'}->{$1} = $pic;
            $pic->{'id'} = $1;
            }
    }

    return \%subjecticon;
}

# entryid-commentid-emailrecipientpassword hash
sub ecphash {
    my ($itemid, $talkid, $password) = @_;
    return "ecph-" . Digest::MD5::md5_hex($itemid . $talkid . $password);
}

# Returns talkurl with GET args added (don't pass #anchors to this :-)
sub talkargs {
    my $talkurl = shift;
    my $args = join("&", grep {$_} @_);
    my $sep;
    $sep = ($talkurl =~ /\?/ ? "&" : "?") if $args;
    return "$talkurl$sep$args";
}

# Returns HTML to display an image, given the image id as an argument.
sub show_image
{
    my $pics = shift;
    my $id = shift;
    my $extra = shift;
    return unless defined $pics->{'pic'}->{$id};
    my $p = $pics->{'pic'}->{$id};
    my $pfx = "$LJ::IMGPREFIX/talk";
    return "<img src='$pfx/$p->{'img'}' border='0' ".
        "width='$p->{'w'}' height='$p->{'h'}' valign='middle' $extra />";
}

# Returns 'none' icon.
sub show_none_image
{
    my $extra = shift;
    my $img = 'none.gif';
    my $w = 15;
    my $h = 15;
    my $pfx = "$LJ::IMGPREFIX/talk";
    return "<img src='$pfx/$img' border='0' ".
        "width='$w' height='$h' valign='middle' $extra />";
}

sub link_bar
{
    my $opts = shift;
    my ($u, $up, $remote, $headref, $itemid) =
        map { $opts->{$_} } qw(u up remote headref itemid);
    my $ret;

    my @linkele;

    my $mlink = sub {
        my ($url, $piccode) = @_;
        return ("<a href=\"$url\">" .
                LJ::img($piccode, "", { 'align' => 'absmiddle' }) .
                "</a>");
    };

    my $jarg = "journal=$u->{'user'}&";
    my $jargent = "journal=$u->{'user'}&amp;";

    my $entry = LJ::Entry->new($u, ditemid => $itemid);

    # << Previous
    push @linkele, $mlink->("$LJ::SITEROOT/go.bml?${jargent}itemid=$itemid&amp;dir=prev", "prev_entry");
    $$headref .= "<link href='$LJ::SITEROOT/go.bml?${jargent}itemid=$itemid&amp;dir=prev' rel='Previous' />\n";

    # memories
    unless ($LJ::DISABLED{'memories'}) {
        push @linkele, $mlink->("$LJ::SITEROOT/tools/memadd.bml?${jargent}itemid=$itemid", "memadd");
    }

    # edit entry - if we have a remote, and that person can manage
    # the account in question, OR, they posted the entry, and have
    # access to the community in question
    if (defined $remote && (LJ::can_manage($remote, $u) ||
                            (LJ::u_equals($remote, $up) && LJ::can_use_journal($up->{userid}, $u->{user}, {}))))
    {
        push @linkele, $mlink->("$LJ::SITEROOT/editjournal.bml?${jargent}itemid=$itemid", "editentry");
    }

    # edit tags
    unless ($LJ::DISABLED{tags}) {
        if (defined $remote && LJ::Tags::can_add_entry_tags($remote, $entry)) {
            push @linkele, $mlink->("$LJ::SITEROOT/edittags.bml?${jargent}itemid=$itemid", "edittags");
        }
    }

    unless ($LJ::DISABLED{'sharethis'}) {
        my $entry_url = $entry->url;
        my $entry_title = LJ::ejs($entry->subject_html);
        push @linkele, $mlink->("javascript:void(0)", "sharethis") . qq|<script type="text/javascript">
            SHARETHIS.addEntry({url:'$entry_url', title: '$entry_title'}, {button: false})
                .attachButton(jQuery('a:last')[0]);
            </script>|
            if $entry->security eq 'public';
     }

    if ($remote && $remote->can_use_esn) {
        my $img_key = $remote->has_subscription(journal => $u, event => "JournalNewComment", arg1 => $itemid, require_active => 1) ?
            "track_active" : "track";
        push @linkele, $mlink->("$LJ::SITEROOT/manage/subscriptions/entry.bml?${jargent}itemid=$itemid", $img_key);
    }

    if ($remote && $remote->can_see_content_flag_button( content => $entry )) {
        my $flag_url = LJ::ContentFlag->adult_flag_url($entry);
        push @linkele, $mlink->($flag_url, 'flag');
    }


    ## Next
    push @linkele, $mlink->("$LJ::SITEROOT/go.bml?${jargent}itemid=$itemid&amp;dir=next", "next_entry");
    $$headref .= "<link href='$LJ::SITEROOT/go.bml?${jargent}itemid=$itemid&amp;dir=next' rel='Next' />\n";

    if (@linkele) {
        $ret .= BML::fill_template("standout", {
            'DATA' => "<table><tr><td valign='middle'>" .
                join("&nbsp;&nbsp;", @linkele) .
                "</td></tr></table>",
            });
    }

    return $ret;
}

sub init
{
    my ($form) = @_;
    my $init = {};  # structure to return

    my $journal = $form->{'journal'};
    my $ju = undef;
    my $item = undef;        # hashref; journal item conversation is in

    # defaults, to be changed later:
    $init->{'itemid'} = $form->{'itemid'}+0;
    $init->{'ditemid'} = $init->{'itemid'};
    $init->{'thread'} = $form->{'thread'}+0;
    $init->{'dthread'} = $init->{'thread'};
    $init->{'clustered'} = 0;
    $init->{'replyto'} = $form->{'replyto'}+0;
    $init->{'style'} = $form->{'style'} ? "mine" : undef;

    if ($journal) {
        # they specified a journal argument, which indicates new style.
        $ju = LJ::load_user($journal);
        return { 'error' => BML::ml('talk.error.nosuchjournal')} unless $ju;
        return { 'error' => BML::ml('talk.error.purged')} if $ju->is_expunged;

        LJ::assert_is($ju->{user}, lc $journal);

        $init->{'clustered'} = 1;
        foreach (qw(itemid replyto)) {
            next unless $init->{$_};
            $init->{'anum'} = $init->{$_} % 256;
            $init->{$_} = int($init->{$_} / 256);
            last;
        }
        $init->{'thread'} = int($init->{'thread'} / 256)
            if $init->{'thread'};
    } else {
        # perhaps it's an old URL for a user that's since been clustered.
        # look up the itemid and see what user it belongs to.
        if ($form->{'itemid'}) {
            my $itemid = $form->{'itemid'}+0;
            my $newinfo = LJ::get_newids('L', $itemid);
            if ($newinfo) {
                $ju = LJ::load_userid($newinfo->[0]);
                return { 'error' => BML::ml('talk.error.nosuchjournal')} unless $ju;
                $init->{'clustered'} = 1;
                $init->{'itemid'} = $newinfo->[1];
                $init->{'oldurl'} = 1;
                if ($form->{'thread'}) {
                    my $tinfo = LJ::get_newids('T', $init->{'thread'});
                    $init->{'thread'} = $tinfo->[1] if $tinfo;
                }
            } else {
                return { 'error' => BML::ml('talk.error.noentry') };
            }
        } elsif ($form->{'replyto'}) {
            my $replyto = $form->{'replyto'}+0;
            my $newinfo = LJ::get_newids('T', $replyto);
            if ($newinfo) {
                $ju = LJ::load_userid($newinfo->[0]);
                return { 'error' => BML::ml('talk.error.nosuchjournal')} unless $ju;
                $init->{'replyto'} = $newinfo->[1];
                $init->{'oldurl'} = 1;
            } else {
                return { 'error' => BML::ml('talk.error.noentry') };
            }
        }
    }

    $init->{'journalu'} = $ju;
    return $init;
}

# $u, $itemid
sub get_journal_item
{
    my ($u, $itemid) = @_;
    return unless $u && $itemid;

    my $uid = $u->{'userid'}+0;
    $itemid += 0;

    my $item = LJ::get_log2_row($u, $itemid);
    return undef unless $item;

    $item->{'alldatepart'} = LJ::TimeUtil->alldatepart_s2($item->{'eventtime'});

    $item->{'itemid'} = $item->{'jitemid'};    # support old & new keys
    $item->{'ownerid'} = $item->{'journalid'}; # support old & news keys

    my $lt = LJ::get_logtext2($u, $itemid);
    my $v = $lt->{$itemid};
    $item->{'subject'} = $v->[0];
    $item->{'event'} = $v->[1];

    ### load the log properties
    my %logprops = ();
    LJ::load_log_props2($u->{'userid'}, [ $itemid ], \%logprops);
    $item->{'props'} = $logprops{$itemid} || {};

    if ($LJ::UNICODE && $logprops{$itemid}->{'unknown8bit'}) {
        LJ::item_toutf8($u, \$item->{'subject'}, \$item->{'event'},
                        $item->{'logprops'}->{$itemid});
    }
    return $item;
}

sub check_viewable
{
    my ($remote, $item, $form, $errref) = @_;
    # note $form no longer used

    my $err = sub {
        $$errref = "<?h1 <?_ml Error _ml?> h1?><?p $_[0] p?>";
        return 0;
    };

    unless (LJ::can_view($remote, $item)) {
        if (defined $remote) {
             LJ::Request->pnotes ('error' => 'private');
             LJ::Request->pnotes ('remote' => LJ::get_remote());
             BML::return_error_status(403);
             return;
            return $err->(BML::ml('talk.error.notauthorised'));
        } else {
            my $host = LJ::Request->header_in("Host");
            my $args = scalar LJ::Request->args;
            my $querysep = $args ? "?" : "";
            my $redir = LJ::eurl("http://" . $host . LJ::Request->uri . $querysep . $args);

            return $err->(BML::redirect("$LJ::SITEROOT/?returnto=$redir&errmsg=notloggedin"));
        }
    }

    return 1;
}

# <LJFUNC>
# name: LJ::Talk::can_delete
# des: Determines if a user can delete a comment or entry: You can
#       delete anything you've posted.  You can delete anything posted in something
#       you own (i.e. a comment in your journal, a comment to an entry you made in
#       a community).  You can also delete any item in an account you have the
#       "A"dministration edge for.
# args: remote, u, up, userpost
# des-remote: User object we're checking access of.  From [func[LJ::get_remote]].
# des-u: Username or object of the account the thing is located in.
# des-up: Username or object of person who owns the parent of the thing.  (I.e. the poster
#           of the entry a comment is in.)
# des-userpost: Username (<strong>not</strong> object) of person who posted the item.
# returns: Boolean indicating whether remote is allowed to delete the thing
#           specified by the other options.
# </LJFUNC>
sub can_delete {
    my ($remote, $u, $up, $userpost) = @_; # remote, journal, posting user, commenting user
    return 0 unless $remote;
    return 1 if $remote->{'user'} eq $userpost ||
                $remote->{'user'} eq (ref $u ? $u->{'user'} : $u) ||
                $remote->{'user'} eq (ref $up ? $up->{'user'} : $up) ||
                LJ::can_manage($remote, $u);
    return 0;
}

sub can_screen {
    my ($remote, $u, $up, $userpost) = @_;
    return 0 unless $remote;
    return 1 if $remote->{'user'} eq $u->{'user'} ||
                $remote->{'user'} eq (ref $up ? $up->{'user'} : $up) ||
                LJ::can_manage($remote, $u);
    return 0;
}

sub can_unscreen {
    return LJ::Talk::can_screen(@_);
}

sub can_view_screened {
    return LJ::Talk::can_delete(@_);
}

sub can_freeze {
    return LJ::Talk::can_screen(@_);
}

sub can_unfreeze {
    return LJ::Talk::can_unscreen(@_);
}

# <LJFUNC>
# name: LJ::Talk::screening_level
# des: Determines the screening level of a particular post given the relevant information.
# args: journalu, jitemid
# des-journalu: User object of the journal the post is in.
# des-jitemid: Itemid of the post.
# returns: Single character that indicates the screening level.  Undef means don't screen
#          anything, 'A' means screen All, 'R' means screen Anonymous (no-remotes), 'F' means
#          screen non-friends.
# </LJFUNC>
sub screening_level {
    my ($journalu, $jitemid) = @_;
    die 'LJ::screening_level needs a user object.' unless ref $journalu;
    $jitemid += 0;
    die 'LJ::screening_level passed invalid jitemid.' unless $jitemid;

    # load the logprops for this entry
    my %props;
    LJ::load_log_props2($journalu->{userid}, [ $jitemid ], \%props);

    # determine if userprop was overriden
    my $val = $props{$jitemid}{opt_screening};
    return if $val eq 'N'; # N means None, so return undef
    return $val if $val;

    # now return userprop, as it's our last chance
    LJ::load_user_props($journalu, 'opt_whoscreened');
    return if $journalu->{opt_whoscreened} eq 'N';
    return $journalu->{opt_whoscreened};
}

sub update_commentalter {
    my ($u, $itemid) = @_;
    LJ::set_logprop($u, $itemid, { 'commentalter' => time() });
}

sub update_journals_commentalter {
    my $u = shift;

    # journal data consists of two types: posts and comments.
    # last post time is stored in 'userusage' table.
    # last comment add/update/delete/whateverchange time - here:
    $u->set_prop("comment_alter_time", time());
}

# <LJFUNC>
# name: LJ::Talk::get_comments_in_thread
# class: web
# des: Gets a list of comment ids that are contained within a thread, including the
#      comment at the top of the thread.  You can also limit this to only return comments
#      of a certain state.
# args: u, jitemid, jtalkid, onlystate, screenedref
# des-u: user object of user to get comments from
# des-jitemid: journal itemid to get comments from
# des-jtalkid: journal talkid of comment to use as top of tree
# des-onlystate: if specified, return only comments of this state (e.g. A, F, S...)
# des-screenedref: if provided and an array reference, will push on a list of comment
#                   ids that are being returned and are screened (mostly for use in deletion so you can
#                   unscreen the comments)
# returns: undef on error, array reference of jtalkids on success
# </LJFUNC>
sub get_comments_in_thread {
    my ($u, $jitemid, $jtalkid, $onlystate, $screened_ref) = @_;
    $u = LJ::want_user($u);
    $jitemid += 0;
    $jtalkid += 0;
    $onlystate = uc $onlystate;
    return undef unless $u && $jitemid && $jtalkid &&
                        (!$onlystate || $onlystate =~ /^\w$/);

    # get all comments to post
    my $comments = LJ::Talk::get_talk_data($u, 'L', $jitemid) || {};

    # see if our comment exists
    return undef unless $comments->{$jtalkid};

    # create relationship hashref and count screened comments in post
    my %parentids;
    $parentids{$_} = $comments->{$_}{parenttalkid} foreach keys %$comments;

    # now walk and find what to update
    my %to_act;
    foreach my $id (keys %$comments) {
        my $act = ($id == $jtalkid);
        my $walk = $id;
        while ($parentids{$walk}) {
            if ($parentids{$walk} == $jtalkid) {
                # we hit the one we want to act on
                $act = 1;
                last;
            }
            last if $parentids{$walk} == $walk;

            # no match, so move up a level
            $walk = $parentids{$walk};
        }

        # set it as being acted on
        $to_act{$id} = 1 if $act && (!$onlystate || $comments->{$id}{state} eq $onlystate);

        # push it onto the list of screened comments? (if the caller is doing a delete, they need
        # a list of screened comments in order to unscreen them)
        push @$screened_ref, $id if ref $screened_ref &&             # if they gave us a ref
                                    $to_act{$id} &&                  # and we're acting on this comment
                                    $comments->{$id}{state} eq 'S';  # and this is a screened comment
    }

    # return list from %to_act
    return [ keys %to_act ];
}

# <LJFUNC>
# name: LJ::Talk::delete_thread
# class: web
# des: Deletes an entire thread of comments.
# args: u, jitemid, jtalkid
# des-u: Userid or user object to delete thread from.
# des-jitemid: Journal itemid of item to delete comments from.
# des-jtalkid: Journal talkid of comment at top of thread to delete.
# returns: 1 on success; undef on error
# </LJFUNC>
sub delete_thread {
    my ($u, $jitemid, $jtalkid) = @_;

    # get comments and delete 'em
    my @screened;
    my $ids = LJ::Talk::get_comments_in_thread($u, $jitemid, $jtalkid, undef, \@screened);
    LJ::Talk::unscreen_comment($u, $jitemid, @screened) if @screened; # if needed only!
    my $num = LJ::delete_comments($u, "L", $jitemid, @$ids);
    LJ::replycount_do($u, $jitemid, "decr", $num);
    LJ::Talk::update_commentalter($u, $jitemid);
    LJ::Talk::update_journals_commentalter($u);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::delete_author
# class: web
# des: Deletes all comments of one author for one entry.
# args: u, jitemid, posterid
# des-u: Userid or user object to delete thread from.
# des-jitemid: Journal itemid of item to delete comments from.
# des-posterid: Userid of author.
# returns: 1 on success; undef on error
# </LJFUNC>
sub delete_author {
    my ($u, $jitemid, $posterid) = @_;

    # get all comments to post
    my $comments = LJ::Talk::get_talk_data($u, 'L', $jitemid) || {};

    my @screened;
    my @ids;
    foreach my $id (keys %$comments) {
        next unless $comments->{$id}{posterid} eq $posterid;
        next if $comments->{$id}{state} eq 'D';
        push @ids, $id;
        push @screened, $id if $comments->{$id}{state} eq 'S';
    }

    LJ::Talk::unscreen_comment($u, $jitemid, @screened) if @screened; # if needed only!
    my $num = LJ::delete_comments($u, "L", $jitemid, @ids);
    LJ::replycount_do($u, $jitemid, "decr", $num);
    LJ::Talk::update_commentalter($u, $jitemid);
    LJ::Talk::update_journals_commentalter($u);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::delete_comment
# class: web
# des: Deletes a single comment.
# args: u, jitemid, jtalkid, state?
# des-u: Userid or user object to delete comment from.
# des-jitemid: Journal itemid of item to delete comment from.
# des-jtalkid: Journal talkid of the comment to delete.
# des-state: Optional. If you know it, provide the state
#            of the comment being deleted, else we load it.
# returns: 1 on success; undef on error
# </LJFUNC>
sub delete_comment {
    my ($u, $jitemid, $jtalkid, $state) = @_;
    return undef unless $u && $jitemid && $jtalkid;

    unless ($state) {
        my $td = LJ::Talk::get_talk_data($u, 'L', $jitemid);
        return undef unless $td;

        $state = $td->{$jtalkid}->{state};
    }
    return undef unless $state;

    # if it's screened, unscreen it first to properly adjust logprops
    LJ::Talk::unscreen_comment($u, $jitemid, $jtalkid)
        if $state eq 'S';

    # now do the deletion
    my $num = LJ::delete_comments($u, "L", $jitemid, $jtalkid);
    LJ::replycount_do($u, $jitemid, "decr", $num);
    LJ::Talk::update_commentalter($u, $jitemid);
    LJ::Talk::update_journals_commentalter($u);

    # done
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::freeze_thread
# class: web
# des: Freezes an entire thread of comments.
# args: u, jitemid, jtalkid
# des-u: Userid or user object to freeze thread from.
# des-jitemid: Journal itemid of item to freeze comments from.
# des-jtalkid: Journal talkid of comment at top of thread to freeze.
# returns: 1 on success; undef on error
# </LJFUNC>
sub freeze_thread {
    my ($u, $jitemid, $jtalkid) = @_;

    # now we need to update the states
    my $ids = LJ::Talk::get_comments_in_thread($u, $jitemid, $jtalkid, 'A');
    LJ::Talk::freeze_comments($u, "L", $jitemid, 0, $ids);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::unfreeze_thread
# class: web
# des: unfreezes an entire thread of comments.
# args: u, jitemid, jtalkid
# des-u: Userid or user object to unfreeze thread from.
# des-jitemid: Journal itemid of item to unfreeze comments from.
# des-jtalkid: Journal talkid of comment at top of thread to unfreeze.
# returns: 1 on success; undef on error
# </LJFUNC>
sub unfreeze_thread {
    my ($u, $jitemid, $jtalkid) = @_;

    # now we need to update the states
    my $ids = LJ::Talk::get_comments_in_thread($u, $jitemid, $jtalkid, 'F');
    LJ::Talk::freeze_comments($u, "L", $jitemid, 1, $ids);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::freeze_comments
# class: web
# des: Freezes comments.  This is the internal helper function called by
#      freeze_thread/unfreeze_thread.  Use those if you wish to freeze or
#      unfreeze a thread.  This function just freezes specific comments.
# args: u, nodetype, nodeid, unfreeze, ids
# des-u: Userid or object of user to manipulate comments in.
# des-nodetype: Nodetype of the thing containing the specified ids.  Typically "L".
# des-nodeid: Id of the node to manipulate comments from.
# des-unfreeze: If 1, unfreeze instead of freeze.
# des-ids: Array reference containing jtalkids to manipulate.
# returns: 1 on success; undef on error
# </LJFUNC>
sub freeze_comments {
    my ($u, $nodetype, $nodeid, $unfreeze, $ids) = @_;
    $u = LJ::want_user($u);
    $nodeid += 0;
    $unfreeze = $unfreeze ? 1 : 0;
    return undef unless LJ::isu($u) && $nodetype =~ /^\w$/ && $nodeid && @$ids;

    # get database and quote things
    return undef unless $u->writer;
    my $quserid = $u->{userid}+0;
    my $qnodetype = $u->quote($nodetype);
    my $qnodeid = $nodeid+0;

    # now perform action
    my @batch = map { int $_ } @$ids;
    my $in = join(',', @batch);
    my $newstate = $unfreeze ? 'A' : 'F';
    LJ::run_hooks('report_cmt_update', $quserid, \@batch);
    my $res = $u->talk2_do(nodetype => $nodetype, nodeid => $nodeid,
                           sql =>   "UPDATE talk2 SET state = '$newstate' " .
                                    "WHERE journalid = $quserid AND nodetype = $qnodetype " .
                                    "AND nodeid = $qnodeid AND jtalkid IN ($in)");

    # invalidate memcache for this comment
    LJ::Talk::invalidate_comment_cache($u->id, $nodeid, @$ids);
    
    # set time of comments modification in the journal
    LJ::Talk::update_journals_commentalter($u);    

    LJ::run_hooks('freeze_comment', $unfreeze, $u, $nodeid, [@batch]); # jitemid, [jtalkid]

    return undef unless $res;
    return 1;
}

sub screen_comment {
    my $u = shift;
    return undef unless LJ::isu($u);
    my $itemid = shift(@_) + 0;
    my @jtalkids = @_;
    
    my @batch = map { int $_ } @jtalkids;
    my $in = join(',', @batch);
    return unless $in;

    my $userid = $u->{'userid'} + 0;

    LJ::run_hooks('report_cmt_update', $userid, \@batch);
    my $updated = $u->talk2_do(nodetype => "L", nodeid => $itemid,
                               sql =>   "UPDATE talk2 SET state='S' ".
                                        "WHERE journalid=$userid AND jtalkid IN ($in) ".
                                        "AND nodetype='L' AND nodeid=$itemid ".
                                        "AND state NOT IN ('S','D')");
    return undef unless $updated;

    # invalidate memcache for this comment
    LJ::Talk::invalidate_comment_cache($u->id, $itemid, @jtalkids);

    if ($updated > 0) {
        LJ::replycount_do($u, $itemid, "decr", $updated);
        LJ::set_logprop($u, $itemid, { 'hasscreened' => 1 });
    }

    LJ::Talk::update_commentalter($u, $itemid);
    LJ::Talk::update_journals_commentalter($u);

    LJ::run_hooks('screen_comment', $userid, $itemid, [@batch]); # jitemid, [jtalkid]

    return;
}

sub unscreen_comment {
    my $u = shift;
    return undef unless LJ::isu($u);
    my $itemid = shift(@_) + 0;
    my @jtalkids = @_;

    my @batch = map { int $_ } @jtalkids;
    my $in = join(',', @batch);
    return unless $in;

    my $userid = $u->{'userid'} + 0;
    my $prop = LJ::get_prop("log", "hasscreened");

    LJ::run_hooks('report_cmt_update', $userid, \@batch);
    my $updated = $u->talk2_do(nodetype => "L", nodeid => $itemid,
                               sql =>   "UPDATE talk2 SET state='A' ".
                                        "WHERE journalid=$userid AND jtalkid IN ($in) ".
                                        "AND nodetype='L' AND nodeid=$itemid ".
                                        "AND state='S'");
    return undef unless $updated;

    # invalidate memcache for this comment
    LJ::Talk::invalidate_comment_cache($u->id, $itemid, @jtalkids);

    if ($updated > 0) {
        LJ::replycount_do($u, $itemid, "incr", $updated);
        my $dbcm = LJ::get_cluster_master($u);
        my $hasscreened = $dbcm->selectrow_array("SELECT COUNT(*) FROM talk2 " .
                                                 "WHERE journalid=$userid AND nodeid=$itemid AND nodetype='L' AND state='S'");
        LJ::set_logprop($u, $itemid, { 'hasscreened' => 0 }) unless $hasscreened;
    }
    
    LJ::run_hooks('unscreen_comment', $userid, $itemid, $in);

    LJ::Talk::update_commentalter($u, $itemid);
    LJ::Talk::update_journals_commentalter($u);

    return;
}

sub get_talk_data {
    my ($u, $nodetype, $nodeid) = @_;
    return undef unless LJ::isu($u);
    return undef unless $nodetype =~ /^\w$/;
    return undef unless $nodeid =~ /^\d+$/;
    my $uid = $u->id;

    # call normally if no gearman/not wanted
    my $gc = LJ::gearman_client();
    return get_talk_data_do($uid, $nodetype, $nodeid)
        unless $gc && LJ::conf_test($LJ::LOADCOMMENTS_USING_GEARMAN, $u->id);

    # invoke gearman
    my $result;
    my @a = ($uid, $nodetype, $nodeid);
    my $args = Storable::nfreeze(\@a);
    my $task = Gearman::Task->new("get_talk_data", \$args,
                                  {
                                      uniq => join("-", $uid, $nodetype, $nodeid),
                                      on_complete => sub {
                                          my $res = shift;
                                          return unless $res;
                                          $result = Storable::thaw($$res);
                                      }
                                  });

    my $ts = $gc->new_task_set();
    $ts->add_task($task);
    $ts->wait(timeout => 30); # 30 sec timeout

    return $result;
}

# retrieves data from the talk2 table (but preferably memcache)
# returns a hashref (key -> { 'talkid', 'posterid', 'datepost', 'datepost_unix',
#                             'parenttalkid', 'state' } , or undef on failure
sub get_talk_data_do
{
    my ($uid, $nodetype, $nodeid) = @_;
    my $u = LJ::want_user($uid);
    return undef unless LJ::isu($u);
    return undef unless $nodetype =~ /^\w$/;
    return undef unless $nodeid =~ /^\d+$/;

    my $ret = {};

    # check for data in memcache
    my $DATAVER = "3";  # single character
    my $RECORD_SIZE = 17;

    my $memkey = [$u->{'userid'}, "talk2:$u->{'userid'}:$nodetype:$nodeid"];

    my $lockkey = $memkey->[1];
    my $packed = LJ::MemCache::get($memkey);

    # we check the replycount in memcache, the value we count, and then fix it up
    # if it seems necessary.
    my $rp_memkey = $nodetype eq "L" ? [$u->{'userid'}, "rp:$u->{'userid'}:$nodeid"] : undef;
    my $rp_count = $rp_memkey ? LJ::MemCache::get($rp_memkey) : 0;

    # hook for tests to count memcache gets
    if ($LJ::_T_GET_TALK_DATA_MEMCACHE) {
        $LJ::_T_GET_TALK_DATA_MEMCACHE->();
    }

    my $rp_ourcount = 0;
    my $fixup_rp = sub {
        return unless $nodetype eq "L";
        return if $rp_count == $rp_ourcount;
        return unless @LJ::MEMCACHE_SERVERS;
        return unless $u->writer;

        my $gc = LJ::gearman_client();
        if ($gc && LJ::conf_test($LJ::FIXUP_USING_GEARMAN, $u)) {
            $gc->dispatch_background("fixup_logitem_replycount",
                                     Storable::nfreeze([ $u->id, $nodeid ]), {
                                         uniq => "-",
                                     });
        } else {
            LJ::Talk::fixup_logitem_replycount($u, $nodeid);
        }
    };

    my $make_comment_singleton = sub {
        my ($jtalkid, $row) = @_;
        return 1 unless $nodetype eq 'L';

        # at this point we have data for this comment loaded in memory
        # -- instantiate an LJ::Comment object as a singleton and absorb
        #    that data into the object
        my $comment = LJ::Comment->new($u, jtalkid => $jtalkid);
        # add important info to row
        $row->{nodetype} = $nodetype;
        $row->{nodeid}   = $nodeid;
        $comment->absorb_row(%$row);

        return 1;
    };

    # This is a bit tricky.  Since we just loaded and instantiated all comment singletons for this
    # entry (journalid, jitemid) we'll instantiate a skeleton LJ::Entry object (probably a singleton
    # used later in this request anyway) and let it know that its comments are already loaded
    my $set_entry_cache = sub {
        return 1 unless $nodetype eq 'L';

        my $entry = LJ::Entry->new($u, jitemid => $nodeid);

        # find all singletons that LJ::Comment knows about, then grep for the ones we've set in
        # this get_talk_data call (ones for this userid / nodeid)
        my @comments_for_entry =
            grep { $_->journalid == $u->{userid} && $_->nodeid == $nodeid } LJ::Comment->all_singletons;

        $entry->set_comment_list(@comments_for_entry);
    };

    my $memcache_good = sub {
        return $packed && substr($packed,0,1) eq $DATAVER &&
            length($packed) % $RECORD_SIZE == 1;
    };

    my $memcache_decode = sub {
        my $n = (length($packed) - 1) / $RECORD_SIZE;
        for (my $i=0; $i<$n; $i++) {
            my ($talkid, $par, $poster, $time, $state) = unpack(LJ::Talk::PACK_FORMAT, substr($packed,$i*$RECORD_SIZE+1,$RECORD_SIZE));

            $state = chr($state);
            $ret->{$talkid} = {
                talkid => $talkid,
                state => $state,
                posterid => $poster,
                datepost_unix => $time,
                datepost => LJ::TimeUtil->mysql_time($time),  # timezone surely fucked.  deprecated.
                parenttalkid => $par,
            };

            # instantiate comment singleton
            $make_comment_singleton->($talkid, $ret->{$talkid});

            # comments are counted if they're 'A'pproved or 'F'rozen
            $rp_ourcount++ if $state eq "A" || $state eq "F";
        }
        $fixup_rp->();

        # set cache in LJ::Entry object for this set of comments
        $set_entry_cache->();

        ## increase profiling counter
        ## may be safely removed
        LJ::MemCache::add("talk2fromMemc", 0);
        LJ::MemCache::incr("talk2fromMemc");

        return $ret;
    };

    return $memcache_decode->() if $memcache_good->();

    # get time of last modification of comments in this journal.
    # if comments in journal were not updated for a some time, we could
    # load them from any server in cluster: master or slave
    my $dbcr = undef;
    my $comments_updated = $u->prop("comment_alter_time");
    if (LJ::is_web_context()
        and not LJ::did_post()
        and $LJ::USER_CLUSTER_MAX_SECONDS_BEHIND_MASTER
        and $comments_updated
        and time() - $comments_updated > $LJ::USER_CLUSTER_MAX_SECONDS_BEHIND_MASTER
    ){
        # try to load comments from Slave
        $dbcr = LJ::get_cluster_reader($u);

        ## increase profiling counter
        ## may be safely removed
        LJ::MemCache::add("talk2fromSlave", 0);
        LJ::MemCache::incr("talk2fromSlave");

    } else {
        $dbcr = LJ::get_cluster_def_reader($u);
    }
    return undef unless $dbcr;

    my $lock = $dbcr->selectrow_array("SELECT GET_LOCK(?,10)", undef, $lockkey);
    return undef unless $lock;

    # it's quite likely (for a popular post) that the memcache was
    # already populated while we were waiting for the lock
    $packed = LJ::MemCache::get($memkey);
    if ($memcache_good->()) {
        $dbcr->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockkey);
        $memcache_decode->();
        return $ret;
    }

    ## increase profiling counter
    ## may be safely removed
    LJ::MemCache::add("talk2fromDB", 0);
    LJ::MemCache::incr("talk2fromDB");

    my $memval = $DATAVER;
    my $sth = $dbcr->prepare("SELECT t.jtalkid AS 'talkid', t.posterid, ".
                             "t.datepost, UNIX_TIMESTAMP(t.datepost) as 'datepost_unix', ".
                             "t.parenttalkid, t.state ".
                             "FROM talk2 t ".
                             "WHERE t.journalid=? AND t.nodetype=? AND t.nodeid=?");
    $sth->execute($u->{'userid'}, $nodetype, $nodeid);
    die $dbcr->errstr if $dbcr->err;
    while (my $r = $sth->fetchrow_hashref) {
        $ret->{$r->{'talkid'}} = $r;

        {
            # make a new $r-type hash which also contains nodetype and nodeid
            # -- they're not in $r because they were known and specified in the query
            my %row_arg = %$r;
            $row_arg{nodeid}   = $nodeid;
            $row_arg{nodetype} = $nodetype;

            # instantiate comment singleton
            $make_comment_singleton->($r->{talkid}, \%row_arg);

            # set talk2row memcache key for this bit of data
            LJ::Talk::add_talk2row_memcache($u->id, $r->{talkid}, \%row_arg);
        }

        $memval .= pack(LJ::Talk::PACK_FORMAT,
                        $r->{'talkid'},
                        $r->{'parenttalkid'},
                        $r->{'posterid'},
                        $r->{'datepost_unix'},
                        ord($r->{'state'}));

        $rp_ourcount++ if $r->{'state'} eq "A";
    }
    LJ::MemCache::set($memkey, $memval, 3600); # LJSV-748, using LJ::MemCache::append(...) in some (rare) cases 
                                               # can produce comment lose. This is a workaround. Real solution is more complicated.
    $dbcr->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockkey);

    $fixup_rp->();

    # set cache in LJ::Entry object for this set of comments
    $set_entry_cache->();

    return $ret;
}

sub fixup_logitem_replycount {
    my ($u, $jitemid) = @_;

    # attempt to get a database lock to make sure that nobody else is in this section
    # at the same time we are
    my $nodetype = "L";  # this is only for logitem comment counts

    my $rp_memkey = [$u->{'userid'}, "rp:$u->{'userid'}:$jitemid"];
    my $rp_count = LJ::MemCache::get($rp_memkey) || 0;
    my $fix_key = "rp_fixed:$u->{userid}:$nodetype:$jitemid:$rp_count";

    my $db_key = "rp:fix:$u->{userid}:$nodetype:$jitemid";
    my $got_lock = $u->selectrow_array("SELECT GET_LOCK(?, 1)", undef, $db_key);
    return unless $got_lock;

    # setup an unlock handler
    my $unlock = sub {
        $u->do("SELECT RELEASE_LOCK(?)", undef, $db_key);
        return undef;
    };

    # check memcache to see if someone has previously fixed this entry in this journal
    # with this reply count
    my $was_fixed = LJ::MemCache::get($fix_key);
    return $unlock->() if $was_fixed;

    # if we're doing innodb, begin a transaction, else lock tables
    my $sharedmode = "";
    if ($u->is_innodb) {
        $sharedmode = "LOCK IN SHARE MODE";
        $u->begin_work;
    } else {
        $u->do("LOCK TABLES log2 WRITE, talk2 READ");
    }

    # get count and then update.  this should be totally safe because we've either
    # locked the tables or we're in a transaction.
    my $ct = $u->selectrow_array("SELECT COUNT(*) FROM talk2 FORCE INDEX (nodetype) WHERE ".
                                 "journalid=? AND nodetype='L' AND nodeid=? ".
                                 "AND state IN ('A','F') $sharedmode",
                                 undef, $u->{'userid'}, $jitemid);
    LJ::run_hooks('report_entry_update', $u->{'userid'}, $jitemid);
    $u->do("UPDATE log2 SET replycount=? WHERE journalid=? AND jitemid=?",
           undef, int($ct), $u->{'userid'}, $jitemid);
    print STDERR "Fixing replycount for $u->{'userid'}/$jitemid from $rp_count to $ct\n"
        if $LJ::DEBUG{'replycount_fix'};

    # now, commit or unlock as appropriate
    if ($u->is_innodb) {
        $u->commit;
    } else {
        $u->do("UNLOCK TABLES");
    }

    # mark it as fixed in memcache, so we don't do this again
    LJ::MemCache::add($fix_key, 1, 60);
    $unlock->();
    LJ::MemCache::set($rp_memkey, int($ct));
}

# LJ::Talk::load_comments($u, $remote, $nodetype, $nodeid, $opts)
#
# nodetype: "L" (for log) ... nothing else has been used
# noteid: the jitemid for log.
# opts keys:
#   thread -- jtalkid to thread from ($init->{'thread'} or int($GET{'thread'} / 256))
#   page -- $GET{'page'}
#   view -- $GET{'view'} (picks page containing view's ditemid)
#   flat -- boolean:  if set, threading isn't done, and it's just a flat chrono view
#   up -- [optional] hashref of user object who posted the thing being replied to
#         only used to make things visible which would otherwise be screened?
#   out_error -- set by us if there's an error code:
#        nodb:  database unavailable
#        noposts:  no posts to load
#   out_pages:  number of pages
#   out_page:  page number being viewed
#   out_itemfirst:  first comment number on page (1-based, not db numbers)
#   out_itemlast:  last comment number on page (1-based, not db numbers)
#   out_pagesize:  size of each page
#   out_items:  number of total top level items
#
#   userpicref -- hashref to load userpics into, or undef to
#                 not load them.
#   userref -- hashref to load users into, keyed by userid
#
# returns:
#   array of hashrefs containing keys:
#      - talkid (jtalkid)
#      - posterid (or zero for anon)
#      - userpost (string, or blank if anon)
#      - upost    ($u object, or undef if anon)
#      - datepost (mysql format)
#      - parenttalkid (or zero for top-level)
#      - parenttalkid_actual (set when the $flat mode is set, in which case parenttalkid is always faked to be 0)
#      - state ("A"=approved, "S"=screened, "D"=deleted stub)
#      - userpic number
#      - picid   (if userpicref AND userref were given)
#      - subject
#      - body
#      - props => { propname => value, ... }
#      - children => [ hashrefs like these ]
#      - _loaded => 1 (if fully loaded, subject & body)
#        unknown items will never be _loaded
#      - _show => {0|1}, if item is to be ideally shown (0 if deleted or screened)
sub load_comments
{
    my ($u, $remote, $nodetype, $nodeid, $opts) = @_;

    my $n = $u->{'clusterid'};
    my $viewall = $opts->{viewall};

    my $posts = get_talk_data($u, $nodetype, $nodeid);  # hashref, talkid -> talk2 row, or undef
    unless ($posts) {
        $opts->{'out_error'} = "nodb";
        return;
    }
    my %users_to_load;  # userid -> 1
    my @posts_to_load;  # talkid scalars
    my %children;       # talkid -> [ childenids+ ]

    my $uposterid = $opts->{'up'} ? $opts->{'up'}->{'userid'} : 0;

    my $post_count = 0;
    {
        my %showable_children;  # $id -> $count

        foreach my $post (sort { $b->{'talkid'} <=> $a->{'talkid'} } values %$posts) {

            # kill the threading in flat mode
            if ($opts->{'flat'}) {
                $post->{'parenttalkid_actual'} = $post->{'parenttalkid'};
                $post->{'parenttalkid'} = 0;
            }

            # see if we should ideally show it or not.  even if it's
            # zero, we'll still show it if it has any children (but we won't show content)
            my $should_show = $post->{'state'} eq 'D' ? 0 : 1;
            unless ($viewall) {
                $should_show = 0 if
                    $post->{'state'} eq "S" && ! ($remote && ($remote->{'userid'} == $u->{'userid'} ||
                                                              $remote->{'userid'} == $uposterid ||
                                                              $remote->{'userid'} == $post->{'posterid'} ||
                                                              LJ::can_manage($remote, $u) ));
            }
            $post->{'_show'} = $should_show;
            $post_count += $should_show;

            # make any post top-level if it says it has a parent but it isn't
            # loaded yet which means either a) row in database is gone, or b)
            # somebody maliciously/accidentally made their parent be a future
            # post, which could result in an infinite loop, which we don't want.
            $post->{'parenttalkid'} = 0
                if $post->{'parenttalkid'} && ! $posts->{$post->{'parenttalkid'}};

            $post->{'children'} = [ map { $posts->{$_} } @{$children{$post->{'talkid'}} || []} ];

            # increment the parent post's number of showable children,
            # which is our showability plus all those of our children
            # which were already computed, since we're working new to old
            # and children are always newer.
            # then, if we or our children are showable, add us to the child list
            my $sum = $should_show + $showable_children{$post->{'talkid'}};
            if ($sum) {
                $showable_children{$post->{'parenttalkid'}} += $sum;
                unshift @{$children{$post->{'parenttalkid'}}}, $post->{'talkid'};
            }
        }
    }

    # with a wrong thread number, silently default to the whole page
    my $thread = $opts->{'thread'}+0;
    $thread = 0 unless $posts->{$thread};

    unless ($thread || $children{$thread}) {
        $opts->{'out_error'} = "noposts";
        return;
    }

    my $page_size = $opts->{page_size} || $LJ::TALK_PAGE_SIZE || 25;
    my $max_subjects = $LJ::TALK_MAX_SUBJECTS || 200;
    my $threading_point = $LJ::TALK_THREAD_POINT || 50;

    # we let the page size initially get bigger than normal for awhile,
    # but if it passes threading_point, then everything's in page_size
    # chunks:
    $page_size = $threading_point if $post_count < $threading_point;

    my $top_replies = $thread ? 1 : scalar(@{$children{$thread}});
    my $pages = int($top_replies / $page_size);
    if ($top_replies % $page_size) { $pages++; }

    my @top_replies = $thread ? ($thread) : @{$children{$thread}};
    my $page_from_view = 0;
    if ($opts->{'view'} && !$opts->{'page'}) {
        # find top-level comment that this comment is under
        my $viewid = int($opts->{'view'} / 256);
        while ($posts->{$viewid} && $posts->{$viewid}->{'parenttalkid'}) {
            $viewid = $posts->{$viewid}->{'parenttalkid'};
        }
        for (my $ti = 0; $ti < @top_replies; ++$ti) {
            if ($posts->{$top_replies[$ti]}->{'talkid'} == $viewid) {
                $page_from_view = int($ti/$page_size)+1;
                last;
            }
        }
    }
    my $page = int($opts->{'page'}) || $page_from_view || 1;
    $page = $page < 1 ? 1 : $page > $pages ? $pages : $page;

    my $itemfirst = $page_size * ($page-1) + 1;
    my $itemlast = $page==$pages ? $top_replies : ($page_size * $page);

    @top_replies = @top_replies[$itemfirst-1 .. $itemlast-1];

    push @posts_to_load, @top_replies;

    # mark child posts of the top-level to load, deeper
    # and deeper until we've hit the page size.  if too many loaded,
    # just mark that we'll load the subjects;
    my @check_for_children = @posts_to_load;

    ## expand first reply to top-level comments
    ## %expand_children - list of comments, children of which are to expand
    my %expand_children = map { $_ => 1 } @top_replies;

    ## new strategy to expand comments: by level 
    if ($opts->{expand_strategy} eq 'by_level' and $opts->{expand_level} > 1) {
        my $expand = sub {
            my ($fun, $cur_level, $item_ids) = @_;
            next if $cur_level >= $opts->{expand_level};

            foreach my $itemid (@$item_ids){
                $expand_children{$itemid} = 1;
                next unless $children{$itemid};

                ## expand next level it there are comments
                $fun->($fun, $cur_level+1, $children{$itemid});
            }
        };

        ## go through first level
        foreach my $itemid (keys %expand_children){
            next unless $children{$itemid};
            ## expand next (second) level
            $expand->($expand, 2, $children{$itemid});
        }
    }

    my (@subjects_to_load, @subjects_ignored);
    while (@check_for_children) {
        my $cfc = shift @check_for_children;
        next unless defined $children{$cfc};
        foreach my $child (@{$children{$cfc}}) {
            if (@posts_to_load < $page_size || $expand_children{$cfc} || $opts->{expand_all}) {
                push @posts_to_load, $child;
                ## expand only the first child (unless 'by_level' strategy is in use), 
                ## then clear the flag
                delete $expand_children{$cfc}
                    unless $opts->{expand_strategy} eq 'by_level';
            }
            elsif (@posts_to_load < $page_size) {
                push @posts_to_load, $child;
            } else {
                if (@subjects_to_load < $max_subjects) {
                    push @subjects_to_load, $child;
                } else {
                    push @subjects_ignored, $child;
                }
            }
            push @check_for_children, $child;
        }
    }

    $opts->{'out_pages'} = $pages;
    $opts->{'out_page'} = $page;
    $opts->{'out_itemfirst'} = $itemfirst;
    $opts->{'out_itemlast'} = $itemlast;
    $opts->{'out_pagesize'} = $page_size;
    $opts->{'out_items'} = $top_replies;

    # load text of posts
    my ($posts_loaded, $subjects_loaded);
    $posts_loaded = LJ::get_talktext2($u, @posts_to_load);
    $subjects_loaded = LJ::get_talktext2($u, {'onlysubjects'=>1}, @subjects_to_load) if @subjects_to_load;
    foreach my $talkid (@posts_to_load) {
        next unless $posts->{$talkid}->{'_show'};
        $posts->{$talkid}->{'_loaded'} = 1;
        $posts->{$talkid}->{'subject'} = $posts_loaded->{$talkid}->[0];
        $posts->{$talkid}->{'body'} = $posts_loaded->{$talkid}->[1];
        $users_to_load{$posts->{$talkid}->{'posterid'}} = 1;
    }
    foreach my $talkid (@subjects_to_load) {
        next unless $posts->{$talkid}->{'_show'};
        $posts->{$talkid}->{'subject'} = $subjects_loaded->{$talkid}->[0];
        $users_to_load{$posts->{$talkid}->{'posterid'}} ||= 0.5;  # only care about username
    }
    foreach my $talkid (@subjects_ignored) {
        next unless $posts->{$talkid}->{'_show'};
        $posts->{$talkid}->{'subject'} = "...";
        $users_to_load{$posts->{$talkid}->{'posterid'}} ||= 0.5;  # only care about username
    }

    # load meta-data
    {
        my %props;
        LJ::load_talk_props2($u->{'userid'}, \@posts_to_load, \%props);
        foreach (keys %props) {
            next unless $posts->{$_}->{'_show'};
            $posts->{$_}->{'props'} = $props{$_};
        }
    }

    if ($LJ::UNICODE) {
        foreach (@posts_to_load) {
            if ($posts->{$_}->{'props'}->{'unknown8bit'}) {
                LJ::item_toutf8($u, \$posts->{$_}->{'subject'},
                                \$posts->{$_}->{'body'},
                                {});
              }
        }
    }

    # load users who posted
    delete $users_to_load{0};
    my %up = ();
    if (%users_to_load) {
        LJ::load_userids_multiple([ map { $_, \$up{$_} } keys %users_to_load ]);

        # fill in the 'userpost' member on each post being shown
        while (my ($id, $post) = each %$posts) {
            my $up = $up{$post->{'posterid'}};
            next unless $up;
            $post->{'upost'}    = $up;
            $post->{'userpost'} = $up->{'user'};
        }
    }

    ## Fix: if authors of comments deleted their journals, 
    ## and choosed to delete their content in other journals,
    ## then show their comments as deleted.
    ## Note: only posts with loaded users (posts that will be shown) are processed here.
    if (!$LJ::JOURNALS_WITH_PROTECTED_CONTENT{ $u->{'user'} }) {
        foreach my $post (values %$posts) {
            my $up = $up{ $post->{'posterid'} };
            if ($up && $up->is_deleted) {
                my ($purge_comments, undef) = split /:/, $up->prop("purge_external_content");
                if ($purge_comments) {
                    delete @$post{qw/ _loaded subject body /};
                    $post->{'status'} = 'D';
                }
            }
        }
    } 

    # optionally give them back user refs
    if (ref($opts->{'userref'}) eq "HASH") {
        my %userpics = ();
        # copy into their ref the users we've already loaded above.
        while (my ($k, $v) = each %up) {
            $opts->{'userref'}->{$k} = $v;
        }

        # optionally load userpics
        if (ref($opts->{'userpicref'}) eq "HASH") {
            my @load_pic;
            foreach my $talkid (@posts_to_load) {
                my $post = $posts->{$talkid};
                my $kw;
                if ($post->{'props'} && $post->{'props'}->{'picture_keyword'}) {
                    $kw = $post->{'props'}->{'picture_keyword'};
                }
                my $pu = $opts->{'userref'}->{$post->{'posterid'}};
                my $id = LJ::get_picid_from_keyword($pu, $kw);
                $post->{'picid'} = $id;
                push @load_pic, [ $pu, $id ];
            }
            LJ::load_userpics($opts->{'userpicref'}, \@load_pic);
        }
    }
    return map { $posts->{$_} } @top_replies;
}

# XXX these strings should be in talk, but moving them means we have
# to retranslate.  so for now we're just gonna put it off.
my $SC = '/talkpost_do.bml';

sub talkform {
    # Takes a hashref with the following keys / values:
    # remote:      optional remote u object
    # journalu:    prequired journal u object
    # parpost:     parent post object
    # replyto:     init->replyto
    # ditemid:     init->ditemid
    # stylemine:   user using style=mine or not
    # form:        optional full form hashref
    # do_captcha:  optional toggle for creating a captcha challenge
    # require_tos: optional toggle to include TOS requirement form
    # errors:      optional error arrayref
    # text_hint:   hint before message textarea
    my $opts = shift;
    return "Invalid talkform values." unless ref $opts eq 'HASH';

    my $ret;
    my ($remote, $journalu, $parpost, $form) =
        map { $opts->{$_} } qw(remote journalu parpost form);

    my $editid = $form->{edit} ? $form->{edit} : 0;
    my $comment;
    if ($editid) {
        $comment = LJ::Comment->new($journalu, dtalkid => $editid);
        return "Cannot load comment information." unless $comment;
    }

    my $pics = LJ::Talk::get_subjecticons();

    # early bail if the user can't be making comments yet
    return $LJ::UNDERAGE_ERROR
        if $remote && $remote->underage;

    # once we clean out talkpost.bml, this will need to be changed.
    BML::set_language_scope('/talkpost.bml');

    # make sure journal isn't locked
    return "Sorry, this journal is locked and comments cannot be posted to it or edited at this time."
        if $journalu->{statusvis} eq 'L';

    # check max comments only if posting a new comment (not when editing)
    unless ($editid) {
        my $jitemid = int($opts->{'ditemid'} / 256);
        return "Sorry, this entry already has the maximum number of comments allowed."
            if LJ::Talk::Post::over_maxcomments($journalu, $jitemid);
    }

    if (!$editid && $parpost->{'state'} eq "S") {
        $ret .= "<div class='ljwarnscreened'>$BML::ML{'.warnscreened'}</div>";
    }
    $ret .= "<form method='post' action='$LJ::SITEROOT/talkpost_do.bml' id='postform'>";
    $ret .= LJ::form_auth();

    # Login challenge/response
    my $authchal = LJ::challenge_generate(900); # 15 minute auth token
    $ret .= "<input type='hidden' name='chal' id='login_chal' value='$authchal' />";
    $ret .= "<input type='hidden' name='response' id='login_response' value='' />";

    if ($opts->{errors} && @{$opts->{errors}}) {
        $ret .= '<ul>';
        $ret .= "<li><b>$_</b></li>" foreach @{$opts->{errors}};
        $ret .= '</ul>';
        $ret .= "<hr />";
    }

    # hidden values
    my $parent = $opts->{replyto}+0;
    $ret .= LJ::html_hidden("replyto", $opts->{replyto},
                            "parenttalkid", $parent,
                            "itemid", $opts->{ditemid},
                            "journal", $journalu->{'user'},
                            "stylemine", $opts->{stylemine});

    # rate limiting challenge
    {
        my ($time, $secret) = LJ::get_secret();
        my $rchars = LJ::rand_chars(20);
        my $chal = $opts->{ditemid} . "-$journalu->{userid}-$time-$rchars";
        my $res = Digest::MD5::md5_hex($secret . $chal);
        $ret .= LJ::html_hidden("chrp1", "$chal-$res");
    }

    # if we know the user who is posting (error on talkpost_do POST action),
    # then see if we
    if ($opts->{require_tos}) {
        $ret .= LJ::tosagree_html('comment', $form->{agree_tos}, BML::ml('tos.error'));
    }

    my $oid_identity = $remote ? $remote->openid_identity : undef;

    # Default radio button
    # 4 possible scenarios:
    # remote - initial form load, error and redisplay
    # no remote - initial load, error and redisplay
    my $whocheck = sub {
        my $type = shift;
        my $default = " checked='checked'";

        # Initial page load (no remote)
        return $default if $type eq 'anonymous' &&
            ! $form->{'usertype'} && ! $remote && ! $oid_identity;

        # Anonymous
        return $default if $type eq 'anonymous' &&
            $form->{'usertype'} eq 'anonymous';

        if (LJ::OpenID->consumer_enabled) {
            # OpenID
            return $default if $type eq 'openid' &&
                $form->{'usertype'} eq 'openid';

            return $default if $type eq 'openid_cookie' &&
                ($form->{'usertype'} eq 'openid_cookie' ||
                (defined $oid_identity));
        }

        # Remote user, remote equals userpost
        return $default if $type eq 'remote' &&
                           ($form->{'usertype'} eq 'cookieuser' ||
                            $form->{'userpost'} eq $form->{'cookieuser'});

        # Possible remote, using ljuser field
        if ($type eq 'ljuser') {
        return $default if
            # Remote user posting as someone else.
            ($form->{'userpost'} && $form->{'userpost'} ne $form->{'cookieuser'} && $form->{'usertype'} ne 'anonymous') ||
            ($form->{'usertype'} eq 'user' && ! $form->{'userpost'});
        }

        return;
    };

    # special link to create an account
    my $create_link;
    if (!$remote || defined $oid_identity) {
        $create_link = LJ::run_hook("override_create_link_on_talkpost_form", $journalu);
        $ret .= $create_link;
    }

    # from registered user or anonymous?
    $ret .= "<table>\n";
    $ret .= "<tr><td align='right' valign='top'>$BML::ML{'.opt.from'}</td>";
    $ret .= "<td>";
    $ret .= "<table>"; # Internal for "From" options
    my $screening = LJ::Talk::screening_level($journalu, int($opts->{ditemid} / 256));

    if ($editid) {

        return "You cannot edit this comment." unless $remote && !defined $oid_identity;

        $ret .= "<tr valign='middle' id='ljuser_row'>";
        my $logged_in = LJ::ehtml($remote->display_name);

        if (LJ::is_banned($remote, $journalu)) {
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo.gif' /></td>";
            $ret .= "<td align='center'>( )</td>";
            $ret .= "<td align='left'><span class='ljdeem'>" . BML::ml(".opt.loggedin", {'username'=>"<i>$logged_in</i>"}) . "</font>" . BML::ml(".opt.bannedfrom", {'journal'=>$journalu->{'user'}}) . "</td>";
        } else {
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo.gif'  onclick='handleRadios(1);' /></td>";
            $ret .= "<td align='left'><label for='talkpostfromremote'>" . BML::ml(".opt.loggedin", {'username'=>"<i>$logged_in</i>"}) . "</label>\n";

            $ret .= "<input type='hidden' name='usertype' value='cookieuser' />";
            $ret .= "<input type='hidden' name='cookieuser' value='$remote->{'user'}' id='cookieuser' />\n";
            $ret .= "</td>";
        }
        $ret .= "</tr>\n";

    } else { # if not edit

    if ($journalu->{'opt_whocanreply'} eq "all") {
        my $entry = LJ::Entry->new($journalu, ditemid => $opts->{ditemid});

        if ($entry && $entry->security ne "public") {
            $ret .= "<tr valign='middle'>";
            $ret .= "<td align='center' width='20'><img src='$LJ::IMGPREFIX/anonymous.gif' /></td>";
            $ret .= "<td align='center'>(  )</td>";
            $ret .= "<td align='left' colspan='2'><font color='#c0c0c0'><b>$BML::ML{'.opt.anonymous'}</b></font>$BML::ML{'.opt.noanonpost.nonpublic'}</td>";
            $ret .= "</tr>\n";
        } else {
            $ret .= "<tr valign='center'>";
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/anonymous.gif' onclick='handleRadios(0);'/></td>";
            $ret .= "<td align='center'><input type='radio' name='usertype' value='anonymous' id='talkpostfromanon'" .
                    $whocheck->('anonymous') .
                    " /></td>";
            $ret .= "<td align='left'><b><label for='talkpostfromanon'>$BML::ML{'.opt.anonymous'}</label></b>";
            $ret .= " " . $BML::ML{'.opt.willscreen'} if $screening;
            $ret .= "</td></tr>\n";
        }

        if (LJ::OpenID->consumer_enabled) {
            # OpenID!!
            # Logged in
            if (defined $oid_identity) {
                $ret .= "<tr valign='middle' id='oidli' name='oidli'>";
                $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(4);' /></td><td align='center'><input type='radio' name='usertype' value='openid_cookie' id='talkpostfromoidli'" .
                    $whocheck->('openid_cookie') . "/>";
                $ret .= "</td><td align='left'><b><label for='talkpostfromoid' onclick='handleRadios(4);return false;'>OpenID identity:</label></b> ";

                $ret .= "<strong>" . $remote->display_name . "</strong>";

                $ret .= $BML::ML{'.opt.willscreen'} if $screening;
                $ret .= "</td></tr>\n";
            } else {
                # logged out
                $ret .= "<tr valign='middle' id='oidlo' name='oidlo'>";
                $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(3);' /></td><td align='center'><input type='radio' name='usertype' value='openid' id='talkpostfromoidlo'" .
                    $whocheck->('openid') . "/>";
                $ret .= "</td><td align='left'><b><label for='talkpostfromoidlo' onclick='handleRadios(3);return false;'>OpenID</label></b> ";

                $ret .= LJ::help_icon_html("openid", " ");

                $ret .= $BML::ML{'.opt.willscreen'} if $screening;
                $ret .= "</td></tr>\n";
            }

            # URL: [    ]  Verify? [ ]
            my $url_def = defined $oid_identity ? ($form->{'oidurl'} || $oid_identity) : '';

            $ret .= "<tr valign='middle' align='left' id='oid_more'><td colspan='2'></td><td>";
            $ret .= "Identity URL:&nbsp;<input class='textbox' name='oidurl' maxlength='60' size='53' id='oidurl' value='$url_def' /> ";
            $ret .= "<br /><label for='oidlogincheck'>$BML::ML{'.loginq'}&nbsp;</label><input type='checkbox' name='oiddo_login' id='oidlogincheck' ";
            $ret .= "checked='checked' " if $form->{'oiddo_login'};
            $ret .= "/></td></tr>\n";
        }
    }

    if ($journalu->{'opt_whocanreply'} eq "reg") {
        $ret .= "<tr valign='middle'>";
        $ret .= "<td align='center' width='20'><img src='$LJ::IMGPREFIX/anonymous.gif' /></td>";
        $ret .= "<td align='center'>(  )</td>";
        $ret .= "<td align='left' colspan='2'><font color='#c0c0c0'><b>$BML::ML{'.opt.anonymous'}</b></font> $BML::ML{'.opt.noanonpost'}</td>";
        $ret .= "</tr>\n";

        if (LJ::OpenID->consumer_enabled) {
            # OpenID user can comment if the account has validated e-mail address or OpenID provider is trusted
            if (defined $oid_identity && $remote->is_trusted_identity) {
                my $logged_in = LJ::ehtml($remote->display_name);
                $ret .= "<tr valign='middle' id='oidli' name='oidli'>";
                if (LJ::is_banned($remote, $journalu)) {
                    $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' /></td>";
                    $ret .= "<td align='center'>( )</td>";
                    $ret .= "<td align='left'><span class='ljdeem'>" . BML::ml(".opt.loggedin", {'username'=>"<i>$logged_in</i>"}) . "</font>" . BML::ml(".opt.bannedfrom", {'journal'=>$journalu->{'user'}}) . "</td>";
                } else {
                    $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(4);' /></td><td align='center'><input type='radio' name='usertype' value='openid_cookie' id='talkpostfromoidli'" .
                        $whocheck->('openid_cookie') . "/>";
                    $ret .= "</td><td align='left'><b><label for='talkpostfromoid' onclick='handleRadios(4);return false;'>OpenID identity:</label></b> ";

                    $ret .= "<strong>" . $remote->display_name . "</strong>";

                    $ret .= $BML::ML{'.opt.willscreen'} if $screening;
                }
                $ret .= "</td></tr>\n";
            } else {
                # logged out or no validated email
                $ret .= "<tr valign='middle'>";
                $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(3);' /></td>";
                $ret .= "<td align='center'>(  )</td>";
                $ret .= "<td align='left' colspan='2'><font color='#c0c0c0'><b>OpenID</b></font>";
                $ret .= BML::ml('.opt.noopenidpost', { aopts1 => "href='$LJ::SITEROOT/changeemail.bml'", aopts2 => "href='$LJ::SITEROOT/register.bml'" })
                    if defined $oid_identity;

                $ret .= LJ::help_icon_html("openid", " ");

                $ret .= "</td></tr>\n";
            }
        }
    }

    my $remote_can_comment = 1;
    $remote_can_comment = 0 if $journalu->{'opt_whocanreply'} eq 'friends' and $remote and not LJ::is_friend($journalu, $remote);

    if ($journalu->{'opt_whocanreply'} eq 'friends') {
        $ret .= "<tr valign='middle'>";
        $ret .= "<td align='center' width='20'><img src='$LJ::IMGPREFIX/anonymous.gif' /></td>";
        $ret .= "<td align='center'>(  )</td>";
        $ret .= "<td align='left' colspan='2'><font color='#c0c0c0'><b>$BML::ML{'.opt.anonymous'}</b></font>";
        my $stringname = $journalu->is_person ? ".opt.friendsonly" : ".opt.membersonly";
        $ret .= ' ' . BML::ml($stringname, {'username'=>"<b>$journalu->{'user'}</b>"});
        $ret .= "</tr>\n";

        ## the if clause was a copy of code from ($journalu->{'opt_whocanreply'} eq 'all')`
        if (LJ::OpenID->consumer_enabled) {
            # OpenID!!
            # Logged in
            if (defined $oid_identity) {
                $ret .= "<tr valign='middle' id='oidli' name='oidli'>";
                $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(4);' /></td>";
                if ($remote_can_comment) {
                    $ret .= "<td align='center'><input type='radio' name='usertype' value='openid_cookie' id='talkpostfromoidli'" .
                        $whocheck->('openid_cookie') . "/>";
                    $ret .= "</td><td align='left'><b><label for='talkpostfromoid' onclick='handleRadios(4);return false;'>OpenID identity:</label></b> ";
                } else {
                    $ret .= "<td align='center'>( )</td><td align='left'><b><font color='#c0c0c0'>OpenID identity:</font></b>&nbsp;";
                }

                $ret .= "<strong>" . $remote->display_name . "</strong>";
                unless ($remote_can_comment) {
                    my $msg = $journalu->is_comm ? "notamember" : "notafriend";
                    $ret .= "&nbsp;- " . BML::ml("$SC.error.$msg", {'user' => $journalu->{'user'} });
                }

                $ret .= $BML::ML{'.opt.willscreen'} if $screening;
                $ret .= "</td></tr>\n";
            } else {
                # logged out
                $ret .= "<tr valign='middle' id='oidlo' name='oidlo'>";
                $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(3);' /></td><td align='center'><input type='radio' name='usertype' value='openid' id='talkpostfromoidlo'" .
                    $whocheck->('openid') . "/>";
                $ret .= "</td><td align='left'><b><label for='talkpostfromoidlo' onclick='handleRadios(3);return false;'>OpenID</label></b> ";

                $ret .= LJ::help_icon_html("openid", " ");

                $ret .= $BML::ML{'.opt.willscreen'} if $screening;
                $ret .= "</td></tr>\n";
            }

            # URL: [    ]  Verify? [ ]
            my $url_def = defined $oid_identity ? ($form->{'oidurl'} || $oid_identity) : '';

            $ret .= "<tr valign='middle' align='left' id='oid_more'><td colspan='2'></td><td>";
            $ret .= "Identity URL:&nbsp;<input class='textbox' name='oidurl' maxlength='60' size='53' id='oidurl' value='$url_def' /> ";
            $ret .= "<br /><label for='oidlogincheck'>$BML::ML{'.loginq'}&nbsp;</label><input type='checkbox' name='oiddo_login' id='oidlogincheck' ";
            $ret .= "checked='checked' " if $form->{'oiddo_login'};
            $ret .= "/></td></tr>\n";
        }
    }

    if ($remote && !defined $oid_identity) {
        $ret .= "<tr valign='middle' id='ljuser_row" . ($remote_can_comment ? '' : '_cannot') . "'>";
        my $logged_in = LJ::ehtml($remote->display_name);

        # Don't worry about a real href since js hides the row anyway
        my $other_user = "<script language='JavaScript'>if (document.getElementById) {document.write(\"&nbsp;<a href='#' onClick='otherLJUser();return false;'>[other]</a>\");}</script>";

        if (LJ::is_banned($remote, $journalu)) {
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo.gif' /></td>";
            $ret .= "<td align='center'>( )</td>";
            $ret .= "<td align='left'><span class='ljdeem'>" . BML::ml(".opt.loggedin", {'username'=>"<i>$logged_in</i>"}) . "</font>" . BML::ml(".opt.bannedfrom", {'journal'=>$journalu->{'user'}}) . $other_user . "</td>";
        } else {
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo.gif'  onclick='handleRadios(1);' /></td>";
            if ($remote_can_comment) {
                $ret .= "<td align='center'><input type='radio' name='usertype' value='cookieuser' id='talkpostfromremote'" .
                        $whocheck->('remote') .
                        " /></td>";
            } else {
                $ret .= "<td align='center'>( )</td>";
            }
            $ret .= "<td align='left'>";
            if ($remote_can_comment) {
                $ret .= "<label for='talkpostfromremote'>";
                $ret .= BML::ml(".opt.loggedin", {'username'=>"<strong>$logged_in</strong>"});
                $ret .= "</label>\n";
            } else {
                $ret .= "<font color='#c0c0c0'>";
                $ret .= BML::ml(".opt.loggedin", {'username'=>"</font> <strong>$logged_in</strong><font color='#c0c0c0'>"});
                $ret .= "</font>\n";
            }
            if ($remote_can_comment) {
                $ret .= $other_user;
            } else {
                my $msg = $journalu->is_comm ? "notamember" : "notafriend";
                $ret .= "&nbsp;- " . BML::ml("$SC.error.$msg", {'user' => $journalu->{'user'} });
            }

            $ret .= "<input type='hidden' name='cookieuser' value='$remote->{'user'}' id='cookieuser' />\n";
            if ($screening eq 'A' ||
                ($screening eq 'F' && !LJ::is_friend($journalu, $remote))) {
                $ret .= " " . $BML::ML{'.opt.willscreen'};
            }
            $ret .= "</td>";
        }
        $ret .= "</tr>\n";
    }

    # ( ) LiveJournal user:
    $ret .= "<tr valign='middle' id='otherljuser_row' name='otherljuser_row'>";
    $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/pencil.gif' onclick='handleRadios(2);' /></td><td align='center'><input type='radio' name='usertype' value='user' id='talkpostfromlj'" .
        ( $remote_can_comment ? $whocheck->('ljuser') : ' checked="checked"' ) . "/>";
    $ret .= "</td><td align='left'><b><label for='talkpostfromlj' onclick='handleRadios(2); return false;'>$BML::ML{'.opt.ljuser2'}</label></b> ";
    $ret .= $BML::ML{'.opt.willscreenfriend'} if $screening eq 'F';
    $ret .= $BML::ML{'.opt.willscreen'} if $screening eq 'A';
    $ret .= "</td></tr>\n";

    if ($remote && ! defined $oid_identity) {
        $ret .= "<script language='JavaScript'>\n";
        $ret .= "<!--\n";
        $ret .= "if (document.getElementById) {\n";
        $ret .= "var radio_user = document.getElementById(\"talkpostfromlj\");\n";
        $ret .= "if (!radio_user.checked) {\n";
        $ret .= "var otherljuser_row = document.getElementById(\"otherljuser_row\");\n";
        $ret .= "otherljuser_row.className = 'display_none';\n";
        $ret .= "}\n";
        $ret .= "}\n";
        $ret .= "//-->\n";
        $ret .= "</script>";
   }

    # Username: [    ] Password: [    ]  Login? [ ]
    $ret .= "<tr valign='middle' align='left' id='lj_more'><td colspan='2'></td><td>";

    my $ljuser_def = "";
    if ($remote && !defined $oid_identity) {
        if ($form->{userpost} ne $form->{cookieuser} && $form->{usertype} ne 'anonymous') {
            $ljuser_def = BML::eall($form->{userpost});
        } else {
            $ljuser_def = $remote->{user};
        }
    }
    $ljuser_def = "" unless $remote_can_comment;

    $ret .= "<table><tr><td>";
    $ret .= "$BML::ML{'Username'}:</td><td>";
    $ret .= "<input class='textbox' name='userpost' size='13' maxlength='15' id='username' value='$ljuser_def' onclick='this.value=\"\"' ";
    $ret .= "style='background: url($LJ::IMGPREFIX/userinfo.gif) no-repeat; background-color: #fff; background-position: 0px 1px; padding-left: 18px; color: #00C; font-weight: bold;'/>";

    $ret .= "</td></tr><tr><td>";
    $ret .= "$BML::ML{'Password'}:</td><td>";
    $ret .= "<input class='textbox' name='password' type='password' maxlength='30' size='18' id='password' />";
    $ret .= "</td></tr><tr><td colspan='2'>";
    $ret .= "<label for='logincheck'>$BML::ML{'.loginq'}&nbsp;</label><input type='checkbox' name='do_login' id='logincheck' /></td></tr></table>";
    $ret .= "</td></tr>\n";

    # Link to create an account
    if (!$create_link && (!$remote || defined $oid_identity)) {
        $ret .= "<tr valign='middle' align='left'>";
        $ret .= "<td colspan='2'></td><td><span style='font-size: 8pt; font-style: italic;'>";
        $ret .= BML::ml('.noaccount', {'aopts' => "href='$LJ::SITEROOT/create.bml'"});
        $ret .= "</span></td>";
        $ret .= "</tr>\n";
    }

    } # end edit check

    my $basesubject = $form->{subject} || "";
    if ($opts->{replyto} && !$basesubject && $parpost->{'subject'}) {
        $basesubject = $parpost->{'subject'};
        $basesubject =~ s/^Re:\s*//i;
        $basesubject = "Re: $basesubject";
    }

    # Closing internal "From" table
    $ret .= "</td></tr></table>";

    # subject
    $basesubject = BML::eall($basesubject) if $basesubject;
    $ret .= "<tr valign='top'><td align='right'>$BML::ML{'.opt.subject'}</td><td><input class='textbox' type='text' size='50' maxlength='100' name='subject' id='subject' value=\"$basesubject\" onKeyPress='subjectNoHTML(event);'/>\n";

    # Subject Icon toggle button
    {
        my $subjicon = $form->{subjecticon} || 'none';
        my $foundicon = 0;
        $ret .= "<input type='hidden' id='subjectIconField' name='subjecticon' value='$subjicon'>\n";
        $ret .= "<script type='text/javascript' language='Javascript'>\n";
        $ret .= "<!--\n";
        $ret .= "if (document.getElementById) {\n";
        $ret .= "document.write(\"";
        if ($subjicon eq 'none') {
            $ret .= LJ::ejs(LJ::Talk::show_none_image("id='subjectIconImage' style='cursor:pointer;cursor:hand' align='absmiddle' ".
                                                      "onclick='subjectIconListToggle();' ".
                                                      "title='Click to change the subject icon'"));
        } else {
            foreach my $type (@{$pics->{types}}) {
                foreach (@{$pics->{lists}->{$type}}) {
                    if ($_->{id} eq $subjicon) {
                        $ret .= LJ::Talk::show_image($pics, $subjicon,
                                                     "id='subjectIconImage' onclick='subjectIconListToggle();' style='cursor:pointer;cursor:hand'");
                        $foundicon = 1;
                        last;
                    }
                }
                last if $foundicon == 1;
            }
        }
        if ($foundicon == 0 && $subjicon ne 'none') {
            $ret .= LJ::ejs(LJ::Talk::show_none_image("id='subjectIconImage' style='cursor:pointer;cursor:hand' align='absmiddle' ".
                                                      "onclick='subjectIconListToggle();' ".
                                                      "title='Click to change the subject icon'"));
        }
        $ret .="\");\n";

        # spit out a pretty table of all the possible subjecticons
        $ret .= "document.write(\"";
        $ret .= "<blockquote style='display:none;' id='subjectIconList'>";
        $ret .= "<table border='0' cellspacing='5' cellpadding='0' style='border: 1px solid #AAAAAA'>\");\n";

        foreach my $type (@{$pics->{'types'}}) {

            $ret .= "document.write(\"<tr>\");\n";

            # make an option if they don't want an image
            if ($type eq $pics->{'types'}->[0]) {
                $ret .= "document.write(\"";
                $ret .= "<td valign='middle' align='center'>";
                $ret .= LJ::Talk::show_none_image(
                        "id='none' onclick='subjectIconChange(this);' style='cursor:pointer;cursor:hand' title='No subject icon'");
                $ret .= "</td>\");\n";
            }

            # go through and make clickable image rows.
            foreach (@{$pics->{'lists'}->{$type}}) {
                $ret .= "document.write(\"";
                $ret .= "<td valign='middle' align='center'>";
                $ret .= LJ::Talk::show_image($pics, $_->{'id'},
                        "id='$_->{'id'}' onclick='subjectIconChange(this);' style='cursor:pointer;cursor:hand'");
                $ret .= "</td>\");\n";
            }

            $ret .= "document.write(\"</tr>\");\n";

        }
        # end that table, bar!
        $ret .= "document.write(\"</table></blockquote>\");\n";

        $ret .= "}\n";
        $ret .="//-->\n";
        $ret .= "</script>\n";
    }

    # finish off subject line
    $ret .= "<div id='ljnohtmlsubj' class='ljdeem'><span style='font-size: 8pt; font-style: italic;'>$BML::ML{'.nosubjecthtml'}</span></div>\n";

    $ret .= "<div id=\"subjectCaptionText\">" . $opts->{text_hint} . "</div>"
        if $opts->{text_hint};
    
    $ret .= "<div id='userpics'>";
    my %res;
    if ($remote) {
        LJ::do_request({ "mode" => "login",
                         "ver" => ($LJ::UNICODE ? "1" : "0"),
                         "user" => $remote->{'user'},
                         "getpickws" => 1,
                       }, \%res, { "noauth" => 1, "userid" => $remote->{'userid'} });
    }
    if ($res{'pickw_count'}) {
        $ret .= BML::ml('.label.picturetouse2',
                        {
                            'aopts'=>"href='$LJ::SITEROOT/allpics.bml?user=$remote->{'user'}'"}) . " ";
        my @pics;
        for (my $i=1; $i<=$res{'pickw_count'}; $i++) {
            push @pics, $res{"pickw_$i"};
        }
        @pics = sort { lc($a) cmp lc($b) } @pics;
        $ret .= LJ::html_select({'name' => 'prop_picture_keyword',
                                 'selected' => $form->{'prop_picture_keyword'}, },
                                ("", $BML::ML{'.opt.defpic'}, map { ($_, $_) } @pics));

        $ret .= LJ::help_icon_html("userpics", " ");
    }

    $ret .= "&nbsp;&nbsp;<label for='prop_opt_preformatted'>$BML::ML{'.opt.noautoformat'}</label>";
    $ret .= LJ::html_check(
                           {
                               name  => 'prop_opt_preformatted',
                               id    => 'prop_opt_preformatted',
                               value => 1,
                               selected => $form->{'prop_opt_preformatted'}
                           }
    );

    $ret .= LJ::help_icon_html("noautoformat", " ");

    if ($remote) {
        # only show on initial compostion
        my $quickquote;
        unless ($opts->{errors} && @{$opts->{errors}}) {
            # quick quote button
            $quickquote = "&nbsp;&nbsp;" . LJ::ejs('<input type="button" value="Quote" onmousedown="quote();" onclick="quote();" />');
        }

        $ret .= "<script type='text/javascript' language='JavaScript'>\n<!--\n";
        $ret .= <<"QQ";

        var helped = 0; var pasted = 0;
        function quote () {
            var text = '';

            if (document.getSelection) {
                text = document.getSelection();
            } else if (document.selection) {
                text = document.selection.createRange().text;
            } else if (window.getSelection) {
                text = window.getSelection();
            }

            // Fix for Safari
            if (typeof(text) == 'object') text = text.toString();
            if (text == '') {
                if (helped != 1 && pasted != 1) {
                    helped = 1; alert("If you'd like to quote a portion of the original message, highlight it then press 'Quote'");
                }
                return false;
            } else {
                pasted = 1;
            }

            var element = text.search(/\\n/) == -1 ? 'q' : 'blockquote';
            var textarea = document.getElementById('commenttext');
            textarea.focus();
            textarea.value = textarea.value + "<" + element + ">" + text + "</" + element + ">";
            textarea.caretPos = textarea.value;
            textarea.focus();
            return false;
        }
        if (document.getElementById && (document.getSelection || document.selection || window.getSelection)) {
            // Opera clears the paste buffer before mouse events, useless here
                if (navigator.userAgent.indexOf("Opera") == -1) { document.write('$quickquote'); }
        }
QQ

        $ret .= "-->\n</script>\n";
    }

    $ret .= "</div>";
    $ret .= "</td></tr>\n";
    
    # textarea for their message body
    $ret .= "<tr valign='top'><td align='right'>$BML::ML{'.opt.message'}";
    $ret .= "</td><td style='width: 90%'>";
    $ret .= "<textarea class='textbox' rows='10' cols='75' wrap='soft' name='body' id='commenttext'>" . LJ::ehtml($form->{body}) . "</textarea>";

    # Display captcha challenge if over rate limits.
    if ($opts->{do_captcha}) {
        if (LJ::is_enabled("recaptcha")) {
            my $c = Captcha::reCAPTCHA->new;
            $ret .= $c->get_options_setter({ theme => 'white', lang => BML::get_language() });
            $ret .= $c->get_html( LJ::conf_test($LJ::RECAPTCHA{public_key}) );
        } else {
            my ($wants_audio, $captcha_sess, $captcha_chal);
            $wants_audio = 1 if lc($form->{answer}) eq 'audio';

            # Captcha sessions
            my $cid = $journalu->{clusterid};
            $captcha_chal = $form->{captcha_chal} || LJ::challenge_generate(900);
            $captcha_sess = LJ::get_challenge_attributes($captcha_chal);
            my $dbcr = LJ::get_cluster_reader($journalu);

            my $try = 0;
            if ($form->{captcha_chal}) {
                $try = $dbcr->selectrow_array('SELECT trynum FROM captcha_session ' .
                                              'WHERE sess=?', undef, $captcha_sess);
            }
            $ret .= '<br /><br />';

            # Visual challenge
            if (! $wants_audio && ! $form->{audio_chal}) {
                $ret .= "<div class='formitemDesc'>$BML::ML{'/create.bml.captcha.desc'}</div>";
                $ret .= "<img src='/captcha/image.bml?chal=$captcha_chal&amp;cid=$cid&amp;try=$try' width='175' height='35' />";
                $ret .= "<br /><br />$BML::ML{'/create.bml.captcha.answer'}";
            }
            # Audio challenge
            else {
                $ret .= "<div class='formitemDesc'>$BML::ML{'/create.bml.captcha.audiodesc'}</div>";
                $ret .= "<a href='/captcha/audio.bml?chal=$captcha_chal&amp;cid=$cid&amp;try=$try'>$BML::ML{'/create.bml.captcha.play'}</a> &nbsp; ";
                $ret .= LJ::html_hidden(audio_chal => 1);
            }
            $ret .= LJ::html_text({ name =>'answer', size =>15 });
            $ret .= LJ::html_hidden(captcha_chal => $captcha_chal);
        }
        $ret .= '<br />';
    }

    my $submit_btn = $editid ? LJ::Lang::ml('.opt.edit') : LJ::Lang::ml('.opt.submit');

    # post and preview buttons
    my $limit = LJ::CMAX_COMMENT; # javascript String.length uses characters
    $ret .= <<LOGIN;
    <br />
    <script language="JavaScript" type='text/javascript'>
        <!--
        function checkLength() {
            if (!document.getElementById) return true;
            var textbox = document.getElementById('commenttext');
            if (!textbox) return true;
            if (textbox.value.length > $limit) {
                alert('Sorry, but your comment of ' + textbox.value.length + ' characters exceeds the maximum character length of $limit.  Please try shortening it and then post again.');
                return false;
            }
            return true;
        }
        // -->
    </script>

    <input type='submit' name='submitpost' onclick='return checkLength() && sendForm("postform", "username")' value="$submit_btn" />
    &nbsp;
    <input type='submit' name='submitpreview' onclick='return checkLength() && sendForm("postform", "username")' value="$BML::ML{'talk.btn.preview'}" />
LOGIN

    if ($LJ::SPELLER) {
        $ret .= "<input type='checkbox' name='do_spellcheck' value='1' id='spellcheck' /> <label for='spellcheck'>$BML::ML{'talk.spellcheck'}</label>";
    }

    if ($journalu->{'opt_logcommentips'} eq "A") {
        $ret .= "<br />$BML::ML{'.logyourip'}";
        $ret .= LJ::help_icon_html("iplogging", " ");
    }
    if ($journalu->{'opt_logcommentips'} eq "S") {
        $ret .= "<br />$BML::ML{'.loganonip'}";
        $ret .= LJ::help_icon_html("iplogging", " ");
    }

    $ret .= LJ::html_hidden( editid => $editid );
    $ret .= "</td></tr></td></tr></table>\n";

    # Some JavaScript to help the UI out

    $ret .= "<script type='text/javascript' language='JavaScript'>\n";
    $ret .= "var usermismatchtext = \"" . LJ::ejs($BML::ML{'.usermismatch'}) . "\";\n";
    $ret .= "</script><script type='text/javascript' language='JavaScript' src='$LJ::JSPREFIX/talkpost.js'></script>";
    $ret .= "</form>\n";

    return $ret;
}

# <LJFUNC>
# name: LJ::record_anon_comment_ip
# class: web
# des: Records the IP address of an anonymous comment.
# args: journalu, jtalkid, ip
# des-journalu: User object of journal comment was posted in.
# des-jtalkid: ID of this comment.
# des-ip: IP address of the poster.
# returns: 1 for success, 0 for failure
# </LJFUNC>
sub record_anon_comment_ip {
    my ($journalu, $jtalkid, $ip) = @_;
    $journalu = LJ::want_user($journalu);
    $jtalkid += 0;
    return 0 unless LJ::isu($journalu) && $jtalkid && $ip;

    $journalu->do("INSERT INTO tempanonips (reporttime, journalid, jtalkid, ip) VALUES (UNIX_TIMESTAMP(),?,?,?)",
                  undef, $journalu->{userid}, $jtalkid, $ip);
    return 0 if $journalu->err;
    return 1;
}

# <LJFUNC>
# name: LJ::mark_comment_as_spam
# class: web
# des: Copies a comment into the global [dbtable[spamreports]] table.
# args: journalu, jtalkid
# des-journalu: User object of journal comment was posted in.
# des-jtalkid: ID of this comment.
# returns: 1 for success, 0 for failure
# </LJFUNC>
sub mark_comment_as_spam {
    my ($journalu, $jtalkid) = @_;
    $journalu = LJ::want_user($journalu);
    $jtalkid += 0;
    return 0 unless $journalu && $jtalkid;

    my $dbcr = LJ::get_cluster_def_reader($journalu);
    my $dbh = LJ::get_db_writer();

    # step 1: get info we need
    my $row = LJ::Talk::get_talk2_row($dbcr, $journalu->{userid}, $jtalkid);
    my $temp = LJ::get_talktext2($journalu, $jtalkid);
    my ($subject, $body, $posterid) = ($temp->{$jtalkid}[0], $temp->{$jtalkid}[1], $row->{posterid});
    return 0 unless ($body && $body ne '');

    # can't mark your own comments as spam.
    return 0 if $posterid && $posterid == $journalu->id;

    LJ::run_hooks('spam_comment', $journalu->userid, $row->{nodeid}, $jtalkid);

    # step 2a: if it's a suspended user, don't add, but pretend that we were successful
    if ($posterid) {
    	my $posteru = LJ::want_user($posterid);
    	return 1 if $posteru->is_suspended;
    }

    # step 2b: if it was an anonymous comment, attempt to get comment IP to make some use of the report
    my $ip;
    unless ($posterid) {
        $ip = $dbcr->selectrow_array('SELECT ip FROM tempanonips WHERE journalid=? AND jtalkid=?',
                                      undef, $journalu->{userid}, $jtalkid);
        return 0 if $dbcr->err;

        # we want to fail out if we have no IP address and this is anonymous, because otherwise
        # we have a completely useless spam report.  pretend we were successful, too.
        return 1 unless $ip;

        # we also want to log this attempt so that we can do some throttling
        my $rates = LJ::MemCache::get("spamreports:anon:$ip") || $RATE_DATAVER;
        $rates .= pack("N", time);
        LJ::MemCache::set("spamreports:anon:$ip", $rates);
    }

    # step 3: insert into spamreports
    $dbh->do('INSERT INTO spamreports (reporttime, posttime, ip, journalid, posterid, subject, body) ' .
             'VALUES (UNIX_TIMESTAMP(), UNIX_TIMESTAMP(?), ?, ?, ?, ?, ?)',
             undef, $row->{datepost}, $ip, $journalu->{userid}, $posterid, $subject, $body);
    return 0 if $dbh->err;
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::get_talk2_row
# class: web
# des: Gets a row of data from [dbtable[talk2]].
# args: dbcr, journalid, jtalkid
# des-dbcr: Database handle to read from.
# des-journalid: Journal id that comment is posted in.
# des-jtalkid: Journal talkid of comment.
# returns: Hashref of row data, or undef on error.
# </LJFUNC>
sub get_talk2_row {
    my ($dbcr, $journalid, $jtalkid) = @_;
    return $dbcr->selectrow_hashref('SELECT journalid, jtalkid, nodetype, nodeid, parenttalkid, ' .
                                    '       posterid, datepost, state ' .
                                    'FROM talk2 WHERE journalid = ? AND jtalkid = ?',
                                    undef, $journalid+0, $jtalkid+0);
}

# <LJFUNC>
# name: LJ::Talk::get_talk2_row_multi
# class: web
# des: Gets multiple rows of data from [dbtable[talk2]].
# args: items
# des-items: Array of arrayrefs; each arrayref: [ journalu, jtalkid ].
# returns: Array of hashrefs of row data, or undef on error.
# </LJFUNC>
sub get_talk2_row_multi {
    my (@items) = @_; # [ journalu, jtalkid ], ...
    croak("invalid items for get_talk2_row_multi")
        if grep { ! LJ::isu($_->[0]) || @$_ != 2 } @items;

    # what do we need to load per-journalid
    my %need    = (); # journalid => { jtalkid => 1, ... }
    my %have    = (); # journalid => { jtalkid => $row_ref, ... }
    my %cluster = (); # cid => { jid => journalu, jid => journalu }

    # first, what is in memcache?
    my @keys = ();
    foreach my $it (@items) {
        my ($journalu, $jtalkid) = @$it;

        # can't load comments in purged users' journals
        next if $journalu->is_expunged;

        my $cid = $journalu->clusterid;
        my $jid = $journalu->id;

        # we need this for now
        $need{$jid}->{$jtalkid} = 1;

        # which cluster is this user on?
        $cluster{$cid}->{$jid} = $journalu;

        push @keys, LJ::Talk::make_talk2row_memkey($jid, $jtalkid);
    }

    # return an array of rows preserving order in which they were requested
    my $ret = sub {
        my @ret = ();
        foreach my $it (@items) {
            my ($journalu, $jtalkid) = @$it;
            push @ret, $have{$journalu->id}->{$jtalkid};
        }

        return @ret;
    };

    my $mem = LJ::MemCache::get_multi(@keys);
    if ($mem) {
        while (my ($key, $array) = each %$mem) {
            my (undef, $jid, $jtalkid) = split(":", $key);
            my $row = LJ::MemCache::array_to_hash("talk2row", $array);
            next unless $row;

            # add in implicit keys:
            $row->{journalid} = $jid;
            $row->{jtalkid}   = $jtalkid;

            # update our needs
            $have{$jid}->{$jtalkid} = $row;
            delete $need{$jid}->{$jtalkid};
            delete $need{$jid} unless %{$need{$jid}}
        }

        # was everything in memcache?
        return $ret->() unless %need;
    }

    # uh oh, we have things to retrieve from the db!
  CLUSTER:
    foreach my $cid (keys %cluster) {

        # build up a valid where clause for this cluster's select
        my @vals = ();
        my @where = ();
        foreach my $journalu (values %{$cluster{$cid}}) {
            my $jid = $journalu->id;
            my @jtalkids = keys %{$need{$jid}};
            next unless @jtalkids;

            my $bind = join(",", map { "?" } @jtalkids);
            push @where, "(journalid=? AND jtalkid IN ($bind))";
            push @vals, $jid => @jtalkids;
        }
        # is there anything to actually query for this cluster?
        next CLUSTER unless @vals;

        my $dbcr = LJ::get_cluster_reader($cid)
            or die "unable to get cluster reader: $cid";

        my $where = join(" OR ", @where);
        my $sth = $dbcr->prepare
            ("SELECT journalid, jtalkid, nodetype, nodeid, parenttalkid, " .
             "       posterid, datepost, state " .
             "FROM talk2 WHERE $where");
        $sth->execute(@vals);

        while (my $row = $sth->fetchrow_hashref) {
            my $jid = $row->{journalid};
            my $jtalkid = $row->{jtalkid};

            # update our needs
            $have{$jid}->{$jtalkid} = $row;
            delete $need{$jid}->{$jtalkid};
            delete $need{$jid} unless %{$need{$jid}};

            # update memcache
            LJ::Talk::add_talk2row_memcache($jid, $jtalkid, $row);
        }
    }

    return $ret->();
}

sub make_talk2row_memkey {
    my ($jid, $jtalkid) = @_;
    return [ $jid, join(":", "talk2row", $jid, $jtalkid) ];
}

sub add_talk2row_memcache {
    my ($jid, $jtalkid, $row) = @_;

    my $memkey = LJ::Talk::make_talk2row_memkey($jid, $jtalkid);
    my $exptime = 60*30;
    my $array = LJ::MemCache::hash_to_array("talk2row", $row);

    return LJ::MemCache::add($memkey, $array, $exptime);
}

sub invalidate_comment_cache {
    my ($jid, $nodeid, @jtalkids) = @_;

    ## invalidate cache with all commments for this entry
    LJ::MemCache::delete([$jid, "talk2:$jid:L:$nodeid"]);
 
    ## and invalidate all individual caches for each comment
    foreach my $jtalkid (@jtalkids) {
        LJ::MemCache::delete([ $jid, "talk2row:$jid:$jtalkid" ]);
    }

    ## and invalidate items for "/tools/recent_comments.bml" page
    LJ::MemCache::delete([$jid, "rcntalk:$jid" ]);

    return 1;
}

# get a comment count for a journal entry.
sub get_replycount {
    my ($ju, $jitemid) = @_;
    $jitemid += 0;
    return undef unless $ju && $jitemid;

    my $memkey = [$ju->{'userid'}, "rp:$ju->{'userid'}:$jitemid"];
    my $count = LJ::MemCache::get($memkey);
    return $count if $count;

    my $dbcr = LJ::get_cluster_def_reader($ju);
    return unless $dbcr;

    $count = $dbcr->selectrow_array("SELECT replycount FROM log2 WHERE " .
                                    "journalid=? AND jitemid=?", undef,
                                    $ju->{'userid'}, $jitemid);
    LJ::MemCache::add($memkey, $count);
    return $count;
}

package LJ::Talk::Post;

use LJ::EventLogRecord::NewComment;

sub indent {
    my $a = shift;
    my $leadchar = shift || " ";
    require Text::Wrap;
    $Text::Wrap::columns = 76;
    return Text::Wrap::fill("$leadchar ", "$leadchar ", $a);
}

sub blockquote {
    my $a = shift;
    return "<blockquote style='border-left: #000040 2px solid; margin-left: 0px; margin-right: 0px; padding-left: 15px; padding-right: 0px'>$a</blockquote>";
}

sub generate_messageid {
    my ($type, $journalu, $did) = @_;
    # $type = {"entry" | "comment"}
    # $journalu = $u of journal
    # $did = display id of comment/entry

    my $jid = $journalu->{userid};
    return "<$type-$jid-$did\@$LJ::DOMAIN>";
}

sub enter_comment {
    my ($journalu, $parent, $item, $comment, $errref) = @_;

    my $partid = $parent->{talkid};
    my $itemid = $item->{itemid};

    my $err = sub {
        $$errref = join(": ", @_);
        return 0;
    };

    return $err->("Invalid user object passed.")
        unless LJ::isu($journalu);

    LJ::run_hooks('update_comment_props', $journalu, $comment);

    my $jtalkid = LJ::alloc_user_counter($journalu, "T");
    return $err->("Database Error", "Could not generate a talkid necessary to post this comment.")
        unless $jtalkid;

    # insert the comment
    my $posterid = $comment->{u} ? $comment->{u}{userid} : 0;

    my $errstr;
    $journalu->talk2_do(nodetype => "L", nodeid => $itemid, errref => \$errstr,
                        sql =>  "INSERT INTO talk2 ".
                                "(journalid, jtalkid, nodetype, nodeid, parenttalkid, posterid, datepost, state) ".
                                "VALUES (?,?,'L',?,?,?,NOW(),?)",
                        bindings => [$journalu->{userid}, $jtalkid, $itemid, $partid, $posterid, $comment->{state}],
                        flush_cache => 0, # do not flush cache with talks tree, just append a new comment.
                        );
    if ($errstr) {
        return $err->("Database Error",
            "There was an error posting your comment to the database.  " .
            "Please report this.  The error is: <b>$errstr</b>");
    }

    # append new comment to memcached tree
    {
        my $memkey = [$journalu->{'userid'}, "talk2:$journalu->{'userid'}:L:$itemid"];
        my $append = pack(LJ::Talk::PACK_FORMAT,
                        $jtalkid,
                        $partid,
                        $posterid,
                        time(),
                        ord($comment->{state}));
        my $res = LJ::MemCache::append($memkey, $append);
    }


    LJ::MemCache::incr([$journalu->{'userid'}, "talk2ct:$journalu->{'userid'}"]);

    $comment->{talkid} = $jtalkid;

    # record IP if anonymous
    LJ::Talk::record_anon_comment_ip($journalu, $comment->{talkid}, LJ::get_remote_ip())
        unless $posterid;

    # add to poster's talkleft table, or the xfer place
    if ($posterid) {
        my $table;
        my $db = LJ::get_cluster_master($comment->{u});

        if ($db) {
            # remote's cluster is writable
            $table = "talkleft";
        } else {
            # log to global cluster, another job will move it later.
            $db = LJ::get_db_writer();
            $table = "talkleft_xfp";
        }
        my $pub  = $item->{'security'} eq "public" ? 1 : 0;
        if ($db) {
            $db->do("INSERT INTO $table (userid, posttime, journalid, nodetype, ".
                    "nodeid, jtalkid, publicitem) VALUES (?, UNIX_TIMESTAMP(), ".
                    "?, 'L', ?, ?, ?)", undef,
                    $posterid, $journalu->{userid}, $itemid, $jtalkid, $pub);

        } else {
            # both primary and backup talkleft hosts down.  can't do much now.
        }

        my $poster = LJ::want_user($posterid);
        $poster->incr_num_comments_posted;
    }

    $journalu->do("INSERT INTO talktext2 (journalid, jtalkid, subject, body) ".
                  "VALUES (?, ?, ?, ?)", undef,
                  $journalu->{userid}, $jtalkid, $comment->{subject},
                  LJ::text_compress($comment->{body}));
    die $journalu->errstr if $journalu->err;

    my $memkey = "$journalu->{'clusterid'}:$journalu->{'userid'}:$jtalkid";
    LJ::MemCache::set([$journalu->{'userid'},"talksubject:$memkey"], $comment->{subject});
    LJ::MemCache::set([$journalu->{'userid'},"talkbody:$memkey"], $comment->{body});

    # dudata
    my $bytes = length($comment->{subject}) + length($comment->{body});
    # we used to do a LJ::dudata_set(..) on 'T' here, but decided
    # we could defer that.  to find size of a journal, summing
    # bytes in dudata is too slow (too many seeks)

    my %talkprop;   # propname -> value
    # meta-data
    $talkprop{'unknown8bit'} = 1 if $comment->{unknown8bit};
    $talkprop{'subjecticon'} = $comment->{subjecticon};

    $talkprop{'picture_keyword'} = $comment->{picture_keyword};

    $talkprop{'opt_preformatted'} = $comment->{preformat} ? 1 : 0;
    if ($journalu->{'opt_logcommentips'} eq "A" ||
        ($journalu->{'opt_logcommentips'} eq "S" && $comment->{usertype} ne "user"))
    {
        if (LJ::is_web_context()) {
            my $ip = BML::get_remote_ip();
            my $forwarded = BML::get_client_header('X-Forwarded-For');
            $ip = "$forwarded, via $ip" if $forwarded && $forwarded ne $ip;
            $talkprop{'poster_ip'} = $ip;
        }
    }

    # remove blank/0 values (defaults)
    foreach (keys %talkprop) { delete $talkprop{$_} unless $talkprop{$_}; }

    # update the talkprops
    LJ::load_props("talk");
    if (%talkprop) {
        my $values;
        my $hash = {};
        foreach (keys %talkprop) {
            my $p = LJ::get_prop("talk", $_);
            next unless $p;
            $hash->{$_} = $talkprop{$_};
            my $tpropid = $p->{'tpropid'};
            my $qv = $journalu->quote($talkprop{$_});
            $values .= "($journalu->{'userid'}, $jtalkid, $tpropid, $qv),";
        }
        if ($values) {
            chop $values;
            $journalu->do("INSERT INTO talkprop2 (journalid, jtalkid, tpropid, value) ".
                      "VALUES $values");
            die $journalu->errstr if $journalu->err;
        }
        LJ::MemCache::set([$journalu->{'userid'}, "talkprop:$journalu->{'userid'}:$jtalkid"], $hash);
    }

    # record up to 25 (or $LJ::TALK_MAX_URLS) urls from a comment
    my (%urls, $dbh);
    if ($LJ::TALK_MAX_URLS &&
        ( %urls = map { $_ => 1 } LJ::get_urls($comment->{body}) ) &&
        ( $dbh = LJ::get_db_writer() )) # don't log if no db available
    {
        my (@bind, @vals);
        my $ip = LJ::get_remote_ip();
        while (my ($url, undef) = each %urls) {
            push @bind, '(?,?,?,?,UNIX_TIMESTAMP(),?)';
            push @vals, $posterid, $journalu->{userid}, $ip, $jtalkid, $url;
            last if @bind >= $LJ::TALK_MAX_URLS;
        }
        my $bind = join(',', @bind);
        my $sql = qq{
            INSERT INTO commenturls
                (posterid, journalid, ip, jtalkid, timecreate, url)
            VALUES $bind
        };
        $dbh->do($sql, undef, @vals);
    }

    # update the "replycount" summary field of the log table
    if ($comment->{state} eq 'A') {
        LJ::replycount_do($journalu, $itemid, "incr");
    }

    # update the "hasscreened" property of the log item if needed
    if ($comment->{state} eq 'S') {
        LJ::set_logprop($journalu, $itemid, { 'hasscreened' => 1 });
    }

    # update the comment alter property
    LJ::Talk::update_commentalter($journalu, $itemid);

    # journals data consists of two types of data: posts and comments.
    # last post time is stored in 'userusage' table.
    # last comment add/update/delete/whateverchange time - here:
    LJ::Talk::update_journals_commentalter($journalu);

    # fire events
    unless ($LJ::DISABLED{esn}) {
        my $cmtobj = LJ::Comment->new($journalu, jtalkid => $jtalkid);
        LJ::Event::JournalNewComment->new($cmtobj)->fire;
        LJ::EventLogRecord::NewComment->new($cmtobj)->fire;
    }

    return $jtalkid;
}

sub init {
    my ($form, $remote, $need_captcha, $errret) = @_;
    my $sth = undef;
    
    my $err = sub {
        my $error = shift;
        push @$errret, $error;
        return undef;
    };
    my $bmlerr = sub {
        return $err->(LJ::Lang::ml($_[0]));
    };

    my $init = LJ::Talk::init($form);
    return $err->($init->{error}) if $init->{error};

    my $journalu = $init->{'journalu'};
    return $bmlerr->('talk.error.nojournal') unless $journalu;
    return $err->($LJ::MSG_READONLY_USER) if LJ::get_cap($journalu, "readonly");

    return $err->("Account is locked, unable to post or edit a comment.") if $journalu->{statusvis} eq 'L';

    eval {
        LJ::Request->notes("journalid" => $journalu->{'userid'});
    };

    my $dbcr = LJ::get_cluster_def_reader($journalu);
    return $bmlerr->('error.nodb') unless $dbcr;

    my $itemid = $init->{'itemid'}+0;

    my $item = LJ::Talk::get_journal_item($journalu, $itemid);

    if ($init->{'oldurl'} && $item) {
        $init->{'anum'} = $item->{'anum'};
        $init->{'ditemid'} = $init->{'itemid'}*256 + $item->{'anum'};
    }

    unless ($item && $item->{'anum'} == $init->{'anum'}) {
        return $bmlerr->('talk.error.noentry');
    }

    my $iprops = $item->{'props'};
    my $ditemid = $init->{'ditemid'}+0;

    my $entry = LJ::Entry->new($journalu, ditemid => $ditemid);
    $entry->handle_prefetched_props($iprops);

    my $talkurl = LJ::journal_base($journalu) . "/$ditemid.html";
    $init->{talkurl} = $talkurl;

    ### load users
    LJ::load_userids_multiple([
                               $item->{'posterid'} => \$init->{entryu},
                               ], [ $journalu ]);
    LJ::load_user_props($journalu, "opt_logcommentips");

    if ($form->{'userpost'} && $form->{'usertype'} ne "user") {
        unless ($form->{'usertype'} eq "cookieuser" &&
                $form->{'userpost'} eq $form->{'cookieuser'}) {
            $bmlerr->("$SC.error.confused_identity");
        }
    }

    # anonymous/cookie users cannot authenticate with ecphash
    if ($form->{'ecphash'} && $form->{'usertype'} ne "user") {
        $err->(BML::ml("$SC.error.badusername2", {'sitename' => $LJ::SITENAMESHORT, 'aopts' => "href='$LJ::SITEROOT/lostinfo.bml'"}));
        return undef;
    }

    my $cookie_auth;
    if ($form->{'usertype'} eq "cookieuser") {
        $bmlerr->("$SC.error.lostcookie")
            unless ($remote && $remote->{'user'} eq $form->{'cookieuser'});
        return undef if @$errret;

        $cookie_auth = 1;
        $form->{'userpost'} = $remote->{'user'};
        $form->{'usertype'} = "user";
    }
    # XXXevan hack:  remove me when we fix preview.
    $init->{cookie_auth} = $cookie_auth;

    # test accounts may only comment on other test accounts.
    if ((grep { $form->{'userpost'} eq $_ } @LJ::TESTACCTS) &&
        !(grep { $journalu->{'user'} eq $_ } @LJ::TESTACCTS) && !$LJ::IS_DEV_SERVER)
    {
        $bmlerr->("$SC.error.testacct");
    }

    my $userpost = lc($form->{'userpost'});
    my $up;             # user posting
    my $exptype;        # set to long if ! after username
    my $ipfixed;        # set to remote  ip if < after username
    my $used_ecp;       # ecphash was validated and used

    if ($form->{'usertype'} eq "user") {
        if ($form->{'userpost'}) {

            # parse inline login opts
            if ($form->{'userpost'} =~ s/[!<]{1,2}$//) {
                $exptype = 'long' if index($&, "!") >= 0;
                $ipfixed = LJ::get_remote_ip() if index($&, "<") >= 0;
            }

            $up = LJ::load_user($form->{'userpost'});
            if ($up) {
                ### see if the user is banned from posting here
                if (LJ::is_banned($up, $journalu)) {
                    $bmlerr->("$SC.error.banned");
                }

                # TEMP until we have better openid support
                if ($up->is_identity && $journalu->{'opt_whocanreply'} eq "reg") {
                    $bmlerr->("$SC.error.noopenid");
                }

                unless ($up->{'journaltype'} eq "P" ||
                        ($up->{'journaltype'} eq "I" && $cookie_auth)) {
                    $bmlerr->("$SC.error.postshared");
                }

                # if we're already authenticated via cookie, then userpost was set
                # to the authenticated username, so we got into this block, but we
                # don't want to re-authenticate, so just skip this
                unless ($cookie_auth) {

                    # if ecphash present, authenticate on that
                    if ($form->{'ecphash'}) {

                        if ($form->{'ecphash'} eq
                            LJ::Talk::ecphash($itemid, $form->{'parenttalkid'}, $up->password))
                        {
                            $used_ecp = 1;
                        } else {
                            $err->(BML::ml("$SC.error.badpassword2", {'aopts' => "href='$LJ::SITEROOT/lostinfo.bml'"}));
                        }

                    # otherwise authenticate on username/password
                    } else {
                        my $ok;
                        if ($form->{response}) {
                            $ok = LJ::challenge_check_login($up, $form->{chal}, $form->{response});
                        } else {
                            $ok = LJ::auth_okay($up, $form->{'password'}, $form->{'hpassword'});
                        }
                        $err->(BML::ml("$SC.error.badpassword2", {'aopts' => "href='$LJ::SITEROOT/lostinfo.bml'"})) unless $ok;
                    }
                }

                unless (@$errret) {
                    # if the user chooses to log in, do so
                    if ($form->{'do_login'}) {
                        $init->{didlogin} =
                            $up->make_login_session($exptype, $ipfixed);
                    } elsif (!$cookie_auth) {
                        # record their login session anyway
                        LJ::Session->record_login($up);
                    }
                }
            } else {
                $err->(BML::ml("$SC.error.badusername2", {'sitename' => $LJ::SITENAMESHORT, 'aopts' => "href='$LJ::SITEROOT/lostinfo.bml'"}));
            }
        } else {
            $bmlerr->("$SC.error.nousername");
        }
    }

    # OpenID
    if (LJ::OpenID->consumer_enabled && ($form->{'usertype'} eq 'openid' ||  $form->{'usertype'} eq 'openid_cookie')) {

        if ($remote && defined $remote->openid_identity) {
            $up = $remote;

            ### see if the user is banned from posting here
            $bmlerr->("$SC.error.banned") if (LJ::is_banned($up, $journalu));

            if ($form->{'oiddo_login'}) {
                $up->make_login_session($form->{'exptype'}, $form->{'ipfixed'});
            }
        } else { # First time through
            my $csr = LJ::OpenID::consumer();
            my $exptype = 'short';
            my $ipfixed = 0;
            my $etime = 0;

            # parse inline login opts
            return $err->("No OpenID identity URL entered") unless $form->{'oidurl'};
            if ($form->{'oidurl'} =~ s/[!<]{1,2}$//) {
                if (index($&, "!") >= 0) {
                    $exptype = 'long';
                    $etime = time()+60*60*24*60;
                }
                $ipfixed = LJ::get_remote_ip() if index($&, "<") >= 0;
            }

            my $tried_local_ref = LJ::OpenID::blocked_hosts($csr);

            my $claimed_id = $csr->claimed_identity($form->{'oidurl'});

            unless ($claimed_id) {
                return $err->("You can't use a $LJ::SITENAMESHORT OpenID account on $LJ::SITENAME &mdash; ".
                                 "just <a href='/login.bml'>go login</a> with your actual $LJ::SITENAMESHORT account.") if $$tried_local_ref;
                return $err->("No claimed id: ".$csr->err);
            }

            # Store their cleaned up identity url vs what they
            # actually typed in
            $form->{'oidurl'} = $claimed_id->claimed_url();

            # Store the entry
            my $pendcid = LJ::alloc_user_counter($journalu, "C");

            $err->("Unable to allocate pending id") unless $pendcid;

            # Since these were gotten from the oidurl and won't
            # persist in the form data
            $form->{'exptype'} = $exptype;
            $form->{'etime'} = $etime;
            $form->{'ipfixed'} = $ipfixed;
            my $penddata = Storable::nfreeze($form);

            $err->("Unable to get database handle to store pending comment") unless $journalu->writer;

            $journalu->do("INSERT INTO pendcomments (jid, pendcid, data, datesubmit) VALUES (?, ?, ?, UNIX_TIMESTAMP())", undef, $journalu->{'userid'}, $pendcid, $penddata);

            $err->($journalu->errstr) if $journalu->err;

            my $check_url = $claimed_id->check_url(
                                                   return_to      => "$LJ::SITEROOT/talkpost_do.bml?jid=$journalu->{'userid'}&pendcid=$pendcid",
                                                   trust_root     => "$LJ::SITEROOT",
                                                   delayed_return => 1,
                                                   );
            # Don't redirect them if errors
            return undef if @$errret;
            return BML::redirect($check_url);
        }
    }

    # validate the challenge/response value (anti-spammer)
    unless ($used_ecp) {
        my $chrp_err;
        if (my $chrp = $form->{'chrp1'}) {
            my ($c_ditemid, $c_uid, $c_time, $c_chars, $c_res) =
                split(/\-/, $chrp);
            my $chal = "$c_ditemid-$c_uid-$c_time-$c_chars";
            my $secret = LJ::get_secret($c_time);
            my $res = Digest::MD5::md5_hex($secret . $chal);
            if ($res ne $c_res) {
                $chrp_err = "invalid";
            } elsif ($c_time < time() - 2*60*60) {
                $chrp_err = "too_old" if $LJ::REQUIRE_TALKHASH_NOTOLD;
            }
        } else {
            $chrp_err = "missing";
        }
        if ($chrp_err) {
            my $ip = LJ::get_remote_ip();
            if ($LJ::DEBUG{'talkspam'}) {
                my $ruser = $remote ? $remote->{user} : "[nonuser]";
                print STDERR "talkhash error: from $ruser \@ $ip - $chrp_err - $talkurl\n";
            }
            if ($LJ::REQUIRE_TALKHASH) {
                return $err->("Sorry, form expired.  Press back, copy text, reload form, paste into new form, and re-submit.")
                    if $chrp_err eq "too_old";
                return $err->("Missing parameters");
            }
        }
    }

    # check that user can even view this post, which is required
    # to reply to it
    ####  Check security before viewing this post
    unless (LJ::can_view($up, $item)) {
        $bmlerr->("$SC.error.mustlogin") unless (defined $up);
        $bmlerr->("$SC.error.noauth");
        return undef;
    }

    # If the reply is to a comment, check that it exists.
    # if it's screened, check that the user has permission to
    # reply and unscreen it

    my $parpost;
    my $partid = $form->{'parenttalkid'}+0;

    if ($partid) {
        $parpost = LJ::Talk::get_talk2_row($dbcr, $journalu->{userid}, $partid);
        unless ($parpost) {
            $bmlerr->("$SC.error.noparent");
        }

        # can't use $remote because we may get here
        # with a reply from email. so use $up instead of $remote
        # in the call below.

        if ($parpost && $parpost->{'state'} eq "S" &&
            !LJ::Talk::can_unscreen($up, $journalu, $init->{entryu}, $init->{entryu}{'user'})) {
            $bmlerr->("$SC.error.screened");
        }
    }
    $init->{parpost} = $parpost;

    # don't allow anonymous comments on syndicated items
    if ($journalu->{'journaltype'} eq "Y" && $journalu->{'opt_whocanreply'} eq "all") {
        $journalu->{'opt_whocanreply'} = "reg";
    }

    if (($form->{'usertype'} ne "user" && $form->{'usertype'} ne 'openid' && $form->{'usertype'} ne 'openid_cookie')
        && $journalu->{'opt_whocanreply'} ne "all")
    {
        $bmlerr->("$SC.error.noanon");
    }

    unless ($entry->posting_comments_allowed) {
        $bmlerr->("$SC.error.nocomments");
    }

    if ($up) {
        if ($up->{'status'} eq "N" && $up->{'journaltype'} ne "I" && !LJ::run_hook("journal_allows_unvalidated_commenting", $journalu, $up)) {
            $err->(LJ::Lang::ml("$SC.error.noverify2", {'aopts' => "href='$LJ::SITEROOT/register.bml'"}));
        }
        if ($up->{'statusvis'} eq "D") {
            $bmlerr->("$SC.error.deleted");
        } elsif ($up->{'statusvis'} eq "S") {
            $bmlerr->("$SC.error.suspended");
        } elsif ($up->{'statusvis'} eq "X") {
            $bmlerr->("$SC.error.purged");
        }
    }

    if ($journalu->{'opt_whocanreply'} eq "friends") {
        if ($up) {
            if ($up->{'userid'} != $journalu->{'userid'}) {
                unless (LJ::is_friend($journalu, $up)) {
                    my $msg = $journalu->is_comm ? "notamember" : "notafriend";
                    $err->(BML::ml("$SC.error.$msg", {'user'=>$journalu->{'user'}}));
                }
            }
        } else {
            my $msg = $journalu->is_comm ? "membersonly" : "friendsonly";
            $err->(BML::ml("$SC.error.$msg", {'user'=>$journalu->{'user'}}));
        }
    }

    $bmlerr->("$SC.error.blankmessage") unless $form->{'body'} =~ /\S/;

    # in case this post comes directly from the user's mail client, it
    # may have an encoding field for us.
    if ($form->{'encoding'}) {
        $form->{'body'} = Unicode::MapUTF8::to_utf8({-string=>$form->{'body'}, -charset=>$form->{'encoding'}});
        $form->{'subject'} = Unicode::MapUTF8::to_utf8({-string=>$form->{'subject'}, -charset=>$form->{'encoding'}});
    }

    # unixify line-endings
    $form->{'body'} =~ s/\r\n/\n/g;

    # now check for UTF-8 correctness, it must hold

    return $err->("<?badinput?>") unless LJ::text_in($form);

    $init->{unknown8bit} = 0;
    unless (LJ::is_ascii($form->{'body'}) && LJ::is_ascii($form->{'subject'})) {
        if ($LJ::UNICODE) {
            # no need to check if they're well-formed, we did that above
        } else {
            # so rest of site can change chars to ? marks until
            # default user's encoding is set.  (legacy support)
            $init->{unknown8bit} = 1;
        }
    }

    my ($bl, $cl) = LJ::text_length($form->{'body'});
    if ($cl > LJ::CMAX_COMMENT) {
        $err->(BML::ml("$SC.error.manychars", {'current'=>$cl, 'limit'=>LJ::CMAX_COMMENT}));
    } elsif ($bl > LJ::BMAX_COMMENT) {
        $err->(BML::ml("$SC.error.manybytes", {'current'=>$bl, 'limit'=>LJ::BMAX_COMMENT}));
    }
    # the Subject can be silently shortened, no need to reject the whole comment
    $form->{'subject'} = LJ::text_trim($form->{'subject'}, 100, 100);

    my $subjecticon = "";
    if ($form->{'subjecticon'} ne "none" && $form->{'subjecticon'} ne "") {
        $subjecticon = LJ::trim(lc($form->{'subjecticon'}));
    }

    # New comment state
    my $state = 'A';
    my $screening = LJ::Talk::screening_level($journalu, int($ditemid / 256));
    if ($form->{state} =~ /^[A-Z]\z/){
        # use provided state.
        $state = $form->{state};
    } else {
        # figure out whether to post this comment screened
        if (!$form->{editid} && ($screening eq 'A' ||
            ($screening eq 'R' && ! $up) ||
            ($screening eq 'F' && !($up && LJ::is_friend($journalu, $up))))) {
            $state = 'S';
        }
        $state = 'A' if LJ::Talk::can_unscreen($up, $journalu, $init->{entryu}, $init->{entryu}{user});
    }

    if ($state eq 'A' && $screening eq 'L' && !($up && LJ::is_friend($journalu, $up))) {
        my $spam = 0;
        LJ::run_hook('spam_comment_detector', $form, \$spam);
        $state = 'S' if $spam;
    }

    my $parent = {
        state     => $parpost->{state},
        talkid    => $partid,
    };
    my $comment = {
        u               => $up,
        usertype        => $form->{'usertype'},
        subject         => $form->{'subject'},
        body            => $form->{'body'},
        unknown8bit     => $init->{unknown8bit},
        subjecticon     => $subjecticon,
        preformat       => $form->{'prop_opt_preformatted'},
        picture_keyword => $form->{'prop_picture_keyword'},
        state           => $state,
        editid          => $form->{editid},
    };

    $init->{item} = $item;
    $init->{parent} = $parent;
    $init->{comment} = $comment;

    # anti-spam captcha check
    if (ref $need_captcha eq 'SCALAR') {

        # see if they're in the second+ phases of a captcha check.
        # are they sending us a response?
        if (LJ::is_enabled("recaptcha") && $form->{recaptcha_response_field}) {
            # assume they won't pass and re-set the flag
            $$need_captcha = 1;

            my $c = Captcha::reCAPTCHA->new;
            my $result = $c->check_answer(
                LJ::conf_test($LJ::RECAPTCHA{private_key}), $ENV{'REMOTE_ADDR'},
                $form->{'recaptcha_challenge_field'}, $form->{'recaptcha_response_field'}
            );

            return $err->("Incorrect response to spam robot challenge.") unless $result->{is_valid} eq '1';
        } elsif (!LJ::is_enabled("recaptcha") && $form->{captcha_chal}) {
            # assume they won't pass and re-set the flag
            $$need_captcha = 1;

            # if they typed "audio", we don't double-check if they still need
            # a captcha (they still do), they just want an audio version.
            if (lc($form->{answer}) eq 'audio') {
                return;
            }

            my ($capid, $anum) = LJ::Captcha::session_check_code($form->{captcha_chal},
                                                                 $form->{answer}, $journalu);

            return $err->("Incorrect response to spam robot challenge.") unless $capid && $anum;
            my $expire_u = $comment->{'u'} || LJ::load_user('system');
            LJ::Captcha::expire($capid, $anum, $expire_u->{userid});

        } else {
            $$need_captcha = LJ::Talk::Post::require_captcha_test($comment->{'u'}, $journalu, $form->{body}, $ditemid);
            if ($$need_captcha) {
                return $err->("Please confirm you are a human below.");
            }
        }
    }

    return undef if @$errret;
    return $init;
}

# <LJFUNC>
# name: LJ::Talk::Post::require_captcha_test
# des: returns true if user must answer CAPTCHA (human test) before posting a comment
# args: commenter, journal, body, ditemid
# des-commenter: User object of author of comment, undef for anonymous commenter
# des-journal: User object of journal where to post comment
# des-body: Text of the comment (may be checked for spam, may be empty)
# des-ditemid: identifier of post, need for checking reply-count
# </LJFUNC>
sub require_captcha_test {
    my ($commenter, $journal, $body, $ditemid, $nowrite) = @_;

    ## allow some users (our bots) to post without captchas in any rate
    return if $commenter and 
              grep { $commenter->username eq $_ } @LJ::NO_RATE_CHECK_USERS;

    ## anonymous commenter user =
    ## not logged-in user, or OpenID without validated e-mail
    my $anon_commenter = !LJ::isu($commenter) ||
        ($commenter->identity && !$commenter->is_trusted_identity);

    ##
    ## 1. Check rate by remote user and by IP (for anonymous user)
    ##
    if ($LJ::HUMAN_CHECK{anonpost} || $LJ::HUMAN_CHECK{authpost}) {
        return 1 if !LJ::Talk::Post::check_rate($commenter, $journal, $nowrite);
    }
    if ($LJ::HUMAN_CHECK{anonpost} && $anon_commenter) {
        return 1 if LJ::sysban_check('talk_ip_test', LJ::get_remote_ip());
    }


    ##
    ## 4. Test preliminary limit on comment.
    ## We must check it before we will allow owner to pass.
    ##
    if (LJ::Talk::get_replycount($journal, int($ditemid / 256)) >= LJ::get_cap($journal, 'maxcomments-before-captcha')) {
        return 1;
    }

    ##
    ## 2. Don't show captcha to the owner of the journal, no more checks
    ##
    if (!$anon_commenter && $commenter->{userid}==$journal->{userid}) {
        return;
    }

    ##
    ## 3. Custom (journal) settings
    ##
    my $show_captcha_to = $journal->prop('opt_show_captcha_to');
    if (!$show_captcha_to || $show_captcha_to eq 'N') {
        ## no one
    } elsif ($show_captcha_to eq 'R') {
        ## anonymous
        return 1 if $anon_commenter;
    } elsif ($show_captcha_to eq 'F') {
        ## not friends
        return 1 if !LJ::is_friend($journal, $commenter);
    } elsif ($show_captcha_to eq 'A') {
        ## all
        return 1;
    }

    ##
    ## 4. Global (site) settings
    ## See if they have any tags or URLs in the comment's body
    ##
    if ($LJ::HUMAN_CHECK{'comment_html_auth'}
        || ($LJ::HUMAN_CHECK{'comment_html_anon'} && $anon_commenter))
    {
        if ($body =~ /<[a-z]/i) {
            # strip white-listed bare tags w/o attributes,
            # then see if they still have HTML.  if so, it's
            # questionable.  (can do evil spammy-like stuff w/
            # attributes and other elements)
            my $body_copy = $body;
            $body_copy =~ s/<(?:q|blockquote|b|strong|i|em|cite|sub|sup|var|del|tt|code|pre|p)>//ig;
            return 1 if $body_copy =~ /<[a-z]/i;
        }
        # multiple URLs is questionable too
        return 1 if $body =~ /\b(?:http|ftp|www)\b.+\b(?:http|ftp|www)\b/s;

        # or if they're not even using HTML
        return 1 if $body =~ /\[url/is;

        # or if it's obviously spam
        return 1 if $body =~ /\s*message\s*/is;
    }
}


# returns 1 on success.  0 on fail (with $$errref set)
sub post_comment {
    my ($entryu, $journalu, $comment, $parent, $item, $errref) = @_;

    # unscreen the parent comment if needed
    if ($parent->{state} eq 'S') {
        LJ::Talk::unscreen_comment($journalu, $item->{itemid}, $parent->{talkid});
        $parent->{state} = 'A';
    }

    # make sure they're not underage
    if ($comment->{u} && $comment->{u}->underage) {
        $$errref = $LJ::UNDERAGE_ERROR;
        return 0;
    }

    # check for duplicate entry (double submission)
    # Note:  we don't do it inside a locked section like ljprotocol.pl's postevent,
    # so it's not perfect, but it works pretty well.
    my $posterid = $comment->{u} ? $comment->{u}{userid} : 0;
    my $jtalkid;

    # check for dup ID in memcache.
    my $memkey;
    if (@LJ::MEMCACHE_SERVERS) {
        my $md5_b64 = Digest::MD5::md5_base64(
            join(":", ($comment->{body}, $comment->{subject},
                       $comment->{subjecticon}, $comment->{preformat},
                       $comment->{picture_keyword})));
        $memkey = [$journalu->{userid}, "tdup:$journalu->{userid}:$item->{itemid}-$parent->{talkid}-$posterid-$md5_b64" ];
        $jtalkid = LJ::MemCache::get($memkey);
    }

    # they don't have a duplicate...
    unless ($jtalkid) {
        # XXX do select and delete $talkprop{'picture_keyword'} if they're lying
        my $pic = LJ::get_pic_from_keyword($comment->{u}, $comment->{picture_keyword});
        delete $comment->{picture_keyword} unless $pic && $pic->{'state'} eq 'N';
        $comment->{pic} = $pic;

        # put the post in the database
        my $ditemid = $item->{itemid}*256 + $item->{anum};
        $jtalkid = enter_comment($journalu, $parent, $item, $comment, $errref);
        return 0 unless $jtalkid;

        # save its identifying characteristics to protect against duplicates.
        LJ::MemCache::set($memkey, $jtalkid+0, time()+60*10);
    }

    # the caller wants to know the comment's talkid.
    $comment->{talkid} = $jtalkid;

    # cluster tracking
    LJ::mark_user_active($comment->{u}, 'comment');

    LJ::run_hooks('new_comment', $journalu->{userid}, $item->{itemid}, $jtalkid);

    return 1;
}

# returns 1 on success.  0 on fail (with $$errref set)
sub edit_comment {
    my ($entryu, $journalu, $comment, $parent, $item, $errref) = @_;

    my $err = sub {
        $$errref = join(": ", @_);
        return 0;
    };

    my $comment_obj = LJ::Comment->new($journalu, dtalkid => $comment->{editid});

    my $remote = LJ::get_remote();
    return 0 unless $comment_obj->remote_can_edit($errref);

    my %props = (
        subjecticon => $comment->{subjecticon},
        picture_keyword => $comment->{picture_keyword},
        opt_preformatted => $comment->{preformat} ? 1 : 0,
    );

    # set most of the props together
    $comment_obj->set_props(%props);

    # set edit time separately since it needs to be a raw value
    $comment_obj->set_prop_raw( edit_time => "UNIX_TIMESTAMP()" );

    # set poster IP separately since it has special conditions
    my $opt_logcommentips = $comment_obj->journal->prop('opt_logcommentips');
    if ($opt_logcommentips eq "A" || ($opt_logcommentips eq "S" && $comment->{usertype} ne "user")) {
        $comment_obj->set_poster_ip;
    }
    
    ## Save changes if comment is screened now and it wasn't.
    ## Don't save opposite change (screened --> unscreened), because change
    ## may be caused by that edit comment form misses 'state' field.
    if ($comment_obj->state ne $comment->{state} && $comment->{state} eq 'S') {
        $comment_obj->set_state($comment->{state});
    }
    
    # set subject and body text
    $comment_obj->set_subject_and_body($comment->{subject}, $comment->{body});

    # the caller wants to know the comment's talkid.
    $comment->{talkid} = $comment_obj->jtalkid;


    # journals data consists of two types of data: posts and comments.
    # last post time is stored in 'userusage' table.
    # last comment add/update/delete/whateverchange time - here:
    LJ::Talk::update_journals_commentalter($comment_obj->journal);

    # cluster tracking
    LJ::mark_user_active($comment_obj->poster, 'comment');

    # fire events
    unless ($LJ::DISABLED{esn}) {
        LJ::Event::JournalNewComment->new($comment_obj)->fire;
        LJ::EventLogRecord::NewComment->new($comment_obj)->fire;
    }

    LJ::run_hooks('edit_comment', $journalu->{userid}, $item->{itemid}, $comment->{talkid});

    return 1;
}

# XXXevan:  this function should have its functionality migrated to talkpost.
# because of that, it's probably not worth the effort to make it not mangle $form...
sub make_preview {
    my ($talkurl, $cookie_auth, $form) = @_;
    my $ret = "";

    my $cleansubject = $form->{'subject'};
    LJ::CleanHTML::clean_subject(\$cleansubject);

    $ret .= "<?h1 $BML::ML{'/talkpost_do.bml.preview.title'} h1?><?p $BML::ML{'/talkpost_do.bml.preview'} p?><?hr?>";
    $ret .= "<div align=\"center\"><b>(<a href=\"$talkurl\">$BML::ML{'talk.commentsread'}</a>)</b></div>";

    my $event = $form->{'body'};
    my $spellcheck_html;
    # clean first; if the cleaner finds it invalid, don't spellcheck, so that we
    # can show the user the error.
    my $cleanok = LJ::CleanHTML::clean_comment(\$event, $form->{'prop_opt_preformatted'});
    if (defined($cleanok) && $LJ::SPELLER && $form->{'do_spellcheck'}) {
        my $s = new LJ::SpellCheck { 'spellcommand' => $LJ::SPELLER,
                                     'color' => '<?hotcolor?>', };
        $spellcheck_html = $s->check_html(\$event);
    }

    $ret .= "$BML::ML{'/talkpost_do.bml.preview.subject'} " . LJ::ehtml($cleansubject) . "<hr />\n";
    if ($spellcheck_html) {
        $ret .= $spellcheck_html;
        $ret .= "<p>";
    } else {
        $ret .= $event;
    }

    $ret .= "<hr />";

    # While it may seem like we need form auth for this form, the form for
    # actually composing a comment includes it.  It is then put into this
    # form about 20 lines below: foreach (keys %$form).
    $ret .= "<div style='width: 90%'><form method='post'><p>\n";
    $ret .= "<input name='subject' size='50' maxlength='100' value='" . LJ::ehtml($form->{'subject'}) . "' /><br />";
    $ret .= "<textarea class='textbox' rows='10' cols='50' wrap='soft' name='body' style='width: 100%'>";
    $ret .= LJ::ehtml($form->{'body'});
    $ret .= "</textarea></p>";

    # change mode:
    delete $form->{'submitpreview'}; $form->{'submitpost'} = 1;
    if ($cookie_auth) {
        $form->{'usertype'} = "cookieuser";
        delete $form->{'userpost'};
    }
    delete $form->{'do_spellcheck'};
    foreach (keys %$form) {
        $ret .= LJ::html_hidden($_, $form->{$_})
            unless $_ eq 'body' || $_ eq 'subject' || $_ eq 'prop_opt_preformatted';
    }

    $ret .= "<br /><input type='submit' value='$BML::ML{'/talkpost_do.bml.preview.submit'}' />\n";
    $ret .= "<input type='submit' name='submitpreview' value='$BML::ML{'talk.btn.preview'}' />\n";
    if ($LJ::SPELLER) {
        $ret .= "<input type='checkbox' name='do_spellcheck' value='1' id='spellcheck' /> <label for='spellcheck'>$BML::ML{'talk.spellcheck'}</label>";
    }
    $ret .= "<p>";
    $ret .= "$BML::ML{'/talkpost.bml.opt.noautoformat'} ".
        LJ::html_check({ 'name' => 'prop_opt_preformatted',
                         selected => $form->{'prop_opt_preformatted'} });
    $ret .= LJ::help_icon_html("noautoformat", " ");
    $ret .= "</p>";

    $ret .= "<p> <?de $BML::ML{'/talkpost.bml.allowedhtml'}: ";
    foreach (sort &LJ::CleanHTML::get_okay_comment_tags()) {
        $ret .= "&lt;$_&gt; ";
    }
    $ret .= "de?> </p>";

    $ret .= "</form></div>";
    return $ret;
}

# given a journalu and jitemid, return 1 if the entry
# is over the maximum comments allowed.
sub over_maxcomments {
    my ($journalu, $jitemid) = @_;
    $journalu = LJ::want_user($journalu);
    $jitemid += 0;
    return 0 unless $journalu && $jitemid;

    my $count = LJ::Talk::get_replycount($journalu, $jitemid);
    return ($count >= LJ::get_cap($journalu, 'maxcomments')) ? 1 : 0;
}

# more anti-spammer rate limiting.  returns 1 if rate is okay, 0 if too fast.
sub check_rate {
    my ($remote, $journalu, $nowrite) = @_;
    return 1 unless $LJ::ANTI_TALKSPAM;

    my $ip = LJ::get_remote_ip();
    my @watch = ();

    if ($remote) {
        # registered human (or human-impersonating robot)
        push @watch,
          [
            "talklog:$remote->{userid}",
            $LJ::RATE_COMMENT_AUTH || [ [ 200, 3600 ], [ 20, 60 ] ],
          ];
    } else {
        # anonymous, per IP address (robot or human)
        push @watch,
          [
            "talklog:$ip",
            $LJ::RATE_COMMENT_ANON ||
                [ [ 300, 3600 ], [ 200, 1800 ], [ 150, 900 ], [ 15, 60 ] ]
          ];

        # anonymous, per journal.
        # this particular limit is intended to combat flooders, instead
        # of the other 'spammer-centric' limits.
        push @watch,
          [
            "talklog:anonin:$journalu->{userid}",
            $LJ::RATE_COMMENT_ANON ||
                [ [ 300, 3600 ], [ 200, 1800 ], [ 150, 900 ], [ 15, 60 ] ]
          ];

        # throttle based on reports of spam
        push @watch,
          [
            "spamreports:anon:$ip",
            $LJ::SPAM_COMMENT_RATE ||
                [ [ 50, 86400], [ 10, 3600 ] ]
          ];
    }

    return LJ::RateLimit->check($remote, \@watch, $nowrite);
}

1;

