package Language::P::Object;

use strict;
use warnings;

# tiny replacement for Class::Accessor::Fast: C::A::F uses base, which
# uses eval STRING, and most of its replacement are either XS or use
# eval STRING as well

# Since we're not going to have eval STRING, we could attempt to do the
# following for a nice speed boost due to the OO heavy nature of this
# code:
# eval {
#     use Class::XSAccessor::Compat;
#     our @ISA = ('Class::XSAccessor::Compat');
#     1
# } or do {
#     *mk_ro_accessors = sub {...};
#     *mk_wo_accessors = sub {...};
#     *mk_accessors = sub {...};
# }
# Now, that module is XS, so it's not desireable for the self-parse test
# and bootstrapping, but if we can have it, I don't see a reason why not.

sub new {
    return bless { %{$_[1] || {}} }, ref $_[0] || $_[0];
}

sub mk_ro_accessors {
    no strict 'refs';

    my $package = shift;

    foreach my $method ( @_ ) {
        *{"${package}::${method}"} = sub {
            return $_[0]->{$method};
        };
    }
}

sub mk_accessors {
    no strict 'refs';

    my $package = shift;

    foreach my $method ( @_ ) {
        *{"${package}::${method}"} = sub {
            return $_[0]->{$method} = $_[1] if @_ == 2;
            return $_[0]->{$method};
        };
    }
}

1;
