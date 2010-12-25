package Language::P::Intermediate::Transform;

use strict;
use warnings;
use parent qw(Language::P::Object);

__PACKAGE__->mk_accessors( qw(_temporary_count _current_basic_block
                              _converting _queue _stack _converted _current
                              _converted_segments _bytecode _phi) );

use Language::P::Constants qw(:all);
use Language::P::Opcodes qw(:all);
use Language::P::Assembly qw(:all);

my %op_map =
  ( OP_MAKE_LIST()        => '_make_list_array',
    OP_MAKE_ARRAY()       => '_make_list_array',
    OP_POP()              => '_pop',
    OP_SWAP()             => '_swap',
    OP_DUP()              => '_dup',
    OP_DISCARD_STACK()    => '_discard',
    OP_CONSTANT_SUB()     => '_const_sub',
    OP_CONSTANT_REGEX()   => '_const_regex',
    OP_JUMP_IF_TRUE()     => '_cond_jump',
    OP_JUMP_IF_FALSE()    => '_cond_jump',
    OP_JUMP_IF_NULL()     => '_cond_jump',
    OP_JUMP_IF_F_GT()     => '_cond_jump',
    OP_JUMP_IF_F_GE()     => '_cond_jump',
    OP_JUMP_IF_F_EQ()     => '_cond_jump',
    OP_JUMP_IF_F_NE()     => '_cond_jump',
    OP_JUMP_IF_F_LE()     => '_cond_jump',
    OP_JUMP_IF_F_LT()     => '_cond_jump',
    OP_JUMP_IF_S_GT()     => '_cond_jump',
    OP_JUMP_IF_S_GE()     => '_cond_jump',
    OP_JUMP_IF_S_EQ()     => '_cond_jump',
    OP_JUMP_IF_S_NE()     => '_cond_jump',
    OP_JUMP_IF_S_LE()     => '_cond_jump',
    OP_JUMP_IF_S_LT()     => '_cond_jump',
    OP_JUMP()             => '_jump',
    OP_REPLACE()          => '_replace',
    OP_RX_START_GROUP()   => '_rx_start_group',
    OP_RX_QUANTIFIER()    => '_rx_quantifier',
    OP_RX_TRY()           => '_rx_try',
    OP_RX_BACKTRACK()     => '_rx_backtrack',
    );

sub _local_name { ++$_[0]->{_temporary_count} }

sub new {
    my( $class, $args ) = @_;
    my $self = $class->SUPER::new( $args );

    $self->_temporary_count( 0 );

    return $self;
}

# determine the slot type for the result value of an opcode
sub _slot_type {
    my( $sub, $op ) = @_;
    my $opn = $op->{opcode_n};

    if(    $opn == OP_GLOB_SLOT
        || $opn == OP_GLOBAL
        || $opn == OP_TEMPORARY
        || $opn == OP_GET ) {
        my $slot = $op->slot;
        die "Undefined slot for $opn" unless $slot;

        # for now, make no difference between scalars and globs
        return VALUE_SCALAR if $slot == VALUE_GLOB;
        # stashes really are just hashes
        return VALUE_HASH if $slot == VALUE_STASH;

        return $slot;
    }
    if(    $opn == OP_LEXICAL
        || $opn == OP_LEXICAL_PAD ) {
        my $index = $op->index;
        my $slot;

        if( $opn == OP_LEXICAL ) {
            $slot = $sub->lexicals->{lex_idx}[$index]->{sigil};
        } else {
            $slot = $sub->lexicals->{pad_idx}[$index]->{sigil};
        }

        die "Undefined slot for $opn" unless $slot;

        # for now, make no difference between scalars and globs
        return VALUE_SCALAR if $slot == VALUE_GLOB;
        # stashes really are just hashes
        return VALUE_HASH if $slot == VALUE_STASH;

        return $slot;
    }
    if(    $opn == OP_DEREFERENCE_ARRAY
        || $opn == OP_MAKE_ARRAY
        || $opn == OP_MAKE_LIST
        || $opn == OP_VIVIFY_ARRAY ) {
        # for now, make no difference between lists and arrays
        return VALUE_ARRAY;
    }
    if(    $opn == OP_DEREFERENCE_HASH
        || $opn == OP_VIVIFY_HASH ) {
        return VALUE_HASH;
    }
    if(    $opn == OP_CONSTANT_SUB
        || $opn == OP_DEREFERENCE_SUB
        || $opn == OP_FIND_METHOD ) {
        return VALUE_SUB;
    }
    if( $opn == OP_PHI ) {
        my $params = $op->parameters;
        my $slot = $params->[2];
        die "Undefined slot for OP_PHI" unless $slot;

        # unify the values coming from the different basic blocks
        for( my $i = 5; $i <= $#$params; $i += 3 ) {
            $slot = _unify_slot_types( $slot, $params->[$i] );
        }

        return $slot;
    }

    # these are never transmitted across blocks (not unless codegen changes)
    if(    $opn == OP_CONSTANT_REGEX
        || $opn == OP_ITERATOR ) {
        die "Should not happen";
    }

    # defaul to a scalar value
    return VALUE_SCALAR;
}

# determine the common supertype of two slot types
sub _unify_slot_types {
    my( $a, $b ) = @_;

    ( $a, $b ) = ( $b, $a ) if $b == VALUE_SCALAR;

    if( $a == VALUE_SCALAR ) {
        if(    $b == VALUE_SCALAR
            || $b == VALUE_ARRAY
            || $b == VALUE_HASH ) {
            return VALUE_SCALAR;
        }

        die "Unable to unify";
    }

    if( $a != $b ) {
        die "Unable to unify";
    }

    return $a;
}

sub _add_bytecode {
    my( $self, @bytecode ) = @_;

    push @{$self->_bytecode}, @bytecode;
}

sub _opcode_set {
    my( $self, $index, $arg, $slot ) = @_;

    my $op = opcode_np( OP_SET, $arg->{pos}, $arg );
    $op->set_index( $index );
    $op->set_slot( $slot || _slot_type( $self->_current, $arg ) );

    return $op;
}

sub all_to_tree {
    my( $self, $code_segments ) = @_;
    my $all_ssa = $self->all_to_ssa( $code_segments );

    _ssa_to_tree( $self, $_ ) foreach @$all_ssa;

    return $all_ssa;
}

sub all_to_ssa {
    my( $self, $code_segments ) = @_;

    $self->_converted_segments( {} );
    my @converted = map    $self->_converted_segments->{$_}
                        || $self->to_ssa( $_ ), @$code_segments;
    $self->_converted_segments( {} );

    return \@converted;
}

sub to_ssa {
    my( $self, $code_segment ) = @_;

    $self->_temporary_count( 0 );
    $self->_stack( [] );
    $self->_converted( {} );
    $self->_phi( [] );

    my $new_code = Language::P::Intermediate::Code->new
                       ( { type           => $code_segment->type,
                           name           => $code_segment->name,
                           basic_blocks   => [],
                           lexicals       => $code_segment->lexicals,
                           scopes         => [],
                           lexical_states => $code_segment->lexical_states,
                           regex_string   => $code_segment->regex_string,
                           } );
    $self->_converted_segments->{$code_segment} = $new_code;

    foreach my $inner ( @{$code_segment->inner} ) {
        next unless $inner;
        my $new_inner = $self->to_ssa( $inner );
        $new_inner->{outer} = $new_code;
        push @{$new_code->inner}, $new_inner;
    }

    $self->_current( $new_code );
    $code_segment->find_alive_blocks;

    # find all non-empty blocks without predecessors and enqueue them
    # (there can be more than one only if there is dead code or eval blocks)
    $self->_queue( [] );
    foreach my $block ( @{$code_segment->basic_blocks} ) {
        next unless @{$block->bytecode};
        next if $block->dead || @{$block->predecessors};
        push @{$self->_queue}, $block;
    }

    my $stack = $self->_stack;
    while( @{$self->_queue} ) {
        my $block = shift @{$self->_queue};

        next if $self->_converted->{$block}{converted};
        $self->_converted->{$block} =
          { %{$self->_converted->{$block}},
            converted => 1,
            created   => 0,
            };
        $self->_converting( $self->_converted->{$block} );
        my $cblock = $self->_converting->{block} ||=
            Language::P::Intermediate::BasicBlock
                ->new_from_label( $block->start_label,
                                  $block->lexical_state,
                                  $block->scope, $block->dead );

        push @{$new_code->basic_blocks}, $cblock;
        $self->_current_basic_block( $cblock );
        $self->_bytecode( $cblock->bytecode );
        @$stack = @{$self->_converting->{in_stack} || []};

        # duplicated below
        foreach my $bc ( @{$block->bytecode} ) {
            next if $bc->{label};
            my $meth = $op_map{$bc->{opcode_n}} || '_generic';

            $self->$meth( $bc );
        }

        _add_bytecode $self,
            grep $_->{opcode_n} != OP_PHI && $_->{opcode_n} != OP_GET, @$stack;
    }

    # convert block exit bytecode
    foreach my $scope ( @{$code_segment->scopes} ) {
         push @{$new_code->scopes},
             { outer         => $scope->{outer},
               bytecode      => [],
               id            => $scope->{id},
               flags         => $scope->{flags},
               context       => $scope->{context},
               pos_s         => $scope->{pos_s},
               pos_e         => $scope->{pos_e},
               lexical_state => $scope->{lexical_state},
               exception     => $scope->{exception} ? $self->_converted->{$scope->{exception}}{block} : undef,
               };

       foreach my $seg ( @{$scope->{bytecode}} ) {
            my @bytecode;
            @$stack = ();
            $self->_bytecode( \@bytecode );

            # duplicated above
            foreach my $bc ( @$seg ) {
                next if $bc->{label};
                my $meth = $op_map{$bc->{opcode_n}} || '_generic';

                $self->$meth( $bc );
            }

            _add_bytecode $self,
                grep $_->{opcode_n} != OP_PHI && $_->{opcode_n} != OP_GET, @$stack;

            push @{$new_code->scopes->[-1]{bytecode}}, \@bytecode;
        }
    }

    # remove dummy phi values that all get the same value; doing this here
    # will create some useless set/get pairs, but it is good enough for now
    foreach my $phi ( @{$self->_phi} ) {
        next if $phi->{opcode_n} == OP_GET;
        my $index = $phi->{parameters}[1];
        my $slot = $phi->{parameters}[2];
        my $same = 1;
        for( my $i = 4; $same && $i < @{$phi->{parameters}}; $i += 3 ) {
            $same &&= $phi->{parameters}[$i] == $index;
        }
        if( $same ) {
            # morph the PHI opcode into a GET
            $phi->{opcode_n} = OP_GET;
            $phi->{attributes} = { index => $index, slot => $slot };
            $phi->{parameters} = undef;
        }
    }

    return $new_code;
}

sub to_tree {
    my( $self, $code_segment ) = @_;
    my $ssa = $self->to_ssa( $code_segment );

    return _ssa_to_tree( $self, $ssa );
}

sub _ssa_to_tree {
    my( $self, $ssa ) = @_;

    $self->_current( $ssa );
    $self->_temporary_count( 0 );

    foreach my $block ( @{$ssa->basic_blocks} ) {
        my $op_off = 0;
        while( $op_off <= $#{$block->bytecode} ) {
            my $op = $block->bytecode->[$op_off];
            ++$op_off;
            next if    $op->{label}
                    || $op->{opcode_n} != OP_SET
                    || $op->parameters->[0]->{opcode_n} != OP_PHI;

            my $parameters = $op->parameters->[0]->parameters;
            my $result_slot = _slot_type( $self->_current, $op->parameters->[0] );

            for( my $i = 0; $i < @$parameters; $i += 3 ) {
                my( $label, $variable, $slot ) = @{$parameters}[ $i, $i + 1, $i + 2];
                my( $block_from ) = grep $_ eq $label,
                                         @{$ssa->basic_blocks};
                my $op_from_off = $#{$block_from->bytecode};

                # find the jump coming to this block
                while( $op_from_off >= 0 ) {
                    my $op_from = $block_from->bytecode->[$op_from_off];
                    last if    $op_from->{attributes} # TODO is_jump
                            && exists $op_from->{attributes}{to}
                            && $op_from->{attributes}{to} eq $block;
                    --$op_from_off;
                }

                die "Can't find jump: ", $block_from->start_label,
                    " => ", $block->start_label
                    if $op_from_off < 0;

                # add SET nodes to rename the variables
                splice @{$block_from->bytecode}, $op_from_off, 0,
                       _opcode_set( $self, $op->index,
                                    opcode_npm( OP_GET, $op->{pos},
                                                index => $variable,
                                                slot  => $slot ),
                                    $result_slot )
                    if $op->index != $variable;
            }

            --$op_off;
            splice @{$block->bytecode}, $op_off, 1;
        }
    }

    return $ssa;
}

sub _get_stack {
    my( $self, $count, $force_get ) = @_;
    return unless $count;
    my @values = splice @{$self->_stack}, -$count;
    _created( $self, -$count );

    foreach my $value ( @values ) {
        next if $value->{opcode_n} != OP_PHI && !$force_get;
        my $name = _local_name( $self );
        my $slot = _slot_type( $self->_current, $value );
        _add_bytecode $self, _opcode_set( $self, $name, $value, $slot );
        $value = opcode_npm( OP_GET, $value->{pos},
                             index => $name,
                             slot  => $slot );
    }

    return @values;
}

sub _jump_to {
    my( $self, $op, $to, $out_names ) = @_;

    my $stack = $self->_stack;
    my $converted_blocks = $self->_converted;
    my $converted = $converted_blocks->{$to} ||= {};

    # check that input stack height is the same on all in branches
    if( defined $converted->{depth} ) {
        die sprintf "Inconsistent depth %d != %d in %s => %s",
            $converted->{depth}, scalar @$stack,
            $self->_current_basic_block->start_label, $to->start_label
            if $converted->{depth} != scalar @$stack;
    }

    # emit as OP_SET all stack elements created in the basic block
    # and construct the input stack of the next basic block
    if( @$stack ) {
        @$out_names = _emit_out_stack( $self ) unless @$out_names;

        # copy inherited elements, generated GET or PHI for created elements
        if( !$converted->{in_stack} ) {
            if( @{$to->predecessors} > 1 ) {
                $converted->{in_stack} = [ map opcode_n( OP_PHI ), @$stack ];
                push @{$self->_phi}, @{$converted->{in_stack}};
            } else {
                $converted->{in_stack} = [ map opcode_nm( OP_GET,
                                                          index => $_->[0],
                                                          slot  => $_->[1] ),
                                               @$out_names ];
            }
        }

        # update PHI nodes with the (block, value) pair
        if( @{$to->predecessors} > 1 ) {
            my $i = 0;
            foreach my $out ( @$out_names ) {
                die "Node with multiple predecessors has no phi ($i)"
                    unless $converted->{in_stack}[$i]->{opcode_n} == OP_PHI;
                push @{$converted->{in_stack}[$i]{parameters}},
                     $self->_current_basic_block, $out->[0], $out->[1];
                ++$i;
            }
        }
    }

    $converted->{depth} = @$stack;
    $converted->{block} ||= Language::P::Intermediate::BasicBlock
                                ->new_from_label( $to->start_label,
                                                  $to->lexical_state,
                                                  $to->scope, $to->dead );
    $op->set_to( $converted->{block} );
    push @{$self->_queue}, $to;

    return $out_names;
}

sub _emit_out_stack {
    my( $self ) = @_;
    my $stack = $self->_stack;
    return unless @$stack;

    # add named targets for all trees in stack, emit
    # them and replace stack with the targets
    my( @out_names, @out_stack );
    my $i = @$stack - $self->_converting->{created};

    die sprintf 'Inconsistent stack count in %s: %d elements in stack < %d elements created',
                $self->_current_basic_block->start_label,
                scalar( @$stack ), $self->_converting->{created}
        if scalar( @$stack ) < $self->_converting->{created};

    # copy inherited stack elements and all created GET opcodes add a
    # SET in the block and a GET in the out stack for all other
    # created ops
    @out_stack = @{$stack}[0 .. $i - 1];
    for( my $j = 0; $j < $i; ++$j ) {
        my $op = $stack->[$j];
        if( $op->{opcode_n} == OP_GET ) {
            push @out_names, [ $op->index, $op->slot ];
        } else {
            my $index = _local_name( $self );
            my $slot = _slot_type( $self->_current, $op );
            push @out_names, [ $index, $slot ];
            _add_bytecode $self, _opcode_set( $self, $index, $op, $slot );
        }
    }
    for( my $j = $i; $i < @$stack; ++$i, ++$j ) {
        my $op = $stack->[$i];
        if( $op->{opcode_n} == OP_GET ) {
            $out_names[$j] = [ $op->index, _slot_type( $self->_current, $op ) ];
            $out_stack[$i] = $op;
        } else {
            my $index = _local_name( $self );
            my $slot = _slot_type( $self->_current, $op );
            $out_names[$j] = [ $index, $slot ];
            $out_stack[$i] = opcode_npm( OP_GET, $op->{pos},
                                         index => $index,
                                         slot  => $slot );
            _add_bytecode $self, _opcode_set( $self, $index, $op, $slot );
        }
    }
    @$stack = @out_stack;

    return @out_names;
}

sub _generic {
    my( $self, $op ) = @_;
    my $attrs = $OP_ATTRIBUTES{$op->{opcode_n}};
    my $in_args = ( $attrs->{flags} & Language::P::Opcodes::FLAG_VARIADIC ) ?
                      $op->{attributes}{arg_count} : $attrs->{in_args};
    my @in = $in_args ? _get_stack( $self, $in_args ) : ();
    my $new_op;

    if( $op->{attributes} ) { # TODO clone
        $new_op = opcode_nm( $op->{opcode_n}, %{$op->{attributes}} );
        $new_op->set_parameters( \@in ) if @in;
    } elsif( $op->parameters ) {
        die "Can't handle fixed and dynamic parameters for $NUMBER_TO_NAME{$op->{opcode_n}}" if @in;
        $new_op = opcode_n( $op->{opcode_n}, @{$op->parameters} );
    } else {
        $new_op = opcode_n( $op->{opcode_n}, @in );
    }
    $new_op->{pos} = $op->{pos} if $op->{pos};

    if( !$attrs->{out_args} ) {
        _emit_out_stack( $self );
        _add_bytecode $self, $new_op;
    } elsif( $attrs->{out_args} == 1 ) {
        push @{$self->_stack}, $new_op;
        _created( $self, 1 );
    } else {
        die "Unhandled out_args value: ", $attrs->{out_args};
    }
}

sub _const_sub {
    my( $self, $op ) = @_;
    my $new_seg = $self->_converted_segments->{$op->value};
    my $new_op = opcode_nm( OP_CONSTANT_SUB, value => $new_seg );

    push @{$self->_stack}, $new_op;
    _created( $self, 1 );
}

sub _const_regex {
    my( $self, $op ) = @_;
    my $new_seg = $self->_converted_segments->{$op->value};
    my $new_op = opcode_nm( OP_CONSTANT_REGEX, value => $new_seg );

    push @{$self->_stack}, $new_op;
    _created( $self, 1 );
}

sub _discard {
    my( $self, undef ) = @_;

    while( @{$self->_stack} ) {
        my $op = pop @{$self->_stack};
        _add_bytecode $self, $op if    $op->{opcode_n} != OP_PHI
                                    && $op->{opcode_n} != OP_GET;
    }

    _created( $self, -@{$self->_stack} );
}

sub _pop {
    my( $self, $op ) = @_;

    die 'Empty stack in pop' unless @{$self->_stack} >= 1;
    my $top = pop @{$self->_stack};
    _add_bytecode $self, $top if    $top->{opcode_n} != OP_PHI
                                 && $top->{opcode_n} != OP_GET;
    _created( $self, -1 );
    _emit_out_stack( $self );
}

sub _dup {
    my( $self, $op ) = @_;

    die 'Empty stack in dup' unless @{$self->_stack} >= 1;
    my( $v ) = _get_stack( $self, 1, 1 );
    push @{$self->_stack}, $v, $v;
    _created( $self, 2 );
}

sub _swap {
    my( $self, $op ) = @_;
    my $stack = $self->_stack;
    my $t = $stack->[-1];

    die 'Empty stack in swap' unless @{$self->_stack} >= 2;
    $stack->[-1] = $stack->[-2];
    $stack->[-2] = $t;
}

sub _make_list_array {
    my( $self, $op ) = @_;

    my $nop = opcode_npm( $op->{opcode_n}, $op->{pos},
                          context => $op->context );
    $nop->set_parameters( [ _get_stack( $self, $op->{attributes}{count} ) ] )
        if $op->{attributes}{count};

    push @{$self->_stack}, $nop;

    _created( $self, 1 );
}

sub _cond_jump {
    my( $self, $op ) = @_;
    my $attrs = $OP_ATTRIBUTES{$op->{opcode_n}};
    my @in = _get_stack( $self, $attrs->{in_args} );
    my $new_cond = opcode_n( $op->{opcode_n}, @in );
    my $new_jump = opcode_n( OP_JUMP );

    my @out_names;
    _jump_to( $self, $new_cond, $op->true, \@out_names );
    _add_bytecode $self, $new_cond;
    _jump_to( $self,$new_jump,  $op->false, \@out_names );
    _add_bytecode $self, $new_jump;
}

sub _jump {
    my( $self, $op ) = @_;
    my $new_jump = opcode_nm( $op->{opcode_n} );

    _jump_to( $self, $new_jump, $op->to, [] );
    _add_bytecode $self, $new_jump;
}

sub _replace {
    my( $self, $op ) = @_;
    my $new_jump = opcode_npm( $op->{opcode_n}, $op->{pos},
                               context => $op->context,
                               index   => $op->index,
                               flags   => $op->flags,
                               );
    $new_jump->set_parameters( [ _get_stack( $self, 2 ) ] );

    my $to = $op->to;

    # extracted from _jump_to
    my $converted_blocks = $self->_converted;
    my $converted = $converted_blocks->{$to} ||= {};

    $converted->{block} ||= Language::P::Intermediate::BasicBlock
                                ->new_from_label( $to->start_label,
                                                  $to->lexical_state,
                                                  $to->scope, $to->dead );
    $new_jump->set_to( $converted->{block} );
    push @{$self->_queue}, $to;

    push @{$self->_stack}, $new_jump;

    _created( $self, 1 );
}

sub _rx_start_group {
    my( $self, $op ) = @_;
    my $new_jump = opcode_nm( OP_RX_START_GROUP );

    _jump_to( $self, $new_jump, $op->to, [] );
    _add_bytecode $self, $new_jump;
}

sub _rx_quantifier {
    my( $self, $op ) = @_;
    my $attrs = $op->{attributes};
    my $new_quant = # TODO clone
        opcode_nm( OP_RX_QUANTIFIER,
                   min => $attrs->{min}, max => $attrs->{max},
                   greedy => $attrs->{greedy},
                   group => $attrs->{group},
                   subgroups_start => $attrs->{subgroups_start},
                   subgroups_end => $attrs->{subgroups_end} );
    my $new_jump = opcode_n( OP_JUMP );

    _jump_to( $self, $new_quant, $op->true, [] );
    _add_bytecode $self, $new_quant;
    _jump_to( $self, $new_jump, $op->false, [] );
    _add_bytecode $self, $new_jump;
}

sub _rx_try {
    my( $self, $op ) = @_;
    my $new_jump = opcode_nm( OP_RX_TRY );

    _jump_to( $self, $new_jump, $op->to, [] );
    _add_bytecode $self, $new_jump;
}

sub _rx_backtrack {
    my( $self, $op ) = @_;
    my $new_jump = opcode_nm( OP_RX_BACKTRACK );

    _jump_to( $self, $new_jump, $op->to, [] );
    _add_bytecode $self, $new_jump;
}

sub _created {
    my( $self, $count ) = @_;

    $self->_converting->{created} += $count;
    if( $count < 0 && $self->_converting->{created} < 0 ) {
        $self->_converting->{created} = 0;
    }
}

1;
