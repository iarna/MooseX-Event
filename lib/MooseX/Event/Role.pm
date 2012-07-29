# ABSTRACT: A Node style event Role for Moose
package MooseX::Event::Role;
use MooseX::Event ();
use Any::Moose 'Role';
use Scalar::Util qw( refaddr reftype blessed );
use Event::Wrappable ();

=attr my Str $.current_event is ro

This is the name of the current event being triggered, or undef if no event
is being triggered.

=cut

=method method metaevent( Str $event ) returns Bool

Returns true if $event is a valid event name for this class.

=cut
sub metaevent {
    my $self = shift;
    my( $event ) = @_;
    my $accessor = $self->can("event:$event");
    return defined $accessor ? $self->$accessor() : undef;
}

sub get_all_events {
    my $self = shift;
    return map {substr($_,6)} grep {/^event:/} map {$_->name} $self->meta->get_all_attributes;
}

=method method event_listeners( Str $event ) returns Array|Int

In array context, returns a list of all of the event listeners for a
particular event.  In scalar context, returns the number of listeners
registered.

=cut

sub event_listeners {
    my $self = shift;
    my( $event ) = @_;
    my $emeta = $self->metaevent($event);
    unless ( $emeta ) {
        require Carp;
        Carp::confess("Event $event does not exist");
    }
    my @listeners = values %{$emeta->listeners};
    return wantarray? @listeners : scalar @listeners;
}

# Having the first argument flatten the argument list isn't actually allowed
# in Rakudo (and possibly P6 too)

=method method on( Array[Str] *@events, CodeRef $listener ) returns CodeRef

Registers $listener as a listener on $event.  When $event is emitted all
registered listeners are executed.

If you are using L<Coro> then listeners are called in their own thread,
which makes them fully Coro safe.  There is no need to use "unblock_sub"
with MooseX::Event.

Returns the listener coderef.

=cut

sub on {
    my $self = shift;
    my $listener = pop;

    # If it's not an Event::Wrappable object, make it one.
    if ( ! blessed $listener or ! $listener->isa("Event::Wrappable") ) {
        $listener = &Event::Wrappable::event( $listener );
    }

    for my $event (@_) {
        my $emeta = $self->metaevent($event);
        unless ( $emeta ) {
            require Carp;
            Carp::confess("Event $event does not exist");
        }
        $emeta->listen( $listener );
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

    # If it's not an Event::Wrappable object, make it one.
    if ( ! blessed $listener or ! $listener->isa("Event::Wrappable") ) {
        $listener = &Event::Wrappable::event( $listener );
    }

    for my $event (@_) {
        my $emeta = $self->metaevent($event);
        unless ( $emeta ) {
            require Carp;
            Carp::confess("Event $event does not exist");
        }
        $emeta->listen_once( $listener );
    }
    return $listener;
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
sub emit {
    my $self = shift;
    my( $event, @args ) = @_;
    # The event object attributes are lazy, so if one doesn't exist yet
    # don't trigger the creation of it just to fire events into the void
    if ( reftype $self eq 'HASH' ) {
        return unless exists $self->{"event:$event"};
    }
    my $emeta = $self->metaevent($event);
    unless ( $emeta ) {
        require Carp;
        Carp::confess("Event $event does not exist");
    }
    $emeta->emit_self( @args );
}


=method method remove_all_listeners( Str $event )

Removes all listeners for $event

=cut

sub remove_all_listeners {
    my $self = shift;
    foreach ($self->get_all_events) {
        $self->metaevent($_)->stop_all_listeners;
    }
}

=method method remove_listener( Str $event, CodeRef $listener )

Removes $listener from $event

=cut

sub remove_listener {
    my $self = shift;
    my( $event, $listener ) = @_;
    my $emeta = $self->metaevent($event);
    unless ( $emeta ) {
        require Carp;
        Carp::confess("Event $event does not exist");
    }
    $emeta->stop_listener($listener);
}

1;

=pod

=head1 DESCRIPTION

This is the role that L<MooseX::Event> extends your class with.  All classes
using MooseX::Event will have these methods, attributes and events.

=head1 SEE ALSO

MooseX::Event::Role::ClassMethods
