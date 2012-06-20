# ABSTRACT: A Node style event Role for Moose
package MooseX::Event::Role;
use MooseX::Event ();
use Any::Moose 'Role';

# Stores our active listeners
has '_listeners'    => (isa=>'HashRef', is=>'ro', default=>sub{ {} });
# Stores our wrapped sub aliases, so that we can refer to any given listener
# using either the original sub, or any wrapping layer.
has '_aliases'      => (isa=>'HashRef', is=>'ro', default=>sub{ {} });

=attr my Str $.current_event is rw

This is the name of the current event being triggered, or undef if no event
is being triggered.

=cut

has 'current_event' => (isa=>'Str|Undef', is=>'rw');

=event new_listener( Str $event, CodeRef $listener )

Called when a listener is added.  $event is the name of the event being listened to, and $listener is the
listener being installed.

=cut

MooseX::Event::has_event('new_listener');

=method method event_exists( Str $event ) returns Bool

Returns true if $event is a valid event name for this class.

=cut

sub event_exists {
    my $self = shift;
    my( $event ) = @_;
    return $self->can("event:$event");
}

# Having the first argument flatten the argument list isn't actually allowed
# in Rakudo (and possibly P6 too)

=method method on( Array[Str] *@events, CodeRef $listener, ArrayRef[CodeRef] $wrappers=[] ) returns CodeRef

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
    my $wrappers = [];
    if (ref $_[-1] eq 'ARRAY') {
        $wrappers = pop;
    }
    my $listener = pop;
    my @aliases;
    my $wrapped = $listener;
    for ( reverse(@$wrappers), reverse(@MooseX::Event::listener_wrappers) ) {
        push @aliases, 0+$wrapped;
        $wrapped = $_->( $wrapped );
    }
    for my $event (@_) {
        if ( ! $self->event_exists($event) ) {
            require Carp;
            Carp::confess("Event $event does not exist");
        }
        $self->_listeners->{$event} ||= [];
        $self->_aliases->{$event} ||= {};
        if ( ! @{$self->_listeners->{$event}} and $self->can('activate_event') ) {
            $self->activate_event($event);
        }
        $self->_aliases->{$event}{0+$wrapped} = \@aliases;
        for ( @aliases ) {
            $self->_aliases->{$event}{$_} = $wrapped;
        }
        $self->emit('new_listener', $event, $wrapped);
        push @{ $self->_listeners->{$event} }, $wrapped;
    }
    return $wrapped;
}

=method method once( Str $event, CodeRef $listener ) returns CodeRef

Registers $listener as a listener on $event. Event listeners registered via
once will emit only once.

Returns the listener coderef.

=cut

sub once {
    my $self = shift;
    $self->on( @_, [sub {
        my($listener) = @_;
        my $wrapped;
        $wrapped = sub {
            my $self = shift;
            $self->remove_listener($self->current_event=>$wrapped);
            $wrapped=undef;
            goto $listener;
        };
        return $wrapped;
    }]);
}

BEGIN {

# The standard implementation of the emit method-- calls the listeners
# immediately and in the order they were defined.
    my $emit_stock = sub {
        my $self = shift;
        my( $event, @args ) = @_;
        if ( ! $self->event_exists($event) ) {
            require Carp;
            Carp::confess("Event $event does not exist");
        }
        return unless exists $self->_listeners->{$event};
        my $ce = $self->current_event;
        $self->current_event( $event );
        foreach ( @{ $self->_listeners->{$event} } ) {
            $_->($self,@args);
        }
        $self->current_event($ce);
        return;
    };

# The L<Coro> implementation of the emit method-- calls each of the listeners
# in its own thread.
    my $emit_coro = sub {
        my $self = shift;
        my( $event, @args ) = @_;
        if ( ! $self->event_exists($event) ) {
            require Carp;
            Carp::confess("Event $event does not exist");
        }
        return unless exists $self->_listeners->{$event};

        foreach my $todo ( @{ $self->_listeners->{$event} } ) {
            my $ce;
            &Coro::async_pool( sub {
                &Coro::on_enter( sub {
                    $ce  = $self->current_event;
                    $self->current_event($event);
                });
                $todo->(@_);
                &Coro::on_leave( sub {
                    $self->current_event($ce);
                });
            }, $self, @args );
        }

        return;
    };

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

    sub emit {
        no warnings 'redefine';
        if ( defined *Coro::async_pool{CODE} ) {
            *emit = $emit_coro;
            goto $emit_coro;
        }
        else {
            *emit = $emit_stock;
            goto $emit_stock;
        }
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
        delete $self->_aliases->{$event};
        if ( $self->can('deactivate_event') ) {
            $self->deactivate_event($event);
        }
    }
    else {
        if ( $self->can('deactivate_event') ) {
            for ( keys %{$self->_listeners} ) {
                $self->deactivate_event($_);
            }
        }
        %{ $self->_listeners } = ();
        %{ $self->_aliases } = ();
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
    return unless exists $self->_listeners->{$event};
    
    my $aliases = $self->_aliases->{$event}{0+$listener};
    delete $self->_aliases->{$event}{0+$listener};
    
    if ( ref $aliases eq "ARRAY" ) {
        for ( @$aliases ) {
            delete $self->_aliases->{$event}{$_};
        }
    }
    else {
        $listener = $aliases;
    }

    $self->_listeners->{$event} =
        [ grep { $_ != $listener } @{ $self->_listeners->{$event} } ];
        
    if ( ! @{$self->_listeners->{$event}} and $self->can('deactivate_event') ) {
        $self->deactivate_event($event);
    }
}

1;

=pod

=head1 DESCRIPTION

This is the role that L<MooseX::Event> extends your class with.  All classes
using MooseX::Event will have these methods, attributes and events.

=head1 SEE ALSO

MooseX::Event::Role::ClassMethods
