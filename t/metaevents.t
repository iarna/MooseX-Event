use strict;
use warnings;
use Test::More tests => 12;

BEGIN {
    package TestEvent;
    use strict;
    use warnings;
    use MooseX::Event;

    has_event 'ping';

    no MooseX::Event; 
    __PACKAGE__->meta->make_immutable();
}

my $te = TestEvent->new;

my( $add, $remove, $first, $none, $emit ) = (0)x5;

$te->metaevent('ping')->on( add_listener => sub {
    my $self = shift;
    my( $listener ) = @_;
    $add ++;
});

$te->metaevent('ping')->on( remove_listener => sub {
    my $self = shift;
    my( $listener ) = @_;
    $remove ++;
});

$te->metaevent('ping')->on( first_listener => sub {
    my $self = shift;
    my( $listener ) = @_;
    $first ++;
});

$te->metaevent('ping')->on( no_listeners => sub {
    my $self = shift;
    $none ++;
});

my $ping = $te->on( ping => sub { $emit ++ } );
is( $add, 1, "new listener for ping");
is( $first, 1, "first listener for ping");
$te->emit("ping");
is( $emit, 1, "ping event fired");
$te->remove_listener( ping=>$ping );
is($remove, 1, "remove listener for ping");
is($none, 1, "no listeners left ping");

$te->emit("ping");
is( $emit, 1, "removed event didn't fire again" );

$te->once( ping => sub { $emit ++ } );
is( $add, 2, "new listener for ping");
is( $first, 2, "first listener for ping");
$te->emit("ping");
is( $emit, 2, "ping event fired");
is($remove, 2, "remove listener for ping");
is($none, 2, "no listeners left ping");
$te->emit("ping");
is( $emit, 2, "removed event didn't fire again" );
