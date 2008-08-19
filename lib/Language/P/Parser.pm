package Language::P::Parser;

use strict;
use warnings;
use base qw(Class::Accessor::Fast);

use Language::P::Lexer qw(:all);
use Language::P::ParseTree qw(:all);
use Language::P::Parser::Regex;
use Language::P::Value::ScratchPad;
use Language::P::Value::Code;
use Language::P::ParseTree::PropagateContext;

__PACKAGE__->mk_ro_accessors( qw(lexer generator runtime) );
__PACKAGE__->mk_accessors( qw(_package _lexicals _pending_lexicals
                              _current_sub _propagate_context
                              _lexical_state) );

use constant
  { PREC_HIGHEST       => 0,
    PREC_NAMED_UNOP    => 10,
    PREC_TERNARY       => 18,
    PREC_TERNARY_COLON => 40,
    PREC_LISTOP        => 21,
    PREC_LOWEST        => 50,

    BLOCK_OPEN_SCOPE      => 1,
    BLOCK_IMPLICIT_RETURN => 2,

    ASSOC_LEFT         => 1,
    ASSOC_RIGHT        => 2,
    ASSOC_NON          => 3,
    };

my %token_to_sigil =
  ( T_DOLLAR()    => VALUE_SCALAR,
    T_AT()        => VALUE_ARRAY,
    T_PERCENT()   => VALUE_HASH,
    T_STAR()      => VALUE_GLOB,
    T_AMPERSAND() => VALUE_SUB,
    T_ARYLEN()    => VALUE_ARRAY_LENGTH,
    );

my %prec_assoc_bin =
  ( T_ARROW()       => [ 2,  ASSOC_LEFT ],
    T_POWER()       => [ 4,  ASSOC_RIGHT, OP_POWER ],
    T_MATCH()       => [ 6,  ASSOC_LEFT,  OP_MATCH ],
    T_NOTMATCH()    => [ 6,  ASSOC_LEFT,  OP_NOT_MATCH ],
    T_STAR()        => [ 7,  ASSOC_LEFT,  OP_MULTIPLY ],
    T_SLASH()       => [ 7,  ASSOC_LEFT,  OP_DIVIDE ],
    T_PERCENT()     => [ 7,  ASSOC_LEFT,  OP_MODULUS ],
    T_SSTAR()       => [ 7,  ASSOC_LEFT,  OP_REPEAT ],
    T_PLUS()        => [ 8,  ASSOC_LEFT,  OP_ADD ],
    T_MINUS()       => [ 8,  ASSOC_LEFT,  OP_SUBTRACT ],
    T_DOT()         => [ 8,  ASSOC_LEFT,  OP_CONCATENATE ],
    T_OPAN()        => [ 11, ASSOC_NON,   OP_NUM_LT ],
    T_CLAN()        => [ 11, ASSOC_NON,   OP_NUM_GT ],
    T_LESSEQUAL()   => [ 11, ASSOC_NON,   OP_NUM_LE ],
    T_GREATEQUAL()  => [ 11, ASSOC_NON,   OP_NUM_GE ],
    T_SLESS()       => [ 11, ASSOC_NON,   OP_STR_LT ],
    T_SGREAT()      => [ 11, ASSOC_NON,   OP_STR_GT ],
    T_SLESSEQUAL()  => [ 11, ASSOC_NON,   OP_STR_LE ],
    T_SGREATEQUAL() => [ 11, ASSOC_NON,   OP_STR_GE ],
    T_EQUALEQUAL()  => [ 12, ASSOC_NON,   OP_NUM_EQ ],
    T_NOTEQUAL()    => [ 12, ASSOC_NON,   OP_NUM_NE ],
    T_CMP()         => [ 12, ASSOC_NON,   OP_NUM_CMP ],
    T_SEQUALEQUAL() => [ 12, ASSOC_NON,   OP_STR_EQ ],
    T_SNOTEQUAL()   => [ 12, ASSOC_NON,   OP_STR_NE ],
    T_SCMP()        => [ 12, ASSOC_NON,   OP_STR_CMP ],
    T_ANDAND()      => [ 15, ASSOC_LEFT,  OP_LOG_AND ],
    T_OROR()        => [ 16, ASSOC_LEFT,  OP_LOG_OR ],
    T_DOTDOT()      => [ 17, ASSOC_NON,   OP_DOT_DOT ],
    T_DOTDOTDOT()   => [ 17, ASSOC_NON,   OP_DOT_DOT_DOT ],
    T_INTERR()      => [ 18, ASSOC_RIGHT ], # ternary
    T_EQUAL()       => [ 19, ASSOC_RIGHT, OP_ASSIGN ],
    T_PLUSEQUAL()   => [ 19, ASSOC_RIGHT, OP_ADD_ASSIGN ],
    T_MINUSEQUAL()  => [ 19, ASSOC_RIGHT, OP_SUBTRACT_ASSIGN ],
    T_STAREQUAL()   => [ 19, ASSOC_RIGHT, OP_MULTIPLY_ASSIGN ],
    T_SLASHEQUAL()  => [ 19, ASSOC_RIGHT, OP_DIVIDE_ASSIGN ],
    # 20, comma
    # 21, list ops
    T_ANDANDLOW()   => [ 23, ASSOC_LEFT,  OP_LOG_AND ],
    T_ORORLOW()     => [ 24, ASSOC_LEFT,  OP_LOG_OR ],
    T_XORLOW()      => [ 24, ASSOC_LEFT,  OP_LOG_XOR ],
    T_COLON()       => [ 40, ASSOC_RIGHT ], # ternary, must be lowest,
    );

my %prec_assoc_un =
  ( T_PLUS()        => [ 5,  ASSOC_RIGHT, OP_PLUS ],
    T_MINUS()       => [ 5,  ASSOC_RIGHT, OP_MINUS ],
    T_NOT()         => [ 5,  ASSOC_RIGHT, OP_LOG_NOT ],
    T_BACKSLASH()   => [ 5,  ASSOC_RIGHT, OP_REFERENCE ],
    T_NOTLOW()      => [ 22, ASSOC_RIGHT, OP_LOG_NOT ],
    );

sub parse_string {
    my( $self, $string, $package ) = @_;

    open my $fh, '<', \$string;

    $self->_package( $package );
    $self->parse_stream( $fh );
}

sub parse_file {
    my( $self, $file ) = @_;

    open my $fh, '<', $file or die "open '$file': $!";

    $self->_package( 'main' );
    $self->parse_stream( $fh );
}

sub parse_stream {
    my( $self, $stream ) = @_;

    $self->{lexer} = Language::P::Lexer->new( { stream => $stream } );
    $self->{_lexical_state} = [];
    $self->_parse;
}

sub _parse {
    my( $self ) = @_;

    $self->_propagate_context( Language::P::ParseTree::PropagateContext->new );
    $self->_pending_lexicals( [] );
    $self->_lexicals( undef );
    $self->_enter_scope( 0 , 1 ); # FIXME eval

    my $code = Language::P::Value::Code->new( { bytecode => [],
                                                 lexicals => $self->_lexicals } );
    $self->generator->push_code( $code );
    $self->_current_sub( $code );

    while( my $line = _parse_line( $self ) ) {
        $self->_propagate_context->visit( $line, CXT_VOID );
        $self->generator->process( $line );
    }
    $self->_lexicals->keep_all_in_pad;
    $self->generator->finished;

    $self->generator->pop_code;

    return $code;
}

sub _enter_scope {
    my( $self, $is_sub, $all_in_pad ) = @_;

    push @{$self->{_lexical_state}}, { package  => $self->_package,
                                       lexicals => $self->_lexicals,
                                       };
    $self->_lexicals( Language::P::Value::ScratchPad->new
                          ( { outer         => $self->_lexicals,
                              is_subroutine => $is_sub || 0,
                              all_in_pad    => $all_in_pad || 0,
                              } ) );
}

sub _leave_scope {
    my( $self ) = @_;

    my $state = pop @{$self->{_lexical_state}};
    $self->_package( $state->{package} );
    $self->_lexicals( $state->{lexicals} );
}

sub _label {
    my( $self ) = @_;

    return undef;
}

sub _lex_token {
    my( $self, $type, $value, $expect ) = @_;
    my $token = $self->lexer->lex( $expect || X_NOTHING );

    return if !$value && !$type;

    if(    ( $type && $type ne $token->[0] )
        || ( $value && $value eq $token->[1] ) ) {
        Carp::confess( $token->[0], ' ', $token->[1] );
    }

    return $token;
}

sub _lex_semicolon {
    my( $self ) = @_;
    my $token = $self->lexer->lex;

    if( $token->[0] == T_EOF || $token->[0] == T_SEMICOLON ) {
        return;
    } elsif( $token->[0] == T_CLBRK ) {
        $self->lexer->unlex( $token );
        return;
    }

    Carp::confess( $token->[0], ' ', $token->[1] );
}

my %special_sub = map { $_ => 1 }
  ( qw(AUTOLOAD DESTROY BEGIN UNITCHECK CHECK INIT END) );

sub _parse_line {
    my( $self ) = @_;

    my $label = _label( $self );
    my $token = $self->lexer->peek( X_STATE );

    if( $token->[0] == T_SEMICOLON ) {
        _lex_semicolon( $self );

        return _parse_line( $self );
    } elsif( $token->[0] == T_OPBRK ) {
        _lex_token( $self, T_OPBRK );

        return _parse_block_rest( $self, BLOCK_OPEN_SCOPE );
    } elsif( $token->[1] eq 'sub' ) {
        return _parse_sub( $self, 1 | 2 );
    } elsif( $special_sub{$token->[1]} ) {
        return _parse_sub( $self, 1, 1 );
    } elsif( $token->[1] eq 'if' || $token->[1] eq 'unless' ) {
        return _parse_cond( $self );
    } elsif( $token->[1] eq 'while' || $token->[1] eq 'until' ) {
        return _parse_while( $self );
    } elsif( $token->[1] eq 'for' || $token->[1] eq 'foreach' ) {
        return _parse_for( $self );
    } elsif( $token->[1] eq 'package' ) {
        _lex_token( $self, T_ID );
        my $id = $self->lexer->lex_identifier;
        _lex_semicolon( $self );

        $self->_package( $id->[1] );

        return Language::P::ParseTree::Package->new
                   ( { name => $id->[1],
                       } );
    } else {
        my $sideff = _parse_sideff( $self );
        _lex_semicolon( $self );

        $self->_add_pending_lexicals;

        return $sideff;
    }

    Carp::confess $token->[0], ' ', $token->[1];
}

sub _add_pending_lexicals {
    my( $self ) = @_;

    # FIXME our() is different
    foreach my $lexical ( @{$self->_pending_lexicals} ) {
        my( undef, $slot ) = $self->_lexicals->add_name( $lexical->sigil,
                                                         $lexical->name );
        $lexical->{slot} = { slot  => $slot,
                             level => 0,
                             };
    }

    $self->_pending_lexicals( [] );
}

sub _parse_sub {
    my( $self, $flags, $no_sub_token ) = @_;
    _lex_token( $self, T_ID ) unless $no_sub_token;
    my $name = $self->lexer->peek( X_BLOCK );

    # TODO prototypes
    if( $name->[0] == T_ID ) {
        die 'Syntax error: named sub' unless $flags & 1;
        _lex_token( $self, T_ID );

        my $next = $self->lexer->lex( X_OPERATOR );

        if( $next->[0] == T_SEMICOLON ) {
            $self->generator->add_declaration( $name->[1] );

            return Language::P::ParseTree::SubroutineDeclaration->new
                       ( { name => $name->[1],
                           } );
        } elsif( $next->[0] != T_OPBRK ) {
            Carp::confess( $next->[0], ' ', $next->[1] );
        }
    } elsif( $name->[0] == T_OPBRK ) {
        die 'Syntax error: anonymous sub' unless $flags & 2;
        undef $name;
        _lex_token( $self, T_OPBRK );
    } else {
        die $name->[0], ' ', $name->[1];
    }

    $self->_enter_scope( 1 );
    my $sub = Language::P::ParseTree::Subroutine->new
                  ( { lexicals => $self->_lexicals,
                      outer    => $self->_current_sub,
                      name     => $name ? $name->[1] : undef,
                      } );

    # FIXME incestuos with runtime
    my $args_slot = $self->_lexicals->add_name( VALUE_ARRAY, '_' );
    $args_slot->{index} = $self->_lexicals->add_value;

    $self->_current_sub( $sub );
    my $block = _parse_block_rest( $self, BLOCK_IMPLICIT_RETURN );
    $sub->{lines} = $block->{lines}; # FIXME encapsulation
    $self->_leave_scope;
    $self->_current_sub( $sub->outer );

    $self->_propagate_context->visit( $sub, CXT_CALLER );

    # add a subroutine declaration, the generator might
    # not create it until later
    if( $name ) {
        $self->generator->add_declaration( $name->[1] );
    }

    return $sub;
}

sub _parse_cond {
    my( $self ) = @_;
    my $cond = _lex_token( $self, T_ID );

    _lex_token( $self, T_OPPAR );

    $self->_enter_scope;
    my $expr = _parse_expr( $self );
    $self->_add_pending_lexicals;

    _lex_token( $self, T_CLPAR );
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

    my $if = Language::P::ParseTree::Conditional->new
                 ( { iftrues => [ Language::P::ParseTree::ConditionalBlock->new
                                      ( { block_type => $cond->[1],
                                          condition  => $expr,
                                          block      => $block,
                                          } )
                                  ],
                     } );

    for(;;) {
        my $else = $self->lexer->peek( X_STATE );
        last if    $else->[0] != T_ID || $else->[2] != T_KEYWORD
                || ( $else->[1] ne 'else' && $else->[1] ne 'elsif' );
        _lex_token( $self );

        my $expr;
        if( $else->[1] eq 'elsif' ) {
            _lex_token( $self, T_OPPAR );
            $expr = _parse_expr( $self );
            _lex_token( $self, T_CLPAR );
        }
        _lex_token( $self, T_OPBRK, undef, X_BLOCK );
        my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

        if( $expr ) {
            push @{$if->iftrues}, Language::P::ParseTree::ConditionalBlock->new
                                      ( { block_type => 'if',
                                          condition  => $expr,
                                          block      => $block,
                                          } )
        } else {
            $if->{iffalse} = Language::P::ParseTree::ConditionalBlock->new
                                      ( { block_type => 'else',
                                          condition  => undef,
                                          block      => $block,
                                          } )
        }
    }

    $self->_leave_scope;

    return $if;
}

sub _parse_for {
    my( $self ) = @_;
    my $keyword = _lex_token( $self, T_ID );
    my $token = $self->lexer->lex( X_OPERATOR );
    my( $foreach_var, $foreach_expr );

    $self->_enter_scope;

    if( $token->[0] == T_OPPAR ) {
        my $expr = _parse_expr( $self );
        my $sep = $self->lexer->lex( X_OPERATOR );

        if( $sep->[0] == T_CLPAR ) {
            $foreach_var = _find_symbol( $self, VALUE_SCALAR, '_' );
            $foreach_expr = $expr;
        } elsif( $sep->[0] == T_SEMICOLON ) {
            # C-style for
            $self->_add_pending_lexicals;

            my $cond = _parse_expr( $self );
            _lex_token( $self, T_SEMICOLON );
            $self->_add_pending_lexicals;

            my $incr = _parse_expr( $self );
            _lex_token( $self, T_CLPAR );
            $self->_add_pending_lexicals;

            _lex_token( $self, T_OPBRK, undef, X_BLOCK );
            my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

            my $for = Language::P::ParseTree::For->new
                          ( { block_type  => 'for',
                              initializer => $expr,
                              condition   => $cond,
                              step        => $incr,
                              block       => $block,
                              } );

            $self->_leave_scope;

            return $for;
        } else {
            Carp::confess $sep->[0], ' ', $sep->[1];
        }
    } elsif( $token->[0] == T_ID && (    $token->[1] eq 'my'
                                      || $token->[1] eq 'our'
                                      || $token->[1] eq 'state' ) ) {
        $foreach_var = _parse_lexical_variable( $self, $token->[1] )
    } elsif( $token->[0] == T_DOLLAR ) {
        my $id = $self->lexer->lex_identifier;
        $foreach_var = _find_symbol( $self, VALUE_SCALAR, $id->[1] );
    } else {
        Carp::confess $token->[0], ' ', $token->[1];
    }

    # if we get there it is not C-style for
    if( !$foreach_expr ) {
        _lex_token( $self, T_OPPAR );
        $foreach_expr = _parse_expr( $self );
        _lex_token( $self, T_CLPAR );
    }

    $self->_add_pending_lexicals;
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

    my $for = Language::P::ParseTree::Foreach->new
                  ( { expression => $foreach_expr,
                      block      => $block,
                      variable   => $foreach_var,
                      } );

    $self->_leave_scope;

    return $for;
}

sub _parse_while {
    my( $self ) = @_;
    my $keyword = _lex_token( $self, T_ID );

    _lex_token( $self, T_OPPAR );

    $self->_enter_scope;
    my $expr = _parse_expr( $self );
    $self->_add_pending_lexicals;

    _lex_token( $self, T_CLPAR );
    _lex_token( $self, T_OPBRK, undef, X_BLOCK );

    my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

    my $while = Language::P::ParseTree::ConditionalLoop
                    ->new( { condition  => $expr,
                             block      => $block,
                             block_type => $keyword->[1],
                             } );

    $self->_leave_scope;

    return $while;
}

sub _parse_sideff {
    my( $self ) = @_;
    my $expr = _parse_expr( $self );
    my $keyword = $self->lexer->peek( X_TERM );

    if( $keyword->[0] == T_ID && $keyword->[2] == T_KEYWORD ) {
        if( $keyword->[1] eq 'if' || $keyword->[1] eq 'unless' ) {
            _lex_token( $self, T_ID );
            my $cond = _parse_expr( $self );

            $expr = Language::P::ParseTree::Conditional->new
                        ( { iftrues => [ Language::P::ParseTree::ConditionalBlock->new
                                             ( { block_type => $keyword->[1],
                                                 condition  => $cond,
                                                 block      => $expr,
                                                 } )
                                         ],
                            } );
        } elsif( $keyword->[1] eq 'while' || $keyword->[1] eq 'until' ) {
            _lex_token( $self, T_ID );
            my $cond = _parse_expr( $self );

            $expr = Language::P::ParseTree::ConditionalLoop->new
                        ( { condition  => $cond,
                            block      => $expr,
                            block_type => $keyword->[1],
                            } );
        } elsif( $keyword->[1] eq 'for' || $keyword->[1] eq 'foreach' ) {
            _lex_token( $self, T_ID );
            my $cond = _parse_expr( $self );

            $expr = Language::P::ParseTree::Foreach->new
                        ( { expression => $cond,
                            block      => $expr,
                            variable   => _find_symbol( $self, VALUE_SCALAR, '_' ),
                            } );
        }
    }

    return $expr;
}

sub _parse_expr {
    my( $self ) = @_;
    my $expr = _parse_term( $self, PREC_LOWEST );
    my $la = $self->lexer->peek( X_TERM );

    if( $la->[0] == T_COMMA ) {
        my $terms = _parse_cslist_rest( $self, PREC_LOWEST,
                                        PROTO_DEFAULT, 0, $expr );

        return Language::P::ParseTree::List->new( { expressions => $terms } );
    }

    return $expr;
}

sub _find_symbol {
    my( $self, $sigil, $name ) = @_;

    if( $name =~ /::/ ) {
        return Language::P::ParseTree::Symbol->new( { name  => $name,
                                                      sigil => $sigil,
                                                      } );
    }

    my( $crossed_sub, $slot ) = $self->_lexicals->find_name( $sigil . $name );

    if( $slot ) {
        $slot->{in_pad} ||= $crossed_sub ? 1 : 0;

        return Language::P::ParseTree::LexicalSymbol->new
                   ( { name  => $name,
                       sigil => $sigil,
                       slot  => { level => $crossed_sub,
                                  slot  => $slot,
                                  },
                       } );
    }

    my $prefix = $self->_package eq 'main' ? '' : $self->_package . '::';
    return Language::P::ParseTree::Symbol->new( { name  => $prefix . $name,
                                                  sigil => $sigil,
                                                  } );
}

sub _parse_maybe_subscript_rest {
    my( $self, $subscripted ) = @_;
    my $next = $self->lexer->peek( X_OPERATOR );

    # array/hash element
    if( $next->[0] == T_ARROW ) {
        _lex_token( $self, T_ARROW );
        my $bracket = $self->lexer->peek( X_OPERATOR );

        if(    $bracket->[0] == T_OPPAR
            || $bracket->[0] == T_OPSQ
            || $bracket->[0] == T_OPBRK ) {
            return _parse_dereference_rest( $self, $subscripted, $bracket );
        } else {
            return _parse_maybe_direct_method_call( $self, $subscripted );
        }
    } elsif(    $next->[0] == T_OPPAR
             || $next->[0] == T_OPSQ
             || $next->[0] == T_OPBRK ) {
        return _parse_dereference_rest( $self, $subscripted, $next );
    } else {
        return $subscripted;
    }
}

sub _parse_indirect_function_call {
    my( $self, $subscripted, $with_arguments, $ampersand ) = @_;

    my $args;
    if( $with_arguments ) {
        _lex_token( $self, T_OPPAR );
        ( $args, undef ) = _parse_arglist( $self, PREC_LOWEST, PROTO_DEFAULT, 0 );
        _lex_token( $self, T_CLPAR );
    }

    # $foo->() requires an additional dereference, while
    # &{...}(...) does not construct a reference but might need it
    if( !$subscripted->is_symbol || $subscripted->sigil != VALUE_SUB ) {
        $subscripted = Language::P::ParseTree::Dereference->new
                           ( { left => $subscripted,
                               op   => VALUE_SUB,
                               } );
    }

    # treat &foo; separately from all other cases
    if( $ampersand && !$with_arguments ) {
        return Language::P::ParseTree::SpecialFunctionCall->new
                   ( { function    => $subscripted,
                       flags       => FLAG_IMPLICITARGUMENTS,
                       } );
    } else {
        return Language::P::ParseTree::FunctionCall->new
                   ( { function    => $subscripted,
                       arguments   => $args,
                       } );
    }
}

sub _parse_dereference_rest {
    my( $self, $subscripted, $bracket ) = @_;
    my $term;

    if( $bracket->[0] == T_OPPAR ) {
        $term = _parse_indirect_function_call( $self, $subscripted, 1, 0 );
    } else {
        my $subscript = _parse_bracketed_expr( $self, $bracket->[0], 0 );
        $term = Language::P::ParseTree::Subscript->new
                    ( { subscripted => $subscripted,
                        subscript   => $subscript,
                        type        => $bracket->[0] == T_OPBRK ? VALUE_HASH :
                                                                  VALUE_ARRAY,
                        reference   => 1,
                        } );
    }

    return _parse_maybe_subscript_rest( $self, $term );
}

sub _parse_bracketed_expr {
    my( $self, $bracket, $allow_empty, $no_consume_opening ) = @_;
    my $close = $bracket == T_OPBRK ? T_CLBRK :
                $bracket == T_OPSQ  ? T_CLSQ :
                                      T_CLPAR;

    _lex_token( $self, $bracket ) unless $no_consume_opening;
    if( $allow_empty ) {
        my $next = $self->lexer->peek( X_TERM );
        if( $next->[0] eq $close ) {
            _lex_token( $self, $close );
            return undef;
        }
    }
    my $subscript = _parse_expr( $self );
    _lex_token( $self, $close );

    return $subscript;
}

sub _parse_maybe_indirect_method_call {
    my( $self, $op, $next ) = @_;
    my $indir = _parse_indirobj( $self, 1 );

    if( $indir ) {
        # if FH -> no method
        # proto FH -> no method
        # Foo $bar (?) -> no method
        # foo $bar -> method
        # print xxx .... -> no method
        if( $op->[1] eq 'print' ) {
            my $la = 1;
        }
        # foo pack:: -> method

        use Data::Dumper;
        Carp::confess Dumper( $indir ) . ' ';
    }

    return Language::P::ParseTree::Constant->new
               ( { value => $op->[1],
                   flags => CONST_STRING|STRING_BARE
                   } );
}

sub _parse_maybe_direct_method_call {
    my( $self, $invocant ) = @_;
    my $token = $self->lexer->lex( X_TERM );

    if( $token->[0] == T_ID ) {
        my $oppar = $self->lexer->peek( X_OPERATOR );
        my $args;
        if( $oppar->[0] == T_OPPAR ) {
            $args = _parse_bracketed_expr( $self, T_OPPAR, 1 );
        }

        my $term = Language::P::ParseTree::MethodCall->new
                       ( { invocant  => $invocant,
                           method    => $token->[1],
                           arguments => $args,
                           indirect  => 0,
                           } );

        return _parse_maybe_subscript_rest( $self, $term );
    } elsif( $token->[0] == T_DOLLAR ) {
        my $id = _lex_token( $self, T_ID );
        my $meth = _find_symbol( $self, VALUE_SCALAR, $id->[1] );
        my $oppar = $self->lexer->peek( X_OPERATOR );
        my $args;
        if( $oppar->[0] == T_OPPAR ) {
            $args = _parse_bracketed_expr( $self, T_OPPAR, 1 );
        }

        my $term = Language::P::ParseTree::MethodCall->new
                       ( { invocant  => $invocant,
                           method    => $meth,
                           arguments => $args,
                           indirect  => 1,
                           } );

        return _parse_maybe_subscript_rest( $self, $term );
    } else {
        die $token->[0], ' ', $token->[1];
    }
}

sub _parse_match {
    my( $self, $token ) = @_;

    if( $token->[6] ) {
        my $string = _parse_string_rest( $self, $token, 1 );
        my $match = Language::P::ParseTree::InterpolatedPattern->new
                        ( { string     => $string,
                            op         => $token->[1],
                            flags      => $token->[5],
                            } );

        return $match;
    } else {
        my $terminator = $token->[2];
        my $interpolate = $terminator eq "'" ? 0 : 1;

        my $parts = Language::P::Parser::Regex->new
                        ( { generator   => $self->generator,
                            runtime     => $self->runtime,
                            interpolate => $interpolate,
                            } )->parse_string( $token->[3] );
        my $match = Language::P::ParseTree::Pattern->new
                        ( { components => $parts,
                            op         => $token->[1],
                            flags      => $token->[5],
                            } );

        return $match;
    }
}

sub _parse_substitution {
    my( $self, $token ) = @_;
    my $match = _parse_match( $self, $token );

    my $replace;
    if( $match->flags & FLAG_RX_EVAL ) {
        local $self->{lexer} = Language::P::Lexer->new
                                   ( { string => $token->[4]->[3] } );
        $replace = _parse_block_rest( $self, BLOCK_OPEN_SCOPE, T_EOF );
    } else {
        $replace = _parse_string_rest( $self, $token->[4], 0 );
    }

    my $sub = Language::P::ParseTree::Substitution->new
                  ( { pattern     => $match,
                      replacement => $replace,
                      } );

    return $sub;
}

sub _parse_string_rest {
    my( $self, $token, $pattern ) = @_;
    my( $quote, $terminator ) = ( $token->[1], $token->[2] );
    my $interpolate = $quote eq 'qq'     ? 1 :
                      $quote eq 'q'      ? 0 :
                      $quote eq 'qw'     ? 0 :
                      $terminator eq "'" ? 0 :
                                           1;
    my @values;
    local $self->{lexer} = Language::P::Lexer->new( { string => $token->[3] } );

    $self->lexer->quote( { interpolate          => $interpolate,
                           pattern              => 0,
                           interpolated_pattern => $pattern,
                           } );
    for(;;) {
        my $value = $self->lexer->lex_quote;

        if( $value->[0] == T_STRING ) {
            push @values, Language::P::ParseTree::Constant->new
                              ( { flags => CONST_STRING,
                                  value => $value->[1],
                                  } );
        } elsif( $value->[0] == T_EOF ) {
            last;
        } elsif( $value->[0] == T_DOLLAR || $value->[0] == T_AT ) {
            push @values, _parse_indirobj_maybe_subscripts( $self, $value );
        } else {
            die $value->[0], ' ', $value->[1];
        }
    }

    $self->lexer->quote( undef );

    my $string;
    if( @values == 1 && $values[0]->is_constant ) {
        $string = $values[0];
    } elsif( @values == 0 ) {
        $string = Language::P::ParseTree::Constant->new
                      ( { value => "",
                          flags => CONST_STRING,
                          } );
    } else {
        $string = Language::P::ParseTree::QuotedString->new
                      ( { components => \@values,
                           } );
    }

    if( $quote eq '`' || $quote eq 'qx' ) {
        $string = Language::P::ParseTree::UnOp->new
                      ( { op   => 'backtick',
                          left => $string,
                          } );
    } elsif( $quote eq 'qw' ) {
        my @words = map Language::P::ParseTree::Constant->new
                            ( { value => $_,
                                flags => CONST_STRING,
                                } ),
                        split /[\s\r\n]+/, $string->value;

        $string = Language::P::ParseTree::List->new
                      ( { expressions => \@words,
                          } );
    }

    return $string;
}

sub _parse_term_terminal {
    my( $self, $token, $is_bind ) = @_;

    if( $token->[0] == T_QUOTE ) {
        my $qstring = _parse_string_rest( $self, $token, 0 );

        if( $token->[1] eq '<' ) {
            # simple scalar: readline, anything else: glob
            if(    $qstring->isa( 'Language::P::ParseTree::QuotedString' )
                && $#{$qstring->components} == 0
                && $qstring->components->[0]->is_symbol ) {
                return Language::P::ParseTree::Overridable
                           ->new( { function  => 'readline',
                                    arguments => [ $qstring->components->[0] ] } );
            } elsif( $qstring->is_constant ) {
                if( $qstring->value =~ /^[a-zA-Z_]/ ) {
                    # FIXME simpler method, make lex_identifier static
                    my $lexer = Language::P::Lexer->new
                                    ( { string => $qstring->value } );
                    my $id = $lexer->lex_identifier;

                    if( $id && !length( ${$lexer->buffer} ) ) {
                        my $glob = Language::P::ParseTree::Symbol->new
                                       ( { name  => $id->[1],
                                           sigil => VALUE_GLOB,
                                           } );
                        return Language::P::ParseTree::Overridable
                                   ->new( { function  => 'readline',
                                            arguments => [ $glob ],
                                            } );
                    }
                }
                return Language::P::ParseTree::Glob
                           ->new( { arguments => [ $qstring ] } );
            } else {
                return Language::P::ParseTree::Glob
                           ->new( { arguments => [ $qstring ] } );
            }
        }

        return $qstring;
    } elsif( $token->[0] == T_PATTERN ) {
        my $pattern;
        if( $token->[1] == OP_QL_M || $token->[1] == OP_QL_QR ) {
            $pattern = _parse_match( $self, $token );
        } elsif( $token->[1] == OP_QL_S ) {
            $pattern = _parse_substitution( $self, $token );
        } else {
            die;
        }

        if( !$is_bind && $token->[1] != OP_QL_QR ) {
            $pattern = Language::P::ParseTree::BinOp->new
                           ( { op    => OP_MATCH,
                               left  => _find_symbol( $self, VALUE_SCALAR, '_' ),
                               right => $pattern,
                               } );
        }

        return $pattern;
    } elsif( $token->[0] == T_NUMBER ) {
        return Language::P::ParseTree::Constant->new
                   ( { value => $token->[1],
                       flags => $token->[2]|CONST_NUMBER,
                       } );
    } elsif( $token->[0] == T_STRING ) {
        return Language::P::ParseTree::Constant->new
                   ( { value => $token->[1],
                       flags => CONST_STRING,
                       } );
    } elsif(    $token->[0] == T_DOLLAR
             || $token->[0] == T_AT
             || $token->[0] == T_PERCENT
             || $token->[0] == T_STAR
             || $token->[0] == T_AMPERSAND
             || $token->[0] == T_ARYLEN ) {
        return _parse_indirobj_maybe_subscripts( $self, $token );
    } elsif(    $token->[0] == T_ID && $token->[2] == T_KEYWORD
             && (    $token->[1] eq 'my' || $token->[1] eq 'our'
                  || $token->[1] eq 'state' ) ) {
        return _parse_lexical( $self, $token->[1] );
    } elsif( $token->[0] == T_ID ) {
        return _parse_listop( $self, $token );
    } elsif( $token->[0] == T_OPHASH ) {
        my $expr = _parse_bracketed_expr( $self, T_OPBRK, 1, 1 );

        return Language::P::ParseTree::ReferenceConstructor->new
                   ( { expression => $expr,
                       type       => VALUE_HASH,
                       } );
    } elsif( $token->[0] == T_OPSQ ) {
        my $expr = _parse_bracketed_expr( $self, T_OPSQ, 1, 1 );

        return Language::P::ParseTree::ReferenceConstructor->new
                   ( { expression => $expr,
                       type       => VALUE_ARRAY,
                       } );
    }

    return undef;
}

sub _parse_indirobj_maybe_subscripts {
    my( $self, $token ) = @_;
    my $indir = _parse_indirobj( $self, 0 );
    my $sigil = $token_to_sigil{$token->[0]};
    my $is_id = ref( $indir ) eq 'ARRAY' && $indir->[0] == T_ID;

    # no subscripting/slicing possible for '%'
    if( $sigil == VALUE_HASH ) {
        return $is_id ? _find_symbol( $self, $sigil, $indir->[1] ) :
                         Language::P::ParseTree::Dereference->new
                             ( { left  => $indir,
                                 op    => $sigil,
                                 } );
    }

    my $next = $self->lexer->peek( X_OPERATOR );

    if( $sigil == VALUE_SUB ) {
        my $deref = $is_id ? _find_symbol( $self, $sigil, $indir->[1] ) :
                             $indir;

        return _parse_indirect_function_call( $self, $deref,
                                              $next->[0] == T_OPPAR, 1 );
    }

    # simplify the code below by resolving the symbol here, so a
    # dereference will be constructed below (probably an unary
    # operator would be more consistent)
    if( $sigil == VALUE_ARRAY_LENGTH && $is_id ) {
        $indir = _find_symbol( $self, VALUE_ARRAY, $indir->[1] );
        $is_id = 0;
    }

    if( $next->[0] == T_ARROW ) {
        my $deref = $is_id ? _find_symbol( $self, $sigil, $indir->[1] ) :
                             Language::P::ParseTree::Dereference->new
                                 ( { left  => $indir,
                                     op    => $sigil,
                                     } );

        return _parse_maybe_subscript_rest( $self, $deref );
    }

    my( $is_slice, $sym_sigil );
    if(    ( $sigil == VALUE_ARRAY || $sigil == VALUE_SCALAR )
        && ( $next->[0] == T_OPSQ || $next->[0] == T_OPBRK ) ) {
        $sym_sigil = $next->[0] == T_OPBRK ? VALUE_HASH : VALUE_ARRAY;
        $is_slice = $sigil == VALUE_ARRAY;
    } elsif( $sigil == VALUE_GLOB && $next->[0] == T_OPBRK ) {
        $sym_sigil = VALUE_GLOB;
    } else {
        return $is_id ? _find_symbol( $self, $sigil, $indir->[1] ) :
                         Language::P::ParseTree::Dereference->new
                             ( { left  => $indir,
                                 op    => $sigil,
                                 } );
    }

    my $subscript = _parse_bracketed_expr( $self, $next->[0], 0 );
    my $subscripted = $is_id ? _find_symbol( $self, $sym_sigil, $indir->[1] ) :
                               $indir;
    my $subscript_type = $next->[0] == T_OPBRK ? VALUE_HASH : VALUE_ARRAY;

    if( $is_slice ) {
        return Language::P::ParseTree::Slice->new
                   ( { subscripted => $subscripted,
                       subscript   => $subscript,
                       type        => $subscript_type,
                       reference   => $is_id ? 0 : 1,
                       } );
    } else {
        my $term = Language::P::ParseTree::Subscript->new
                       ( { subscripted => $subscripted,
                           subscript   => $subscript,
                           type        => $subscript_type,
                           reference   => $is_id ? 0 : 1,
                           } );

        return _parse_maybe_subscript_rest( $self, $term );
    }
}

sub _parse_lexical {
    my( $self, $keyword ) = @_;

    die $keyword unless $keyword eq 'my' || $keyword eq 'our';

    my $list = _parse_lexical_rest( $self, $keyword );

    return $list;
}

sub _parse_lexical_rest {
    my( $self, $keyword ) = @_;

    my $token = $self->lexer->peek( X_TERM );

    if( $token->[0] == T_OPPAR ) {
        my @variables;

        _lex_token( $self, T_OPPAR );

        for(;;) {
            push @variables, _parse_lexical_variable( $self, $keyword );
            my $token = $self->lexer->peek( X_OPERATOR );

            if( $token->[0] == T_COMMA ) {
                _lex_token( $self, T_COMMA );
            } elsif( $token->[0] == T_CLPAR ) {
                _lex_token( $self, T_CLPAR );
                last;
            }
        }

        push @{$self->_pending_lexicals}, @variables;

        return Language::P::ParseTree::List->new( { expressions => \@variables } );
    } else {
        my $variable = _parse_lexical_variable( $self, $keyword );

        push @{$self->_pending_lexicals}, $variable;

        return $variable;
    }
}

sub _parse_lexical_variable {
    my( $self, $keyword ) = @_;
    my $sigil = $self->lexer->lex( X_TERM );

    die $sigil->[0], ' ', $sigil->[1] unless $sigil->[1] =~ /^[\$\@\%]$/;

    my $name = $self->lexer->lex_identifier;
    die unless $name;

    # FIXME our() variable refers to package it was declared in
    return Language::P::ParseTree::LexicalDeclaration->new
               ( { name             => $name->[1],
                   sigil            => $token_to_sigil{$sigil->[0]},
                   declaration_type => $keyword,
                   } );
}

sub _parse_term_p {
    my( $self, $prec, $token, $lookahead, $is_bind ) = @_;
    my $terminal = _parse_term_terminal( $self, $token, $is_bind );

    return $terminal if $terminal && !$lookahead;

    if( $terminal ) {
        my $la = $self->lexer->peek( X_OPERATOR );
        my $binprec = $prec_assoc_bin{$la->[0]};

        if( !$binprec || $binprec->[0] > $prec ) {
            return $terminal;
        } elsif( $la->[0] == T_INTERR ) {
            _lex_token( $self, T_INTERR );
            return _parse_ternary( $self, PREC_TERNARY, $terminal );
        } elsif( $binprec ) {
            return _parse_term_n( $self, $binprec->[0],
                                  $terminal );
        } else {
            Carp::confess $la->[0], ' ', $la->[1];
        }
    } elsif( my $p = $prec_assoc_un{$token->[0]} ) {
        my $rest = _parse_term_n( $self, $p->[0] );

        return Language::P::ParseTree::UnOp->new
                   ( { op    => $p->[2],
                       left  => $rest,
                       } );
    } elsif( $token->[0] == T_OPPAR ) {
        my $term = _parse_expr( $self );
        _lex_token( $self, T_CLPAR );

        # record that there were prentheses, unless it is a list
        if( !$term->isa( 'Language::P::ParseTree::List' ) ) {
            return Language::P::ParseTree::Parentheses->new
                       ( { left => $term,
                           } );
        } else {
            return $term;
        }
    }

    return undef;
}

sub _parse_ternary {
    my( $self, $prec, $terminal ) = @_;

    my $iftrue = _parse_term_n( $self, PREC_TERNARY_COLON - 1 );
    _lex_token( $self, T_COLON );
    my $iffalse = _parse_term_n( $self, $prec - 1 );

    return Language::P::ParseTree::Ternary->new
               ( { condition => $terminal,
                   iftrue    => $iftrue,
                   iffalse   => $iffalse,
                   } );
}

sub _parse_term_n {
    my( $self, $prec, $terminal, $is_bind ) = @_;

    if( !$terminal ) {
        my $token = $self->lexer->lex( X_TERM );
        $terminal = _parse_term_p( $self, $prec, $token, undef, $is_bind );

        if( !$terminal ) {
            $self->lexer->unlex( $token );
            return undef;
        }
    }

    for(;;) {
        my $token = $self->lexer->lex( X_OPERATOR );
        my $bin = $prec_assoc_bin{$token->[0]};
        if( !$bin || $bin->[0] > $prec ) {
            $self->lexer->unlex( $token );
            last;
        } elsif( $token->[0] == T_INTERR ) {
            $terminal = _parse_ternary( $self, PREC_TERNARY, $terminal );
        } else {
            # do not try to use colon as binary
            Carp::confess $token->[0], ' ', $token->[1]
                if $token->[0] == T_COLON;

            my $q = $bin->[1] == ASSOC_RIGHT ? $bin->[0] : $bin->[0] - 1;
            my $rterm = _parse_term_n( $self, $q, undef,
                                       (    $token->[0] == T_MATCH
                                         || $token->[0] == T_NOTMATCH ) );

            $terminal = Language::P::ParseTree::BinOp->new
                            ( { op    => $bin->[2],
                                left  => $terminal,
                                right => $rterm,
                                } );
        }
    }

    return $terminal;
}

sub _parse_term {
    my( $self, $prec ) = @_;
    my $token = $self->lexer->lex( X_TERM );
    my $terminal = _parse_term_p( $self, $prec, $token, 1, 0 );

    if( $terminal ) {
        $terminal = _parse_term_n( $self, $prec, $terminal );

        return $terminal;
    }

    $self->lexer->unlex( $token );

    return undef;
}

sub _add_implicit_return {
    my( $line ) = @_;

    return $line unless $line->can_implicit_return;
    if( !$line->is_compound ) {
        return Language::P::ParseTree::Builtin->new
                   ( { arguments => [ $line ],
                       function  => 'return',
                       } );
    }

    # compund and can implicitly return
    if( $line->isa( 'Language::P::ParseTree::Block' ) && @{$line->lines} ) {
        $line->lines->[-1] = _add_implicit_return( $line->lines->[-1] );
    } elsif( $line->isa( 'Language::P::ParseTree::Conditional' ) ) {
        _add_implicit_return( $_ ) foreach @{$line->iftrues};
        _add_implicit_return( $line->iffalse ) if $line->iffalse;
    } elsif( $line->isa( 'Language::P::ParseTree::ConditionalBlock' ) ) {
        _add_implicit_return( $line->block )
    } else {
        Carp::confess( "Unhandled statement type: ", ref( $line ) );
    }

    return $line;
}

sub _parse_block_rest {
    my( $self, $flags, $end_token ) = @_;

    $end_token ||= T_CLBRK;
    $self->_enter_scope if $flags & BLOCK_OPEN_SCOPE;

    my @lines;
    for(;;) {
        my $token = $self->lexer->lex( X_STATE );
        if( $token->[0] eq $end_token ) {
            if( $flags & BLOCK_IMPLICIT_RETURN && @lines ) {
                $lines[-1] = _add_implicit_return( $lines[-1] );
            }

            $self->_leave_scope if $flags & BLOCK_OPEN_SCOPE;
            return Language::P::ParseTree::Block->new( { lines => \@lines } );
        } else {
            $self->lexer->unlex( $token );
            my $line = _parse_line( $self );

            push @lines, $line if $line; # skip empty satements
        }
    }
}

sub _parse_indirobj {
    my( $self, $allow_fail ) = @_;
    my $id = $self->lexer->lex_identifier;

    if( $id ) {
        return $id;
    }

    my $token = $self->lexer->lex( X_OPERATOR );

    if( $token->[0] == T_OPBRK ) {
        my $block = _parse_block_rest( $self, BLOCK_OPEN_SCOPE );

        return $block;
    } elsif( $token->[0] == T_DOLLAR ) {
        my $indir = _parse_indirobj( $self, 0 );

        if( ref( $indir ) eq 'ARRAY' && $indir->[0] == T_ID ) {
            return _find_symbol( $self, VALUE_SCALAR, $indir->[1] );
        } else {
            return Language::P::ParseTree::Dereference->new
                       ( { left  => $indir,
                           op    => VALUE_SCALAR,
                           } );
        }
    } elsif( $allow_fail ) {
        $self->lexer->unlex( $token );

        return undef;
    } else {
        die $token->[0], ' ', $token->[1];
    }
}

sub _declared_id {
    my( $self, $op ) = @_;
    my $call;

    my $is_print = $op->[1] eq 'print';
    if( $op->[2] == T_OVERRIDABLE ) {
        my $st = $self->runtime->symbol_table;

        if( $st->get_symbol( $op->[1], '&' ) ) {
            die "Overriding '$op->[1]' not implemented";
        }
        $call = Language::P::ParseTree::Overridable->new
                    ( { function  => $op->[1],
                        } );

        return ( $call, 1 );
    } elsif( $is_print ) {
        $call = Language::P::ParseTree::Print->new
                    ( { function  => $op->[1],
                        } );

        return ( $call, 1 );
    } elsif( $op->[2] == T_KEYWORD ) {
        $call = Language::P::ParseTree::Builtin->new
                    ( { function  => $op->[1],
                        } );

        return ( $call, 1 );
    } else {
        my $st = $self->runtime->symbol_table;

        if( $st->get_symbol( $op->[1], '&' ) ) {
            return ( undef, 1 );
        }
    }

    return ( undef, 0 );
}

sub _parse_listop {
    my( $self, $op ) = @_;
    my $next = $self->lexer->peek( X_TERM );

    my( $call, $declared ) = _declared_id( $self, $op );
    my( $args, $fh );

    if( !$call || !$declared ) {
        my $st = $self->runtime->symbol_table;

        if( $next->[0] == T_ARROW ) {
            _lex_token( $self, T_ARROW );
            my $la = $self->lexer->peek( X_OPERATOR );

            if( $la->[0] == T_ID || $la->[0] == T_DOLLAR ) {
                # here we are calling the method on a bareword
                my $invocant = Language::P::ParseTree::Constant->new
                                   ( { value => $op->[1],
                                       flags => CONST_STRING,
                                       } );

                return _parse_maybe_direct_method_call( $self, $invocant );
            } else {
                # looks like a bareword, report as such
                $self->lexer->unlex( $next );

                return Language::P::ParseTree::Constant->new
                           ( { value => $op->[1],
                               flags => CONST_STRING|STRING_BARE
                               } );
            }
        } elsif( !$declared && $next->[0] != T_OPPAR ) {
            # not a declared subroutine, nor followed by parenthesis
            # try to see if it is some sort of (indirect) method call
            return _parse_maybe_indirect_method_call( $self, $op, $next );
        }

        # foo Bar:: is always a method call
        if(    $next->[0] == T_ID
            && $st->get_package( $next->[1] ) ) {
            return _parse_maybe_indirect_method_call( $self, $op, $next );
        }

        my $symbol = Language::P::ParseTree::Symbol->new
                         ( { name   => $op->[1],
                             sigil => VALUE_SUB,
                             } );
        $call = Language::P::ParseTree::FunctionCall->new
                    ( { function  => $symbol,
                        arguments => undef,
                        } );
    }

    my $proto = $call->parsing_prototype;
    if( $next->[0] == T_OPPAR ) {
        $self->lexer->lex; # comsume token
        ( $args, $fh ) = _parse_arglist( $self, PREC_LOWEST, $proto, 0 );
        _lex_token( $self, T_CLPAR );
    } elsif( $proto->[1] == 1 ) {
        ( $args, $fh ) = _parse_arglist( $self, PREC_NAMED_UNOP, $proto, 0 );
    } elsif( $proto->[1] != 0 ) {
        Carp::confess( "Undeclared identifier '$op->[1]'" ) unless $declared;
        ( $args, $fh ) = _parse_arglist( $self, PREC_LISTOP, $proto, 0 );
    }

    $call->{arguments} = $args;
    $call->{filehandle} = $fh if $fh;

    return $call;
}

sub _parse_arglist {
    my( $self, $prec, $proto, $index ) = @_;
    my $la = $self->lexer->peek( X_TERM );

    my $term;
    my $proto_char = $proto->[2 + $index];
    my $indirect_filehandle = $proto_char eq '!';
    if( $indirect_filehandle ) {
        ++$index;
        $proto_char = $proto->[2 + $index];
    }
    if( $la->[0] == T_ID && $indirect_filehandle ) {
        my( $call, $declared ) = _declared_id( $self, $la );

        if( !$declared ) {
            _lex_token( $self, T_ID );
            $term = Language::P::ParseTree::Symbol->new
                        ( { name  => $la->[1],
                            sigil => VALUE_GLOB,
                            } );
        } else {
            $indirect_filehandle = 0;
        }
    } elsif( $indirect_filehandle ) {
        $indirect_filehandle = 0;
    }

    if( !$term ) {
        $term = _maybe_handle( _parse_term( $self, $prec ),
                               $proto, $index );
        ++$index;
    }

    return unless $term;

    # special case for defined/exists &foo
    if( $proto_char eq '#' ) {
        if(    $term->isa( 'Language::P::ParseTree::SpecialFunctionCall' )
            && $term->flags & FLAG_IMPLICITARGUMENTS ) {
            $term = $term->function;
        }
    }
    return [ $term ] if $proto->[1] == $index;

    if( $indirect_filehandle ) {
        my $la = $self->lexer->peek( X_TERM );

        if( $la->[0] == T_COMMA ) {
            return _parse_cslist_rest( $self, $prec, $proto, $index, $term );
        } else {
            return ( _parse_arglist( $self, $prec, $proto, $index ), $term );
        }
    }

    return _parse_cslist_rest( $self, $prec, $proto, $index, $term );
}

sub _parse_cslist_rest {
    my( $self, $prec, $proto, $index, @terms ) = @_;

    for(; $proto->[1] != $index;) {
        my $comma = $self->lexer->lex( X_TERM );
        if( $comma->[0] == T_COMMA ) {
            my $term = _maybe_handle( _parse_term( $self, $prec ),
                                      $proto, $index );
            push @terms, $term;
            ++$index;
        } else {
            $self->lexer->unlex( $comma );
            last;
        }
    }

    return \@terms;
}

sub _maybe_handle {
    my( $term, $proto, $index ) = @_;

    return $term if !$term || !$term->is_bareword;
    return $term if $index + 2 > $#$proto || $proto->[$index + 2] ne '*';

    return Language::P::ParseTree::Symbol->new
               ( { name  => $term->value,
                   sigil => VALUE_GLOB,
                   } );
}

1;
