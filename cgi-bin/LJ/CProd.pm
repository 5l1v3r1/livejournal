package LJ::CProd;
# Mostly abstract base class for LiveJournal's contextual product/prodding.
# Let users know about new/old features they can use but never have.
use strict;

#################### Override:

# optionally override this:
sub applicable {
    my ($class, $u) = @_;
    # given a user object, is it applicable to advertise
    # this product ($class) to the user?
    return 1;
}

# override this:
sub render {
    my ($class, $u) = @_;
    # given a user, return HTML to promote the product ($class)
    return "Hey $u->{user}, did you know about $class?";
}



#################### Don't override.

our $typemap;
# get the typemap for the subscriptions classes (class/instance method)
sub typemap {
    return $typemap ||= LJ::Typemap->new(
        table       => 'cprodlist',
        classfield  => 'class',
        idfield     => 'cprodid',
    );
}

# returns the typeid for this module.
sub cprodid {
    my ($class_self) = @_;
    my $class = ref $class_self ? ref $class_self : $class_self;

    my $tm = $class->typemap
        or return undef;

    return $tm->class_to_typeid($class);
}

# don't override:
sub shortname {
    my $class = shift;
    $class =~ s/^LJ::CProd:://;
    return $class;
}

# returns boolean; if user has dismissed the $class tip
sub has_dismissed {
    my ($class, $u) = @_;
    # TODO: implement
    return 0;
}

sub dismiss {
    my ($class, $u) = @_;
    # TODO: implemnt
}

sub trackable_link {
    my ($class, $href, $text, $goodclick) = @_;
    Carp::croak("bogus caller, forgot param") unless defined $goodclick;
    my $link = "$LJ::SITEROOT/misc/cprod.bml?class=$class&g=$goodclick&to=" . LJ::eurl($href);
    return "<a onclick=\"this.href='" . LJ::ehtml($link) . "';\" href=\"" . LJ::ehtml($href) . "\">$text</a>";
}

sub clickthru_link {
    my ($class, $href, $text) = @_;
    $class->trackable_link($href, $text, 1);
}

sub ack_link {
    my ($class, $href, $text) = @_;
    $class->trackable_link($href, $text, 0);
}

# don't override
sub full_box_for {
    my ($class, $u, %opts) = @_;
    my $showclass = LJ::CProd->prod_to_show($u)
        or return "";
    my $content = eval { $showclass->render($u) } || LJ::ehtml($@);
    return $showclass->wrap_content($content, %opts);
}

sub prod_to_show {
    my ($class, $u) = @_;
    foreach my $prod (@LJ::CPROD_PROMOS) {
        my $class = "LJ::CProd::$prod";
        eval "use $class; 1";
        next if $@;
        next unless eval { $class->applicable($u) };
        return $class;
    }
    return;
}

sub wrap_content {
    my ($class, $content, %opts) = @_;
    my $w = delete $opts{'width'} || 300;
    my $alllink = $class->ack_link("$LJ::SITEROOT/didyouknow/", "View All");
    return qq{<div style='width: ${w}px; border: 3px solid #6699cc;'><div style='padding: 5px'>$content</div><div style='background: #abccec; padding: 4px; font-family: arial; font-size: 8pt;'><img src='http://www.lj.bradfitz.com/img/goat-hiding.png' width='30' height='31' align='absmiddle' /> What else has LJ been hiding? <span $alllink | <a href='#'>Next</a></div></div>};
}

1;
