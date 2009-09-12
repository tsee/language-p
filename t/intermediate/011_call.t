#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 1;

use lib qw(t/lib);
use TestIntermediate qw(:all);

generate_and_diff( <<'EOP', <<'EOI' );
sub foo {
    print "ok $_[0]\n";
}

foo( 1 );
EOP
# main
L1:
  scope_enter scope=0
  constant_integer value=1
  make_list count=1
  global name="foo", slot=4
  call context=2
  pop
  scope_leave scope=0
  end
# foo
L1:
  scope_enter scope=0
  global name="STDOUT", slot=7
  fresh_string value=""
  constant_string value="ok "
  concat_assign context=4
  constant_integer value=0
  lexical index=0, slot=2
  array_element create=0, context=4
  concat_assign context=4
  constant_string value="\x0a"
  concat_assign context=4
  make_list count=1
  print context=0
  make_list count=1
  return context=0
  scope_leave scope=0
  end
EOI
