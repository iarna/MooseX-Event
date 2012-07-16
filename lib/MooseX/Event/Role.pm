# ABSTRACT: A Node style event Role for Moose
package MooseX::Event::Role;
use MooseX::Event ();
use Any::Moose 'Role';
use Scalar::Util qw( refaddr blessed );
use Event::Wrappable ();

# Stores our active listeners
has '_listeners'    => (isa=>'HashRef', is=>'ro', default=>sub{ {} });

my %events;

=attr my Str $.current_event is ro

This is the name of the current event being triggered, or undef if no event
is being triggered.

=cut

=event new_listener( Str $event, CodeRef $listener )

Called when a listener is added.  $event is the name of the event being listened to, and $listener is the
listener being installed.

=cut

MooseX::Event::has_event('new_listener');

=event first_listener( Str $event, CodeRef $listener )

Called when a listener is added and no listeners were yet registered for this event.

=cut

MooseX::Event::has_event('first_listener');

=event no_listeners( Str $event )

Called when a listener is removed and there are no more listeners registered
for this event.  This will fire prior to new_listener.

=cut

MooseX::Event::has_event('no_listeners');

=method method event_exists( Str $event ) returns Bool

Returns true if $event is a valid event name for this class.

=cut

sub event_exists {
    my $self = shift;
    my( $event ) = @_;
    return $self->can("event:$event");
}

=method method event_listeners( Str $event ) returns Array|Int

In array context, returns a list of all of the event listeners for a
particular event.  In scalar context, returns the number of listeners
registered.

=cut

sub event_listeners {
    my $self = shift;
    my($event) = @_;
    if ( ! $self->event_exists($event) ) {
        require Carp;
        Carp::confess("Event $event does not exist");
    }
    my @listeners;
    if (exists $self->_listeners->{$event}) {
        @listeners = $self->_listeners->{$event};
    }
    return wantarray? @listeners : scalar @listeners;
}

# Having the first argument flatten the argument list isn't actually allowed
# in Rakudo (and possibly P6 too)

=method method on( Array[Str] *@events, CodeRef $listener ) returns CodeRef

Registers $listener as a listener on $event.  When $event is emitted all
registered listeners are executed.  If $wrappers are passed then each is
called in turn to wrap $listener in another CodeRef.  The CodeRefs in
wrappers are expected to take a listener as an argument and return a wrapped
listener.  This is how "once" is implemented-- it wraps the listener in a
CodeRef that unregisters the listener when it's called, before passing
control to the listener.

If you are using L<Coro> then listeners are called in their own thread,
which makes them fully Coro safe.  There is no need to use "unblock_sub"
with MooseX::Event.

Returns the listener coderef.

=cut

sub on {
    my $self = shift;
    my $listener = pop;
    my $first_event = $_[0];

    # If it's not an Event::Wrappable object, make it one.
    if ( ! blessed $listener or ! $listener->isa("Event::Wrappable") ) {
        $listener = &Event::Wrappable::event( $listener );
    }

    for my $event (@_) {
        if ( ! $self->event_exists($event) ) {
            require Carp;
            Carp::confess("Event $event does not exist");
        }
        if ( ! $self->event_listeners($event) and $self->event_listeners('first_listener') ) {
            $self->emit('first_listener', $event, $listener )
        }
        $self->_listeners->{$event} ||= [];
        if ( $self->event_listeners('new_listener') ) {
            $self->emit('new_listener', $event, $listener);
        }
        push @{ $self->_listeners->{$event} }, $listener;
    }
    return $listener;
}

=method method once( Str $event, CodeRef $listener ) returns CodeRef

Registers $listener as a listener on $event. Event listeners registered via
once will emit only once.

Returns the listener coderef.

=cut

sub once {
    my $self = shift;
    my $listener = pop;
    my @events = @_;
    my $wrapped;
    Event::Wrappable->wrap_events( sub {
       $wrapped = $self->on( @events, $listener);
    }, sub {
        my( $listener ) = @_;
        return sub {
            my($self) = @_; # No shift, we don't want to change our arg list
            $self->remove_listener($self->current_event=>$wrapped);
            goto $listener;
        };
    } );
    return $wrapped;
}

BEGIN {
    # What we're doing here is building up a separate set of methods for
    # with coroutines and without.

    # The first time you call one of these methods, we check to see if
    # coroutines are loaded and from that point forward only use the
    # version appropriate to that.  The other versions should then be
    # garbage collected.

    my %alternatives;

    {
        my @events;
        $alternatives{'stock'} = {
            "push_event_name" => sub {
                push @events, @_;
            },
            "pop_event_name" => sub {
                pop @events;
            },
            "current_event" => sub {
                my $self = shift;
                return $events[0];
            },
            "emit" => sub {
                my $self = shift;
                my( $event, @args ) = @_;
                if ( ! $self->event_exists($event) ) {
                    require Carp;
                    Carp::confess("Event $event does not exist");
                }
                return unless exists $self->_listeners->{$event};
                push_event_name($event);
                foreach ( @{ $self->_listeners->{$event} } ) {
                    $_->($self,@args) if defined $_;
                }
                pop_event_name();
                return;
            },
        };
    }

    {
        my %events;
        $alternatives{'coro'} = {
            "push_event_name" => sub {
                push @{$events{refaddr $Coro::current}}, @_;
            },
            "pop_event_name" => sub {
                pop @{$events{refaddr $Coro::current}};
            },
            "current_event" => sub {
                my $self = shift;
                my $coro = refaddr $Coro::current;
                $events{$coro} ||= [];
                return $events{$coro}->[0];
            },
            "emit" => sub {
                my $self = shift;
                my( $event, @args ) = @_;
                if ( ! $self->event_exists($event) ) {
                    require Carp;
                    Carp::confess("Event $event does not exist");
                }
                return unless exists $self->_listeners->{$event};

                foreach my $todo ( @{ $self->_listeners->{$event} } ) {
                    &Coro::async_pool( sub {
                        push_event_name($event);
                        $todo->($self,@args) if defined $todo;
                        pop_event_name();
                    });
                }

                return;
            },
        };
    }

=method method emit( Str $event, *@args )

Normally called within the class using the MooseX::Event role.  This calls all
of the registered listeners on $event with @args.

If you're using L<Coro> then each listener is executed in its own thread.
Emit will return immediately, the event listeners won't execute until you
cede or block in some manner.  Normally this isn't something you have to
think about.

This means that MooseX::Event's listeners are Coro safe and can safely cede
or do other Coro thread related tasks.  That is to say, you don't ever need
to use unblock_sub.

=cut

    my $use_coro_or_not = sub {
        no warnings 'redefine';
        my $sub = shift;
        my $which;

        if ( defined $Coro::current ) {
            $which = $alternatives{'coro'};
        }
        else {
            $which = $alternatives{'stock'};
        }
        my $class = ref $_[0];
        no strict 'refs';
        # This is a role, so we want to modify both our role and the class
        # we're used in directly.
        *{$class.'::push_event_name'} = $which->{'push_event_name'};
        *{$class.'::pop_event_name'}  = $which->{'pop_event_name'};
        *{$class.'::emit'}            = $which->{'emit'};
        *{$class.'::current_event'}   = $which->{'current_event'};
        return $which->{$sub};
    };

    sub push_event_name {
        goto $use_coro_or_not->( "push_event_name", @_ );
    }

    sub pop_event_name {
        goto $use_coro_or_not->( "pop_event_name", @_ );
    }

    sub emit {
        goto $use_coro_or_not->( "emit", @_ );
    };

    sub current_event {
        goto $use_coro_or_not->( "current_event", @_ );
    }

}

=method method remove_all_listeners( Str $event )

Removes all listeners for $event

=cut

sub remove_all_listeners {
    my $self = shift;
    if ( @_ ) {
        my( $event ) = @_;
        delete $self->_listeners->{$event};
        if ( $self->event_listeners('no_listeners') ) {
            $self->emit('no_listeners', $event )
        }
    }
    else {
        if ( $self->event_listeners('no_listeners') ) {
            for ( keys %{$self->_listeners} ) {
                $self->emit('no_listeners', $_ )
            }
        }
        %{ $self->_listeners } = ();
    }
}

=method method remove_listener( Str $event, CodeRef $listener )

Removes $listener from $event

=cut

sub remove_listener {
    my $self = shift;
    my( $event, $listener ) = @_;
    if ( ! $self->event_exists($event) ) {
        require Carp;
        Carp::confess("Event $event does not exist");
    }
    my $listeners = $self->_listeners;

    return unless exists $listeners->{$event};

    my $oid = $listener->object_id;
    $listeners->{$event} =
        [ grep { defined $_ and $_->object_id) != $oid } @{ $listeners->{$event} } ];

    if ( ! $self->event_listeners($event) and $self->event_listeners('no_listeners') ) {
        $self->emit('no_listeners', $event )
    }
}

=method DEMOLISH
We clean up after ourselves by clearing out all listeners prior to shutting down.
=cut
sub DEMOLISH {
    my $self = shift;
    $self->remove_all_listeners();
    # If Coro is loaded, immediately cede to ensure that any events triggered
    # by removing listeners are executed before the object is destroyed
    if ( defined *Coro::cede{CODE} ) {
        Coro::cede();
    }
}

1;

=pod

=head1 DESCRIPTION

This is the role that L<MooseX::Event> extends your class with.  All classes
using MooseX::Event will have these methods, attributes and events.

=head1 SEE ALSO

MooseX::Event::Role::ClassMethods
