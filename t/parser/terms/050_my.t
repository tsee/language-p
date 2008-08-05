#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 4;

use lib 't/lib';
use TestParser qw(:all);

parse_and_diff_yaml( <<'EOP', <<'EOE' );
my $foo;
EOP
--- !parsetree:LexicalDeclaration
declaration_type: my
name: foo
sigil: $
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
my $foo = 1;
EOP
--- !parsetree:BinOp
left: !parsetree:LexicalDeclaration
  declaration_type: my
  name: foo
  sigil: $
op: =
right: !parsetree:Number
  flags: NUM_INTEGER
  type: number
  value: 1
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
my( $foo, @bar ) = ( 1, 2, 3 );
EOP
--- !parsetree:BinOp
left: !parsetree:List
  expressions:
    - !parsetree:LexicalDeclaration
      declaration_type: my
      name: foo
      sigil: $
    - !parsetree:LexicalDeclaration
      declaration_type: my
      name: bar
      sigil: '@'
op: =
right: !parsetree:List
  expressions:
    - !parsetree:Number
      flags: NUM_INTEGER
      type: number
      value: 1
    - !parsetree:Number
      flags: NUM_INTEGER
      type: number
      value: 2
    - !parsetree:Number
      flags: NUM_INTEGER
      type: number
      value: 3
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
my( ${foo}, @{b}, $x );
EOP
--- !parsetree:List
expressions:
  - !parsetree:LexicalDeclaration
    declaration_type: my
    name: foo
    sigil: $
  - !parsetree:LexicalDeclaration
    declaration_type: my
    name: b
    sigil: '@'
  - !parsetree:LexicalDeclaration
    declaration_type: my
    name: x
    sigil: $
EOE
