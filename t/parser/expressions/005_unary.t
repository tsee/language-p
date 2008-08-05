#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 6;

use lib 't/lib';
use TestParser qw(:all);

parse_and_diff_yaml( <<'EOP', <<'EOE' );
+12
EOP
--- !parsetree:UnOp
left: !parsetree:Number
  flags: NUM_INTEGER
  type: number
  value: 12
op: +
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
-12
EOP
--- !parsetree:UnOp
left: !parsetree:Number
  flags: NUM_INTEGER
  type: number
  value: 12
op: -
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
-( 1 )
EOP
--- !parsetree:UnOp
left: !parsetree:Number
  flags: NUM_INTEGER
  type: number
  value: 1
op: -
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
-$x
EOP
--- !parsetree:UnOp
left: !parsetree:Symbol
  name: x
  sigil: $
op: -
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
\1
EOP
--- !parsetree:UnOp
left: !parsetree:Number
  flags: NUM_INTEGER
  type: number
  value: 1
op: \
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
\$a
EOP
--- !parsetree:UnOp
left: !parsetree:Symbol
  name: a
  sigil: $
op: \
EOE
