package Language::P::Toy::Value::Undef;

use strict;
use warnings;
use base qw(Language::P::Toy::Value::Scalar);

sub type { 12 }

sub clone {
    my( $self, $runtime, $level ) = @_;

    return Language::P::Toy::Value::Undef->new( $runtime );
}

sub as_string {
    my( $self, $runtime ) = @_;

    # FIXME warn
    return '';
}

sub as_integer {
    my( $self, $runtime ) = @_;

    # FIXME warn
    return 0;
}

sub as_float {
    my( $self, $runtime ) = @_;

    # FIXME warn
    return 0.0;
}

sub assign {
    my( $self, $runtime, $other ) = @_;

    Language::P::Toy::Value::Scalar::assign( $self, $runtime, $other )
        unless ref( $self ) eq ref( $other );

    # nothing to do
}

sub as_boolean_int {
    my( $self, $runtime ) = @_;

    return 0;
}

sub is_defined {
    my( $self, $runtime ) = @_;

    return 0;
}

sub vivify_scalar {
    my( $self, $runtime ) = @_;
    my $new = Language::P::Toy::Value::Reference->new
                  ( $runtime,
                    { reference => Language::P::Toy::Value::Undef->new,
                      } );
    $self->assign( $runtime, $new );

    return $self->dereference_scalar( $runtime );
}

sub vivify_array {
    my( $self, $runtime ) = @_;
    my $new = Language::P::Toy::Value::Reference->new
                  ( $runtime,
                    { reference => Language::P::Toy::Value::Array->new,
                      } );
    $self->assign( $runtime, $new );

    return $self->dereference_array( $runtime );
}

sub vivify_hash {
    my( $self, $runtime ) = @_;
    my $new = Language::P::Toy::Value::Reference->new
                  ( $runtime,
                    { reference => Language::P::Toy::Value::Hash->new,
                      } );
    $self->assign( $runtime, $new );

    return $self->dereference_hash( $runtime );
}

1;
